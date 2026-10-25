#!/bin/bash
# ci/release-eligibility, offline: the real bin/auto-update-state plan on canned
# bin/check-upstream output (a stub in a throwaway repo), so each status gets the daily
# rebase's decision and the release build passes only build and current.
#   1. not-built, repo-stale, current, local: eligible
#   2. upstream-older, bad-pkgrel, not-upstream, dep-mismatch, held: fail (attention)
#   3. rebuild-needed: fail (rebase first)
#   4. an unreadable recipe (inventory_errors) or a check-upstream error: fail
#   5. the published db reaches check-upstream as the channel's local repo db
# Usage: tests/ci/release-eligibility.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0
check() {
    local name=$1; shift
    if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi
}

R=$S/repo
mkdir -p "$R/ci" "$R/bin" "$R/build"
cp "$W/ci/release-eligibility" "$R/ci/"; cp "$W/bin/auto-update-state" "$W/bin/env.sh" "$R/bin/"
printf 'published db\n' >"$S/db"
# bin/check-upstream stub: prints $FIXTURE, records where the local repo db was and what it held
cat >"$R/bin/check-upstream" <<'EOF'
#!/usr/bin/env python3
import os, subprocess, sys
repo_dir = subprocess.run(["bash", "-c", 'source "$1" && echo "$REPO_DIR"', "_",
                           os.path.join(os.path.dirname(os.path.realpath(__file__)), "env.sh")],
                          capture_output=True, text=True, check=True).stdout.strip()
with open(os.environ["STUB_LOG"], "w") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
    f.write(os.environ.get("OMARCHY_ASUS_CHANNEL", "") + "\n")
    f.write(open(os.path.join(repo_dir, "omarchy-asus.db")).read())
sys.stdout.write(open(os.environ["FIXTURE"]).read())
sys.exit(int(os.environ.get("STUB_EXIT", "10")))
EOF
chmod +x "$R/bin/check-upstream"

# row <recipe> <status> [hold]: one check-upstream JSON package row
row() {
    local hold=null; [[ -n ${3:-} ]] && hold="\"$3\""
    printf '{"name": "%s", "ours": "1-1.101", "base": "1-1", "repo": null, "local_only": false, "hold": %s, "upstream": "1-1", "upstream_repo": "extra", "recipe": "%s", "status": "%s", "dep_mismatch": []}' \
        "$1" "$hold" "$1" "$2"
}
fixture() { # inventory_errors JSON, then rows
    local inv=$1 rows; shift
    rows=$(IFS=,; echo "$*")
    printf '{"packages": [%s], "prs": [], "inventory_errors": %s, "action_needed": true, "upstream_dbs": [], "degraded": false, "expired": []}\n' \
        "$rows" "$inv" >"$S/fixture.json"
}
elig() {
    FIXTURE=$S/fixture.json STUB_LOG=$S/stub.log RELEASE_DB=$S/db RELEASE_ELIGIBILITY_SETUP=0 \
        "$R/ci/release-eligibility" --channel rc "$@" 2>&1
}

echo "== 1. eligible"
for st in not-built repo-stale current; do
    fixture '[]' "$(row a "$st")"
    out=$(elig a); rc=$?
    check "$st: passes" test "$rc" = 0
done
fixture '[]' "$(row a local)"
out=$(elig a); rc=$?
check "local (LOCAL_ONLY, published): passes" test "$rc" = 0
fixture '[]' "$(row a not-built)" "$(row b repo-stale)"
out=$(elig a b); rc=$?
check "two eligible recipes: passes" test "$rc" = 0

echo "== 2. attention fails"
for st in upstream-older bad-pkgrel not-upstream dep-mismatch; do
    fixture '[]' "$(row a "$st")"
    out=$(elig a); rc=$?
    check "$st: fails" test "$rc" = 1
    check "$st: says attention" grep -q '::error::a: attention' <<<"$out"
done
fixture '[]' "$(row a not-built "waits for a fix")"
out=$(elig a); rc=$?
check "held: fails" test "$rc" = 1
check "held: gives the reason" grep -q 'held, not built or published: waits for a fix' <<<"$out"
fixture '[]' "$(row a not-built)" "$(row b upstream-older)"
out=$(elig a b); rc=$?
check "one eligible, one not: fails" test "$rc" = 1

echo "== 3. rebuild-needed fails"
fixture '[]' "$(row a rebuild-needed)"
out=$(elig a); rc=$?
check "rebuild-needed: fails" test "$rc" = 1
check "rebuild-needed: says rebase it first" grep -q 'rebase it first' <<<"$out"

echo "== 4. unreadable recipe or check-upstream error"
fixture '["a"]' "$(row b not-built)"
out=$(elig a b); rc=$?
check "inventory error: fails" test "$rc" = 1
check "inventory error: names the recipe" grep -q 'printsrcinfo failed for: a' <<<"$out"
fixture '[]' "$(row a not-built)"
out=$(STUB_EXIT=1 elig a); rc=$?
check "check-upstream exit 1: fails" test "$rc" = 1

echo "== 5. what check-upstream was given"
fixture '[]' "$(row a not-built)"
elig a b >/dev/null
check "--json --no-prs and one --recipe per recipe" test "$(sed -n 1p "$S/stub.log")" = "--json --no-prs --recipe a --recipe b"
check "the channel" test "$(sed -n 2p "$S/stub.log")" = rc
check "the published db as the local repo db" test "$(sed -n 3p "$S/stub.log")" = "published db"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
