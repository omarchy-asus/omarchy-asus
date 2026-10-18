#!/bin/bash
# bin/build-pkg's optional distcc mount, offline: makechrootpkg is a stub that
# records its arguments, SUDO=env stands in for sudo, the data dir is a temp dir.
#   1. no key dir: makechrootpkg gets exactly the arguments it got before distcc
#   2. key in the default dir: that dir is bound read-only (-D) at /distcc
#   3. DISTCC_KEY_DIR= (empty): no mount even though the default key exists
#   4. DISTCC_KEY_DIR=<dir>: that dir is bound; extra args still come after it
#   5. a key dir without id_ed25519: no mount
# Usage: tests/ci/build-pkg-distcc.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d)
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/recipes/demo" "$S/data"
printf 'pkgname=demo\n' >"$S/recipes/demo/PKGBUILD"
cat >"$S/bin/makechrootpkg" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/args"
: >demo-1-1-x86_64.pkg.tar.zst
STUB
chmod +x "$S/bin/makechrootpkg"
export PATH=$S/bin:$PATH SUDO=env OMARCHY_ASUS_DATA=$S/data
unset DISTCC_KEY_DIR
C=/var/lib/omarchy-asus/chroot
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
build() {
    rm -f "$S/args"
    "$W/bin/build-pkg" "$S/recipes/demo" "$@" >"$S/out" 2>&1 ||
        { echo "FAIL: build-pkg exited non-zero"; cat "$S/out"; fail=1; }
}
args() { paste -sd' ' "$S/args" 2>/dev/null; }

echo "== 1. no key dir"
build; expect "$(args)" "-c -u -r $C" "stock arguments"
grep -q distcc "$S/out"; expect $? 1 "no distcc output"
expect "$(ls "$S/data/stage")" demo-1-1-x86_64.pkg.tar.zst "package staged"

echo "== 2. key in the default dir"
mkdir -p "$S/data/distcc"; : >"$S/data/distcc/id_ed25519"
build; expect "$(args)" "-c -u -r $C -D $S/data/distcc:/distcc" "default dir bound read-only"
grep -q 'distcc: key dir mounted read-only at /distcc' "$S/out"; expect $? 0 "says so"

echo "== 3. DISTCC_KEY_DIR= disables it"
DISTCC_KEY_DIR='' build; expect "$(args)" "-c -u -r $C" "stock arguments"

echo "== 4. DISTCC_KEY_DIR=<dir>, extra args"
mkdir -p "$S/other"; : >"$S/other/id_ed25519"
DISTCC_KEY_DIR=$S/other build -- --nocheck
expect "$(args)" "-c -u -r $C -D $S/other:/distcc -- --nocheck" "override dir bound, extra args last"

echo "== 5. dir without a key"
mkdir -p "$S/empty"
DISTCC_KEY_DIR=$S/empty build; expect "$(args)" "-c -u -r $C" "stock arguments"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
