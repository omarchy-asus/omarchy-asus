# hyprland 0.56.2-4.1

**Base:** Arch's `hyprland` 0.56.2-4 packaging, commit `abb207b` ("upgpkg: 0.56.2-4") of
https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland. The Omarchy stable mirror's
`extra` carries the same build: `hyprland` and `hyprpm` 0.56.2-4, with a package sha256 identical to
Arch's `extra`. Arch's split (`hyprland` + `hyprpm`, split out in 0.56.2-3) is unchanged, so both
packages are built at 0.56.2-4.1 and replace exactly what Arch ships. The PKGBUILD is Arch's (0BSD, see
`LICENSE`).

**Our changes to Arch's PKGBUILD:** `pkgrel=4.1`, plus `reconnect-render-offset.patch` added to
`source`/`sha256sums` and applied at the end of `prepare()`.

**Patch:** `reconnect-render-offset.patch` (`src/output/Monitor.cpp`, `CMonitor::onConnect`). After an HDMI
replug, the monitor gets its remembered workspace back through an internal `changeWorkspace()`.
That call never animates the workspace in, so it keeps the slide-out offset it was given while it sat
hidden on the backup monitor, and its windows render off-screen. The patch runs the workspace's
"in" animation (instant, `ANIMATION_TYPE_IN, true, true`) on the active workspace at the end of
`onConnect()`. It applies cleanly to the 0.56.2 source tarball.

**Upstream status (checked 2026-10-17):** no released fix. v0.56.2 is the latest tag, and the
`v0.56.2-b` branch has no commits past the tag. On `main`, `e9e2f64c` "workspace: refactor workspace handling
(#16140)" (2026-09-09) moved this logic into `src/state/workspace/LifecyclePolicy*.cpp`. Its
`activateWorkspace()` now calls `changeWorkspace()` and then `startAnimation(ws, ANIMATION_TYPE_IN, true, true)`,
which is the same fix. `d8504461` (#15890) also changed un-orphaning onto the fallback output.
So the next Hyprland release (0.57) should make this patch unnecessary. Verify on hardware before
dropping it. The patch does not apply to `main`, because `onConnect` no longer does this itself.

**Rebase when Arch moves:** `bin/auto-update` does this automatically from `DELTA`
(`bin/rebase-recipe hyprland --version <arch ver> --out <dir> --verify` by hand). The
`fixed-upstream` line flags the first release that contains `e9e2f64c`. By hand:
1. `git -C recipes/.hyprland-arch-checkout pull` (the gitignored Arch packaging checkout), then
   `git -C recipes/.hyprland-arch-checkout show origin/main:PKGBUILD > recipes/hyprland/PKGBUILD`.
2. Reapply the three edits above, with pkgrel = Arch's pkgrel + `.1`.
3. If pkgver changed: check whether the release contains `e9e2f64c`. If it does, test without the
   patch, and if the bug is gone, `bin/unpublish hyprland hyprpm` and delete this recipe. If it does
   not, regenerate the patch against the new source (`makepkg --nobuild --nodeps` in a scratch copy).
4. Run `bin/check-upstream`, then `bin/build-pkg recipes/hyprland`.
