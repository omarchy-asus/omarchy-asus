#!/bin/bash
# ci/changed-recipes, offline, in a throwaway git repo: which PR changes build
# the kernel.
#   1. NOTES.md, g16-test/ and tests/ under recipes/linux-omarchy: kernel=false
#   2. a patch or the PKGBUILD: kernel=true
#   3. a file named g16-test at the recipe root still counts
#   4. any change to another recipe builds it, its g16-test/ included
# Usage: tests/ci/changed-recipes-kernel-skips.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0
check() {
    local name=$1; shift
    if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi
}

R=$S/repo K=$S/repo/recipes/linux-omarchy
mkdir -p "$R/ci" "$K/g16-test" "$K/tests" "$R/recipes/d/g16-test"
cp "$W/ci/changed-recipes" "$R/ci/"
printf 'pkgname=linux-omarchy\n' >"$K/PKGBUILD"; printf 'patch\n' >"$K/0001-fix.patch"
printf 'notes\n' >"$K/NOTES.md"; printf 'kit\n' >"$K/g16-test/test"; printf 't\n' >"$K/tests/a.sh"
printf 'pkgname=d\n' >"$R/recipes/d/PKGBUILD"; printf 'kit\n' >"$R/recipes/d/g16-test/x"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
base=$(git -C "$R" rev-parse HEAD)

# plan: the GITHUB_OUTPUT lines for base..HEAD
plan() { (cd "$R" && ci/changed-recipes "$base" HEAD 2>/dev/null); }
change() { # file...: append to each, commit, print the plan, then undo
    local f out
    for f; do printf 'more\n' >>"$R/$f"; done
    git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm change
    out=$(plan)
    git -C "$R" reset -q --hard "$base"
    printf '%s\n' "$out"
}

echo "== 1. docs, kit and tests skip the kernel"
p=$(change recipes/linux-omarchy/NOTES.md recipes/linux-omarchy/g16-test/test recipes/linux-omarchy/tests/a.sh)
check "kernel=false" grep -qx 'kernel=false' <<<"$p"
check "no other recipe" grep -qx 'recipes=\[\]' <<<"$p"

echo "== 2. a patch or the PKGBUILD builds it"
check "patch: kernel=true" grep -qx 'kernel=true' <<<"$(change recipes/linux-omarchy/0001-fix.patch)"
check "PKGBUILD: kernel=true" grep -qx 'kernel=true' <<<"$(change recipes/linux-omarchy/PKGBUILD)"

echo "== 3. a root file named like the kit counts"
check "root g16-test file: kernel=true" grep -qx 'kernel=true' <<<"$(change recipes/linux-omarchy/g16-test-notes)"

echo "== 4. other recipes build on any change"
check "d/g16-test/: d builds" grep -qx 'recipes=\["d"\]' <<<"$(change recipes/d/g16-test/x)"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
