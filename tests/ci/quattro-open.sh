#!/bin/bash
# The Quattro channel is open again since the Omarchy 4.5 stable switch (#411), offline: the
# data dir, workspace and chroot are temp dirs, gh is a stub that records it ran.
#   1. bin/build-pkg, bin/publish, bin/unpublish, bin/sync-release and bin/rebase-recipe on
#      quattro (named, the default, or OMARCHY_ASUS_CHANNEL) run without any override and never
#      say "frozen" (each then stops on what this test leaves out: no chroot, no signing key,
#      no recipe);
#   2. the same on rc.
# Usage: tests/ci/quattro-open.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/data" "$S/ws/build" "$S/chroot" "$S/out" "$S/recipe"
cat >"$S/bin/gh" <<STUB
#!/bin/bash
: >"$S/ran"
exit 1
STUB
chmod +x "$S/bin/gh"
printf 'pkgname=x\npkgver=1\npkgrel=1\n' >"$S/recipe/PKGBUILD"
printf 'nothing to see here\n' >"$S/clean.txt"
printf '# test denylist\nzorbleplex\n' >"$S/denylist"
export PATH=$S/bin:$PATH OMARCHY_ASUS_DATA=$S/data OMARCHY_ASUS_WORKSPACE=$S/ws \
    OMARCHY_ASUS_CHROOT=$S/chroot PII_DENYLIST=$S/denylist PII_SCAN=off
unset OMARCHY_ASUS_CHANNEL SYNC_ADOPT_REMOTE
fail=0
# try <what> <cmd...>: the command runs past where the freeze stood: no "frozen" anywhere
try() {
    local what=$1 rc; shift
    "$@" >"$S/o" 2>"$S/e" </dev/null; rc=$?
    if grep -qiF -- "frozen" "$S/o" "$S/e"; then
        printf 'FAIL: %s: refused as frozen (exit %s)\n' "$what" "$rc"; cat "$S/o" "$S/e"; fail=1
    else
        echo "ok: $what (exit $rc, not frozen)"
    fi
}
pkg=$S/data/stage/x-1-1-any.pkg.tar.zst
rebase=(python3 "$W/bin/rebase-recipe" nonexistent --version 1-1 --out "$S/out/r")

echo "== 1. quattro runs, with no override"
try "build-pkg (default channel)" "$W/bin/build-pkg" "$S/recipe"
grep -q "no quattro build chroot" "$S/e" || { echo "FAIL: build-pkg did not reach the chroot check"; cat "$S/e"; fail=1; }
try "build-pkg --channel quattro" "$W/bin/build-pkg" --channel quattro "$S/recipe"
try "publish (default channel)" "$W/bin/publish" "$pkg"
try "publish --channel quattro" "$W/bin/publish" --channel quattro "$pkg"
try "unpublish --channel quattro" "$W/bin/unpublish" --channel quattro x
try "unpublish (default channel)" "$W/bin/unpublish" x
try "sync-release (default channel)" "$W/bin/sync-release"
try "sync-release --channel quattro" "$W/bin/sync-release" --channel quattro
try "sync-release --dry-run --channel quattro" "$W/bin/sync-release" --dry-run --channel quattro
try "sync-release --pii-scan" "$W/bin/sync-release" --pii-scan "$S/clean.txt"
try "rebase-recipe --channel quattro" "${rebase[@]}" --channel quattro
try "rebase-recipe (default channel)" "${rebase[@]}"
try "rebase-recipe, OMARCHY_ASUS_CHANNEL=quattro" env OMARCHY_ASUS_CHANNEL=quattro "${rebase[@]}"

echo "== 2. rc runs too"
try "build-pkg --channel rc" "$W/bin/build-pkg" --channel rc "$S/recipe"
try "publish --channel rc" "$W/bin/publish" --channel rc "$pkg"
try "unpublish --channel rc" "$W/bin/unpublish" --channel rc x
try "sync-release --dry-run --channel rc" "$W/bin/sync-release" --dry-run --channel rc
try "rebase-recipe --channel rc" "${rebase[@]}" --channel rc

((fail == 0)) || exit 1
echo "all ok"
