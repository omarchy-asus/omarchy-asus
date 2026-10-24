# omarchy-asus

**ASUS laptops that just work on Omarchy.**

Every ASUS laptop has its own small list of things that don't work right on Linux. A key that
dies silently. A GPU that never sleeps. A screen that goes blank after a replug. Each one can
be fixed, so we fix them. Then we send every fix upstream to Omarchy, the kernel, NVIDIA and
Hyprland, so the next person never needs this repo at all.

Project site: **https://omarchy-asus.github.io**

This is an unofficial community project. It is not affiliated with Basecamp, Omacom or ASUS.

> [!WARNING]
> **EXPERIMENTAL. Built for and only meant for the ASUS ROG Zephyrus G16 GA605 (GA605KM).**
> Nobody has installed these packages yet. The kernel carries untested patches, including an
> experimental scheduler series that is compiled in but switched off.
>
> Don't add this repo to any other machine. On a G16, use it only if you can recover from a
> kernel or driver that won't boot. This repo replaces `linux-omarchy`, so keep a second
> kernel such as Arch's `linux` installed as a boot fallback.

## Why

Omarchy is a great Linux setup, and it runs well on a lot of hardware. ASUS laptops need a
little more: hybrid NVIDIA graphics, ROG keyboards, power limits set by firmware, touchpads
on busy I2C buses. The fixes for these are usually small. Getting them merged and released
upstream takes weeks or months.

`omarchy-asus` closes that gap. It is a signed pacman repo with patched builds of the packages
that need fixing, plus the recipes, notes and tooling to rebuild them and the issue tracker
for the work. You get the fix today. Upstream gets a tested pull request.

## What ships

The signed `[omarchy-asus]` repo, served from the
[`x86_64` release](https://github.com/omarchy-asus/omarchy-asus/releases/tag/x86_64):

| Package | Version | What it fixes | Upstream |
|---|---|---|---|
| `linux-omarchy`, `linux-omarchy-headers` | 7.2.8-9.5 (next: 7.2.8-9.6, waiting for its G16 test) | Fn+Super (Win-lock) reports from the ROG N-Key keyboard reach userspace instead of being dropped by `hid-asus` | Sent to linux-input, patchwork 14804337, awaiting review |
| | | The touchpad's I2C controller interrupts once per batch, not once per byte (backport) | linux-next `e7d5d642c089`, not in mainline yet |
| | | `asus-armoury` knows the GA605KM's power-limit ranges (nothing is written at boot) | Not submitted yet |
| | | Three amdgpu display backports: no self-refresh on tearing flips, s0i3 pipe teardown, OLED CACP control (off by default) | Mainline v7.3-rc1 / stable |
| | | *9.4:* the GA605KM no longer wakes from s2idle at once while an HDMI monitor is connected (GPIO 16 wakeups ignored) | Not submitted yet (linux-gpio) |
| | | *9.5 (RC):* a USB4 dock's monitors come back when the dock was replugged during suspend (amdgpu replays the hotplugs it skipped while resuming, #205) | Not submitted yet (amd-gfx) |
| | | *9.6:* after a hibernate resume the EC gets the thermal profile and fan curves back, so quiet on battery stays quiet (fans off) instead of running the balanced table | Not submitted yet (platform-driver-x86) |
| | | *Plus an **experimental, default-off** scheduler series (Zen 5c-first soft park) for GA605KM battery testing. Compile-tested only. Nothing enables it. Not meant for upstream.* | Local carry ([notes](recipes/linux-omarchy/NOTES.md)) |
| `nvidia-open-dkms` | 615.78.08-1.2 | No hang at power-off after hibernate | [NVIDIA/open-gpu-kernel-modules#1412](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1412), open |
| | | The dGPU no longer wakes from D3cold on every battery change | [NVIDIA/open-gpu-kernel-modules#1299](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299), open |
| | | nvidia-modeset no longer leaks memory per composited frame (gigabytes over days) | [NVIDIA/open-gpu-kernel-modules#1368](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1368), open |
| | | *1.102 (RC):* an empty HDMI port no longer comes back as a phantom monitor after hibernate, keeping the dGPU awake (#213) | Not submitted yet (NVIDIA/open-gpu-kernel-modules) |
| `hyprland`, `hyprpm` | 0.56.2-4.1 | Windows no longer render off-screen after an HDMI replug | Fixed on main by [hyprwm/Hyprland#16140](https://github.com/hyprwm/Hyprland/pull/16140), unreleased; dropped when 0.57 ships |
| `omarchy-asus-g16` | 1.0.0-1 | GA605KM: the touchpad no longer wakes the laptop; hibernate powers off cleanly (`HibernateMode=shutdown`); Dynamic Boost keeps working after many charger plug-ins (nvidia-powerd start limit) | Not yet proposed upstream; files are byte-identical to the [omarchy fork](https://github.com/omarchy-asus/omarchy)'s, under `/usr/lib` ([notes](recipes/omarchy-asus-g16/README.md)) |
| `asus-rog-nkey-winlock` | 0.1.0-9 (main: 0.1.0-10) | A toast when Fn+Super locks or unlocks the Windows key, or auto-unlock (needs the kernel's Win-lock patch) | Userspace for the kernel patch ([notes](recipes/asus-rog-nkey-winlock/README.md)) |
| **omarchy-asus plugin**: the bar widget, [omarchy-asus/omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin) (Omarchy plugin) | 1.4.0 | One panel for the laptop's hardware: keyboard and Slash LEDs; per-charger keyboard, refresh rate, backlight and CPU power limits; charge limit; the Fn+Super switch. Install: `omarchy-plugin-add https://github.com/omarchy-asus/omarchy-asus-plugin --enable`. It replaced the `asus-zephyrus-g16-control` package (transitional) | Ours |
| `omarchy`, `omarchy-settings` | 4.0.6-1.1 | **Experimental.** Stock Omarchy 4.0.6 plus the fork's fixes in Omarchy's own scripts and migrations: asusd stops overriding the power profile; USB-C chargers get the battery profile and a charger swap re-applies it; another power manager can own the profile; GA605KM fans stop at idle on battery; a software cursor while an NVIDIA-driven monitor is plugged in; video decode stays on the iGPU; ALC285 Master at full scale; rtkit for PipeWire; no NVIDIA early load on hybrids; four perf fixes; a crashed shell gets its lock screen back while dictation is installed. Migrations leave fixes you made by hand alone | Each fix's upstream PR or draft is listed in the [notes](recipes/omarchy/NOTES.md) |
| `omarchy-asus-g16-apply` | 0.1.0-7 (main: 0.1.0-8) | A command you run yourself. It reports every known G16 fix with `--check` and applies the ones that live in your own config or `/etc` | Local tool ([notes](recipes/omarchy-asus-g16-apply/README.md)) |

Versions are what the release serves now. When main gets ahead, the daily auto-update
publishes the new build.

On a fresh G16, the patched `omarchy` and `omarchy-settings` (#58) apply the G16 fixes that
live in your own config or `/etc` (iGPU video decode, HDMI cursor, rtkit, asusd) through their
migrations on `omarchy update`. `omarchy-asus-g16-apply` reports every known G16 fix with
`--check`, and is the manual path on a stock install and for the speaker level, which no
migration raises. Settings you already have are left alone. See
[its README](recipes/omarchy-asus-g16-apply/README.md).

The three NVIDIA fixes are open pull requests by other people. We carry them because they fix
real bugs on this hardware.

## Install (G16, experimental)

Read the warning above first. Then follow [LAPTOP-SETUP.md](LAPTOP-SETUP.md): import and
locally sign the key, add the repo ahead of `[omarchy]` and `[core]`, and run
`omarchy update`. [`bin/omarchy-asus-setup`](bin/omarchy-asus-setup) does those steps in one
go (`--dry-run` to preview, `--uninstall` to undo). LAPTOP-SETUP.md also covers how to back out.

Signing key: [`keys/omarchy-asus.asc`](keys/omarchy-asus.asc), fingerprint
`0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88`. The same key is on [keys.openpgp.org](https://keys.openpgp.org/vks/v1/by-fingerprint/0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88), so you can check it somewhere other than GitHub.

## How it works

1. **Fix it in upstream's shape.** Omarchy fixes are written in
   [`omarchy-asus/omarchy`](https://github.com/omarchy-asus/omarchy), a fork of
   [omacom/omarchy](https://github.com/omacom/omarchy), the way Omarchy itself would
   write them: a hardware detector, a leaf gated on it, a migration and a test. Each fix is
   one topic branch on top of `quattro`, a mirror of upstream's, listed in the
   [fork-tools README](https://github.com/omarchy-asus/omarchy/tree/fork-tools); the
   omarchy packages carry those fixes as patches from the v4.0.5 backport branch `asus/v4-0-5`. Package
   changes go through [`omarchy-asus/omarchy-pkgs`](https://github.com/omarchy-asus/omarchy-pkgs), a fork of
   [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs).
2. **Package it.** When a fix needs a patched build (a kernel, a driver, a compositor), the
   recipe lives here. Every version is upstream's plus `.1`, for example `615.78.08-1.1`, so
   it installs over the stock build it replaces.
3. **Send it upstream.** Every patch carries a link to its upstream pull request or
   submission. A patch with no upstream path needs a written reason.
4. **Delete it.** When upstream releases the fix, the patch and then the package are dropped,
   and the stock build takes over. Success is this repo getting smaller.

### Staying current

The repo is listed first in `pacman.conf`, so our build wins even when upstream ships a newer
one. That means we have to keep up. A daily check compares each package with upstream and
rebuilds it when upstream moves. If a patch stops applying or the build fails, our last build
stays published and the run flags what needs fixing: on our channels you always get our patched
version, never the stock one, until upstream folds the fix in and we drop the recipe. That check is `bin/auto-update`, run by a daily systemd timer: it opens a rebase
pull request, builds it in a clean chroot as CI, and merges and publishes only after
a verified AI review (`bin/ai-review`) and an agent review pass. The timer runs daily on the build host.

## Release channels

Each of our channels is pinned to one of Omarchy's, and a machine switches both together:

| our channel | built from | chroot and machines use Omarchy's | release (`Server`) |
|---|---|---|---|
| Quattro | `main` | `pkgs.omarchy.org/stable`, `stable-mirror.omarchy.org` | [`x86_64`](https://github.com/omarchy-asus/omarchy-asus/releases/tag/x86_64) (`.../releases/download/$arch`) |
| RC | `next/omarchy-4.5` | `pkgs.omarchy.org/rc`, `rc-mirror.omarchy.org` | `rc-x86_64` (`.../releases/download/rc-$arch`) |

Mixing them breaks upgrades: Omarchy 4.5's migrations install packages that may only exist in
Omarchy's rc repo, and one failed migration holds back every later one, ours included. On a G16,
switching is Omarchy's own `omarchy-channel-set rc` (or `stable`, which downgrades to the Quattro
versions): the pre-refresh hook `omarchy-asus-setup` installs moves the `[omarchy-asus]` server to
the release that matches `[omarchy]` before the upgrade runs, so `omarchy update` and
`omarchy-channel-set` need nothing of ours. A first setup picks the channel that matches the
machine's Omarchy channel. An install set up before the hook did this gets it by running
`omarchy-asus-setup` again (LAPTOP-SETUP.md, "Release channels").

On the build host, the build and publish scripts take `--channel rc` (default `quattro`):
`bin/mkchroot --channel rc` makes the RC chroot from `build/pacman-rc.conf`, `bin/build-pkg
--channel rc` builds in it and stages in its own dir, and `bin/publish`/`bin/sync-release
--channel rc` sign and upload to the RC repo and release only, with the same signature, checksum
and personal-information checks. A package staged for one channel is refused by the other's
`bin/publish`. The daily `bin/auto-update` timer keeps both channels current, one run per
channel with the same gates (systemd/README.md, "Release channels"): Quattro from `main`, RC
from `next/omarchy-4.5` in the RC chroot, published to `rc-x86_64`.

A package filename names one file on both channels, since pacman caches by filename. The RC
channel's `pkgrel` sits in its own range: a package rebuilt from a stock one is
`<upstream pkgrel>.101` and up on RC (`.1` to `.99` on Quattro), and our own packages are 101 and
up on RC (1 to 99 on Quattro). `bin/rebase-recipe --channel rc` starts at `.101`, the recipes lint
(`ci/check-pkgrel`) checks the range of the channel a PR targets, and `bin/publish` refuses a
filename the other channel's repo or release already has with different bytes. RC sorts above
Quattro for the same upstream release, so a switch back to Quattro is a downgrade, which
`omarchy-channel-set stable` already does (its refresh runs `pacman -Syyuu`).

## Supported hardware

| Model | CPU / GPU | Status |
|---|---|---|
| ROG Zephyrus G16 GA605 (GA605KM) | Ryzen AI 300, RTX 50-series laptop GPU | Experimental |

That's one laptop today. We want every ASUS laptop. If you have one, open an issue with the
output of `cat /sys/class/dmi/id/product_name`, `uname -r` and `omarchy version`, and tell us
what's broken. [CONTRIBUTING.md](CONTRIBUTING.md) has the details.

## Contributing

Everyone is welcome. Hardware reports, bug fixes, testing, suggestions, new models: all of it
helps. Keep pull requests small, test them on real hardware, and explain the bug. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [PRINCIPLES.md](PRINCIPLES.md).

## Upstream

Where our fixes are headed:

- **Omarchy:** [#15667](https://github.com/omacom/omarchy/pull/15667) stop asusd switching
  the power profile and EPP on ROG laptops,
  [#15668](https://github.com/omacom/omarchy/pull/15668) save power on USB-C chargers on
  ROG laptops, [#15669](https://github.com/omacom/omarchy/pull/15669) let another power
  manager own the profile on plug and unplug.
- **NVIDIA:** [#1412](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1412) and
  [#1299](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299) and
  [#1368](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1368), all carried here and
  all written by others.
- **Hyprland:** [#16140](https://github.com/hyprwm/Hyprland/pull/16140), merged, waiting on
  a release.
- **Linux:** `hid-asus` Win-lock pass-through, on linux-input as patchwork 14804337.

## Repo layout

- `recipes/<pkg>/`: PKGBUILDs, patches and a `NOTES.md` for each package (base, changes,
  upstream status, how to rebase). `DELTA` declares how the recipe differs from upstream;
  `LOCAL_ONLY` marks a package with no upstream build; `HOLD` (its first line is the reason)
  keeps `bin/auto-update` from building or publishing a recipe.
- `recipes/omarchy-asus-keyring/`: keyring package (`pacman-key --populate omarchy-asus`),
  packaged like omarchy-keyring. Its `omarchy-asus.gpg` is a copy of `keys/omarchy-asus.asc`.
- `bin/omarchy-asus-setup`: the one-step setup a user runs on a G16. See LAPTOP-SETUP.md.
- `recipes/*/UPSTREAM_PRS`: upstream pull requests a recipe carries; `bin/check-upstream`
  reports their state.
- `build/pacman.conf`: package sources for the build chroot (the Omarchy stable snapshot plus
  `[omarchy]`); `build/pacman-rc.conf` is the RC channel's (Omarchy rc). `bin/env.sh` maps each
  channel to its chroot, stage dir, local repo and release.
- `bin/mkchroot`: creates or updates the clean devtools chroot.
- `bin/build-pkg recipes/X`: `makechrootpkg -c -u` at idle CPU and IO priority.
- `bin/publish FILES`: signs the packages and runs `repo-add --sign --verify --remove`. It
  refuses to publish a release cohort member from `build/cohorts.conf` (e.g. omarchy and
  omarchy-settings) without its partner at the same version, in the same call or already in
  the db.
- `bin/unpublish PKG`: drops a package so the stock build flows through (once its recipe is
  removed: `bin/auto-update` withdraws nothing else); it withdraws the
  whole release cohort (the partners the db holds) with it.
- `bin/release-cohort members|check-publish|check-recipes`: the release cohorts in
  `build/cohorts.conf`. `members` lists a package's partners, `check-publish` is the gate
  `bin/publish` runs, `check-recipes` checks that a member's `package()` pins its partner
  as `=${pkgver}-${pkgrel}` (never the build-time `depends=()`: the chroot only has the stock
  partner), and warns when the members' `_tag`, `_commit`, `pkgver`, `pkgrel`, sources or
  checksums differ (`--strict`: refuses; offline test: `tests/ci/release-cohort.sh`).
- `bin/sync-release`: mirrors the local repo to the `x86_64` GitHub release (`--channel rc`: the
  RC repo to the `rc-x86_64` release). It uploads nothing (exit 3) while the repo lacks our
  build of a package the previous release served and a recipe of the checkout it runs from
  still ships (RC: the Quattro release counts too; systemd/README.md, "No regression"), so run
  it from a checkout of the channel's branch.
- `bin/issue find|file|comment|labels|template`: the issue tracker helper (duplicate check,
  PII scan); agents read [AGENTS.md](AGENTS.md) first. Offline tests:
  `python3 -I tests/test_issue.py`.
- `bin/check-upstream [--json]`: compares each package with the version upstream ships and
  the state of its upstream PRs. Exits 10 when something needs action.
- `bin/rebase-recipe`: rebuilds a recipe from a new upstream release plus its `DELTA` and
  checks it with `makepkg --nobuild`.
- `bin/revdep-check`: builds a DKMS package against a kernel headers package in a throwaway
  chroot; `build/revdeps.conf` lists the pairs checked before publishing either one.
- `bin/auto-update`: the daily pipeline (rebase PR, chroot build, reviews, merge and
  publish; on failure our last build stays published).
- `bin/install-auto-update` and `systemd/`: the service and timer units and their installer;
  [systemd/README.md](systemd/README.md) covers the design and the privilege model.
- `recipes/omarchy-asus-g16-apply/`: the user-run command for the G16 fixes no package can
  ship (they live in your config or `/etc`); `--check` is read-only.
- `recipes/omarchy-asus-g16-testd/`: G16 hardware test sessions' root helper, started with
  one polkit dialog per session, with fixed allowlisted steps that are all put back at the
  end (held; test tooling).
- `keys/`: the repo signing key.
- `.github/workflows/`, `ci/`: PR CI on GitHub Actions (lint, build the changed recipes in an Arch
  container with the package sources of the channel the PR targets (`ci/channel`), compile
  nvidia-open-dkms against linux-omarchy-headers). Artifacts are unsigned;
  signing and publishing stay on the maintainer's machine.

Maintained by [@rdoupe](https://github.com/rdoupe) and contributors.

## License

The tooling, docs and our own recipe files are [MIT](LICENSE). Packaged software keeps its own upstream license (each recipe declares it), and patches carried from upstream projects keep theirs.
