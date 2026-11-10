# hyprland 0.56.2-4.106

**Base:** Arch's `hyprland` 0.56.2-4 packaging, commit `abb207b` ("upgpkg: 0.56.2-4") of
https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland. The Omarchy stable mirror's
`extra` carries the same build: `hyprland` and `hyprpm` 0.56.2-4, with a package sha256 identical to
Arch's `extra`. Arch's split (`hyprland` + `hyprpm`, split out in 0.56.2-3) is unchanged, so both
packages are built at 0.56.2-4.103 and replace exactly what Arch ships. The PKGBUILD is Arch's (0BSD, see
`LICENSE`).

**Our changes to Arch's PKGBUILD:** `pkgrel=4.106`, `(omarchy-asus build)` appended to both
`pkgdesc`s (`pkgbuild-pkgdesc-label.diff`), plus `reconnect-render-offset.patch` and
`seat-leave-on-capability-loss.patch`, `output-late-bind-inert.patch`,
`output-global-destroy-delay.patch`, `xwayland-no-focus-window.patch` and
`session-lock-removed-output.patch` added to `source`/`sha256sums` and applied, in that order, at the
end of `prepare()`.
On the RC channel our pkgrel is Arch's pkgrel + `.101` and up (`.1` to `.99` is Quattro's range, where
this recipe is at 4.2): 4.101 moved the recipe into the RC range (#201), 4.102 added
`seat-leave-on-capability-loss.patch` (#302, #305), and 4.103 changes nothing in the packages: it
releases them once through the release workflow (`build/release-path.conf`, #258). 4.104, built on `main` for
Quattro since the Omarchy 4.5 stable switch (#411), adds the two output patches (#422). 4.105 adds `xwayland-no-focus-window.patch` (#424), 4.106
`session-lock-removed-output.patch` (#131).

**No `hyprland-debug`:** the chroot path also published a `hyprland-debug` package; the release
workflow publishes no `-debug` packages, so the RC channel stopped serving it when this recipe moved
to the release path (4.103). Only `hyprland` and `hyprpm` are released.

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

**Patch:** `seat-leave-on-capability-loss.patch` (`src/protocols/core/Seat.cpp`,
`CWLSeatProtocol::updateCapabilities`). When the last keyboard goes away (libinput removes the
keyboards across suspend), Hyprland sends `wl_seat.capabilities` without the keyboard bit but no
`wl_keyboard.leave`, because `CWLKeyboardResource::sendLeave()` is a no-op once `m_currentCaps` lacks the
keyboard bit, and `updateCapabilities()` updates it first. The focused client never learns it lost
focus; when the keyboard comes back, it gets `enter` on the same surface. Qt does not re-activate the
window on that enter (#298), so the lock screen ignores typing after resume until it is clicked (#295).
The patch sends `leave` to the keyboard resources, and `leave` plus `frame` to the focused pointer resources
(`frame` is gated on `m_currentCaps` too, hence the `friend class CWLSeatProtocol` in `Seat.hpp`), before the
capability is dropped, as wlroots does (`wlr_seat_set_capabilities`). Hyprland's own keyboard focus is kept, so a re-added
keyboard's new `wl_keyboard` gets `enter` on the same surface as before. wl_touch has no leave
event, and wlroots doesn't cancel touches here either, so touch is unchanged.

**Upstream status (checked 2026-10-24):** not fixed on `main`; `updateCapabilities()` is unchanged.
Not submitted (hyprwm/Hyprland#16178, the same symptom, was closed because reports go to
Discussions). Drop the patch once a release sends leave before dropping the capability.

**Patch:** `output-late-bind-inert.patch` (`src/protocols/core/Output.{cpp,hpp}`). Backport of
Hyprland main's `c7932c6ef` ("core/output: install cleanup handlers for inert resources") and
`5b6b75ac5` ("core/output: make late bindings to removed outputs inert"), both 2026-10-21, `src/`
only (their test needs main's test harness). The one change: 0.56.2 spells the removed warning
`Log::logger->log(...)`, not `LOG(...)`. A bind to a removed output, or to one whose monitor has no
backend output any more, gets an inert resource: no events, no `outputBound`, and its release and
destroy handlers installed so it drains. On its own it does not stop the disconnects below.

**Patch:** `output-global-destroy-delay.patch` (`src/protocols/core/Output.{cpp,hpp}`,
`src/managers/ProtocolManager.cpp`). Ours: Hyprland destroyed a removed wl_output global at once
(`retireOutputGlobal()` when a monitor with the same name came back, and
`CWLOutputProtocol::destroyResource()` when the last resource was released), so every client with a
bind in flight got libwayland's fatal `global wl_output (N) is unavailable`. On the G16 an HDMI
connector that flickers on resume disconnected Xwayland, the shell, the portals, fcitx5 and the
browsers at once (#422). `remove()` now records the removal and arms a timer; `canDestroy()` is
true only 5 s after it (wlroots' `wlr_global_destroy_safe` delay) with no resource bound, and both
paths, plus the timer's sweep, destroy only then. `isGlobalPrivileged()` also checks
`defunctOutputs`, so a sandboxed client's late bind isn't filtered into the same error.

**Upstream status (checked 2026-11-10):** `c7932c6ef` and `5b6b75ac5` are on `main`, in no release
(v0.56.2 is the latest). `main` still destroys retired output globals at once; the delay is not
submitted (a report draft is in docs/deltas.md#hyprland-output-global-destroy-delay). `DELTA`'s
`fixed-upstream` line flags the first release with `5b6b75ac5`.

**Patch:** `xwayland-no-focus-window.patch` (`src/xwayland/XWM.cpp`/`XWM.hpp`, `CXWM::activateSurface`,
`CXWM::focusWindow`, new `CXWM::createNoFocusWindow`). When focus moves from an X11 window to a Wayland
window, Hyprland set `_NET_ACTIVE_WINDOW` and the X input focus to None. Wine (10.x and later, Proton
too) takes the foreground from `_NET_ACTIVE_WINDOW` and reads None as a transient state, so the game
stays in the foreground: it keeps its sound with "sound in background" off, doesn't pause, keeps the
mouse (#424). The patch does what wlroots, KWin and Weston do: a mapped, 1x1, off-screen,
override-redirect "no focus" window, created with the WM window, is named as `_NET_ACTIVE_WINDOW` and
gets the X input focus whenever no X11 window is focused. Wine maps a window it doesn't own to the
desktop, so the game is deactivated. `isWMWindow()` lists it, so it never becomes a managed surface.
The patch also covers focus going to no window at all (an empty workspace), where 0.56.2 re-named the
old X11 window as active.

**Upstream status (checked 2026-11-10):** not fixed on `main` (`activateSurface` still sets
`XCB_WINDOW_NONE`), not submitted. The same change is in wlroots (MR 5076), KWin (MR 7664) and Weston
(MR 1761); Wine reverted its own None-means-desktop fix (wine MR 8108, reverted by 8117) in favour of
them. Drop the patch once a Hyprland release no longer sets None when a Wayland window is focused.

**Patch:** `session-lock-removed-output.patch` (`src/protocols/SessionLock.cpp`,
`CSessionLockProtocol::onGetLockSurface`, the `CSessionLockSurface` constructor). Backport of
hyprwm/Hyprland#16784 (main `8b6f4329`, "protocols/session-lock: fix removed output causing a protocol
error"), `src/` only: its test extends `tests/protocols/Output.cpp`, which 0.56.2's test tree doesn't
have. While the session is locked and an output vanishes (an HDMI plug during hibernate, a resume
flicker), the shell can ask for a lock surface on a `wl_output` whose monitor is already gone. 0.56.2
returned without creating the `ext_session_lock_surface_v1` object, so the client's later `destroy` of
that id was a protocol error: Hyprland disconnected the shell and showed its "lockscreen app died"
screen on every monitor (#131). The patch creates the object anyway, with only its destroy handlers,
no configure and no `newLockSurface`, so the client can destroy it.

**Upstream status (checked 2026-11-10):** merged on `main` 2026-11-02 (`8b6f4329`) and released in 0.57.1
(release-branch commit `518be87e`). Omarchy closed omacom/omarchy#11084 as fixed by it for Omarchy 4.6.0.
`DELTA`'s `fixed-upstream` lines flag the first release with either commit; drop the patch there.

**Rebase when Arch moves:** `bin/auto-update` does this automatically from `DELTA`
(`bin/rebase-recipe hyprland --version <arch ver> --out <dir> --verify` by hand). The
`fixed-upstream` line flags the first release that contains `e9e2f64c`. By hand:
1. `git -C recipes/.hyprland-arch-checkout pull` (the gitignored Arch packaging checkout), then
   `git -C recipes/.hyprland-arch-checkout show origin/main:PKGBUILD > recipes/hyprland/PKGBUILD`.
2. Reapply the edits above, with pkgrel = Arch's pkgrel + `.101` (`bin/rebase-recipe --channel rc` starts there).
3. If pkgver changed: check whether the release contains `e9e2f64c`. If it does, test without
   `reconnect-render-offset.patch`, and if the bug is gone, drop that patch. Separately, check whether the
   release's `CWLSeatProtocol::updateCapabilities()` sends `leave` before dropping a capability; if it does,
   test without `seat-leave-on-capability-loss.patch` (lock, suspend, resume, type) and drop it if typing works.
   If the release contains `5b6b75ac5` and `c7932c6ef`, drop `output-late-bind-inert.patch`. If its
   `CWLOutputProtocol` delays destroying a removed global, run the flicker reproducer
   (docs/deltas.md#hyprland-output-global-destroy-delay) without `output-global-destroy-delay.patch`
   and drop it if no client dies.
   If the release's `CXWM::activateSurface` no longer sets `XCB_WINDOW_NONE` for a Wayland focus, run #424's
   test without `xwayland-no-focus-window.patch` and drop it if the game is deactivated.
   If the release contains `8b6f4329` or `518be87e` (0.57.1 and later), drop `session-lock-removed-output.patch`.
   Only when no patch is left, `bin/unpublish hyprland hyprpm` and delete this recipe. Regenerate
   each patch that is still needed against the new source (`makepkg --nobuild --nodeps` in a scratch copy).
4. Run `bin/check-upstream`, then `bin/build-pkg recipes/hyprland`.
