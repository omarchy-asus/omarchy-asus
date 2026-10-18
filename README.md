# omarchy-asus

**ASUS laptops that just work on Omarchy.**

Every ASUS laptop has its own small list of things that don't work right on Linux. A key that
dies silently. A GPU that never sleeps. A screen that goes blank after a replug. Each one can
be fixed, so we fix them. Then we send every fix upstream to Omarchy, the kernel, NVIDIA and
Hyprland, so the next person never needs this repo at all.

What you get, and the numbers: **https://omarchy-asus.github.io**

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
| `linux-omarchy`, `linux-omarchy-headers` | 7.2.8-9.1 | Fn+Super (Win-lock) reports from the ROG N-Key keyboard reach userspace instead of being dropped by `hid-asus` | Sent to linux-input, patchwork 14804337, awaiting review |
| | | *Plus an **experimental, default-off** scheduler series (Zen 5c-first soft park) for GA605KM battery testing. Compile-tested only. Nothing enables it. Not meant for upstream.* | Local carry ([notes](recipes/linux-omarchy/NOTES.md)) |
| `nvidia-open-dkms` | 615.78.08-1.2 | No hang at power-off after hibernate | [NVIDIA/open-gpu-kernel-modules#1412](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1412), open |
| | | The dGPU no longer wakes from D3cold on every battery change | [NVIDIA/open-gpu-kernel-modules#1299](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299), open |
| | | nvidia-modeset no longer leaks memory per composited frame (gigabytes over days) | [NVIDIA/open-gpu-kernel-modules#1368](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1368), open |
| `hyprland`, `hyprpm` | 0.56.2-4.1 | Windows no longer render off-screen after an HDMI replug | Fixed on main by [hyprwm/Hyprland#16140](https://github.com/hyprwm/Hyprland/pull/16140), unreleased; dropped when 0.57 ships |

The three NVIDIA fixes are open pull requests by other people. We carry them because they fix
real bugs on this hardware.

### In progress

- **Kernel 7.2.8-9.2:** an `i2c-designware` RX threshold backport (the touchpad fires about
  52 interrupts per report today) and GA605KM power limits for `asus-armoury`.
- **G16 hardware package:** touchpad wake and hibernate settings for the GA605KM.
- **Win-lock helper and G16 Control widget:** a toast when Fn+Super locks or unlocks the key.
- **Keyring and one-step setup:** one package to trust the key and add the repo.
- **Daily auto-update pipeline:** rebuild and publish on a schedule, and withdraw anything
  that fails.

## Install (G16, experimental)

Read the warning above first. Then follow [LAPTOP-SETUP.md](LAPTOP-SETUP.md): import and
locally sign the key, add the repo ahead of `[omarchy]` and `[core]`, and run
`omarchy update`. It also covers how to back out.

Signing key: [`keys/omarchy-asus.asc`](keys/omarchy-asus.asc), fingerprint
`0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88`.

## How it works

1. **Fix it in upstream's shape.** Omarchy fixes are written in
   [`omarchy-asus/omarchy`](https://github.com/omarchy-asus/omarchy), a fork of
   [basecamp/omarchy](https://github.com/basecamp/omarchy), the way Omarchy itself would
   write them: a hardware detector, a leaf gated on it, a migration and a test. Package
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
rebuilds it when upstream moves. If a patch stops applying or the build fails, our package is
withdrawn from the repo and the stock build flows through again. You never get stuck on a
stale pin. Until the automation is live, that check is run by hand.

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

- **Omarchy:** [#15667](https://github.com/basecamp/omarchy/pull/15667) stop asusd switching
  the power profile and EPP on ROG laptops,
  [#15668](https://github.com/basecamp/omarchy/pull/15668) save power on USB-C chargers on
  ROG laptops, [#15669](https://github.com/basecamp/omarchy/pull/15669) let another power
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
  upstream status, how to rebase).
- `recipes/*/UPSTREAM_PRS`: upstream pull requests a recipe carries; `bin/check-upstream`
  reports their state.
- `build/pacman.conf`: package sources for the build chroot (the Omarchy stable snapshot plus
  `[omarchy]`).
- `bin/mkchroot`: creates or updates the clean devtools chroot.
- `bin/build-pkg recipes/X`: `makechrootpkg -c -u` at idle CPU and IO priority.
- `bin/publish FILES`: signs the packages and runs `repo-add --sign --verify --remove`.
- `bin/unpublish PKG`: drops a package so the stock build flows through.
- `bin/sync-release`: mirrors the local repo to the `x86_64` GitHub release.
- `bin/issue find|file|comment|labels|template`: the issue tracker helper (duplicate check,
  PII scan); agents read [AGENTS.md](AGENTS.md) first. Offline tests:
  `python3 -I tests/test_issue.py`.
- `bin/check-upstream [--json]`: compares each package with the version upstream ships and
  the state of its upstream PRs. Exits 10 when something needs action.
- `keys/`: the repo signing key.

Maintained by [@rdoupe](https://github.com/rdoupe) and contributors.
