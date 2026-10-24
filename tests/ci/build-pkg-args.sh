#!/bin/bash
# bin/build-pkg checks its arguments before it runs or creates anything (#301), offline:
# the data dir and the chroot are temp dirs, makechrootpkg is a stub that records it ran,
# SUDO=env stands in for sudo. Each case asserts the exit code, that the usage is printed
# and that the data dir stays empty (no work-* dir, no stage or log dir):
#   1. -h and --help: the usage on stdout, exit 0
#   2. --version, --bogus, a mistyped --chanel rc, --channel with no value, an empty one
#      ("") or an unknown one (beta): exit 2
#   3. no argument at all, or only --channel rc: exit 2
#   4. a dir without a PKGBUILD (/tmp), or a path that doesn't exist: exit 2
#   5. a recipe named like an option, after --: built (realpath -- "$1")
# Usage: tests/ci/build-pkg-args.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/data" "$S/norecipe"
cat >"$S/bin/makechrootpkg" <<STUB
#!/bin/bash
: >"$S/ran"
: >demo-1-1-x86_64.pkg.tar.zst
STUB
chmod +x "$S/bin/makechrootpkg"
C=$S/chroot
mkdir -p "$C/root/etc"
cp "$W/build/pacman.conf" "$C/root/etc/pacman.conf"
export PATH=$S/bin:$PATH SUDO=env OMARCHY_ASUS_DATA=$S/data OMARCHY_ASUS_CHROOT=$C
unset DISTCC_KEY_DIR CCACHE_HOST_DIR OMARCHY_ASUS_CHANNEL OMARCHY_ASUS_WORKSPACE
# Quattro is frozen (#309); this test runs the default (quattro) channel's code, so it overrides
export OMARCHY_ASUS_ALLOW_QUATTRO=1
fail=0
# run <want exit> <what> [build-pkg args]: exit code, usage shown, nothing created
run() {
    local want=$1 what=$2 rc; shift 2
    rm -f "$S/ran"
    "$W/bin/build-pkg" "$@" >"$S/out" 2>"$S/err"; rc=$?
    local shown=$S/err; ((want == 0)) && shown=$S/out
    if [[ $rc -ne $want ]]; then
        printf 'FAIL: %s: exit %s, want %s\n' "$what" "$rc" "$want"; cat "$S/out" "$S/err"; fail=1
    elif ! grep -q '^Usage: bin/build-pkg ' "$shown"; then
        echo "FAIL: $what: no usage on $( ((want == 0)) && echo stdout || echo stderr)"; cat "$S/out" "$S/err"; fail=1
    elif [[ -n $(ls -A "$S/data") || -e $S/ran ]]; then
        echo "FAIL: $what: something was created or built:"; ls -A "$S/data"; fail=1
    else
        echo "ok: $what"
    fi
}

echo "== 1. help"
run 0 "-h prints the usage" -h
run 0 "--help prints the usage" --help
run 0 "--help after --channel prints the usage" --channel rc --help

echo "== 2. unknown options"
run 2 "--version is an error" --version
run 2 "--bogus is an error" --bogus
run 2 "a mistyped --chanel rc is an error" --chanel rc
run 2 "--channel with no value is an error" --channel
run 2 "an empty --channel is an error" --channel "" "$W/recipes/omarchy"
run 2 "an unknown --channel is an error" --channel beta "$W/recipes/omarchy"
grep -q 'unknown option: --bogus' <("$W/bin/build-pkg" --bogus 2>&1); [[ $? -eq 0 ]] && echo "ok: names the option" || { echo "FAIL: doesn't name the option"; fail=1; }

echo "== 3. no recipe"
run 2 "no argument is an error"
run 2 "only --channel rc is an error" --channel rc

echo "== 4. not a recipe dir"
run 2 "/tmp (no PKGBUILD) is an error" /tmp
run 2 "a dir without a PKGBUILD is an error" "$S/norecipe"
run 2 "a missing path is an error" "$S/missing"

echo "== 5. a recipe named like an option, after --"
mkdir -p "$S/r/--odd"; printf 'pkgname=demo\n' >"$S/r/--odd/PKGBUILD"
rm -f "$S/ran"
if (cd "$S/r" && "$W/bin/build-pkg" -- --odd) >"$S/out" 2>&1 && [[ -e $S/ran ]]; then
    echo "ok: built"
else
    echo "FAIL: -- --odd was not built"; cat "$S/out"; fail=1
fi
[[ -z $(compgen -G "$S/data/work-*") ]] && echo "ok: work dir removed" || { echo "FAIL: work dir left"; fail=1; }

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
