#!/bin/bash
# Exercise bin/auto-update without a chroot build or any publishing:
#   1. --plan and --dry-run against the current state
#   2. simulated Arch rebuild hyprland 0.56.2-5: rebase + makepkg --nobuild must pass
#   3. simulated 0.56.2-6 whose prepare() rewrites the lines our patch touches: the patch
#      must fail, the run must plan an unpublish of hyprland+hyprpm and exit 1
# The fake upstream is a local clone of Arch's hyprland packaging with two extra tags;
# upstream versions are overridden with OMARCHY_ASUS_UPSTREAM_OVERRIDE. State goes to a
# temp dir; the real repo db is only read (through a symlink). Downloads the Hyprland
# source tarball once (into the temp dir's srcdest).
# Usage: tests/auto-update-simulate.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
S=$(mktemp -d)
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
real=${OMARCHY_ASUS_REAL_DATA:-$HOME/.local/share/omarchy-asus}
D=$S/data F=$S/fake-upstream
mkdir -p "$D/repo" "$F"
ln -s "$real/repo/x86_64" "$D/repo/x86_64"
export OMARCHY_ASUS_DATA=$D XDG_CONFIG_HOME=$S/no-config
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 (exit $1, want $2)"; fail=1; fi; }

echo "== 1. current state"
"$W/bin/auto-update" --plan --workspace "$W"; expect $? 0 "plan"
"$W/bin/auto-update" --dry-run --workspace "$W"; expect $? 0 "dry-run"

git clone --quiet --bare https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland.git "$F/hyprland.git"
git clone --quiet "$F/hyprland.git" "$F/work"
(
    cd "$F/work" || exit 1
    g() { git -c user.name=sim -c user.email=sim@invalid "$@"; }
    git checkout --quiet 0.56.2-4
    sed -i 's/^pkgrel=4$/pkgrel=5/' PKGBUILD
    g commit --quiet -am "upgpkg: 0.56.2-5 (simulated)"; git tag 0.56.2-5
    sed -i 's/^pkgrel=5$/pkgrel=6/' PKGBUILD
    sed -i '/find_package.glaze/a\	sed -i "s/AQ_SCHEDULE_NEW_MONITOR/AQ_SCHEDULE_NEW_OUTPUT/g" src/output/Monitor.cpp' PKGBUILD
    g commit --quiet -am "upgpkg: 0.56.2-6 (simulated)"; git tag 0.56.2-6
    git push --quiet --tags origin HEAD:refs/heads/sim
)
export OMARCHY_ASUS_ARCH_GIT_URL="file://$F/{pkgbase}.git"

echo "== 2. upstream hyprland 0.56.2-5"
OMARCHY_ASUS_UPSTREAM_OVERRIDE=hyprland=0.56.2-5,hyprpm=0.56.2-5 \
    "$W/bin/auto-update" --dry-run --workspace "$W" --recipe hyprland
expect $? 0 "pkgrel bump rebases and passes makepkg --nobuild"
cat "$(ls -dt "$D"/auto-update/runs/*/ | head -1)/hyprland.diff"

echo "== 3. upstream hyprland 0.56.2-6 (patch no longer applies)"
out=$(OMARCHY_ASUS_UPSTREAM_OVERRIDE=hyprland=0.56.2-6,hyprpm=0.56.2-6 \
    "$W/bin/auto-update" --dry-run --workspace "$W" --recipe hyprland 2>&1)
rc=$?
echo "$out" | grep -E '^\[|^\| hyprland|auto-update:'
expect $rc 1 "failed rebase fails the run"
grep -q 'would unpublish hyprland hyprpm' <<<"$out"; expect $? 0 "failed rebase unpublishes hyprland hyprpm"
exit $fail
