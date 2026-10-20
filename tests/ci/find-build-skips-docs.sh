#!/bin/bash
# ci/find-build's artifact label, offline (FORCE_BUILD=true: no API call), in a
# throwaway git repo. Edits that never reach the build keep the label; the rest
# change it:
#   1. NOTES.md, DELTA, HOLD, g16-test/, tests/: same label (linux-omarchy-like recipe)
#   2. PKGBUILD or a patch: new label
#   3. a README.md the PKGBUILD names (installed doc): new label
#   4. a new file at the recipe root: new label
#   5. build/pacman.conf: new label
# Usage: tests/ci/find-build-skips-docs.sh [keep]
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
mkdir -p "$R/ci" "$R/build" "$R/recipes/k/g16-test" "$R/recipes/k/tests" "$R/recipes/d"
cp "$W/ci/find-build" "$R/ci/"
printf 'stub\n' >"$R/ci/build-recipe"; printf 'stub\n' >"$R/ci/setup-arch"; printf 'key\n' >"$R/ci/omarchy-signing-key.asc"
printf '[options]\n' >"$R/build/pacman.conf"
printf "pkgname=k\nsource=(0001-fix.patch)\n" >"$R/recipes/k/PKGBUILD"
printf 'patch\n' >"$R/recipes/k/0001-fix.patch"
for f in NOTES.md DELTA README.md; do printf '%s\n' "$f" >"$R/recipes/k/$f"; done
printf 'kit\n' >"$R/recipes/k/g16-test/test"; printf 't\n' >"$R/recipes/k/tests/a.test.js"
printf "pkgname=d\nsource=(README.md)\n" >"$R/recipes/d/PKGBUILD"
printf 'doc\n' >"$R/recipes/d/README.md"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm base

label() { (cd "$R" && BUILDER_IMAGE=img FORCE_BUILD=true ci/find-build "$1" 2>/dev/null | sed -n 's/^label=//p'); }
commit() { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm "$1"; }

k0=$(label k) d0=$(label d)
check "labels are produced" [ -n "$k0" ] && [ -n "$d0" ]

echo "== 1. docs, hold and kit edits keep the label"
printf 'more\n' >>"$R/recipes/k/NOTES.md"; printf 'more\n' >>"$R/recipes/k/DELTA"
printf 'held\n' >"$R/recipes/k/HOLD"; printf 'more\n' >>"$R/recipes/k/g16-test/test"
printf 'more\n' >>"$R/recipes/k/tests/a.test.js"; printf 'more\n' >>"$R/recipes/k/README.md"
commit docs
check "same label after docs/HOLD/kit edits" [ "$(label k)" = "$k0" ]

echo "== 2. PKGBUILD and patch edits change it"
printf 'patch2\n' >>"$R/recipes/k/0001-fix.patch"; commit patch
k1=$(label k)
check "new label after a patch edit" [ "$k1" != "$k0" ]
printf 'pkgrel=2\n' >>"$R/recipes/k/PKGBUILD"; commit pkgbuild
k2=$(label k)
check "new label after a PKGBUILD edit" [ "$k2" != "$k1" ]

echo "== 3. a README the PKGBUILD names counts"
printf 'more\n' >>"$R/recipes/d/README.md"; commit readme
check "new label after an installed README edit" [ "$(label d)" != "$d0" ]

echo "== 4. a new root file counts"
printf 'x\n' >"$R/recipes/k/config.x86_64"; commit config
k3=$(label k)
check "new label after a new config file" [ "$k3" != "$k2" ]

echo "== 5. build inputs outside the recipe count"
printf 'Server = x\n' >>"$R/build/pacman.conf"; commit pacman
check "new label after build/pacman.conf" [ "$(label k)" != "$k3" ]

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
