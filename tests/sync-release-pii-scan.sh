#!/bin/bash
# Exercise the PII scan of bin/sync-release (--pii-scan mode) offline, against a
# throwaway denylist and small tar archives standing in for packages:
#   1. valid denylist, no hits: passes
#   2. valid denylist, a hit in a file's contents or in a file name: blocked
#   3. invalid regex in the denylist (an unmatched '('): fails closed, also on a clean
#      package, and names the line, never the entry
#   4. a hit allowed by build/pii-allow-packages: passes
# No network, no gh; workspace and data dir are temp dirs.
# Usage: tests/sync-release-pii-scan.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d)
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/ws/build" "$S/data" "$S/pkg/clean" "$S/pkg/hit" "$S/pkg/name/zorbleplex"
export OMARCHY_ASUS_WORKSPACE=$S/ws OMARCHY_ASUS_DATA=$S/data
unset PII_SCAN
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (exit $1, want $2)"; fail=1; fi; }
scan() { PII_DENYLIST=$1 "$W/bin/sync-release" --pii-scan "${@:2}" 2>&1; }

printf 'nothing to see here\n' >"$S/pkg/clean/README"
printf 'built by Zorbleplex on a laptop\n' >"$S/pkg/hit/README"
printf 'plain\n' >"$S/pkg/name/zorbleplex/README"
bsdtar -cf "$S/clean.tar" -C "$S/pkg/clean" .
bsdtar -cf "$S/hit.tar" -C "$S/pkg/hit" .
bsdtar -cf "$S/name.tar" -C "$S/pkg/name" .
printf '# test denylist\nzorbleplex\nquux-host\n' >"$S/good"
printf '# test denylist\nzorbleplex\nfoo(\n' >"$S/bad"

echo "== 1. valid denylist, no hits"
out=$(scan "$S/good" "$S/clean.tar"); expect $? 0 "clean package passes"

echo "== 2. valid denylist, hits"
out=$(scan "$S/good" "$S/hit.tar"); rc=$?
expect $rc 1 "hit in contents is blocked"
grep -q 'BLOCKED hit.tar: denylist line(s) 2$' <<<"$out"; expect $? 0 "names denylist line 2"
grep -qi zorbleplex <<<"$out"; expect $? 1 "does not print the entry"
out=$(scan "$S/good" "$S/name.tar"); expect $? 1 "hit in a file name is blocked"
out=$(scan "$S/good" "$S/clean.tar" "$S/hit.tar"); expect $? 1 "one hit among several files is blocked"

echo "== 3. invalid regex in the denylist"
out=$(scan "$S/bad" "$S/hit.tar"); expect $? 1 "invalid denylist fails with a hit present"
out=$(scan "$S/bad" "$S/clean.tar"); rc=$?
expect $rc 1 "invalid denylist fails on a clean package"
grep -q 'invalid regex (line(s) 3)' <<<"$out"; expect $? 0 "names the invalid line"
grep -q 'foo(' <<<"$out"; expect $? 1 "does not print the entry"

echo "== 4. allowed by build/pii-allow-packages"
printf '# test\nhit.tar\n' >"$S/ws/build/pii-allow-packages"
out=$(scan "$S/good" "$S/hit.tar"); expect $? 0 "allowed package passes"
out=$(scan "$S/bad" "$S/hit.tar"); expect $? 1 "allow list does not excuse an invalid denylist"
exit $fail
