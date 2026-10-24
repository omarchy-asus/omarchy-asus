#!/bin/bash
# bin/build-pkg removes its work dir ($DATA/work-<name>.XXXX) however it exits (#300), offline:
# makechrootpkg is a stub whose behaviour each case sets in $S/mode, SUDO is a stand-in for
# sudo that logs its calls and can remove what the build user can't, the data dir is a temp dir.
#   1. a build that succeeds: package staged, no work dir left
#   2. makechrootpkg fails: build-pkg exits with its status, no work dir left
#   3. makechrootpkg makes no package: build-pkg fails, no work dir left
#   4. the build leaves files the build user can't remove (root's, in a real build):
#      removed through SUDO, no work dir left
#   5. KEEP_WORK=1 on a failed build: the work dir is kept and its path printed
#   6. build-pkg is stopped (SIGTERM) mid-build: exits 143, no work dir left
# Usage: tests/ci/build-pkg-work-cleanup.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/recipes/demo" "$S/data"
printf 'pkgname=demo\n' >"$S/recipes/demo/PKGBUILD"
cat >"$S/bin/makechrootpkg" <<STUB
#!/bin/bash
case \$(cat "$S/mode") in
    ok) : >demo-1-1-x86_64.pkg.tar.zst ;;
    fail) exit 3 ;;
    nopkg) ;;
    locked) : >demo-1-1-x86_64.pkg.tar.zst; mkdir -p src/root; : >src/root/f; chmod 555 src/root ;;
    wait) : >"$S/started"; for _ in \$(seq 100); do [[ -e $S/go ]] && break; sleep 0.1; done ;;
esac
STUB
cat >"$S/bin/fakesudo" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$S/sudo-calls"
[[ \$1 == rm ]] && chmod -R u+w "\${@: -1}"
exec "\$@"
STUB
chmod +x "$S/bin/makechrootpkg" "$S/bin/fakesudo"
C=$S/chroot
mkdir -p "$C/root/etc"
cp "$W/build/pacman.conf" "$C/root/etc/pacman.conf"
export PATH=$S/bin:$PATH SUDO=fakesudo OMARCHY_ASUS_DATA=$S/data OMARCHY_ASUS_CHROOT=$C DISTCC_KEY_DIR=
unset OMARCHY_ASUS_CHANNEL OMARCHY_ASUS_WORKSPACE KEEP_WORK
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
build() {  # build <mode>: run build-pkg with that makechrootpkg; its status is in $rc
    echo "$1" >"$S/mode"; rm -f "$S/sudo-calls"
    "$W/bin/build-pkg" "$S/recipes/demo" >"$S/out" 2>&1; rc=$?
}
works() { (cd "$S/data" && ls -d work-* 2>/dev/null); }

echo "== 1. success"
build ok
expect $rc 0 "build-pkg exits 0"
expect "$(ls "$S/data/stage")" demo-1-1-x86_64.pkg.tar.zst "package staged"
expect "$(works)" "" "no work dir left"
expect "$(grep -c '^rm ' "$S/sudo-calls")" 0 "no root removal needed"
rm -f "$S/data/stage"/*

echo "== 2. makechrootpkg fails"
build fail
expect $rc 3 "build-pkg exits with makechrootpkg's status"
expect "$(works)" "" "no work dir left"

echo "== 3. no package made"
build nopkg
[[ $rc -ne 0 ]]; expect $? 0 "build-pkg fails"
expect "$(works)" "" "no work dir left"

echo "== 4. files the build user can't remove"
build locked
expect $rc 0 "build-pkg exits 0"
expect "$(works)" "" "no work dir left"
expect "$(grep -c "^rm -rf -- $S/data/work-demo\.....$" "$S/sudo-calls")" 1 "removed as root"
rm -f "$S/data/stage"/*

echo "== 5. KEEP_WORK=1"
KEEP_WORK=1 build fail
expect $rc 3 "build-pkg exits with makechrootpkg's status"
kept=$(works)
expect "$(wc -w <<<"$kept")" 1 "the work dir is kept"
grep -qF "work dir kept (KEEP_WORK=1): $S/data/$kept" "$S/out"; expect $? 0 "its path is printed"
rm -rf "${S:?}/data/$kept"

echo "== 6. stopped mid-build"
echo wait >"$S/mode"; rm -f "$S/started" "$S/go"
"$W/bin/build-pkg" "$S/recipes/demo" >"$S/out" 2>&1 & pid=$!
for _ in $(seq 100); do [[ -e $S/started ]] && break; sleep 0.1; done
kill -TERM $pid; : >"$S/go"
wait $pid; expect $? 143 "build-pkg exits 143"
expect "$(works)" "" "no work dir left"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
