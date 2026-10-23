#!/bin/bash
# Exercise bin/auto-update without a chroot build or any publishing:
#   1. --plan and --dry-run against the current state
#   2. simulated Arch rebuild hyprland 0.56.2-5: rebase + makepkg --nobuild must pass
#   3. simulated 0.56.2-6 whose prepare() rewrites the lines our patch touches: the patch
#      must fail, the run must keep our hyprland+hyprpm published and exit 1
#   4. full-mode runs (PR, merge, publish) against stubs only: a local bare repo as the hub,
#      a fake gh, build, publish, unpublish, rebase-recipe, check-upstream and agent; no
#      network, nothing real is pushed, merged or published:
#      a. the base branch changes the recipe before the merge: nothing is published
#      b. the merged tree is the built one: published
#      c. the agent's notes and reply contain a denylisted word: not posted verbatim (the
#         reply goes to ai-review, never to GitHub; ai-review PII-scans its one final post)
#      d. the agent command fails: no absolute path in the PR comment or the status
#      e. the PII scan fails closed (missing denylist, scan error, unreadable body)
#      f. ai-review cannot run (codex missing): the PR is left open, nothing merged or published
#      g. the rebase commit carries a denylisted word: nothing pushed, no PR, class=pii
#      h. the fixer's edit carries a denylisted word: not pushed, not merged
#      Section 4 needs bubblewrap (recipe code runs in bin/recipe-sandbox); it is skipped
#      when bwrap cannot run.
# The fake upstream is a local clone of Arch's hyprland packaging with two extra tags;
# upstream versions are overridden with OMARCHY_ASUS_UPSTREAM_OVERRIDE. State goes to a
# temp dir; the real repo db is only read (through a symlink). Downloads the Hyprland
# source tarball once (into the temp dir's srcdest).
# Usage: tests/auto-update-simulate.sh [keep] [stubs]
#   keep: leave the temp dir for inspection; stubs: only section 4 (offline)
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d)
keep=0 only_stubs=0
for a in "$@"; do case $a in keep) keep=1 ;; stubs) only_stubs=1 ;; esac; done
if ((keep)); then echo "state: $S"; else trap 'rm -rf "$S"' EXIT; fi
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (exit $1, want $2)"; fail=1; fi; }

if ((!only_stubs)); then
real=${OMARCHY_ASUS_REAL_DATA:-$HOME/.local/share/omarchy-asus}
D=$S/data F=$S/fake-upstream
mkdir -p "$D/repo" "$F"
ln -s "$real/repo/x86_64" "$D/repo/x86_64"
export OMARCHY_ASUS_DATA=$D XDG_CONFIG_HOME=$S/no-config

echo "== 1. current state"
"$W/bin/auto-update" --plan --workspace "$W"; expect $? 0 "plan"
"$W/bin/auto-update" --dry-run --workspace "$W"; expect $? 0 "dry-run"

git clone --quiet --bare https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland.git "$F/hyprland.git"
git clone --quiet "$F/hyprland.git" "$F/work"
(
    cd "$F/work" || exit 1
    g() { git -c user.name=sim -c user.email=sim@invalid "$@"; }
    git checkout --quiet 0.56.2-4
    sed -i 's/^pkgrel=4$/pkgrel=5/' PKGBUILD
    g commit --quiet -am "upgpkg: 0.56.2-5 (simulated)"; git tag 0.56.2-5
    sed -i 's/^pkgrel=5$/pkgrel=6/' PKGBUILD
    sed -i '/find_package.glaze/a\	sed -i "s/AQ_SCHEDULE_NEW_MONITOR/AQ_SCHEDULE_NEW_OUTPUT/g" src/output/Monitor.cpp' PKGBUILD
    g commit --quiet -am "upgpkg: 0.56.2-6 (simulated)"; git tag 0.56.2-6
    git push --quiet --tags origin HEAD:refs/heads/sim
)
export OMARCHY_ASUS_ARCH_GIT_URL="file://$F/{pkgbase}.git"

echo "== 2. upstream hyprland 0.56.2-5"
OMARCHY_ASUS_UPSTREAM_OVERRIDE=hyprland=0.56.2-5,hyprpm=0.56.2-5 \
    "$W/bin/auto-update" --dry-run --workspace "$W" --recipe hyprland
expect $? 0 "pkgrel bump rebases and passes makepkg --nobuild"
cat "$(ls -dt "$D"/auto-update/runs/*/ | head -1)/hyprland.diff"

echo "== 3. upstream hyprland 0.56.2-6 (patch no longer applies)"
out=$(OMARCHY_ASUS_UPSTREAM_OVERRIDE=hyprland=0.56.2-6,hyprpm=0.56.2-6 \
    "$W/bin/auto-update" --dry-run --workspace "$W" --recipe hyprland 2>&1)
rc=$?
echo "$out" | grep -E '^\[|^\| hyprland|auto-update:'
expect $rc 1 "failed rebase fails the run"
grep -q 'would unpublish' <<<"$out"; expect $? 1 "a failed rebase withdraws nothing (never stock over our patch)"
unset OMARCHY_ASUS_ARCH_GIT_URL
fi

# ---------------------------------------------------------------- 4. stubbed full runs
# A copy of bin/ in which every step that builds, signs, publishes or calls a network is a
# stub that logs its call to $T/calls. bin/sync-release --pii-scan(-text) stays the real one.
if ! bwrap --ro-bind / / true >/dev/null 2>&1; then
    echo "skip: section 4 needs bubblewrap (bwrap) with unprivileged user namespaces"
    exit $fail
fi
stub_case() {  # stub_case <name> <base changes the recipe: 0|1> <agent: approve|pii|pii-edit|fail> [review: off|nocodex] [rebase: clean|pii]
    local name=$1 race=$2 agent=$3 review=${4:-off}
    T=$S/stub-$name
    local L=$T/lib B=$T/bin
    mkdir -p "$L" "$B" "$T/posted" "$T/cfg/omarchy-asus"
    cp -a "$W/bin/." "$L/"
    local ai_review=off
    if [[ $review == nocodex ]]; then
        # ai-review without codex: what the real bin/ai-review does when codex is not on PATH
        # (no --json file, exit 1). AI_REVIEW=required makes auto-update depend on it.
        ai_review=required
        cat >"$L/ai-review" <<'EOF'
#!/bin/bash
echo "ai-review $*" >>"$T/calls"
echo "ai-review: codex not found on PATH: install it and run codex login; no review was made, so the gate stays closed" >&2
exit 1
EOF
        chmod +x "$L/ai-review"
    fi
    mv "$L/sync-release" "$L/sync-release.real"
    : >"$T/calls"
    STUB_REBASE=${5:-clean}
    export T STUB_REBASE
    for s in build-pkg publish unpublish rebase-recipe check-upstream sync-release; do
        cat >"$L/$s" <<'EOF'
#!/bin/bash
set -eu
me=$(basename "$0")
case $me in
    sync-release) [[ ${1:-} == --pii-scan* ]] && exec "$(dirname "$0")/sync-release.real" "$@" ;;
esac
echo "$me $*" >>"$T/calls"
case $me in
    build-pkg)
        source "$(dirname "$0")/env.sh"
        mkdir -p "$STAGE_DIR"; echo built >"$STAGE_DIR/fake-1.0-2.1-x86_64.pkg.tar.zst"; echo "build ok" ;;
    rebase-recipe)   # rebase-recipe fake --version V --out OUT --force --verify --report REPORT
        out= report=; while (($#)); do case $1 in --out) out=$2 ;; --report) report=$2 ;; esac; shift; done
        cp -a "$OMARCHY_ASUS_WORKSPACE/recipes/fake" "$out"
        sed -i 's/^pkgrel=.*/pkgrel=2.1/' "$out/PKGBUILD"
        [[ ${STUB_REBASE:-clean} != pii ]] || echo 'built on zorblaxhost' >>"$out/NOTES.md"
        cat >"$report" <<'J'
{"from": "1.0-1.1", "to": "1.0-2.1", "fuzz": false, "flags": [], "verify_offset_hunks": 0,
 "upstream_source": {"url": "file:///nowhere", "ref": "1.0-2"}, "files_added": [], "files_removed": [], "patches": []}
J
        ;;
    check-upstream)
        if [[ " $* " == *" --recipe-path "* ]]; then echo '{"packages": [], "prs": []}'
        else echo '{"packages": [{"name": "fake", "ours": "1.0-1.1", "base": "1.0-1", "repo": "1.0-1.1",
            "upstream": "1.0-2", "upstream_repo": "extra", "recipe": "fake", "status": "rebuild-needed",
            "dep_mismatch": []}], "prs": []}'; fi ;;
esac
EOF
        chmod +x "$L/$s"
    done
    # The agent: approves; approves with a denylisted word in its notes and reply; approves
    # after an edit (in its cwd, the clone) that carries a denylisted word; or fails.
    cat >"$B/agent" <<EOF
#!/bin/bash
cat >/dev/null
case $agent in
    fail) exit 1 ;;
    pii-edit)
        echo 'fixed on zorblaxhost' >>recipes/fake/NOTES.md
        echo '{"result": "{\"verdict\": \"approve\", \"notes\": \"mechanical bump\", \"replies\": [{\"id\": 101, \"reply\": \"noted\"}]}"}' ;;
    pii) echo '{"result": "{\"verdict\": \"approve\", \"notes\": \"built fine on zorblaxhost\", \"replies\": [{\"id\": 101, \"reply\": \"#mtree checked on zorblaxhost\"}]}"}' ;;
    *) echo '{"result": "{\"verdict\": \"approve\", \"notes\": \"mechanical bump\", \"replies\": [{\"id\": 101, \"reply\": \"no change needed\"}]}"}' ;;
esac
EOF
    # gh: PR list/create/comment/merge/view and review replies; the merge is a squash merge
    # in the local hub repo, after a commit to the recipe on the base branch when $race=1.
    cat >"$B/gh" <<EOF
#!/bin/bash
set -eu
echo "gh \$*" >>"$T/calls"
hub=$T/hub.git
g() { git -c user.name=sim -c user.email=sim@invalid "\$@"; }
case "\$1 \$2" in
    "pr list") echo "" ;;
    "pr create") echo "https://github.com/example/example/pull/7" ;;
    "pr comment") while ((\$#)); do [[ \$1 == --body-file ]] && cp "\$2" "$T/posted/comment.md"; shift; done ;;
    "pr view") cat "$T/merge-sha" ;;
    "pr merge")
        git clone --quiet "\$hub" "$T/merge"; cd "$T/merge"
        if [[ $race == 1 ]]; then
            echo "base branch edit while the PR was built" >>recipes/fake/NOTES.md
            g commit --quiet -am "fake: notes (on main meanwhile)"
        fi
        git fetch --quiet origin auto-update/fake
        git merge --quiet --squash FETCH_HEAD >/dev/null; g commit --quiet -m "fake: squash-merged PR"
        git push --quiet origin HEAD:main; git push --quiet origin :auto-update/fake
        git rev-parse HEAD >"$T/merge-sha" ;;
    "api -X")
        while ((\$#)); do [[ \$1 == -f && \$2 == body=* ]] && printf '%s\n' "\${2#body=}" >>"$T/posted/replies"; shift; done ;;
    *) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
EOF
    chmod +x "$B/agent" "$B/gh"
    # The hub: a bare repo with one recipe on main.
    git init --quiet --bare -b main "$T/hub.git"
    git clone --quiet "$T/hub.git" "$T/seed" 2>/dev/null
    mkdir -p "$T/seed/recipes/fake"
    printf 'pkgname=fake\npkgver=1.0\npkgrel=1.1\narch=(x86_64)\n' >"$T/seed/recipes/fake/PKGBUILD"
    echo "# no delta" >"$T/seed/recipes/fake/DELTA"
    echo "# fake" >"$T/seed/recipes/fake/NOTES.md"
    (cd "$T/seed" && git add -A && git -c user.name=sim -c user.email=sim@invalid commit --quiet -m seed &&
        git push --quiet origin HEAD:main)
    printf 'zorblaxhost\n' >"$T/denylist"
    cat >"$T/cfg/omarchy-asus/auto-update.conf" <<EOF
GIT_URL=$T/hub.git
EXTRA_PATH=$B
AI_REVIEW=$ai_review
REVIEW_CMD=$B/agent
MERGE_MODE=auto
EOF
    mkdir -p "$T/data"
    # EXTRA_PATH (above) puts the stubs first on the build user's PATH. Should a real gh be
    # reached anyway, it has no config and no token: it cannot touch GitHub.
    mkdir -p "$T/no-gh"
    GH_CONFIG_DIR=$T/no-gh GH_TOKEN='' GITHUB_TOKEN='' \
        OMARCHY_ASUS_DATA=$T/data XDG_CONFIG_HOME=$T/cfg PII_DENYLIST=$T/denylist \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_AUTHOR_NAME=sim GIT_AUTHOR_EMAIL=sim@invalid GIT_COMMITTER_NAME=sim GIT_COMMITTER_EMAIL=sim@invalid \
        "$L/auto-update" --recipe fake >"$T/out" 2>&1
    rc=$?
    grep -E '^\[|auto-update:' "$T/out"
}
last() {  # last <key>: that field of fake's last status entry
    jq -r --arg k "$1" '.recipes.fake.last[$k] // ""' "$T/data/status.json"
}

echo "== 4a. the base branch changes the recipe before the merge"
stub_case race 1 approve
expect $rc 1 "a merged tree that was not built fails the run"
grep -q '^publish ' "$T/calls"; expect $? 1 "merged tree differs from the built one: nothing published"
grep -q '^gh pr merge ' "$T/calls"; expect $? 0 "the PR was merged"
expect "$(last class)" merge-mismatch "status records the mismatch"
grep -q '^unpublish fake' "$T/calls"; expect $? 1 "our last build stays published (never stock over our patch)"
stat -- "$T/data/stage/.built-fake" >/dev/null 2>&1; expect $? 1 "no built-tree marker: the next run rebuilds from main"

echo "== 4b. the merged tree is the built one"
stub_case same 0 approve
expect $rc 0 "clean run"
grep -q '^publish .*fake-1.0-2.1' "$T/calls"; expect $? 0 "published"
expect "$(last message)" "merged and published" "status says published"
stat -- "$T/posted/replies" >/dev/null 2>&1; expect $? 1 "no reply goes to GitHub during the rounds"
grep -qs 'no change needed (auto-update agent)' "$T"/data/auto-update/runs/*/fake.replies.json
expect $? 0 "the fixer's answer goes to the reviewer (ai-review --reply)"

echo "== 4c. the agent's notes and reply contain a denylisted word"
stub_case pii 0 pii
grep -qi zorblaxhost "$T/posted/comment.md"; expect $? 1 "the PR comment does not carry the denylisted word"
grep -q "the agent's notes withheld: failed the PII scan, see run" "$T/posted/comment.md"; expect $? 0 "a placeholder replaces the notes"
stat -- "$T/posted/replies" >/dev/null 2>&1; expect $? 1 "the reply is not posted (it goes to the reviewer; ai-review scans its final post)"
grep -q '^\[pii\] ' "$T/out"; expect $? 0 "the withheld bodies are logged"

echo "== 4d. the agent command fails"
stub_case agentfail 0 fail
grep -q 'agent command failed or timed out (see run [0-9-]*: fake.agent.json)' "$T/posted/comment.md"
expect $? 0 "the failure names the run file by run id"
grep -qE "(^|[^[:alnum:]])/(home|tmp|root|var)/|$T" "$T/posted/comment.md"; expect $? 1 "no absolute path in the PR comment"
grep -qF "$T" "$T/data/status.json"; expect $? 1 "no absolute path in status.json"

echo "== 4f. codex is missing: ai-review cannot review, so the PR waits"
stub_case nocodex 0 approve nocodex
grep -q '^ai-review pr ' "$T/calls"; expect $? 0 "ai-review was asked to review the head"
grep -q '^gh pr merge ' "$T/calls"; expect $? 1 "not merged without a review"
grep -q '^publish ' "$T/calls"; expect $? 1 "nothing published without a review"
expect "$(last result)" attention "status: the PR only needs attention"
expect "$(last class)" "" "no failure class"
last message | grep -q 'ai-review has not reviewed the head'; expect $? 0 "status names the missing review"
grep -q 'ai-review has not reviewed the head' "$T/posted/comment.md"; expect $? 0 "the PR comment names the missing review"

echo "== 4e. the PII scan fails closed"
printf 'hello\n' >"$T/text.md"
PII_DENYLIST=$T/denylist "$W/bin/sync-release" --pii-scan-text "$T/text.md" >/dev/null 2>&1; expect $? 0 "clean text passes"
printf 'Zorblaxhost was here\n' >"$T/text.md"
PII_DENYLIST=$T/denylist "$W/bin/sync-release" --pii-scan-text "$T/text.md" >/dev/null 2>&1; expect $? 1 "a denylisted word in text is a hit"
printf 'hello\n' >"$T/text.md"
PII_DENYLIST=$T/no-such-list "$W/bin/sync-release" --pii-scan-text "$T/text.md" >/dev/null 2>&1; expect $? 1 "a missing denylist is a hit"
printf 'a(b\n' >"$T/bad-denylist"
PII_DENYLIST=$T/bad-denylist "$W/bin/sync-release" --pii-scan-text "$T/text.md" >/dev/null 2>&1; expect $? 1 "a scan error (grep exit 2) is a hit"
PII_DENYLIST=$T/denylist "$W/bin/sync-release" --pii-scan-text "$T/no-such-file.md" >/dev/null 2>&1; expect $? 1 "an unreadable body is a hit"
printf '#mtree\n# built on zorblaxhost\n' >"$T/text.md"   # bsdtar would read this as an archive
PII_DENYLIST=$T/denylist "$W/bin/sync-release" --pii-scan-text "$T/text.md" >/dev/null 2>&1; expect $? 1 "text that looks like an mtree archive is still scanned as text"

echo "== 4g. the rebase commit carries a denylisted word"
stub_case piirebase 0 approve off pii
expect $rc 1 "a rebase commit that fails the PII scan fails the run"
git -C "$T/hub.git" rev-parse --verify -q refs/heads/auto-update/fake >/dev/null; expect $? 1 "nothing is pushed"
grep -q '^gh pr create' "$T/calls"; expect $? 1 "no PR is opened"
expect "$(last class)" pii "status records class=pii"
grep -q '^unpublish fake' "$T/calls"; expect $? 1 "our last build stays published (never stock over our patch)"
grep -q '^\[pii\] ' "$T/out"; expect $? 0 "the scan hit is logged"

echo "== 4h. the fixer's edit carries a denylisted word"
stub_case piifix 0 pii-edit
git -C "$T/hub.git" show main:recipes/fake/NOTES.md 2>/dev/null | grep -qi zorblaxhost
expect $? 1 "the fixer's edit is neither pushed nor merged"
git -C "$T/hub.git" log --all --format=%B 2>/dev/null | grep -q 'auto-update fixer'
expect $? 1 "no fixer commit reached the hub"
grep -q '^gh pr merge ' "$T/calls"; expect $? 1 "a PR whose fixer edits were withheld is not auto-merged"
grep -q '^\[pii\] ' "$T/out"; expect $? 0 "the scan hit is logged"
exit $fail
