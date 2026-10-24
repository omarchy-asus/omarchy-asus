#!/bin/bash
# The Quattro channel is frozen until the Omarchy 4.5 stable switch (#309), offline: the data
# dir, workspace and chroot are temp dirs, gh is a stub that records it ran.
#   1. bin/build-pkg, bin/publish, bin/unpublish, bin/sync-release and bin/rebase-recipe on
#      quattro (named, or the default) exit 1 with the freeze message, and gh never ran;
#   2. bin/sync-release --dry-run and --pii-scan on quattro still run;
#   3. OMARCHY_ASUS_ALLOW_QUATTRO=1 lets each past the freeze (it then stops on what this
#      test leaves out: no chroot, no signing key, no recipe);
#   4. --channel rc never sees the freeze.
# Usage: tests/ci/quattro-frozen.sh [keep]   (keep: leave the temp dir for inspection)
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
unset OMARCHY_ASUS_CHANNEL OMARCHY_ASUS_ALLOW_QUATTRO SYNC_ADOPT_REMOTE
MSG='the Quattro channel is frozen until the Omarchy 4.5 stable switch (#309); OMARCHY_ASUS_ALLOW_QUATTRO=1 overrides'
fail=0
# try <frozen|open> <what> <cmd...>: frozen = exit 1, the message on stderr, gh not run;
# open = the message nowhere
try() {
    local want=$1 what=$2 rc; shift 2
    rm -f "$S/ran"
    "$@" >"$S/o" 2>"$S/e" </dev/null; rc=$?
    if [[ $want == frozen ]]; then
        if [[ $rc -eq 1 ]] && grep -qF -- "$MSG" "$S/e" && [[ ! -e $S/ran ]]; then
            echo "ok: $what"
        else
            printf 'FAIL: %s: exit %s, want 1 and the freeze message, gh not run\n' "$what" "$rc"; cat "$S/o" "$S/e"; fail=1
        fi
    elif grep -qF -- "frozen until" "$S/o" "$S/e"; then
        printf 'FAIL: %s: refused as frozen (exit %s)\n' "$what" "$rc"; cat "$S/o" "$S/e"; fail=1
    else
        echo "ok: $what (exit $rc past the freeze)"
    fi
}
pkg=$S/data/stage/x-1-1-any.pkg.tar.zst
rebase=(python3 "$W/bin/rebase-recipe" nonexistent --version 1-1 --out "$S/out/r")

echo "== 1. quattro is refused"
try frozen "build-pkg (default channel)" "$W/bin/build-pkg" "$S/recipe"
try frozen "build-pkg --channel quattro" "$W/bin/build-pkg" --channel quattro "$S/recipe"
try frozen "publish (default channel)" "$W/bin/publish" "$pkg"
try frozen "publish --channel quattro" "$W/bin/publish" --channel quattro "$pkg"
try frozen "unpublish --channel quattro" "$W/bin/unpublish" --channel quattro x
try frozen "unpublish (default channel)" "$W/bin/unpublish" x
try frozen "sync-release (default channel)" "$W/bin/sync-release"
try frozen "sync-release --channel quattro" "$W/bin/sync-release" --channel quattro
try frozen "rebase-recipe --channel quattro" "${rebase[@]}" --channel quattro
try frozen "rebase-recipe (default channel)" "${rebase[@]}"
try frozen "rebase-recipe, OMARCHY_ASUS_CHANNEL=quattro" env OMARCHY_ASUS_CHANNEL=quattro "${rebase[@]}"

echo "== 2. reading Quattro still works"
try open "sync-release --dry-run --channel quattro" "$W/bin/sync-release" --dry-run --channel quattro
try open "sync-release --pii-scan" "$W/bin/sync-release" --pii-scan "$S/clean.txt"

echo "== 3. OMARCHY_ASUS_ALLOW_QUATTRO=1 overrides"
export OMARCHY_ASUS_ALLOW_QUATTRO=1
try open "build-pkg" "$W/bin/build-pkg" --channel quattro "$S/recipe"
grep -q "no quattro build chroot" "$S/e" || { echo "FAIL: build-pkg did not reach the chroot check"; cat "$S/e"; fail=1; }
try open "publish" "$W/bin/publish" --channel quattro "$pkg"
try open "unpublish" "$W/bin/unpublish" --channel quattro x
try open "rebase-recipe" "${rebase[@]}" --channel quattro
unset OMARCHY_ASUS_ALLOW_QUATTRO
# a value other than 1 is no override
OMARCHY_ASUS_ALLOW_QUATTRO=yes try frozen "OMARCHY_ASUS_ALLOW_QUATTRO=yes is no override" "$W/bin/publish" "$pkg"

echo "== 4. rc is never frozen"
try open "build-pkg --channel rc" "$W/bin/build-pkg" --channel rc "$S/recipe"
try open "publish --channel rc" "$W/bin/publish" --channel rc "$pkg"
try open "unpublish --channel rc" "$W/bin/unpublish" --channel rc x
try open "sync-release --dry-run --channel rc" "$W/bin/sync-release" --dry-run --channel rc
try open "rebase-recipe --channel rc" "${rebase[@]}" --channel rc

((fail == 0)) || exit 1
echo "all ok"
