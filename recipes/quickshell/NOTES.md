# quickshell 0.3.2.r7.g2b4501a-1.101 (RC channel)

**Base:** Omarchy's `quickshell` 0.3.2.r7.g2b4501a-1 packaging, `pkgbuilds/quickshell` at commit
`2be7cd98` ("Pin quickshell to master at 2b4501a (#1208)") of omacom/omarchy-pkgs, the build
pkgs.omarchy.org/rc serves. Its later `-2` to `-5` (rebuilds against updated Qt) aren't on the rc
channel yet; the daily rebase onto upstream picks up the next one it serves. Omarchy's
`load_qtquick_611.patch` and `quickshell-check.hook` are taken as they are.

**Our changes to Omarchy's PKGBUILD:** `pkgrel=1.101` (the RC range: Omarchy's pkgrel + `.101`),
`(omarchy-asus build)` appended to `pkgdesc` (`pkgbuild-pkgdesc-label.diff`), and
`clock-dst-fall-back.patch` added to `source`/`sha256sums` and applied at the end of `prepare()`
(after Omarchy's patch). Not on the release path yet (`build/release-path.conf`): it builds in the
build host's chroot like any new recipe until `bin/compare-build-paths` has passed for it.

**Patch:** `clock-dst-fall-back.patch` (`src/core/clock.cpp`, `SystemClock::setTime` and
`SystemClock::schedule`; plus upstream's QTest `src/core/test/clock.cpp`/`clock.hpp`, built only
with `-D BUILD_TESTING=ON`, which the package doesn't set). In the hour a DST fall-back repeats,
`QDateTime::setTime()` resolves the rounded local time to its first occurrence: the clock shows
the summer-time hour, the next tick is an hour in the past, Qt clamps the delay to 1 ms and the
tick reschedules itself, so the shell logs `QTimer::start: negative intervals aren't allowed`
about a thousand times a second for the whole hour and fills `$XDG_RUNTIME_DIR` with its log.
The patch rounds with elapsed-time arithmetic (`addMSecs`), which keeps the current occurrence,
and keeps `setTime()` where that would cross a partial-hour transition. It is upstream's commit
`7894689c` of quickshell-mirror/quickshell#1385 (Niko Storni), taken as is, less its
`changelog/next.md` line, which doesn't apply at 2b4501a. It applies at fuzz 0 after Omarchy's
`load_qtquick_611.patch`.

**Upstream status (checked 2026-11-01):** quickshell-mirror/quickshell#1385 is an open draft, for
quickshell-mirror/quickshell#329 and #1383; quickshell master is unchanged in `clock.cpp`. Omarchy
has no fix of its own (omacom/omarchy#16677, open). `UPSTREAM_PRS` has #1385 watched.

**Test:** `tests/channel/quickshell-dst-fall-back.sh` (docs/deltas.md#quickshell-clock-dst-fall-back).

**Drop when:** a quickshell Omarchy builds from contains #1385 or another fix for #329; then
`bin/unpublish quickshell` and delete this recipe.
