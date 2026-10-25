#!/bin/bash
# ci/changed-recipes, offline, in a throwaway git repo: a PR that changes only build
# tooling still builds one small recipe, omarchy-asus-keyring, fresh.
#   1. ci/, build/distcc-ssh or a workflow alone: keyring, fresh (bin/build-pkg and
#      build/pacman*.conf already rebuild every recipe but the kernel: nothing fresh)
#   2. tooling plus a recipe: that recipe only, nothing fresh
#   3. tooling plus a kernel patch: the kernel only, nothing fresh
#   4. docs, tests or other bin/ scripts: nothing
#   5. a dispatch (--list): exactly the list, nothing fresh
# Usage: tests/ci/changed-recipes-tooling.sh [keep]
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
mkdir -p "$R/ci" "$R/bin" "$R/build" "$R/docs" "$R/tests/ci" "$R/.github/workflows"
cp "$W/ci/changed-recipes" "$R/ci/"
for r in omarchy-asus-keyring hyprland linux-omarchy; do
    mkdir -p "$R/recipes/$r"; printf 'pkgname=%s\n' "$r" >"$R/recipes/$r/PKGBUILD"
done
for f in ci/build-recipe build/distcc-ssh bin/build-pkg bin/issue docs/releases.md \
    tests/ci/x.sh .github/workflows/build-pr.yml recipes/linux-omarchy/0001-fix.patch; do
    printf 'x\n' >"$R/$f"
done
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
base=$(git -C "$R" rev-parse HEAD)

change() { # file...: append to each, commit, print the plan, then undo
    local f out
    for f; do printf 'more\n' >>"$R/$f"; done
    git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm change
    out=$(cd "$R" && ci/changed-recipes "$base" HEAD 2>/dev/null)
    git -C "$R" reset -q --hard "$base"
    printf '%s\n' "$out"
}
canary() { grep -qx 'recipes=\["omarchy-asus-keyring"\]' <<<"$1" && grep -qx 'fresh=\["omarchy-asus-keyring"\]' <<<"$1"; }

echo "== 1. tooling alone builds the keyring fresh"
for f in ci/build-recipe build/distcc-ssh .github/workflows/build-pr.yml; do
    p=$(change "$f")
    check "$f: keyring, fresh" canary "$p"
    check "$f: no kernel" grep -qx 'kernel=false' <<<"$p"
done
p=$(change bin/build-pkg)
check "bin/build-pkg: every recipe but the kernel" grep -qx 'recipes=\["hyprland", "omarchy-asus-keyring"\]' <<<"$p"
check "bin/build-pkg: nothing fresh" grep -qx 'fresh=\[\]' <<<"$p"

echo "== 2. tooling plus a recipe builds that recipe"
p=$(change ci/build-recipe recipes/hyprland/PKGBUILD)
check "hyprland only" grep -qx 'recipes=\["hyprland"\]' <<<"$p"
check "nothing fresh" grep -qx 'fresh=\[\]' <<<"$p"

echo "== 3. tooling plus a kernel patch builds the kernel"
p=$(change ci/build-recipe recipes/linux-omarchy/0001-fix.patch)
check "kernel=true" grep -qx 'kernel=true' <<<"$p"
check "no other recipe" grep -qx 'recipes=\[\]' <<<"$p"
check "nothing fresh" grep -qx 'fresh=\[\]' <<<"$p"

echo "== 4. not build tooling: nothing builds"
p=$(change bin/issue docs/releases.md tests/ci/x.sh)
check "no recipe" grep -qx 'recipes=\[\]' <<<"$p"
check "nothing fresh" grep -qx 'fresh=\[\]' <<<"$p"

echo "== 5. a dispatch builds its list"
p=$(cd "$R" && ci/changed-recipes --list "hyprland" 2>/dev/null)
check "hyprland only" grep -qx 'recipes=\["hyprland"\]' <<<"$p"
check "nothing fresh" grep -qx 'fresh=\[\]' <<<"$p"
p=$(cd "$R" && ci/changed-recipes --list "" 2>/dev/null)
check "empty list: nothing" grep -qx 'recipes=\[\]' <<<"$p"

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
