#!/bin/bash
# bin/build-pkg's optional distcc mount, offline: makechrootpkg is a stub that
# records its arguments, SUDO=env stands in for sudo, the data dir is a temp dir.
#   1. no key dir: makechrootpkg gets exactly the arguments it got before distcc
#   2. key and this repo's build/distcc-ssh as ssh in the default dir: bound read-only (-D) at /distcc
#   3. DISTCC_KEY_DIR= (empty): no mount even though the default key exists
#   4. DISTCC_KEY_DIR=<dir>: that dir is bound; extra args still come after it
#   5. a key dir without id_ed25519: no mount
#   6. a relative DISTCC_KEY_DIR: bound by its absolute path (build-pkg cds first)
# and the cases that keep distcc off (#163):
#   6a. the key dir's ssh is not build/distcc-ssh (an older wrapper, or none): no mount
#   6b. a recipe with a NO_DISTCC file: no mount
# and the release channel's chroot (#167; OMARCHY_ASUS_CHROOT is a temp dir):
#   7. --channel rc against a chroot made from build/pacman.conf (Omarchy stable): refused
#   8. --channel rc against a chroot made from build/pacman-rc.conf: built, staged in stage-rc only
#   9. the default (quattro) channel against that rc chroot: refused
#  10. no chroot at all: refused
# Usage: tests/ci/build-pkg-distcc.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/recipes/demo" "$S/data"
printf 'pkgname=demo\n' >"$S/recipes/demo/PKGBUILD"
cat >"$S/bin/makechrootpkg" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/args"
: >demo-1-1-x86_64.pkg.tar.zst
STUB
chmod +x "$S/bin/makechrootpkg"
C=$S/chroot
mkdir -p "$C/root/etc"
cp "$W/build/pacman.conf" "$C/root/etc/pacman.conf"
export PATH=$S/bin:$PATH SUDO=env OMARCHY_ASUS_DATA=$S/data OMARCHY_ASUS_CHROOT=$C
unset DISTCC_KEY_DIR OMARCHY_ASUS_CHANNEL OMARCHY_ASUS_WORKSPACE
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
cp "$W/build/distcc-ssh" "$S/data/distcc/ssh"
build; expect "$(args)" "-c -u -r $C -D $S/data/distcc:/distcc" "default dir bound read-only"
grep -q 'distcc: key dir mounted read-only at /distcc' "$S/out"; expect $? 0 "says so"

echo "== 3. DISTCC_KEY_DIR= disables it"
DISTCC_KEY_DIR='' build; expect "$(args)" "-c -u -r $C" "stock arguments"

echo "== 4. DISTCC_KEY_DIR=<dir>, extra args"
mkdir -p "$S/other"; : >"$S/other/id_ed25519"; cp "$W/build/distcc-ssh" "$S/other/ssh"
DISTCC_KEY_DIR=$S/other build -- --nocheck
expect "$(args)" "-c -u -r $C -D $S/other:/distcc -- --nocheck" "override dir bound, extra args last"

echo "== 5. dir without a key"
mkdir -p "$S/empty"
DISTCC_KEY_DIR=$S/empty build; expect "$(args)" "-c -u -r $C" "stock arguments"

echo "== 6. relative DISTCC_KEY_DIR"
(cd "$S" && DISTCC_KEY_DIR=other build); expect "$(args)" "-c -u -r $C -D $S/other:/distcc" "bound by absolute path"

echo "== 6a. key dir with an older ssh wrapper, or none"
printf '#!/bin/sh\nexec ssh -i /distcc/id_ed25519 "$@"\n' >"$S/other/ssh"
DISTCC_KEY_DIR=$S/other build; expect "$(args)" "-c -u -r $C" "older wrapper: stock arguments"
grep -q 'distcc: off: .* is not build/distcc-ssh' "$S/out"; expect $? 0 "says why"
rm "$S/other/ssh"
DISTCC_KEY_DIR=$S/other build; expect "$(args)" "-c -u -r $C" "no wrapper: stock arguments"

echo "== 6b. a NO_DISTCC recipe"
printf 'precompiled headers\n' >"$S/recipes/demo/NO_DISTCC"
build; expect "$(args)" "-c -u -r $C" "stock arguments"
grep -q 'distcc: off for demo (recipes/demo/NO_DISTCC)' "$S/out"; expect $? 0 "says why"
rm "$S/recipes/demo/NO_DISTCC"

refused() {  # refused <what> [build-pkg args]: build-pkg exits non-zero before makechrootpkg runs
    local what=$1; shift
    rm -f "$S/args"
    if "$W/bin/build-pkg" "$@" "$S/recipes/demo" >"$S/out" 2>&1; then
        echo "FAIL: $what (build-pkg exited 0)"; fail=1
    elif [[ -e $S/args ]]; then
        echo "FAIL: $what (makechrootpkg ran)"; fail=1
    else
        echo "ok: $what"
    fi
}
rm -rf "$S/data/distcc" "$S/data/stage"/*

echo "== 7. rc channel, stable chroot"
refused "an rc build in a chroot on Omarchy stable is refused" --channel rc
grep -q 'mkchroot --channel rc' "$S/out"; expect $? 0 "says how to make the rc chroot"

echo "== 8. rc channel, rc chroot"
cp "$W/build/pacman-rc.conf" "$C/root/etc/pacman.conf"
rm -f "$S/args"
"$W/bin/build-pkg" --channel rc "$S/recipes/demo" >"$S/out" 2>&1 || { echo "FAIL: rc build-pkg exited non-zero"; cat "$S/out"; fail=1; }
expect "$(args)" "-c -u -r $C" "stock arguments"
expect "$(ls "$S/data/stage-rc" 2>/dev/null)" demo-1-1-x86_64.pkg.tar.zst "package staged in stage-rc"
expect "$(ls "$S/data/stage" 2>/dev/null)" "" "nothing in the quattro stage dir"

echo "== 9. quattro channel, rc chroot"
refused "a quattro build in a chroot on Omarchy rc is refused"

echo "== 10. no chroot"
rm -rf "$C/root"
refused "a build without a chroot is refused"
refused "an unknown channel is refused" --channel edge

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
