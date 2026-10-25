#!/bin/bash
# Exercise bin/release-train (#212) offline: a fake gh whose issues are files, recipes read
# through a stub sandbox, a git workspace with a bare origin for the tag push:
#   a. the first update opens the train issue: every package on the release with its version,
#      recipe (a -debug package goes with its recipe), status and the recipe's last issue and
#      PR; what waits (not built, behind its version, held); the recipes commit is recorded
#   b. the next update edits the same issue, also once the remembered number is gone
#   c. a withheld update lists the regression, and the package is blocked in Waiting
#   d. --dry-run posts nothing
#   e. a PII hit in the body posts nothing (exit 1)
#   f. notes come from the issue: On the release and Changes, never Waiting or Withheld
#   g. cut: --dry-run changes nothing; cut tags the recorded commit train/<tag>/NAME, pushes
#      it, comments and closes the issue; the next update opens a new train whose Changes
#      list the recipe commits since that tag; a second cut of the same name is refused
#   g also stops a cut at the push, the comment and the close: the issue is marked, an update
#      leaves it alone, another name is refused, and rerunning the cut finishes it (one comment)
#   h. updates run one at a time under the publication lock (three at once open one issue; a
#      held lock is exit 75 for update and cut); a control character in the body posts nothing
#   i. bin/sync-release's failure to update the issue is a warning, not a failed sync (the
#      sync-release transaction test runs with a gh that knows no issues)
# No network, no real gh, no makepkg; workspace and data dir are temp dirs.
# Usage: tests/ci/release-train.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
for t in bsdtar git python3; do
    command -v "$t" >/dev/null && continue
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
S=$(mktemp -d)
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
L=$S/lib
mkdir -p "$L" "$S/bin" "$S/issues" "$S/data" "$S/k"
cp "$W/bin/release-train" "$W/bin/sync-release" "$W/bin/env.sh" "$W/bin/publish-lib.sh" "$W/bin/check-upstream" "$L/"
cat >"$L/recipe-sandbox" <<'STUB'
#!/bin/bash
dir=.
while (($#)) && [[ $1 != -- ]]; do [[ $1 == --chdir ]] && { dir=$2; shift; }; shift; done
shift; cd "$dir" && exec "$@"
STUB
cat >"$S/bin/makepkg" <<'STUB'
#!/bin/bash
[[ $* == --printsrcinfo && -f SRCINFO ]] || exit 1
cat SRCINFO
STUB
# A fake gh: issue N is $FAKE_ISSUES/N.{title,body,state,comments} (comments: one JSON string
# per line); every call is logged; FAKE_FAIL=<subcommand> makes that issue subcommand fail.
cat >"$S/bin/gh" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_ISSUES"]
a = sys.argv[1:]
if len(a) > 1 and a[1] == os.environ.get("FAKE_FAIL"):
    sys.exit("fake gh: failing " + a[1])
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(" ".join(a[:3]) + "\n")
def opt(name):
    return a[a.index(name) + 1] if name in a else None
def read(n, k):
    with open(f"{d}/{n}.{k}") as f:
        return f.read()
def write(n, k, v):
    with open(f"{d}/{n}.{k}", "w") as f:
        f.write(v)
nums = sorted(int(x.split(".")[0]) for x in os.listdir(d) if x.endswith(".state"))
if a[:2] == ["issue", "list"]:
    print(json.dumps([{"number": n, "title": read(n, "title"), "body": read(n, "body")}
                      for n in nums if read(n, "state") == "OPEN"]))
elif a[:2] == ["issue", "view"]:
    n = int(a[2])
    if n not in nums:
        sys.exit("no such issue")
    cs = read(n, "comments").splitlines() if os.path.exists(f"{d}/{n}.comments") else []
    print(json.dumps({"number": n, "state": read(n, "state"), "body": read(n, "body"),
                      "comments": [{"body": json.loads(c)} for c in cs]}))
elif a[:2] == ["issue", "create"]:
    n = (nums[-1] if nums else 0) + 1
    write(n, "title", opt("--title")); write(n, "body", open(opt("--body-file")).read()); write(n, "state", "OPEN")
    print(f"https://github.com/omarchy-asus/omarchy-asus/issues/{n}")
elif a[:2] == ["issue", "edit"]:
    write(int(a[2]), "body", open(opt("--body-file")).read())
elif a[:2] == ["issue", "comment"]:
    with open(f"{d}/{a[2]}.comments", "a") as f:
        f.write(json.dumps(open(opt("--body-file")).read()) + "\n")
elif a[:2] == ["issue", "close"]:
    write(int(a[2]), "state", "CLOSED")
else:
    sys.exit("fake gh: unsupported: " + " ".join(a))
EOF
chmod +x "$L"/* "$S/bin"/*
printf '# test denylist\nzorbleplex\n' >"$S/denylist"
unset BASH_ENV ENV GH_TOKEN GITHUB_TOKEN OMARCHY_ASUS_CHANNEL PII_SCAN RELEASE_TRAIN
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data PII_DENYLIST=$S/denylist \
    FAKE_ISSUES=$S/issues FAKE_LOG=$S/gh.log PATH=$S/bin:$PATH GH_CONFIG_DIR=$S/no-gh GH_HOST=fake-gh.invalid \
    GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
[[ $(bash -c 'command -v gh') == "$S/bin/gh" ]] || { echo "FAIL: the fake gh does not win on PATH"; exit 1; }

fail=0 out=''
check() {  # check <description> <command...>: the command must succeed
    local d=$1; shift
    if "$@"; then echo "ok: $d"; else echo "FAIL: $d"; sed 's/^/    | /' <<<"$out"; fail=1; fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
train() { "$L/release-train" "$@" 2>&1; }

recipe() {  # recipe <dir> <pkgver-pkgrel> <pkgname>
    local d=$S/ws/recipes/$1
    mkdir -p "$d"; : >"$d/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n\npkgname = %s\n' "$1" "${2%-*}" "${2##*-}" "$3" >"$d/SRCINFO"
}
mkdb() {  # mkdb <db> <name>-<pkgver>-<pkgrel>...
    local out=$1 e n v; shift
    rm -rf "$S/k"; mkdir -p "$S/k"
    for e; do
        n=${e%-*-*} v=${e#"$n"-}
        mkdir -p "$S/k/$e"
        printf '%%FILENAME%%\n%s-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' "$e" "$n" "$v" >"$S/k/$e/desc"
    done
    (cd "$S/k" && bsdtar -czf "$out" --format=ustar ./*)
}
commit() { git -C "$S/ws" add -A && git -C "$S/ws" commit -qm "$1" -m "${2:-}"; }

git init -q --bare "$S/origin.git"
git init -q -b main "$S/ws"
git -C "$S/ws" remote add origin "$S/origin.git"
mkdir -p "$S/ws/build"
recipe foo 1.0-1.1 foo; commit "foo 1.0-1.1: the fix (#5) (#7)" "Refs #9"
recipe bar 2.0-1.2 bar; commit "bar 2.0-1.2 (#8)"
recipe baz 3.0-1.1 baz; echo "waits for the G16" >"$S/ws/recipes/baz/HOLD"; commit "baz: hold (#10)"
recipe new 0.1-1 new; touch "$S/ws/recipes/new/LOCAL_ONLY"; commit "new: a new package"
head=$(git -C "$S/ws" rev-parse HEAD)
# the release: foo ready, bar behind (2.0-1.1), baz held but published, gone (no recipe)
mkdb "$S/db1" foo-1.0-1.1 foo-debug-1.0-1.1 bar-2.0-1.1 baz-3.0-1.0 gone-1-1

echo "== a. the first update opens the issue"
out=$(train update --db "$S/db1"); rc=$?
B=$S/issues/1.body
check "exit 0" [ $rc = 0 ]
check "issue #1 opened, open" has "$S/issues/1.state" OPEN
check "title names the release" has "$S/issues/1.title" "Release train: x86_64 (Quattro channel)"
check "marker first" has <(head -1 "$B") "<!-- release-train:x86_64 -->"
check "commit recorded" has "$B" "<!-- release-train-commit:$head -->"
check "foo ready with its issue and PR" has "$B" "| foo | 1.0-1.1 | foo | ready | #5, #9 | #7 |"
check "bar: our last build, recipe waits" has "$B" "| bar | 2.0-1.1 | bar | our last build; recipe at 2.0-1.2 waits | - | #8 |"
check "baz held, stays" has "$B" "| baz | 3.0-1.0 | baz | held (waits for the G16); our last build stays | - | #10 |"
check "foo-debug goes with foo" has "$B" "| foo-debug | 1.0-1.1 | foo | ready | #5, #9 | #7 |"
check "gone has no recipe" has "$B" "| gone | 1-1 | - | no recipe: withdrawn by the next unpublish | - | - |"
check "waiting: bar behind" has "$B" "| bar | bar | 2.0-1.1 | 2.0-1.2 | behind its version: not built yet | - | #8 |"
check "waiting: baz held" has "$B" "| baz | baz | 3.0-1.0 | 3.0-1.1 | held: waits for the G16 |"
check "waiting: new not built" has "$B" "| new | new | - | 0.1-1 | not built yet | - | - |"
check "no cut yet" has "$B" "No train has been cut on this release yet"
check "no Withheld section" hasnt "$B" "## Withheld"
check "number remembered" has "$S/data/release-train-issue" 1

echo "== b. the next update edits the same issue"
mkdb "$S/db2" foo-1.0-1.1 bar-2.0-1.2 baz-3.0-1.0 gone-1-1
out=$(train update --db "$S/db2"); rc=$?
check "exit 0, #1 updated" [ $rc = 0 ]
check "bar now ready" has "$B" "| bar | 2.0-1.2 | bar | ready | - | #8 |"
check "no second issue" [ ! -e "$S/issues/2.state" ]
rm -f "$S/data/release-train-issue"
out=$(train update --db "$S/db2"); rc=$?
check "found again without the remembered number" [ $rc = 0 ]
check "still no second issue" [ ! -e "$S/issues/2.state" ]

echo "== c. a withheld update"
printf 'regression bar (recipes/bar)\n' >"$S/gaps"
out=$(train update --db "$S/db1" --withheld "$S/gaps"); rc=$?
check "exit 0" [ $rc = 0 ]
check "Withheld section" has "$B" "## Withheld"
check "the regression line" has "$B" '- `regression bar (recipes/bar)`'
check "last sync says withheld" has "$B" "withheld (a regression)"
check "bar blocked in Waiting" has "$B" "blocked by a regression: regression bar (recipes/bar)"

echo "== d. --dry-run posts nothing"
cp "$B" "$S/before"
out=$(train update --db "$S/db2" --dry-run); rc=$?
check "exit 0" [ $rc = 0 ]
check "says what it would do" has <(echo "$out") "would update #1"
check "issue unchanged" cmp -s "$B" "$S/before"

echo "== e. a PII hit posts nothing"
echo "zorbleplex" >"$S/ws/recipes/baz/HOLD"
out=$(train update --db "$S/db2"); rc=$?
check "exit 1" [ $rc = 1 ]
check "issue unchanged" cmp -s "$B" "$S/before"
git -C "$S/ws" checkout -q -- recipes/baz/HOLD

echo "== f. notes come from the issue"
out=$(train update --db "$S/db2") || true
out=$(train notes); rc=$?
check "exit 0" [ $rc = 0 ]
check "On the release" has <(echo "$out") "## On the release"
check "Last sync" has <(echo "$out") "**Last sync:**"
check "no Waiting" hasnt <(echo "$out") "## Waiting"
check "no markers" hasnt <(echo "$out") "<!--"

echo "== g. cut"
out=$(train cut 2026-10-25 --dry-run); rc=$?
check "dry run: exit 0" [ $rc = 0 ]
check "dry run: no tag" [ -z "$(git -C "$S/ws" tag)" ]
check "dry run: issue open" has "$S/issues/1.state" OPEN
# stop the cut at each step in turn, then resume it with the same name
mv "$S/origin.git" "$S/origin.off"
out=$(train cut 2026-10-25); rc=$?
check "push fails: exit 1" [ $rc = 1 ]
check "push fails: the issue says the cut is under way" has "$B" "<!-- release-train-cutting:train/x86_64/2026-10-25 -->"
check "push fails: issue still open" has "$S/issues/1.state" OPEN
cp "$B" "$S/before"
out=$(train update --db "$S/db1"); rc=$?
check "an update leaves a cut under way alone" [ $rc = 1 ]
check "and the notes unchanged" cmp -s "$B" "$S/before"
out=$(train cut other); rc=$?
check "a cut under another name is refused" [ $rc = 1 ]
mv "$S/origin.off" "$S/origin.git"
out=$(FAKE_FAIL=comment train cut 2026-10-25); rc=$?
check "comment fails: exit 1" [ $rc = 1 ]
check "comment fails: tag pushed" [ -n "$(git -C "$S/origin.git" rev-parse -q --verify refs/tags/train/x86_64/2026-10-25)" ]
out=$(FAKE_FAIL=close train cut 2026-10-25); rc=$?
check "close fails: exit 1" [ $rc = 1 ]
check "close fails: issue open" has "$S/issues/1.state" OPEN
out=$(train cut 2026-10-25); rc=$?
check "cut: exit 0" [ $rc = 0 ]
check "tag at the recorded commit" [ "$(git -C "$S/ws" rev-parse 'train/x86_64/2026-10-25^{commit}')" = "$head" ]
check "tag pushed" [ -n "$(git -C "$S/origin.git" rev-parse -q --verify refs/tags/train/x86_64/2026-10-25)" ]
check "tag message is the notes" has <(git -C "$S/ws" tag -n99 train/x86_64/2026-10-25) "| foo | 1.0-1.1 | foo | ready |"
check "issue commented once" [ "$(grep -c 'Cut as `train/x86_64/2026-10-25`' "$S/issues/1.comments")" = 1 ]
check "issue closed" has "$S/issues/1.state" CLOSED
recipe bar 2.0-1.3 bar; commit "bar 2.0-1.3: another fix (#12) (#13)"
out=$(train update --db "$S/db2"); rc=$?
check "next update opens #2" has "$S/issues/2.state" OPEN
check "changes since the cut" has "$S/issues/2.body" "## Changes since train/x86_64/2026-10-25"
check "the new commit listed" has "$S/issues/2.body" "bar 2.0-1.3: another fix (#12) (#13)"
check "an older commit not listed" hasnt "$S/issues/2.body" "foo 1.0-1.1: the fix"
out=$(train cut 2026-10-25); rc=$?
check "the same name again is refused" [ $rc = 1 ]


echo "== h. one at a time, and no control characters"
rm -f "$S/data/release-train-issue"
mv "$S/issues" "$S/issues.g"; mkdir "$S/issues"
for _ in 1 2 3; do train update --db "$S/db2" >/dev/null & done; wait
check "three updates at once open one issue" [ "$(find "$S/issues" -name '*.state' | wc -l)" = 1 ]
B=$S/issues/1.body; cp "$B" "$S/before"
exec {lk}>"$S/data/publish.lock"; flock "$lk"
out=$(PUBLISH_LOCK_WAIT=1 train update --db "$S/db1"); rc=$?
check "update with the lock held elsewhere: exit 75" [ $rc = 75 ]
check "issue unchanged" cmp -s "$B" "$S/before"
out=$(PUBLISH_LOCK_WAIT=1 train cut x); rc=$?
check "cut with the lock held elsewhere: exit 75" [ $rc = 75 ]
out=$(OMARCHY_ASUS_PUBLISH_LOCKED=1 train update --db "$S/db1"); rc=$?
check "under its parent's lock (bin/sync-release) it runs" [ $rc = 0 ]
exec {lk}>&-
cp "$B" "$S/before"
printf 'waits \033[31m\n' >"$S/ws/recipes/baz/HOLD"
out=$(train update --db "$S/db2"); rc=$?
check "a control character: exit 1" [ $rc = 1 ]
check "nothing posted" cmp -s "$B" "$S/before"
check "says why" has <(echo "$out") "control characters"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
