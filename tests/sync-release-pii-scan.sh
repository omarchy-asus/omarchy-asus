#!/bin/bash
# Exercise the PII scan of bin/sync-release (--pii-scan mode) offline, against a
# throwaway denylist and small tar archives standing in for packages:
#   1. valid denylist, no hits: passes
#   2. valid denylist, a hit in a file's contents or in a file name: blocked
#   3. invalid regex in the denylist (an unmatched '('): fails closed, also on a clean
#      package, and names the line, never the entry
#   4. build/pii-allow-packages rules ('<asset glob> <location glob>'): a known hit at
#      an allowed location passes; a different denylisted hit in the same package, the
#      known word in another member, another line of a files-db list, or a hit the
#      located pass cannot place is blocked
#   5. a malformed rule (a bare asset glob) fails closed
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

echo "== 4. allowed by build/pii-allow-packages, scoped to locations"
# A stand-in kernel package: the known hit is a module name and its line in
# modules.order. kern-pkginfo.tar is the same package with a different denylisted
# word in .PKGINFO; kern-elsewhere.tar has the known word in another member.
K=$S/pkg/kern/usr/lib/modules/1.0
mkdir -p "$K/kernel/drivers/hid" "$K/build"
printf 'module\n' >"$K/kernel/drivers/hid/hid-zorbleplex.ko"
printf 'kernel/drivers/hid/hid-zorbleplex.ko\nkernel/drivers/hid/hid-generic.ko\n' >"$K/modules.order"
printf 'pkgname = kern\n' >"$S/pkg/kern/.PKGINFO"
bsdtar -cf "$S/kern.tar" -C "$S/pkg/kern" .
cp -a "$S/pkg/kern" "$S/pkg/kern2"; printf 'pkgname = kern\npackager = quux-host\n' >"$S/pkg/kern2/.PKGINFO"
bsdtar -cf "$S/kern-pkginfo.tar" -C "$S/pkg/kern2" .
cp -a "$S/pkg/kern" "$S/pkg/kern3"; printf 'see zorbleplex\n' >"$S/pkg/kern3/usr/lib/modules/1.0/build/NOTES"
bsdtar -cf "$S/kern-elsewhere.tar" -C "$S/pkg/kern3" .
# A stand-in files db: the kernel's file list is allowed only on its module line.
mkdir -p "$S/pkg/db/kern-1.0" "$S/pkg/db2/kern-1.0"
printf '%%FILES%%\nusr/lib/modules/1.0/kernel/drivers/hid/hid-zorbleplex.ko\n' >"$S/pkg/db/kern-1.0/files"
printf '%%FILES%%\nusr/lib/modules/1.0/kernel/drivers/hid/hid-zorbleplex.ko\nusr/share/doc/quux-host/x\n' \
    >"$S/pkg/db2/kern-1.0/files"
bsdtar -czf "$S/db.files" -C "$S/pkg/db" .
bsdtar -czf "$S/db2.files" -C "$S/pkg/db2" .
# A hit split across two members: the first pass sees it, the located pass cannot place it.
mkdir -p "$S/pkg/span"; printf 'abc zorble' >"$S/pkg/span/a"; printf 'plex def\n' >"$S/pkg/span/b"
bsdtar -cf "$S/span.tar" -C "$S/pkg/span" a b
cat >"$S/ws/build/pii-allow-packages" <<'EOF'
# test rules
kern*.tar  usr/lib/modules/*/kernel/drivers/hid/*
kern*.tar  usr/lib/modules/*/modules.order:*   # trailing comment
db*.files  kern-*/files:usr/lib/modules/*/kernel/drivers/hid/*
span.tar   *
EOF
out=$(scan "$S/good" "$S/kern.tar"); rc=$?
expect $rc 0 "known hit at an allowed location passes"
grep -q 'allowed by build/pii-allow-packages: kern.tar: denylist line(s) 2$' <<<"$out"; expect $? 0 "says it was allowed"
out=$(scan "$S/good" "$S/kern-pkginfo.tar"); rc=$?
expect $rc 1 "another denylisted word in .PKGINFO of the allowed package is blocked"
grep -q 'BLOCKED kern-pkginfo.tar: denylist line(s) 2,3 (1 hit(s) outside its allowed locations)' <<<"$out"
expect $? 0 "names both lines and counts the stray hit"
grep -qiE 'zorbleplex|quux|\.PKGINFO|modules\.order' <<<"$out"; expect $? 1 "prints neither the entries nor the location"
out=$(scan "$S/good" "$S/kern-elsewhere.tar"); expect $? 1 "the known word in another member is blocked"
out=$(scan "$S/good" "$S/db.files"); expect $? 0 "files db: allowed line passes"
out=$(scan "$S/good" "$S/db2.files"); expect $? 1 "files db: another line of the same file list is blocked"
out=$(scan "$S/good" "$S/span.tar"); rc=$?
expect $rc 1 "a hit the located pass cannot place is blocked, even under a catch-all rule"
grep -q 'could not be placed' <<<"$out"; expect $? 0 "says why"
out=$(scan "$S/good" "$S/hit.tar"); expect $? 1 "a package without rules is still blocked"
out=$(scan "$S/bad" "$S/kern.tar"); expect $? 1 "allow list does not excuse an invalid denylist"

echo "== 5. malformed allow rule fails closed"
printf '# a bare asset glob would allow the whole file\nkern.tar\n' >"$S/ws/build/pii-allow-packages"
out=$(scan "$S/good" "$S/kern.tar"); rc=$?
expect $rc 1 "bare asset glob is refused"
grep -q 'pii-allow-packages line 2' <<<"$out"; expect $? 0 "names the rule line"
out=$(scan "$S/good" "$S/clean.tar"); expect $? 1 "refused even when nothing hits"
exit $fail
