# Carried changes

Every change omarchy-asus carries on top of upstream (Omarchy, Arch, the kernel, NVIDIA,
Hyprland), and every package it ships of its own, has one entry here. This file is the record:
a carried change has no open GitHub issue. Issues are for work only: bugs, experiments being
measured or tested, and tasks (AGENTS.md, "Carried changes").

Each entry gives the component and the patch or package, what it fixes, how to test it, its
upstream state, when to drop it, and anything else worth keeping: measurements, merge commit IDs,
review notes and, where one exists, an **Upstream report draft** for a human to post. Each entry's
anchor (`#kernel-0568-winlock`, ...) is stable: link to it from issues, pull requests and
`NOTES.md`, and keep it when the heading changes.

**Upstream state** is one of:

- **open**: an upstream pull request, patch submission or issue is open;
- **merged-unreleased**: upstream merged it, but no release we build from contains it yet;
- **not submitted**: it belongs upstream, nobody has sent it yet;
- **ours-only**: not for upstream (our own packages, repo infrastructure, experiments).

**Channels.** `main` is the RC channel's trunk (release `rc-x86_64`, Omarchy rc). The Quattro
channel (release `x86_64`, Omarchy stable) is frozen on what it serves until the Omarchy 4.5
stable switch (README.md, "Release channels"). "Both" means both releases serve it; "RC only"
means only `rc-x86_64` does. Versions below are what each release serves, as of 2026-10-25.

**What the daily check watches.** `bin/check-upstream` reads `recipes/*/UPSTREAM_PRS` (one
`owner/repo#N` per line) and reports each pull request's state; a merged one needs action. Today
only `recipes/nvidia-open-dkms/UPSTREAM_PRS` exists, so the upstream states of every other entry
are kept by hand, here and in the recipe's `NOTES.md`. `recipes/hyprland/DELTA`'s
`fixed-upstream` line flags the first Hyprland release with a given commit. To have a GitHub pull
request watched, add it to its recipe's `UPSTREAM_PRS`.

**Keeping it current.** A pull request that adds a patch or a shipped change adds its entry here,
and the recipe's `DELTA` and `NOTES.md`, in the same pull request. A pull request that drops a patch
moves its entry to [Dropped](#dropped), with the release that contains the fix (or why it went).
An upstream state that changes is updated here, with the date it was checked.

## Index

| entry | component | patch / file | channels | upstream |
|---|---|---|---|---|
| [hid-asus Win-lock pass-through](#kernel-0568-winlock) | linux-omarchy | 0568 | both | open |
| [i2c-designware RX FIFO threshold](#kernel-0569-i2c-designware) | linux-omarchy | 0569 | both | merged-unreleased |
| [amdgpu display power backports](#kernel-0481-amdgpu-display-power) | linux-omarchy | 0481 | both | merged-unreleased |
| [amdgpu replays DMUB HPDs skipped in resume](#kernel-0482-dmub-hpd-replay) | linux-omarchy | 0482 | RC only | not submitted |
| [gpiolib-acpi ignores GPIO 16 wakeups on the GA605KM](#kernel-0773-gpio16-wake) | linux-omarchy | 0773 | both | not submitted |
| [asus-armoury GA605KM power limits](#kernel-0807-armoury-power-limits) | linux-omarchy | 0807 | both | not submitted |
| [asus-wmi restores the thermal policy after hibernation](#kernel-0808-thermal-policy-restore) | linux-omarchy | 0808 | RC only | not submitted |
| [panel_power_savings applies when written](#kernel-0810-panel-power-savings) | linux-omarchy | 0810 | RC only | not submitted |
| [EXPERIMENTAL Zen 5c-first soft park](#kernel-9900-zen5c-soft-park) | linux-omarchy | 9900 | both | ours-only |
| [EXPERIMENTAL DCN 3.5 S0i2-ready display idle](#kernel-9901-dcn35-s0i2) | linux-omarchy | 9901 | RC only | not submitted |
| [EXPERIMENTAL display idle with every CRTC off](#kernel-9902-dm-idle-all-off) | linux-omarchy | 9902 | RC only | not submitted |
| [EXPERIMENTAL SMU idlemask trace through s2idle](#kernel-9903-idlemask-trace) | linux-omarchy | 9903 | RC only | ours-only |
| [EXPERIMENTAL idlemask trace between amdgpu's suspend and the LPS0 calls](#kernel-9904-idlemask-window) | linux-omarchy | 9904 | RC only | ours-only |
| [EXPERIMENTAL idlemask trace after each PCI device's noirq suspend](#kernel-9905-idlemask-noirq-devices) | linux-omarchy | 9905 | RC only | ours-only |
| [EXPERIMENTAL runtime PM for the PSP function](#kernel-9906-psp-rpm) | linux-omarchy | 9906 | RC only | not submitted |
| [EXPERIMENTAL SMU metrics table at runtime](#kernel-9907-smu-metrics-runtime) | linux-omarchy | 9907 | RC only | ours-only |
| [EXPERIMENTAL display idle kept allowed with every CRTC off](#kernel-9908-dm-idle-kept) | linux-omarchy | 9908 | RC only | not submitted |
| [EXPERIMENTAL the GA605KM keyboard declares only its Caps Lock LED](#kernel-9909-nkey-caps-led-only) | linux-omarchy | 9909 | RC only | not submitted |
| [EXPERIMENTAL debugfs to send the SMU AllowZstates message](#kernel-9910-smu-allow-zstates) | linux-omarchy | 9910 | RC only | ours-only |
| [hibernate power-off](#nvidia-0001-hibernate-power-off) | nvidia-open-dkms | 0001 | both | open |
| [NVPCF defer (+refcount fix)](#nvidia-0002-nvpcf-defer) | nvidia-open-dkms | 0002 | both | open |
| [nvkms semaphore leak](#nvidia-0003-semaphore-leak) | nvidia-open-dkms | 0003 | both | open |
| [HDMI with no EDID is disconnected](#nvidia-0004-hdmi-no-edid) | nvidia-open-dkms | 0004 | RC only | not submitted |
| [reconnect render offset](#hyprland-reconnect-render-offset) | hyprland | `reconnect-render-offset.patch` | both | merged-unreleased |
| [wl_keyboard.leave before the seat loses its keyboard](#hyprland-seat-leave) | hyprland | `seat-leave-on-capability-loss.patch` | RC only | not submitted |
| [asusd profile/EPP hand-off](#omarchy-0001-asusd-hand-off) | omarchy | 0001 | both | open |
| [USB-C power policy](#omarchy-0002-usbc-power) | omarchy | 0002 | both | open |
| [power profiles: external owner](#omarchy-0003-external-owner) | omarchy | 0003 | both | open |
| [GA605KM quiet fans on battery](#omarchy-0004-quiet-fans) | omarchy | 0004 | both | not submitted |
| [HDMI software cursor](#omarchy-0005-hdmi-cursor) | omarchy | 0005, 0019 | both | not submitted |
| [hybrid video decode on the iGPU](#omarchy-0006-hybrid-video-decode) | omarchy | 0006-0008, 0020, 0023 | both | not submitted |
| [ALC285 Master at 100%](#omarchy-0009-alc285-master) | omarchy | 0009 | both | not submitted |
| [rtkit on x86_64](#omarchy-0010-rtkit) | omarchy | 0010-0011, 0022 | both | open |
| [no NVIDIA early load in the initramfs](#omarchy-0012-initramfs) | omarchy | 0012-0013, 0021 | both | open |
| [webcam guard from udev](#omarchy-0014-webcam-guard) | omarchy | 0014-0015 | both | open |
| [Tailscale panel](#omarchy-0016-tailscale) | omarchy | 0016 | both | open / merged-unreleased |
| [clamshell state from logind events](#omarchy-0017-monitor-watch-logind) | omarchy | 0017 | both | not submitted |
| [launcher icon index throttle](#omarchy-0018-launcher-icon-index) | omarchy | 0018 | Quattro only | not submitted |
| [stranded lock recovered while voxtype runs](#omarchy-0024-stranded-lock) | omarchy | 0024 | both | open |
| [G16 Control widget's dead link swapped for the plugin](#omarchy-0025-widget-link) | omarchy | 0025 | RC only | ours-only |
| [the RTX stays asleep while apps start](#omarchy-0026-rtx-asleep-at-app-start) | omarchy | 0026 | RC only | not submitted |
| [floating mode waits for the app's redraw](#omarchy-general-0001-floating-redraw) | omarchy | general-0001 | RC only | not submitted |
| [the sleep lock's monitor survives suspends](#omarchy-general-0002-sleep-monitor) | omarchy | general-0002 | RC only | not submitted |
| [app library rescans only on real changes](#omarchy-general-0004-app-library) | omarchy | general-0004 | RC only | open |
| [omarchy pins omarchy-settings to its release](#omarchy-pkgbuild-pin-settings) | omarchy | `pkgbuild-pin-settings-release.diff` | both | ours-only |
| [omarchy-settings ships the charger-swap monitor unit](#omarchy-pkgbuild-source-monitor-unit) | omarchy-settings | `pkgbuild-source-monitor-unit.diff` | both | not submitted |
| [the "(omarchy-asus build)" label](#pkgbuild-pkgdesc-label) | omarchy, omarchy-settings, hyprland, hyprpm | `pkgbuild-pkgdesc-label.diff` | both | ours-only |
| [touchpad wake (ASUF1209)](#g16-touchpad-wake) | omarchy-asus-g16 | udev rule | both | not submitted |
| [HibernateMode=shutdown](#g16-hibernate-mode) | omarchy-asus-g16 | sleep.conf.d drop-in | both | not submitted |
| [nvidia-powerd start limit](#g16-nvidia-powerd-start-limit) | omarchy-asus-g16 | unit drop-in | both | not submitted |
| [rcu_nocbs=all](#g16-rcu-nocbs) | omarchy-asus-g16 | limine-entry-tool drop-in | RC only | ours-only |
| [Wi-Fi back after a wake (mt7925)](#g16-mt7925-auth-retries) | omarchy-asus-g16 | NetworkManager drop-in | RC only | not submitted |
| [EXPERIMENTAL built-in keyboard autosuspend](#g16-keyboard-autosuspend) | omarchy-asus-g16 | udev rule | RC only | ours-only |
| [Win-lock helper](#pkg-asus-rog-nkey-winlock) | asus-rog-nkey-winlock | package | both | ours-only |
| [keyring and setup script](#pkg-omarchy-asus-keyring) | omarchy-asus-keyring, `bin/omarchy-asus-setup` | package | both | ours-only |
| [G16 fix applier](#pkg-omarchy-asus-g16-apply) | omarchy-asus-g16-apply | package | both | ours-only |
| [G16 test-session helper (held)](#pkg-omarchy-asus-g16-testd) | omarchy-asus-g16-testd | package | held | ours-only |
| [Proton Experimental fullscreen fix (held)](#pkg-proton-experimental-asus) | proton-experimental-asus | package | held | not submitted |

[Not carried](#not-carried) lists the candidates still in issues; [Dropped](#dropped) lists what
we no longer carry.

## Kernel: linux-omarchy

RC 7.2.8-9.107 (`main`), Quattro 7.2.8-9.4. The patch list is `recipes/linux-omarchy/DELTA`; the
why, the risks and the long test scripts are in `recipes/linux-omarchy/NOTES.md`. Our patches have
no `.sig` (upstream's patch signatures use the Omarchy kernel maintainer's key); their checksums
pin them. The G16 test kit (`recipes/linux-omarchy/g16-test/`) runs a check for each patch.

<a id="kernel-0568-winlock"></a>
### hid-asus Win-lock pass-through (0568)

- **Component:** `linux-omarchy`, `0568-hid-asus-pass-through-rog-nkey-win-lock-reports.patch`.
  Both channels, carried since 7.2.8-9.1.
- **Fixes:** stock `hid-asus` drops the ROG N-Key keyboard's (USB `0b05:19b6`) Win-lock
  notifications (report `0x5d`, opcode `0xbf 0x01`) together with the AURA echo stream. Fn+Super
  then disables the Super key silently: nothing reaches hidraw, so no userspace helper can show a
  toast or undo the lock. The patch adds `QUIRK_HID_WIN_LOCK` for `ROG_NKEY_KEYBOARD2`. Its
  userspace consumer is [the Win-lock helper](#pkg-asus-rog-nkey-winlock).
- **Test:** boot the kernel (`uname -r`). Stop the helper if it runs (Quattro:
  `systemctl --user stop g16-winlock.service`), run `g16-winlock watch --mode=toast` and press
  Fn+Super twice: expect "Win-lock on", then "Win-lock off". Without the patch, `watch` waits
  forever. Raw check: read the keyboard's hidraw node and look for `5d bf 01 xx` on each press.
- **Upstream: open.** Submitted to linux-input on 2026-09-10, patchwork **14804337**, no replies.
  Checked 2026-10-25: not upstream; `hid-asus.c` in v7.2.8 (what we build), v7.3 and mainline
  master after the 7.4 HID merge (`5ac62bdef71a`) still drops report 0x5d whole.
- **Drop when:** mainline or the HID tree carries an equivalent quirk **and** a stock
  `linux-omarchy` release contains it. If nothing else is left in the kernel recipe then,
  `bin/unpublish linux-omarchy linux-omarchy-headers` and delete the recipe.
- **Notes:** before the kernel package existed, the same patch ran as an out-of-tree DKMS module
  (`recipes/hid-asus-winlock-dkms-reference/`, not built or published). With 9.1 or later
  installed it finds no matching variant and installs nothing, so the in-tree patched driver is
  used. Formerly tracked in issue #9.

<a id="kernel-0569-i2c-designware"></a>
### i2c-designware RX FIFO threshold (0569)

- **Component:** `linux-omarchy`, `0569-i2c-designware-size-rx-fifo-threshold.patch`. Both
  channels; added in 7.2.8-9.2, first published in 9.3 (#8, `62a3ea67`), booted on the G16.
- **Fixes:** mainline leaves `DW_IC_RX_TL` at 0 in master mode, so the DesignWare I2C controller
  behind the touchpad raises one RX_FULL interrupt per received byte: about 12.6k interrupts/s while
  touching on the G16, about 52 per touchpad report (about 67 bytes per report at 240 reports/s).
  The patch fires RX_FULL once per queued batch instead: several times fewer interrupts while the
  pad is in use, and fewer wakeups. Touch latency is unchanged. It applies to every DesignWare
  controller in master mode; no knob.
- **Test:** count the controller's interrupts (`grep -iE 'AMDI0010|designware' /proc/interrupts`)
  over 10 s of touchpad movement and divide by the reports (`evtest` or `libinput debug-events`);
  stock is about 12,600/s. Expect a large drop, no lost or laggy input, and no new
  `i2c_designware`/`i2c-hid` timeouts in `journalctl -k -b`, also across suspend, resume and
  hibernate. The full script is in NOTES.md, "0569".
- **Upstream: merged-unreleased.** It is upstream commit `e7d5d642c089` ("i2c: designware: size
  the RX FIFO threshold to the queued transfer", applied to the i2c-host tree, in linux-next since
  2026-10-10), carried with its original header. Checked 2026-10-25: not in 7.3 (not in 7.3-rc7),
  so it is headed for 7.4. It replaced a local draft that was never sent.
- **Drop when:** linux-omarchy is based on a kernel that contains `e7d5d642c089` (7.4 or later),
  or upstream linux-omarchy carries it (0569 then fails to apply at fuzz 0, which shows it).
- **Notes:** formerly tracked in issue #35.

<a id="kernel-0481-amdgpu-display-power"></a>
### amdgpu display power backports (0481)

- **Component:** `linux-omarchy`, `0481-drm-amd-display-power-backports.patch`, right after
  0480. Both channels, carried since 7.2.8-9.3 (#8, `62a3ea67`), booted on the G16 on 2026-10-20.
- **Fixes:** three amdgpu display changes for the G16's Radeon 860M and OLED eDP:
  - self-refresh (PSR/Replay) off on tearing (async) flips (`2e54a92e0136`);
  - an orphaned pipe left by firmware is torn down on boot, so it no longer blocks s0i3 on
    suspend (`98e08a815ef6`);
  - CACP for the OLED eDP, hand-ported from `7b0cc3085216`: adds
    `card*-eDP-1/amdgpu/panel_power_savings` (0-4). It boots at 0 and nothing in this repo
    enables it (no cmdline, udev rule or ppd action).

  An optional staging fix (`37230d7cb7`, flush ISM work before releasing the stream) is not
  carried.
- **Test:** `cat /sys/class/drm/card*-eDP-1/amdgpu/panel_power_savings` reads `0`;
  `/sys/power/mem_sleep` lists `[s2idle]`, and after a suspend
  `sudo cat /sys/kernel/debug/amd_pmc/s0ix_stats` shows s0i3 residency going up; a game or video
  with tearing on shows no PSR flicker.
- **Measurements (G16, 7.2.8-9.3, 2026-10-20, power-profiles-daemon owning the profile):**

  | state | ppd profile | `card1-eDP-1/amdgpu/panel_power_savings` |
  |---|---|---|
  | battery | balanced | 0 |
  | battery | power-saver (`omarchy-powerprofiles-set battery power-saver`, read after 4 s) | 0 |
  | battery, back to balanced | balanced | 0 |

  ppd's `amdgpu_panel_power` action left the level at 0, so CACP stays off. Not checked: AC in
  power-saver, and whether a later ppd release turns the action on by default.
- **Upstream: merged-unreleased.** Checked 2026-10-25: all three are in mainline 7.3
  (`98e08a815ef6` and `7b0cc3085216` by 7.3-rc1, `2e54a92e0136` by rc7; `2e54a92e0136` is in 7.2.11
  stable too). Nothing to submit.
- **Drop when:** linux-omarchy rebases onto a 7.3 Omarchy kernel (the self-refresh part alone
  could go at 7.2.11).
- **Notes:** formerly tracked in issue #46.

<a id="kernel-0482-dmub-hpd-replay"></a>
### amdgpu replays DMUB HPDs skipped during resume (0482)

- **Component:** `linux-omarchy`, `0482-drm-amd-display-replay-dmub-hpd-skipped-in-suspend.patch`,
  after 0481. RC only (since 9.5; 9.103 now).
- **Fixes:** with the G16 on a USB4 dock (two DP monitors), replugging the dock during suspend
  left both monitors dark after resume: the DPIA HPDs for the new DP tunnels arrive while
  `in_suspend` is still set and were dropped, so the tunnels were torn down 12 s later. The patch
  records each skipped HPD's link and replays it from a new DM `.complete` callback once resume
  completes, through the normal HPD path.
- **Test:** `recipes/linux-omarchy/g16-test/test --dock`. By hand: close the lid, unplug the dock,
  wait for the suspend, plug the dock back in, open the lid; `journalctl -k -b | grep -E 'Skip
  DMUB HPD|Replay DMUB HPD|not active, tearing down'` shows skips followed by replays and no
  teardown, and both monitors are lit.
- **Upstream: not submitted** (target amd-gfx). Mainline and amd-staging-drm-next (2026-10-20)
  still drop these HPDs. A draft report is on bug #205.
- **Drop when:** upstream handles HPDs that arrive late in resume.
- **Notes:** #205's second failure (a DPIA link trained at RBR after a resume) has no root cause;
  `test --dock` records each link's settings. Details: NOTES.md, "0482".

<a id="kernel-0773-gpio16-wake"></a>
### gpiolib-acpi ignores GPIO 16 wakeups on the GA605KM (0773)

- **Component:** `linux-omarchy`, `0773-gpiolib-acpi-ignore-wake-on-gpio16-asus-ga605km.patch`.
  Both channels, carried since 7.2.8-9.4.
- **Fixes:** with an HDMI monitor connected (driven by the RTX), the G16 woke from s2idle about
  95 ms after entering it, on battery or AC: firmware GPIO 16 (`amd_gpio 16 ACPI:Event`, an `_AEI`
  pin) fires (`ACPI: PM: Wakeup unrelated to ACPI SCI`, `GPIO 16 is active`). Lid-close and idle
  suspend left it awake with the screens off (bug #132). The patch adds a DMI entry (vendor
  `ASUSTeK COMPUTER INC.`, board `GA605KM`) with `.ignore_wake = "AMDI0030:00@16"` to
  `drivers/gpio/gpiolib-acpi-quirks.c`, the same pattern as the existing entries. It changes
  nothing on other machines.
- **Measurements (#132, comments 6283063898 and 6283194700):**

  | condition | last_hw_sleep |
  |---|---|
  | battery / barrel / battery + phone, no HDMI | 13-43 s (sleeps) |
  | barrel + HDMI / battery + HDMI | 0.095 s (GPIO 16 wakes it) |
  | battery + HDMI with `gpiolib_acpi.ignore_wake=AMDI0030:00@16` | 10.5 s, and 33 s in the HDMI-unplug test |
  | lid close then open, with the option | 44.3 s; the lid wakes it in one go via GPIO 0 |

  The keyboard (GPIO 58) and lid (GPIO 0) still wake it, and both monitors come back at full mode.
- **Test:** boot without the cmdline option (remove a local
  `/etc/limine-entry-tool.d/98-g16-test-gpio16.conf` first); `journalctl -k | grep 'Ignoring
  wakeup on pin 16'` shows one line; suspend with HDMI connected:
  `/sys/power/suspend_stats/last_hw_sleep` reads seconds, not about 95000 µs; a key and the lid
  still wake it.
- **Upstream: not submitted.** Target linux-gpio (`gpiolib-acpi-quirks.c` DMI table,
  `DMI_SYS_VENDOR "ASUSTeK COMPUTER INC."`, `DMI_PRODUCT_NAME "ROG Zephyrus G16
  GA605KM_GA605KM"`). Decoding what GPIO 16's `_AEI` handler is for (it needs an acpidump) would
  strengthen the submission. Related: #132, #133, omacom/omarchy#11794.
- **Drop when:** an equivalent entry is merged upstream and reaches linux-omarchy.
- **Notes:** formerly tracked in issue #151.

<a id="kernel-0807-armoury-power-limits"></a>
### asus-armoury GA605KM power limits (0807)

- **Component:** `linux-omarchy`, `0807-platform-x86-asus-armoury-ga605km-power-limits.patch`.
  Both channels; added in 7.2.8-9.2, first published in 9.3 (#8).
- **Fixes:** without a `power_limits` DMI entry the stock kernel logs `No matching power limits
  found for this system`, and the ppt_*, nv_dynamic_boost and nv_temp_target firmware attributes
  return `-ENODEV`, so asusd, ROG Control Center and scripts can't set CPU power limits. The entry
  gives the GA605KM its ranges (AC: SPL 15-80 W, SPPT 35-80 W, FPPT 35-80 W, Dynamic Boost 5-15 W,
  temp target 75-87 C; DC: 25-35, 31-44, 45-65 W) with `requires_fan_curve = true` (on BIOS 307
  the EC applies PPT only while the CPU custom fan curve is on). `nv_tgp` is left out until
  upstream settles offset-or-absolute watts. Nothing is written at probe or resume.
- **Test:** NOTES.md, "0807" (the range check, `-EBUSY` without a fan curve, `-EINVAL` above the
  range, and package power tracking 25 W then 40 W under load with the curve on).
- **Upstream: not submitted** (target platform-driver-x86).
- **Drop when:** an equivalent GA605KM entry is merged upstream and reaches linux-omarchy.
- **Notes:** issue #34 closed when the per-charger limits moved to the omarchy-asus plugin; the
  patch is still carried.

<a id="kernel-0808-thermal-policy-restore"></a>
### asus-wmi restores the thermal policy after hibernation (0808)

- **Component:** `linux-omarchy`,
  `0808-platform-x86-asus-wmi-restore-thermal-policy-after-hibernation.patch`. RC only (9.103).
- **Fixes:** after a hibernation resume (`HibernateMode=shutdown`: the firmware boots again), the
  EC ran the balanced fan table while every layer above it reported quiet (fans at about
  2100/1800/3800 rpm on a cool idle, about 0.8 W). `asus_hotk_restore()` now writes the thermal
  policy back and re-sends each custom fan curve that was enabled. The RTX wakes for about 20 s
  once per hibernation resume.
- **Test:** on battery with the quiet fan table, `g16-test/test --ec-table` (read only) and
  `test --resume-profile --hibernates 6`: the quiet table survives every hibernate.
- **Upstream: not submitted** (target platform-driver-x86). Not in mainline 7.3 (2026-10-22).
- **Drop when:** upstream restores the policy after hibernation. Bug: #185.

<a id="kernel-0810-panel-power-savings"></a>
### panel_power_savings applies when written (0810)

- **Component:** `linux-omarchy`, `0810-drm-amd-display-panel-power-savings-apply-now.patch`. RC
  only (since 9.102).
- **Fixes:** a `panel_power_savings` write only reached the stream at the next modeset, because
  aquamarine leaves the connector out of page flips. The patch commits the connector and its CRTC
  unchanged right after the write, so the level takes effect at once (no modeset).
- **Test:** the kit's `0810` check: a kprobe on `dmub_cacp_set_level` fires within 3 s of writing
  1 (then 0 is written back).
- **Upstream: not submitted.** Ours; mainline (7.4-rc1) has the same store function.
- **Drop when:** upstream applies the level on write. Issue: #172.

<a id="kernel-9900-zen5c-soft-park"></a>
### EXPERIMENTAL Zen 5c-first soft park (9900)

- **Component:** `linux-omarchy`, `9900-EXPERIMENTAL-zen5c-first-soft-park-default-off.patch`,
  applied last. Both channels.
- **What:** five scheduler changes for GA605KM battery testing (amd_hfi ITMT ranking, soft wakeup
  CPU preference, AMD workload-class steering, optional SMT packing, NOHZ idle-load-balancer
  preference). Every knob defaults off and nothing enables it, so the scheduler takes the stock
  paths. Compile-tested only.
- **Test:** the kit checks that every 9900 knob is at its default. The battery A/B is the work
  in experiment issue #10.
- **Upstream: ours-only.** Not meant for upstream.
- **Drop when:** the A/B shows no win (or move it to a separate `-experimental` kernel).

<a id="kernel-9901-dcn35-s0i2"></a>
### EXPERIMENTAL DCN 3.5 S0i2-ready display idle (9901)

- **Component:** `linux-omarchy`,
  `9901-EXPERIMENTAL-drm-amd-display-dcn35-s0i2-rdy-default-off.patch`, after 9900. RC only
  (since 9.106).
- **What:** a new `amdgpu.dcn35_s0i2` parameter (bool, writable at runtime, default 0). When it is 1,
  the DCN 3.5 clock manager sends `SetDisplayIdleOptimizations` with `df_request_disabled`,
  `phy_ref_clk_off` and `s0i2_rdy` when the active display count drops to 0, as DCN 3.1 does. Stock
  DCN 3.5 never sends them, so the SMU's display-idle bit (idlemask bit 5) and IPS2 (bit 20) stay
  not idle even with every display off (#249). With 0, the driver takes the stock path.
  Compile-tested only.
- **Test:** the kit's `9901` check (present, off, nothing sets it). The one-boot A/B is
  `g16-test/dcn35-s0i2-ab`, and its results go to experiment issue #353.
- **Upstream: not submitted.** Mainline master is unchanged (2026-10-25). An amd-gfx report will be
  drafted after the G16 numbers.
- **Drop when:** the A/B shows no effect or a wake problem, or upstream sends the flags itself.

<a id="kernel-9902-dm-idle-all-off"></a>
### EXPERIMENTAL display idle with every CRTC off (9902)

- **Component:** `linux-omarchy`,
  `9902-EXPERIMENTAL-drm-amd-display-idle-with-all-crtcs-off-default-off.patch`, after 9901. RC
  only (since 9.107).
- **What:** a new `amdgpu.dm_idle_all_off` parameter (bool, writable at runtime, default 0). When
  it is 1, amdgpu's display manager treats "no stream in DC's state" as headless where that check
  gates allowing idle optimizations (the end of a stream commit, the idle worker, periodic
  detection). Stock only re-allows idle with no connector connected, and the internal panel always
  is, so with the screen off (DPMS off) idle stays disallowed and IPS never runs (#249). The paths
  that disallow idle are unchanged. With 0, the driver takes the stock path. Compile-tested only.
- **Test:** `g16-test/dm-idle-all-off` (with 9901 and 9903); results go to experiment issue #353.
- **Upstream: not submitted.** An amd-gfx report will be drafted after the G16 numbers.
- **Drop when:** the A/B shows no effect, or upstream re-allows idle with every CRTC off.

<a id="kernel-9903-idlemask-trace"></a>
### EXPERIMENTAL SMU idlemask trace through s2idle (9903)

- **Component:** `linux-omarchy`, `9903-EXPERIMENTAL-amd-pmc-idlemask-trace-through-s2idle.patch`,
  after 9902. RC only (since 9.107).
- **What:** with `/sys/power/pm_debug_messages` at 1, each s2idle logs `amd_pmc: SMU idlemask
  <stage>: 0x...` after amdgpu's display suspend (`amdgpu-display`), after its other IP suspend
  (`amdgpu-ip`), at amd_pmc's prepare before and after the OS hint (`prepare`, `os-hint`), next to
  the existing `s0i3` line. amd_pmc exports the helper and amdgpu finds it with `symbol_get()`.
  With `pm_debug_messages` at 0 nothing is read or logged.
- **Test:** phase (d) of `g16-test/dm-idle-all-off`: the first stage where bit 16 reads idle (#353).
- **Upstream: ours-only.** A debug aid.
- **Drop when:** with 9902, or once the stage that sets bit 16 is known.

<a id="kernel-9904-idlemask-window"></a>
### EXPERIMENTAL idlemask trace between amdgpu's suspend and the LPS0 calls (9904)

- **Component:** `linux-omarchy`, `9904-EXPERIMENTAL-idlemask-trace-between-amdgpu-suspend-and-lps0.patch`,
  after 9903. RC only (since 9.108).
- **What:** more stages for 9903's trace, with `/sys/power/pm_debug_messages` at 1: after every
  device's suspend_late (`suspend-late`), the s2idle prepare (`s2idle-prepare`), amdgpu's noirq
  (`amdgpu-noirq`), every device's noirq (`noirq`), and each LPS0 `_DSM` call (`dsm-screen-off-amd`,
  `dsm-screen-off`, `dsm-entry-amd`, `dsm-ms-entry`, `dsm-entry`; a call that didn't run logs
  `not run`). On 9.107 the display bits turned idle between `amdgpu-ip` and `prepare`; this
  narrows that window. With `pm_debug_messages` at 0 nothing is read or logged.
- **Test:** `g16-test/idlemask-trace` (one 15 s suspend): the first stage where each display bit
  reads idle (#353).
- **Upstream: ours-only.** A debug aid.
- **Drop when:** with 9903, or once the stage that idles bit 16 is known.

<a id="kernel-9905-idlemask-noirq-devices"></a>
### EXPERIMENTAL idlemask trace after each PCI device's noirq suspend (9905)

- **Component:** `linux-omarchy`, `9905-EXPERIMENTAL-idlemask-trace-after-each-pci-device-noirq-suspend.patch`,
  after 9904. RC only (since 9.109).
- **What:** in an s2idle with `/sys/power/pm_debug_messages` at 1, 9903's trace as the noirq phase
  starts (`noirq-start`) and after each PCI device's noirq suspend, with the device and its
  resulting power state (`SMU idlemask noirq 0000:65:00.0 D3hot: 0x...`). On 9.108 bits 16-19
  turned idle between `s2idle-prepare` and `amdgpu-noirq`, and bits 5, 20 and 25 by `noirq`; this
  names the device whose D3 idles each. With `pm_debug_messages` at 0 nothing is read or logged.
- **Test:** `g16-test/idlemask-trace` (one 15 s suspend): the per-device noirq rows and the first
  device after which each bit reads idle (#353).
- **Upstream: ours-only.** A debug aid.
- **Drop when:** with 9903 and 9904, or once the device that holds bit 16 is known.

<a id="kernel-9906-psp-rpm"></a>
### EXPERIMENTAL runtime PM for the PSP function (9906)

- **Component:** `linux-omarchy`, `9906-EXPERIMENTAL-ccp-psp-runtime-pm-default-off.patch`, after
  9905. RC only (since 9.110).
- **What:** ccp runtime PM for a PSP-only PCI function without SEV (the G16's 1022:17E0,
  65:00.2). `ccp.psp_rpm_delay_ms` (default 0 = off) > 0 gives up the PCI core's probe
  reference and uses autosuspend with that delay, so with `power/control=auto` the function
  sits in D3hot between commands; every register user (mailbox, TEE ring, platform access,
  dbc, the version attributes) holds a runtime PM reference. A write applies at once.
  `ccp.psp_rpm_debug` logs each runtime suspend and resume with the caller that woke it. With
  the delay at 0, or `power/control` at `on`, nothing changes. Idlemask bit 16 (the runtime
  deep-idle blocker) turns idle where s2idle's noirq phase puts this function in D3hot (#353);
  this tries that at runtime.
- **Test:** `g16-test/psp-rpm` (on battery, about 4 minutes): bit 16, socket power and the
  PSP's suspend/resume counts with it runtime-suspended, screen on and off; an fTPM read and a
  version read with it suspended (#249).
- **Upstream: not submitted.** An experiment; a ccp runtime-PM patch for PSP-only parts if it
  works and the TEE, TPM and display keep working.
- **Drop when:** the G16 shows no effect on bit 16 or socket power.

<a id="kernel-9907-smu-metrics-runtime"></a>
### EXPERIMENTAL SMU metrics table at runtime (9907)

- **Component:** `linux-omarchy`, `9907-EXPERIMENTAL-amd-pmc-smu-metrics-at-runtime.patch`, after
  9906. RC only (since 9.110).
- **What:** `/sys/kernel/debug/amd_pmc/smu_metrics_runtime`: a read sends the SMU the metrics dump
  message that amd_pmc otherwise sends only on s2idle resume, and prints every field of the table
  (`timein_s0i2` and both per-IP counter arrays included); a rejection is reported, never retried.
  Writing `start` resets and starts the SMU's logging. Nothing is sent unless the file is used.
- **Test:** `g16-test/psp-rpm` reads it at the end of each phase (#249).
- **Upstream: ours-only.** A debug aid.
- **Drop when:** with 9903.

<a id="kernel-9908-dm-idle-kept"></a>
### EXPERIMENTAL display idle kept allowed with every CRTC off (9908)

- **Component:** `linux-omarchy`, `9908-EXPERIMENTAL-drm-amd-display-keep-idle-allowed-with-every-crtc-off-default-off.patch`,
  after 9907, on top of 9902. RC only (since 9.110).
- **What:** on 9.109, 9902's `dm_idle_all_off` allowed display idle once at the all-off commit
  and every later register access, IRQ change or HPD/backlight call disallowed it for good
  ("Idle optimization" 0 with the panel off). With the parameter set, a delayed work re-allows
  idle while every CRTC stays off (after the commit, when the vblank IRQ count reaches 0, then
  once a second). `amdgpu.dm_idle_trace` logs every idle allow/disallow with its caller, the
  vblank IRQ count, the active CRTCs and the streams; `amdgpu.dm_idle_all_off_debug` logs each
  re-allow. All default off. Caveat: hotplug of an external display with the panel off may go
  undetected until the next disallow.
- **Test:** `g16-test/psp-rpm`, cells d and e (#249, #353).
- **Upstream: not submitted.** With 9902.
- **Drop when:** with 9902.

<a id="kernel-9909-nkey-caps-led-only"></a>
### EXPERIMENTAL the GA605KM keyboard declares only its Caps Lock LED (9909)

- **Component:** `linux-omarchy`, `9909-EXPERIMENTAL-hid-asus-ga605km-keyboard-caps-lock-led-only.patch`,
  after 9908. RC only (since 9.111). Goes with
  [the keyboard autosuspend rule](#g16-keyboard-autosuspend) in omarchy-asus-g16.
- **What:** the G16's tenkeyless N-Key keyboard (USB 0b05:19b6) declares Num Lock, Caps Lock,
  Scroll Lock, Compose and Kana LEDs but has only a Caps Lock light. usbhid refuses autosuspend
  while a declared LED is lit, and Omarchy turns Num Lock on, so the keyboard and its xHCI
  (67:00.0) never runtime-suspend, which holds idlemask bit 16 (#249). On a GA605KM (DMI board
  name), with the exact 745-byte descriptor, hid-asus rewrites the 18 LED bytes in place so only
  Caps Lock is declared, at the same bit; the report layout is unchanged. Caps Lock lit still
  blocks autosuspend, by design. Other machines and keyboards: unchanged.
- **Test:** on 9.111 with the udev rule, Num Lock on, Caps Lock off: `dmesg | grep 'Caps Lock
  only'`; the keyboard's `power/runtime_status` reads `suspended` a few seconds after the last
  key press, and 67:00.0 too with no Bluetooth device connected (#249).
- **Upstream: not submitted.** A HID-tree candidate once the G16 test passes.
- **Drop when:** upstream fixes it, or the G16 test shows no gain.

<a id="kernel-9910-smu-allow-zstates"></a>
### EXPERIMENTAL debugfs to send the SMU AllowZstates message (9910)

- **Component:** `linux-omarchy`, `9910-EXPERIMENTAL-amd-pm-smu-allow-zstates-debugfs.patch`, after
  9909. RC only (since 9.111).
- **What:** maps swsmu's `SMU_MSG_AllowZstates` to `PPSMC_MSG_AllowZstates` (0x25) for SMU 14.0.x
  and adds the debugfs file `amdgpu_smu_allow_zstates` (root, write-only) in amdgpu's DRM debugfs
  directory. Writing 0 (disallow), 8 (Z8) or 9 (Z9 and Z8) sends it; other values are refused;
  each write is logged. Linux never sends this message otherwise; a static read of the SMU
  firmware suggests its runtime S0i2 gate needs the Z-state enable it feeds (#249). Nothing is
  sent unless the file is written.
- **Test:** on battery with the screen off and the PSP and keyboard xHCI suspended, write 9, then
  read `timein_s0i2` (9907) and socket power (#249). The display's own AllowZstatesEntry is
  logged by `echo 'file dcn35_smu.c +p' > /sys/kernel/debug/dynamic_debug/control`.
- **Upstream: ours-only.** An experiment.
- **Drop when:** the test is done.

## NVIDIA: nvidia-open-dkms

615.78.08: RC 1.102, Quattro 1.3. `recipes/nvidia-open-dkms/UPSTREAM_PRS` lists 0001-0003, so the
daily check reports their pull requests' state. When no patch is left, unpublish the package.

<a id="nvidia-0001-hibernate-power-off"></a>
### Hibernate power-off (0001, NVIDIA/open-gpu-kernel-modules#1412)

- **Component:** `nvidia-open-dkms`, patch 0001. Both channels, carried since 615.78.08-1.1.
- **Fixes:** after `systemctl hibernate` the laptop writes the image but never powers off:
  `nv_pci_shutdown()` tears down a GPU that is still hibernate-suspended and hangs. The fix skips
  that teardown while the GPU is hibernate-suspended.
- **Test:** `modinfo nvidia | grep ^version`; `systemctl hibernate` must fully power off (power LED
  off, fans stop) within seconds of the image being written; power on and resume into the session.
- **Upstream: open.** [NVIDIA/open-gpu-kernel-modules#1412](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1412), not merged; the CLA is not signed yet.
- **Drop when:** an NVIDIA release with #1412 (or an equivalent fix) reaches Arch's
  `nvidia-open-dkms`.
- **Notes:** formerly tracked in issue #11.

<a id="nvidia-0002-nvpcf-defer"></a>
### NVPCF defer, with the refcount fix (0002, NVIDIA/open-gpu-kernel-modules#1299)

- **Component:** `nvidia-open-dkms`, patch 0002, a squash of both #1299 commits (the refcount
  underflow fix and the NVPCF defer; on a pristine 615.78.08 tree the same result as the two
  commits). Both channels, carried since 615.78.08-1.1.
- **Fixes:** the dGPU woke from D3cold on every battery or power-source change: NVPCF ACPI
  notifications were handled at once even while the GPU was runtime-suspended. #1299 defers them
  until runtime resume.
- **Test:** on battery with nothing using the dGPU, `watch -n1 cat
  /sys/bus/pci/devices/0000:<addr>/power/runtime_status` (address from `lspci -d 10de:`) stays
  `suspended` through battery percentage changes and charger plug/unplug (apart from a wake a
  plug-in causes on purpose, such as nvidia-powerd). Without the patch it flips to `active` on
  each change.
- **Upstream: open.** [NVIDIA/open-gpu-kernel-modules#1299](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299), not merged.
- **Drop when:** an NVIDIA release with both #1299 commits reaches Arch.
- **Notes:** formerly tracked in issue #12.

<a id="nvidia-0003-semaphore-leak"></a>
### nvkms semaphore leak (0003, NVIDIA/open-gpu-kernel-modules#1368)

- **Component:** `nvidia-open-dkms`, patch 0003. Both channels, carried since 615.78.08-1.2 (#2).
  omacom/omarchy-pkgs ships the same patch in its aarch64 `nvidia-open-dkms`.
- **Fixes:** `nvKmsKapiRegisterSemaphoreSurfaceCallback()` leaks its callback record when RM
  answers `NVOS_STATUS_ERROR_ALREADY_SIGNALLED`. Under explicit sync on Wayland that is nearly
  every composited frame: about 40 bytes of kmalloc-64 per frame, 2.2 GB of unreclaimable slab
  over 4.5 days as measured by the #1368 author. The fix is one `nvKmsKapiFree(cb);`.
- **Test:** use Hyprland normally for several hours, sampling `sudo grep kmalloc-64
  /proc/slabinfo` (or `slabtop -o`) and `SUnreclaim` in `/proc/meminfo` every hour: they grow
  steadily without the patch, and stay flat with it.
- **Upstream: open.** [NVIDIA/open-gpu-kernel-modules#1368](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1368), not merged.
- **Drop when:** an NVIDIA release with #1368 reaches Arch.
- **Notes:** formerly tracked in issue #13.

<a id="nvidia-0004-hdmi-no-edid"></a>
### An HDMI port with no EDID reports disconnected (0004)

- **Component:** `nvidia-open-dkms`, `0004-nvidia-drm-report-HDMI-without-EDID-as-disconnected.patch`.
  RC only (1.102, #286).
- **Fixes:** after a hibernation resume, the RTX's HDMI port reported a phantom monitor with
  nothing plugged in, which lit a phantom output and kept the dGPU awake. An HDMI sink always
  provides an EDID, so a connected HDMI connector with no EDID (and no force or EDID override) is
  reported disconnected, as i915 does.
- **Test:** hibernate and resume with nothing on HDMI: no HDMI output appears (`hyprctl
  monitors`), the kernel log shows `No EDID on connected HDMI connector`, and the dGPU returns to
  `suspended`. A real monitor still lights up.
- **Upstream: not submitted.** Not in `UPSTREAM_PRS` until it has a pull request.
- **Drop when:** NVIDIA fixes the stale connect state, or ships an equivalent check. Bug: #213.

## Hyprland: hyprland and hyprpm

0.56.2: RC 4.103, Quattro 4.2 (Arch's PKGBUILD plus our patches; `recipes/hyprland/NOTES.md`).
Once neither patch is left, `bin/unpublish hyprland hyprpm` and delete the recipe.

<a id="hyprland-reconnect-render-offset"></a>
### Reconnect render offset

- **Component:** `hyprland`/`hyprpm`, `reconnect-render-offset.patch` (`src/output/Monitor.cpp`,
  `CMonitor::onConnect`). Both channels.
- **Fixes:** after an HDMI replug, the monitor gets its remembered workspace back through an
  internal `changeWorkspace()`. That workspace is never animated in, so it keeps the slide-out
  offset from its time on the fallback monitor and its windows render off-screen. The patch runs
  the active workspace's instant "in" animation at the end of `onConnect()`.
- **Test:** open windows on a workspace on the HDMI monitor, unplug HDMI, wait a few seconds, plug
  it back in: the workspace comes back with its windows in place. Without the fix they render
  offset or off-screen until you switch workspaces.
- **Upstream: merged-unreleased.** Fixed on `main` by
  [hyprwm/Hyprland#16140](https://github.com/hyprwm/Hyprland/pull/16140) (commit `e9e2f64c`,
  "workspace: refactor workspace handling"), whose `activateWorkspace()` starts the same IN
  animation. Related: hyprwm/Hyprland#15890 (`d8504461`) changed un-orphaning onto the fallback
  output. Checked 2026-10-25: in no release yet; v0.56.2 is the latest, the fix is expected in
  0.57. Our patch does not apply to `main`. `DELTA`'s `fixed-upstream` line flags the first
  release with `e9e2f64c`; it never drops the patch by itself.
- **Drop when:** we rebase onto an Arch Hyprland release with `e9e2f64c` (0.57 or later) **and** a
  hardware test without the patch shows the bug is gone.
- **Notes:** formerly tracked in issue #14.

<a id="hyprland-seat-leave"></a>
### wl_keyboard.leave before the seat loses its keyboard

- **Component:** `hyprland`/`hyprpm`, `seat-leave-on-capability-loss.patch`
  (`src/protocols/core/Seat.cpp`, `CWLSeatProtocol::updateCapabilities`; `Seat.hpp` gains
  `friend class CWLSeatProtocol` on `CWLPointerResource`). RC only (0.56.2-4.102, #305,
  `ca16ed1d`). A G16 confirmation is queued; work issue #302 stays open until it passes.
- **Fixes:** after a suspend and resume the lock screen ignored typing until clicked. libinput
  removes the keyboards on suspend, and Hyprland 0.56.2 then sends `wl_seat.capabilities` without
  the keyboard bit but no `wl_keyboard.leave` first: `updateCapabilities()` (`Seat.cpp:583-592`,
  reached from `CInputManager::destroyKeyboard`, `InputManager.cpp:1531-1557`) updates
  `m_currentCaps` first, and `CWLKeyboardResource::sendLeave()` is a no-op once it lacks the
  keyboard bit. Hyprland keeps its focus on the surface, so a re-added keyboard's new
  `wl_keyboard` gets `enter` on the same surface (`Seat.cpp:351-356`); the client never saw a
  leave, Qt doesn't re-activate the window on that enter (#298), and `Window.active` stays false.
  The patch sends `leave` to every keyboard resource, and `leave` plus `frame` to every pointer
  resource that had focus (`sendFrame()` is gated on `m_currentCaps` too; unframed, clients that
  buffer until the frame could drop the leave and button releases), before `m_currentCaps` is
  updated, as wlroots does (`types/seat/wlr_seat.c`, `wlr_seat_set_capabilities`). Hyprland's own
  focus is kept. wl_touch has no leave event and wlroots does nothing for touch here, so touch is
  unchanged. It is the compositor-side root cause of #295, and helps any client that keeps
  per-surface keyboard state, not only Qt.
- **Evidence (headless, on the build host):** Hyprland nested in a headless mutter (render node
  only, no DRM card or input devices, its own HOME and runtime dir), a Quickshell `WlSessionLock`
  with a `TextInput`, and three virtual keyboards from `wtype` (each added, typing, removed),
  traced with `WAYLAND_DEBUG`:
  - stock 0.56.2-4: `capabilities(2)`, `enter(wl_surface#34)`, `Window.active=true`, then
    `capabilities(0)` with no leave, then `capabilities(2)` and `enter` on the same surface;
    `Window.active` stays false for the second and third keyboards, and the field ends with `bc`;
  - patched 0.56.2-4.102: `wl_keyboard.leave(wl_surface#34)` right before every
    `capabilities(0)`, `Window.active` true again on all three re-adds, and the field ends with
    `bcefhi`. (The first key of each `wtype` run is lost in both builds: `wtype` types before the
    new keyboard's enter is processed.)
  - two virtual pointers, each moved onto the lock surface and removed: stock sends
    `capabilities(0)` with no leave and no frame; patched sends `wl_pointer.leave`, then
    `wl_pointer.frame`, right before each `capabilities(0)`.
- **Test (G16):** with the lock workaround from #295 **not** installed (it was dropped in omarchy
  RC 1.110): lock, close the lid to suspend, open it, type the password without clicking; three
  times. `WAYLAND_DEBUG=1` on the lock shows `wl_keyboard.leave` before
  `wl_seat.capabilities(0)`.
- **Upstream: not submitted.** `updateCapabilities()` is unchanged on hyprwm/Hyprland `main`
  (checked 2026-10-24). hyprwm/Hyprland#16178 reported the same symptom and was auto-closed
  (reports now go to Discussions). Discussion hyprwm/Hyprland#15963 (the first key after suspend is
  dropped, because `m_pressed` isn't cleared when keyboards are destroyed) is a different bug in
  the same path.
- **Drop when:** a Hyprland release sends leave before dropping a capability, and lock, suspend,
  resume, type works without the patch.

#### Upstream report draft

For a human to post as a hyprwm/Hyprland Discussion.

> **Title:** Seat: no wl_keyboard.leave before the keyboard capability is removed (session lock
> ignores typing after suspend)
>
> When the last keyboard is removed (libinput drops keyboards across suspend),
> `CWLSeatProtocol::updateCapabilities` sets `m_currentCaps` and sends `wl_seat.capabilities`
> without the keyboard bit. No `wl_keyboard.leave` is sent first, and
> `CWLKeyboardResource::sendLeave()` could not send one afterwards, because it returns early once
> `m_currentCaps` lacks the keyboard bit. Keyboard focus stays on the surface, so when a keyboard
> comes back, the client's new `wl_keyboard` gets `enter` on the same surface without ever having
> seen a leave.
>
> Qt clients (Quickshell's `WlSessionLock`, so Omarchy's lock screen among others) don't
> re-activate the window on that enter, and the lock screen ignores typing after resume until it
> is clicked (same symptom as #16178). wlroots sends leave before it drops the capability
> (`wlr_seat_set_capabilities`).
>
> Reproducer: nested Hyprland with no physical keyboard, a `WlSessionLock` with a `TextInput`,
> then `wtype abc; wtype def`. `WAYLAND_DEBUG` shows `capabilities(0)` with no leave, then `enter`
> on the same surface, and `Window.active` stays false.
>
> Suggested fix, in `CWLSeatProtocol::updateCapabilities`, before `m_currentCaps = caps;`:
>
> ```cpp
> const uint32_t LOST = m_currentCaps & ~caps;
> if (LOST & eHIDCapabilityType::HID_INPUT_CAPABILITY_KEYBOARD)
>     for (auto const& k : m_keyboards)
>         k->sendLeave();
> if (LOST & eHIDCapabilityType::HID_INPUT_CAPABILITY_POINTER)
>     for (auto const& p : m_pointers) {
>         if (!p->m_currentSurface)
>             continue;
>         p->sendLeave();
>         p->sendFrame();
>     }
> ```
>
> The pointer leave comes with a `wl_pointer.frame`: `sendFrame()` is gated on `m_currentCaps`
> too, so without it the leave and any button releases would go out unframed.
>
> Tested on 0.56.2: leave arrives before `capabilities(0)`, and the window re-activates on every
> re-add.

## Omarchy: omarchy and omarchy-settings

RC 4.5.0rc1-1.111 (`main`, from fork branch `asus/v4-5-0-rc1`), Quattro 4.0.6-1.3 (from
`asus/v4-0-5`). Both packages build from the same source tree and carry the **same** patch list
(their `DELTA` files stay in lockstep, and they publish as one cohort). Their migrations apply the
fixes that live in user config or `/etc` on `omarchy update`, and leave fixes made by hand alone.
The patch table, the migrations and the rebase steps are in `recipes/omarchy/NOTES.md`; each fix's
topic branch is on [omarchy-asus/omarchy](https://github.com/omarchy-asus/omarchy). ASUS patches
are numbered `0001...`; fixes to Omarchy's own software that don't help the hardware are the
`general-` series, carried with the maintainer's approval.

<a id="omarchy-0001-asusd-hand-off"></a>
### asusd profile/EPP hand-off (0001)

- **Component:** `omarchy`/`omarchy-settings`, patch 0001 (`omarchy-settings`'
  `10-omarchy-power-profiles.conf` drop-in, migration `1792122579`). Both channels. Fork branch
  `asus/asusd-power-profiles`.
- **Fixes:** on ASUS ROG laptops asusd and Omarchy both switch the power profile and EPP on plug
  and unplug, so asusd overrides the profile picked in Omarchy. The change stops asusd from
  switching them and leaves that to Omarchy.
- **Test:** pick a profile in the Omarchy power menu, plug and unplug the charger:
  `powerprofilesctl get` and `cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference`
  follow Omarchy's rules, and `journalctl -u asusd -b` shows no profile switches by asusd.
- **Upstream: open.** [omacom/omarchy#15667](https://github.com/omacom/omarchy/pull/15667) "Stop
  asusd from switching the power profile and EPP on ROG laptops". As of 2026-10-18: head
  `dfa499bc`, merges cleanly into `quattro`, no maintainer review; Greptile 5/5 with no findings.
  Omarchy's review bot (2026-10-17) read the drop-in and migration against asusctl's source and
  found nothing wrong; it left the PR unclassified (no second model) and expects a hardware test of
  the exact commit. It also notes that the `backup=()` entry this change needs in
  `omarchy-settings` is a separate omacom/omarchy-pkgs change; none is open.
- **Fork vs upstream:** `pr/asusd-power-profiles` is `dfa499bc`; `asus/asusd-power-profiles`
  (`faf6db4d` plus fixup `24211666`) and fork `quattro` have the same content on all three PR
  files.
- **Next:** run exactly `dfa499bc` on the G16 (dev link it, one reboot with the drop-in installed,
  then the plug/unplug checks) before posting a hardware confirmation on #15667; the earlier check
  set the three asusd properties live over D-Bus, not through the drop-in. Draft the
  `omarchy-settings` `backup=()` companion for omacom/omarchy-pkgs; a human decides whether to open
  it.
- **Drop when:** #15667 is merged and in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #21.

<a id="omarchy-0002-usbc-power"></a>
### USB-C power policy (0002)

- **Component:** `omarchy`/`omarchy-settings`, patch 0002, plus `omarchy-settings`'
  `pkgbuild-source-monitor-unit.diff` (ships the charger-swap monitor user unit; see
  [its entry](#omarchy-pkgbuild-source-monitor-unit)). Both channels. Fork branch `asus/usbc-power`; pkgs
  branch [`omarchy-settings-source-monitor`](https://github.com/omarchy-asus/omarchy-pkgs/tree/omarchy-settings-source-monitor).
- **Fixes:** ROG laptops on a USB-C charger (lower wattage than the barrel adapter) kept running
  at full power and could drain or barely charge. The change adds a USB-C charger policy
  (`omarchy-hw-asus-rog-usbc-power`) and a charger-swap monitor.
- **Test:** swap between the barrel adapter, a USB-C PD charger and battery; after each swap check
  `powerprofilesctl get` and the charge rate (`upower -i $(upower -e | grep BAT)`). On USB-C the
  policy applies within seconds and the laptop charges or holds. A local power daemon must be off,
  or set as the external owner ([0003](#omarchy-0003-external-owner)), first.
- **Upstream: open.** [omacom/omarchy#15668](https://github.com/omacom/omarchy/pull/15668) "Save
  power on USB-C chargers on ASUS ROG laptops". As of 2026-10-18: head `7a7c9c84`, merges cleanly,
  no maintainer review. Greptile's three points (charger swaps kept the old profile, a dead model
  stub in the test, monitor errors did not recover) are resolved by `b22bc3e4`, `77ad546d` and
  `7a7c9c84`; latest summary 5/5. The omacom/omarchy-pkgs companion (ship
  `omarchy-powerprofiles-source-monitor.service` as a user unit; without it the unit lands only in
  `/usr/share/omarchy/default/systemd/user`, where systemd doesn't find it, and `config-test.sh`
  reports it as not shipped) is not opened. #15668 and #15669 conflict in
  `bin/omarchy-powerprofiles-set` and `test/shell.d/powerprofiles-set-test.sh`; whichever merges
  second needs a rebase (the fork's `quattro` merge has the resolution).
- **Fork vs upstream:** `pr/usbc-power` is `7a7c9c84`; `asus/usbc-power` (`3ce14809` plus five
  fixups) is identical on all eleven PR files. Fork `quattro` differs only where it also carries
  #15669.
- **Next:** test a live barrel-to-USB-C swap and back on the G16 without going through battery
  (each source has been checked on its own, a swap has not). Open the pkgs companion with or after
  #15668; a human decides. A flaky assertion in the fork's
  `test/shell.d/asus-rog-usbc-power-test.sh` ("battery is answered without waiting", `(( SECONDS -
  start < 1 ))`, fails a few percent of runs at a second boundary) should time with
  `EPOCHREALTIME` against about 200 ms, on `asus/usbc-power` and the backport branches, the next
  time the patch is regenerated; it affects only the fork's tests, not the package.
- **Drop when:** #15668 (and its pkgs companion) are in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #22.

<a id="omarchy-0003-external-owner"></a>
### Power profiles: external owner (0003)

- **Component:** `omarchy`/`omarchy-settings`, patch 0003. Both channels. Fork branch
  `asus/powerprofiles-external-owner`.
- **Fixes:** Omarchy's power-profile autoswitch on plug and unplug fights any other power manager
  (a user daemon, asusctl or TLP). The `powerprofiles-autoswitch-off` toggle lets another manager
  own the profile. A machine running its own power daemon should set it, or stop that daemon.
- **Test:** enable the toggle, set a profile with `powerprofilesctl set`, plug and unplug the
  charger: Omarchy doesn't change the profile, and `omarchy-powerprofiles-set` logs that it
  skipped.
- **Upstream: open.** [omacom/omarchy#15669](https://github.com/omacom/omarchy/pull/15669) "Let
  another power manager own the profile on plug and unplug". As of 2026-10-18: head `5205efd2`,
  merges cleanly, no maintainer review; Greptile's one point (the manual's `touch` fails when the
  toggles directory is missing) is resolved in `5205efd2`, summary 5/5. Conflicts with #15668 (see
  [0002](#omarchy-0002-usbc-power)). `pr/powerprofiles-external-owner` is `5205efd2`;
  `asus/powerprofiles-external-owner` (`308e4a37` plus fixup `524481be`) is identical.
- **Next:** nothing to change; rebase if #15668 lands first.
- **Drop when:** #15669 is in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #23.

<a id="omarchy-0004-quiet-fans"></a>
### GA605KM quiet fans on battery (0004)

- **Component:** `omarchy`/`omarchy-settings`, patch 0004 (helper
  `omarchy-powerprofiles-asus-quiet-fans` with a sudoers grant). Both channels. Fork branch
  `asus/ga605km-quiet-fans` (`c55ffe2b` plus fixup `2abed31b`). `omarchy-asus-g16-apply --check`
  hands quiet fans to `omarchy-powerprofiles-set` when the patched omarchy is installed; its
  `omarchy-asus-g16-quiet-fans.service` is the path on stock Omarchy (not exercised in the run
  below).
- **Fixes:** in balanced, the GA605KM's fans spin at 2000-3800 rpm even idle and cool. On battery
  in balanced the change sets only the asus-wmi profile handler to quiet and leaves amd-pmf on
  balanced: the fans stop (about 0.8 W) and the CPU still boosts fully. The write happens only on
  a state change, because each platform-profile write wakes the dGPU for about 20 s.
- **Test:** on battery, balanced, idle 2 minutes: the fans stop; `grep .
  /sys/class/platform-profile/*/{name,profile}` shows asus-wmi `quiet` and amd-pmf `balanced`; a
  short CPU burst still reaches full boost; plugging in the charger brings back the source's
  normal profile.
- **Hardware run (G16, 2026-10-19):** omarchy/omarchy-settings 4.0.5-1.3, omarchy-asus-g16-apply
  0.1.0-5, linux-omarchy 7.2.8-9.1; the local power daemon stopped so the shell's
  `omarchy-powerprofiles-set` drove the helper. Battery profile balanced, barrel AC performance.

  | check | result |
  |---|---|
  | sudoers grant | ✅ `sudo -l`: `(root) NOPASSWD: …asus-quiet-fans on, …asus-quiet-fans off` |
  | unplug barrel | ✅ 1-2 s later ppd balanced, amd-pmf balanced, asus-wmi quiet; one `sudo … on` |
  | idle on battery | ✅ once a running game ended (Tctl 86 °C, fans 3,100-5,600 rpm on the quiet curve): RTX `suspended`, then fans 0/0/0 rpm at Tctl 47.6 °C about a minute later |
  | Fn+F5 on battery | ⚠️ no effect at all, no helper call; kernel `Failed to notify asus-wmi (retval): 0x1` / `hid-asus …: Failed to notify asus-wmi: -5`, also on the stock 7.2.5 kernel, so the hid-asus to asus-wmi hand-off for this key is dead on the GA605KM, independent of our patches |
  | suspend (suspend-then-hibernate) and resume on battery | ✅ asus-wmi still quiet, amd-pmf balanced, fans 0, no extra helper call: the firmware doesn't reset the handler |
  | replug barrel | ✅ within 1 s ppd and both handlers performance; no helper call (`powerprofilesctl set performance` already cleared the mixed state, so `off` exits before sudo) |
  | barrel out, USB-C in | ✅ battery: `on` (quiet); USB-C seen 5 s later: ppd balanced, asus-wmi back to balanced via `sudo … off` |
  | double writes / errors | ✅ none; three sudo calls (on, on, off), one per real state change |

  Not covered: the RTX reaching `suspended` within about 30 s of the unplug itself (a game held
  it; it suspended as soon as the game exited). If a later kernel or BIOS makes the Fn+F5 asus-wmi
  hand-off work, it would cycle the platform profile behind ppd's back; whether the key also emits
  an input event to userspace wasn't checked.
- **Upstream: not submitted.** No upstream PR or issue covers it. The branch merges cleanly into
  `quattro`, and on top of #15668 and #15669 one at a time (all three touch
  `bin/omarchy-powerprofiles-set`, so expect small rebases). Before submitting: squash the fixup
  and open it after #15667, as the fork's order says. Upstream may refuse a new sudoers grant for
  one model; then keep it in the fork, or move it to `omarchy-asus-g16`.
- **Drop when:** an upstream PR is merged and released, or firmware or asusd fixes the idle fan
  curve.
- **Notes:** formerly tracked in issue #24.

#### Upstream report draft

omacom/omarchy, PR against `quattro`. Not opened; a human decides.

> **Title:** Stop the idle fans on battery on the ROG Zephyrus G16 GA605KM
>
> On battery in `balanced`, the GA605KM's fans run at 2000-3800 rpm even when idle and cool. The
> fan floor comes from the `asus-wmi` platform-profile handler and the CPU limits from `amd-pmf`.
> Putting both in quiet stops the fans but caps the CPU at 2.0 GHz.
>
> **Change.** On battery in `balanced`, `omarchy-powerprofiles-set` sets only the asus-wmi handler
> to quiet and leaves amd-pmf on balanced. On any other source or profile it undoes that mixed
> state, and only that state.
>
> The write needs root. It goes through `omarchy-powerprofiles-asus-quiet-fans on|off`, which has
> a sudoers grant naming both whole commands, the same pattern as
> `omarchy-theme-set-browser-policy` and `omarchy-dns`. The helper:
>
> - pins PATH;
> - checks the DMI product itself, gated with `omarchy-hw-match "GA605KM"`, the only model
>   measured;
> - finds the handlers by name;
> - writes `on` only when Mains is offline;
> - writes nothing when the state is already right, because each platform-profile write makes the
>   firmware wake the RTX for about 20 s.
>
> Without the grant and without a terminal, it does nothing. power-profiles-daemon reads the mixed
> state as `custom` and keeps its own profile, so the two do not fight.
>
> **Evidence.** On a GA605KM, against plain balanced (EPP equal, RTX suspended), the median saving
> is 0.79 W per cycle, lower in 3 of 4 cycles. Fans read 7 rpm instead of about 2100/1800/3700
> rpm, and CPU peak is unchanged (5043 MHz single-thread, 5041 MHz all-core; full quiet: 2011
> MHz). On hardware with the packaged code: one helper call per real state change, the handler
> survives suspend and resume, and a charger swap restores the source's profile.
>
> **Tests.** The new `test/shell.d/asus-quiet-fans-test.sh` uses a mocked sysfs. It covers the
> grant (`visudo -c`), the single write per state change, the no-op cases (AC, other profiles,
> other models, no ASUS handler), and that `off` undoes only the mixed state. A mutation that
> removes the state guard makes it fail.
>
> This pull request was written with Claude Code.

<a id="omarchy-0005-hdmi-cursor"></a>
### HDMI software cursor (0005, 0019)

- **Component:** `omarchy`/`omarchy-settings`, patches 0005 and 0019
  (`default/hypr/hybrid-cursor.lua`). Both channels. Fork branch `asus/hdmi-cursor`.
- **Fixes:** on a hybrid laptop the iGPU renders but HDMI is wired to the NVIDIA GPU, so a
  hardware cursor there is copied across GPUs on every update. With the NVIDIA driver that blit
  fails every time (about 74,000 `cursor blit failed` errors in 20 hours on a GA605KM;
  `EGL (blit): glCheckFramebufferStatus failed: 1282`), and aquamarine 0.15.1 leaks the
  EGLImage, renderbuffer and framebuffer of each failed attempt (the early return in
  `Renderer.cpp` `blit()` skips the cleanup), so Hyprland grew to about 900 MB. Hyprland's default
  (`cursor:no_hardware_cursors = 2`) only picks a software cursor when NVIDIA renders. The change
  uses a software cursor only while a monitor on the NVIDIA card is connected, and goes back to
  auto when it is unplugged. 0019 picks the connected card when both GPUs expose a connector of
  the same name (fork `0451beef`, Quattro backport `73a15500`): before it, a monitor on the NVIDIA
  `DP-1` kept the hardware cursor when the iGPU also had a disconnected `DP-1`.
- **Test:** plug in HDMI and move the cursor on it for a few minutes:
  `journalctl --user -b | grep -c 'cursor blit failed'` stays 0, Hyprland's RSS (`ps -o rss -C
  Hyprland`) stays flat. Unplug: `hyprctl getoption cursor:no_hardware_cursors` is back to auto,
  and the panel keeps its hardware cursor. After a config reload the setting is re-applied.
- **Upstream: not submitted.** No upstream PR covers software cursors on hybrid NVIDIA outputs
  (the open `no_hardware_cursors` PRs are about VMware, nouveau and startup blanking). The branch
  merges cleanly into `quattro`; it conflicts with open omacom/omarchy#9483 in
  `test/shell.d/hw-nvidia-test.sh` only, and overlaps [hybrid video decode](#omarchy-0006-hybrid-video-decode)
  in `default/hypr/nvidia.lua` and that test. Before submitting: run the exact module inside
  Hyprland on the G16 once (so far only an equivalent local config keyed on the connector name has
  run) with the checks above. The root cause (the failing cross-GPU blit and aquamarine's leak) is
  for hyprwm/aquamarine; that report is drafted elsewhere and not sent, so the PR text calls this a
  mitigation.
- **Drop when:** Hyprland or aquamarine handles cross-GPU cursors on NVIDIA (or picks software
  for hybrid outputs itself), or the NVIDIA blit stops failing.
- **Notes:** formerly tracked in issue #25.

#### Upstream report draft

omacom/omarchy, PR against `quattro`. Not opened; a human decides.

> **Title:** Use a software cursor while a monitor on the NVIDIA GPU is plugged into a hybrid
> laptop
>
> On hybrid laptops, ports wired to the NVIDIA GPU (usually HDMI) make Hyprland copy the hardware
> cursor across GPUs. With the NVIDIA driver that copy fails every time ("cursor blit failed").
> On an ASUS ROG Zephyrus G16 GA605KM that was about 74,000 failures in 20 hours. aquamarine leaks
> the buffers of each failed attempt, so Hyprland grew to about 900 MB.
>
> This adds `default/hypr/hybrid-cursor.lua`, loaded from `nvidia.lua` when an NVIDIA GPU is
> present:
>
> - It acts only when an NVIDIA DRM card sits next to a display card from another vendor. It reads
>   the cached sysfs `device/vendor`, so the dGPU is never woken.
> - On `monitor.added` and `monitor.removed`, it checks whether any connected monitor's connector
>   belongs to the NVIDIA card (`/sys/class/drm/cardN-<connector>`), not by connector name. When
>   both GPUs expose the same connector name, the card whose `status` reads `connected` wins.
>   - If one does, it sets a software cursor.
>   - When the last one is gone, it goes back to auto, so the laptop panel keeps its hardware
>     cursor.
>   - It checks again a second later, because a removed monitor can still be listed while its
>     event runs.
> - A value the user sets in their own config is left alone. After a config reload, it
>   re-applies.
> - No polling: it reacts to monitor events, `hyprland.start` and `config.reloaded` only.
>
> This is a mitigation. The root causes are the failing cross-GPU blit and aquamarine's leak on
> that path. This can be dropped once those are fixed.
>
> Tests: the new `test/shell.d/hyprland-hybrid-cursor-test.sh` runs the module under a stub `hl`
> against a fake `/sys/class/drm` (`OMARCHY_DRM_PATH`): panel only, an NVIDIA-wired monitor on HDMI
> and DP, the same connector name on both GPUs, unplug, reload, a user-set value, NVIDIA-only, no
> NVIDIA, and no cards. `hw-nvidia-test.sh` now points `OMARCHY_DRM_PATH` at an empty directory,
> so it no longer reads the test machine's cards.
>
> This pull request was written with Claude Code.

<a id="omarchy-0006-hybrid-video-decode"></a>
### Hybrid video decode (and GLX) on the iGPU (0006-0008, 0020, 0023)

- **Component:** `omarchy`/`omarchy-settings`, patches 0006-0008, 0020 and 0023
  (`omarchy-hw-igpu-render-node`, `install/helpers/hybrid-video-decode.sh`, migration
  `1792123636`). Both channels; RC's 0007 also keeps GLX on the iGPU (#264), Quattro's 0007 moves
  video decode only. Fork branch `asus/hybrid-video-decode` (`d51d397b` to `8c59ae0f`).
- **Fixes:** render nodes follow PCI order, so on some hybrid laptops the NVIDIA GPU is
  `renderD128`, and video decode in mpv or Chromium wakes the runtime-suspended dGPU (about 3.5 s
  before the first frame, plus the power). On AMD Krackan the iGPU is a non-VGA display controller
  (class 0x038000, no `boot_vga`), so `omarchy-hw-nvidia-display` also reads NVIDIA as the display
  GPU and `nvidia.lua` exports `LIBVA_DRIVER_NAME=nvidia`. The change pins mpv (`hwdec=vaapi`,
  `vaapi-device`) and Chromium-family browsers (`--render-node-override`) to the iGPU's by-path
  node and repins when the iGPU address changes. 0020 repins only the pins Omarchy wrote (under
  its marker comment); 0023 leaves mpv alone when the user sets `hwdec` or `vaapi-device` anywhere.
  On RC, 0007 also leaves `__GLX_VENDOR_LIBRARY_NAME` unset on a non-VGA iGPU, so GLX apps (the
  Steam client) no longer keep the RTX awake; native OpenGL games then need PRIME render offload
  (`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %command%`), see NOTES.md.
- **Test:** with the dGPU `suspended`, play a video in mpv and YouTube in Chromium: the dGPU stays
  `suspended`, `mpv -v` shows VA-API on the iGPU's node, `chrome://gpu` shows hardware decode.
  Full check (fork `fork/prs/hybrid-video-decode.md`, "Verify on the G16 without waking the RTX"),
  after `omarchy-migrate` and a reboot, with any local `LIBVA_DRIVER_NAME=radeonsi` override
  removed first: `omarchy-hw-igpu-render-node` prints the iGPU by-path node, `LIBVA_DRIVER_NAME` is
  empty, the pins are written, the RTX stays `suspended`, amdgpu fdinfo shows decode engine time,
  and no NVIDIA fds are open. Still to check: MUX dGPU-only mode (the pin should turn off), and
  what Chromium does with a stale `--render-node-override`.
- **Measurements (GA605KM; Radeon 860M + RTX 5060, nvidia-open 610.57.04, mesa 26.2.2, mpv
  0.41.0):** without a node, mpv holds `renderD128`, `nvidia0`, `nvidiactl` and `nvidia-uvm`
  whether `LIBVA_DRIVER_NAME` is `nvidia` or unset. On the iGPU node, H.264, HEVC, VP9 and AV1
  decode on VCN at 4 to 9 times less CPU than software decode, with the RTX suspended. Chrome with
  the override keeps decode on the iGPU: YouTube on battery about 9 W instead of about 12 W.
- **Upstream: not submitted.** Related issue
  [omacom/omarchy#14285](https://github.com/omacom/omarchy/issues/14285) "mpv wakes the
  runtime-suspended NVIDIA dGPU on hybrid laptops" (open, no comments as of 2026-10-18). Related
  open PRs, not ours: omacom/omarchy#15293 (display-GPU check for class 0x0380 iGPUs),
  omacom/omarchy#9483 and omacom/omarchy#13902 (force the NVIDIA env only when NVIDIA drives the
  display), omacom/omarchy#5312 (Chromium EGL on hybrids); omacom/omarchy#11690 is merged on
  `quattro`. The branch conflicts with #9483 in `nvidia.lua` and `hw-nvidia-test.sh`, with #15293
  in the test only, and overlaps [the HDMI cursor](#omarchy-0005-hdmi-cursor). Before submitting:
  run the verify block above, squash the fixups, recheck against #15293 and #9483 and rebase onto
  whichever has landed.
- **Drop when:** Omarchy ships an equivalent fix for #14285 in a release we build from.
- **Notes:** formerly tracked in issue #26 (and bug #264 for the GLX part).

#### Upstream report draft

omacom/omarchy, PR against `quattro`, Refs #14285. Not opened; a human decides. (Written for the
decode-only version; RC's GLX part would be added or sent separately.)

> **Title:** Keep video decode on the iGPU of hybrid NVIDIA laptops
>
> Refs #14285. Related: #15293, #11690, #9483.
>
> On a hybrid laptop whose iGPU drives the panel, video in mpv or Chromium can still decode on the
> NVIDIA GPU and pull it out of runtime suspend. Render nodes follow PCI order, so the dGPU can be
> `renderD128`, and players that do not name a node use it. On AMD Krackan,
> `omarchy-hw-nvidia-display` also cannot see the iGPU, because it has no `boot_vga`, so
> `LIBVA_DRIVER_NAME=nvidia` stays set. This PR moves video decode only. Which GPU OpenGL uses is
> unchanged.
>
> **Change.**
>
> - A new `omarchy-hw-igpu-render-node` prints the stable `/dev/dri/by-path/pci-<BDF>-render` of
>   the iGPU that drives the panel next to an NVIDIA GPU, and exits 1 everywhere else. It reads
>   cached sysfs only, never `lspci`.
> - `nvidia.lua` skips `LIBVA_DRIVER_NAME=nvidia` on the GSP path when that helper finds an iGPU.
>   `NVD_BACKEND` and `__GLX_VENDOR_LIBRARY_NAME` are untouched.
> - `install/helpers/hybrid-video-decode.sh` pins, on those machines only:
>   - mpv: `hwdec=vaapi` and `vaapi-device=<node>`, at top level, unless the user set them;
>   - Chromium, Chrome, Edge and Brave: `--render-node-override=<node>`, in flags files the user
>     already has.
> - The pins are applied by a per-user hardware leaf, by `omarchy-install-browser` and
>   `omarchy-refresh-chromium`, and by a migration for existing installs.
> - `nvidia.lua` checks the pins at config load and repins if the iGPU's PCI address has changed.
> - `omarchy-cmd-browser-handoff` accepts the override flag, so the fast handoff keeps working.
>
> Machines without NVIDIA, NVIDIA-only machines, and hybrids where NVIDIA drives the display get no
> change. No machine gets a different GLX vendor.
>
> **Evidence.** Measured on an ASUS ROG Zephyrus G16 GA605KM:
>
> - mpv on the iGPU node decodes H.264, HEVC, VP9 and AV1 on VCN at 4 to 9 times less CPU than
>   software decode, with the RTX suspended.
> - Chrome with the override keeps decode on the iGPU. YouTube on battery draws about 9 W instead
>   of about 12 W.
>
> **Not covered.** mpv's Vulkan device enumeration (#14285, on Intel + RTX 5070), and other VA-API
> clients that open the first render node, such as GStreamer and ffmpeg defaults.
>
> **Tests.** New `hw-igpu-render-node-test.sh` and `hybrid-video-decode-test.sh`. Two new
> topologies in `hw-nvidia-test.sh`. `./test/cli` passes. `./test/shell` shows the same failing
> files as stock `quattro` when run headless.
>
> This pull request was written with Claude Code.

<a id="omarchy-0009-alc285-master"></a>
### ALC285 Master at 100% (0009)

- **Component:** `omarchy`/`omarchy-settings`, patch 0009. Both channels. Fork branch
  `asus/audio` (`ae5acf14`). `omarchy-asus-g16-apply audio-master` raises the level on request.
- **Fixes:** Omarchy's ROG audio setup moves volume into software (`api.alsa.soft-mixer`) and sets
  the ALC285 hardware Master to `80% unmute`. The soft mixer never touches Master again, and
  `fix-mic.sh`'s `alsactl store` (plus `alsa-restore.service`) keeps the 80%, so the bar's 100% is
  12.75 dB below full scale (step 70 of 87 at 0.75 dB per step). The change unmutes Master at 100%
  (0 dB) on install. Existing installs at exactly the old 80% get a one-time notice with the
  `amixer` command instead of a sudden 12.75 dB jump; the migration never writes the mixer.
- **Test:** `amixer -c <card> sget Master` shows 100% / 0 dB on a fresh install; with the bar at
  100% the speakers reach full volume; on an install at 80%, `omarchy update` shows the notice
  once, changes nothing, and stays silent on the next run.
- **Measurement:** GA605KM (BIOS 307), soft mixer on, 2026-09-09: Master at step 70 of 87,
  -12.75 dB; 100% reads 0.00 dB. The G16 currently runs without the soft-mixer drop-in, so the
  patch has not been re-measured under the condition it fixes; do that before submitting.
- **Upstream: not submitted.** Issue
  [omacom/omarchy#11046](https://github.com/omacom/omarchy/issues/11046) "ASUS ROG: soft-mixer caps
  hardware Master at 80% so bar '100%' is not full volume" is open; the fork commit says "Fixes
  #11046" but no PR is open. Omarchy's review bot (2026-10-11) confirmed the cause from source
  (`fix-audio-mixer.sh:11` sets `Master 80% unmute`) and left the choice of fix to the maintainer,
  raising the smart-amp concern from omacom/omarchy#8359; a contributor (2026-10-13) offered to
  test a one-line change on ROG hardware. The 80% line (upstream `ba31e307`) was added to unmute,
  with no reason given for the level. The branch conflicts with open omacom/omarchy#7459 in
  `fix-audio-mixer.sh` (intents don't conflict). Suggested order: comment on #11046 pointing at the
  branch as option 1, rather than opening a PR cold.
- **Planned widening (on hold until the upstream testers answer, comment 6253673906):** a second
  report on #11046 (comment 6252566874: a ROG GL553VE with a Realtek ALC233, subsystem
  `0x104315e0`) gets the soft mixer, but `fix-audio-mixer.sh` only touches Master on an ALC285, so
  Master stays at ALSA's init level, 69% / -20.25 dB; set to 100% by hand it had no distortion and
  persisted. So: install sets Master to `100% unmute` whenever the soft mixer is on, on internal HDA
  codec cards only (those with `/proc/asound/card*/codec*`; the soft mixer matches
  `~alsa_card.*`, so "every card with Master" would also raise a USB DAC); the migration notices
  any level below 100% under the soft mixer (still notice only); one card-selection method for
  both `fix-audio-mixer.sh` (today `aplay -l`) and `fix-mic.sh` (`/proc/asound/card*/codec*`), so
  they set and store the same card (upstream bot's re-read, comment 6256214112); extend
  `test/shell.d/asus-rog-master-volume-test.sh` to a non-ALC285 card and a card without Master;
  re-export 0009 in both recipes and bump pkgrel. Waiting on: the ALC233 reporter's setup output, a
  listening check at 100% and an A/B with the soft mixer off (if the ALC233 sounds as good without
  it, the better fix may be not enabling the soft mixer there), and the second commenter's results
  with a codec-independent `amixer` one-liner.
- **Drop when:** an equivalent fix for #11046 is in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #27.

#### Upstream report draft

omacom/omarchy, PR against `quattro`, part of #11046 (option 1). Not opened; a human decides.
(Written for the ALC285-only version; the widening above changes the install and migration
bullets.)

> **Title:** Set the ASUS ROG ALC285 Master to full scale under the soft mixer
>
> Part of #11046.
>
> On ASUS ROG laptops with the ALC285, `fix-audio-mixer.sh` moves volume into software
> (`api.alsa.soft-mixer`) and sets the hardware `Master` to `80% unmute`. The soft mixer never
> touches `Master` again, and `alsactl store` keeps the 80%. So the bar's 100% is 12.75 dB below
> full scale on a GA605KM. The commit that added the line only meant to unmute.
>
> **Change.**
>
> - Install unmutes `Master` at 100% instead of 80%. On this codec 100% is 0 dB, with no gain above
>   full scale.
> - Existing installs are not changed. Raising `Master` during `omarchy update` would make the
>   speakers jump 12.75 dB at the same slider setting. Instead, a migration finds installs still at
>   exactly the old 80% and tells the user once, in the update output and as a notification. The
>   notice gives the exact command, using the card's ALSA id, e.g. `amixer -c Generic_1 set Master
>   100% unmute`.
> - The migration stays silent on non-ROG machines, without an ALC285, without the soft-mixer
>   drop-in, and at any other level. It never writes the mixer.
>
> If you would rather limit this to confirmed boards (the smart-amp concern from #8359), the
> install line and the migration can be gated on `omarchy-hw-match`. Say so and I'll narrow it.
>
> **Tests.** The new `test/shell.d/asus-rog-master-volume-test.sh` covers install at 100%, a
> migration that never writes, one notice at 80%, and silence at other levels, on non-ROG machines,
> without an ALC285, and without the drop-in. `./test/all` shows no new failures in the touched
> areas against stock `quattro`.
>
> Overlaps with #7459 in `fix-audio-mixer.sh`. Whichever merges second needs a rebase.
>
> This pull request was written with Claude Code.

<a id="omarchy-0010-rtkit"></a>
### rtkit on x86_64 (0010-0011, 0022)

- **Component:** `omarchy`/`omarchy-settings`, patches 0010-0011 (the two commits of
  omacom/omarchy#12428, taken as is) and 0022 (ours: restart the portal and PipeWire only for a
  session that started without rtkit). Migration `1789747667`. Both channels.
- **Fixes:** rtkit was only in Omarchy's aarch64 package list, so on a fresh x86_64 install no
  PipeWire thread ran realtime. With rtkit, PipeWire's data loop runs SCHED_RR at priority 20.
  After installing rtkit, `xdg-desktop-portal` must restart before PipeWire, or PipeWire clients
  take a hard `RLIMIT_RTTIME` of 0 from the stale portal (omacom/omarchy#12443).
- **Test:** `pacman -Q rtkit`; the portal's `RTTimeUSecMax` (`busctl --user get-property ...
  org.freedesktop.portal.Realtime RTTimeUSecMax`) is 200000; while audio plays, `ps -eLo
  pid,cls,rtprio,comm | grep -E 'pipewire|data-loop'` shows RR 20. Not yet verified on the G16.
- **Upstream: open.** We carry another contributor's PR,
  [omacom/omarchy#12428](https://github.com/omacom/omarchy/pull/12428) "Install rtkit so PipeWire
  gets realtime priority". As of 2026-10-18: head `dac602f5`, merges cleanly, no maintainer
  decision. Omarchy's review bot (2026-10-01) ran it in a VM and pushed `dac602f5` (rtkit moves to
  `omarchy-base.packages`, and the migration try-restarts `xdg-desktop-portal` before PipeWire); it
  says (2026-10-04) that merged omacom/omarchy#12958 doesn't replace this PR; a contributor
  (2026-10-12) calls it ready. #12428 adds rtkit to the base list without removing the aarch64
  entry, so aarch64 lists it twice (harmless; worth a line on a rebase). 0022 is ours, not on that
  PR. Optional: a comment on #12428 with G16 results; a human decides.
- **Drop when:** #12428 is in an Omarchy release we build from (and 0022 with it, or upstreamed).
- **Notes:** formerly tracked in issue #28.

<a id="omarchy-0012-initramfs"></a>
### No NVIDIA early load in the initramfs on hybrids (0012-0013, 0021)

- **Component:** `omarchy`/`omarchy-settings`, patches 0012-0013 (the two commits of
  omacom/omarchy#8263) and 0021 (ours: the migration removes the NVIDIA drop-in only when it is
  byte for byte the one Omarchy's installer wrote; any other content is kept with a note). Migration
  `1787683023`. Both channels. Fork branch `carry/initramfs-8263` (`aa9f2808`, `618b86ab`).
- **Fixes:** Omarchy writes `MODULES+=(nvidia ...)` into the initramfs on every NVIDIA machine. On a
  hybrid laptop that breaks resume from hibernation: the driver loads before the image is restored,
  its procfs suspend interface was never called, so `nv_pmops_freeze` returns -5 and the machine
  boots fresh. The iGPU already gives early KMS, so the early load buys nothing. The change early-
  loads only when NVIDIA owns every display controller, and migrates existing hybrid installs.
- **Test:** `lsinitcpio` on the initramfs or the Limine UKI lists no nvidia modules; hibernate and
  power on: the session resumes (`boot_id` unchanged), and `journalctl -b -1 | grep
  nv_pmops_freeze` shows no -5. For upstream's requested test of exact commit `0cdb9d69` on a
  hybrid that **still has** `/etc/mkinitcpio.conf.d/nvidia.conf` (the migration skips machines
  where it was removed by hand): restore the stock drop-in first, dev link `0cdb9d69` (or fork
  `quattro`), run `omarchy-migrate`, check `lsinitcpio`, then read `boot_id`, hibernate, power on
  and read it again. A human decides whether to post the result on #8263.
- **Upstream: open.** [omacom/omarchy#8263](https://github.com/omacom/omarchy/pull/8263) "Stop
  early-loading the NVIDIA driver on hybrid GPU machines so hibernation can resume" (another
  contributor's PR). As of 2026-10-18: head `0cdb9d69`, merges cleanly into `quattro` (888 commits
  past its base), no maintainer decision. Two Copilot threads on `migrations/1787683023.sh`
  (restore the drop-in when the rebuild fails; add a migration test) are answered and addressed in
  `0cdb9d69` but still marked unresolved. Omarchy's review bot (2026-09-28 and 2026-10-09, two
  models) found no defect; left open are a maintainer choice between this PR and
  omacom/omarchy#10065 (open; strips GPU drivers from the initramfs whenever hibernation is set up,
  also covers NVIDIA-only desktops; the two models disagreed on which is better), and the hardware
  resume test above. Confirmed elsewhere on a ThinkPad T480 (Intel + MX150, proprietary 580xx) and
  an AMD + NVIDIA laptop.
- **Drop when:** #8263 (or #10065) is in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #29.

<a id="omarchy-0014-webcam-guard"></a>
### Webcam menu guard from udev (0014-0015)

- **Component:** `omarchy`/`omarchy-settings`, patches 0014-0015 (`bin/omarchy-hw-webcam`). Both
  channels, in different versions: RC's 0015 (since 4.5.0rc1-1.111, #330) is fork commits
  `1c396770` + `5ba289be` + `ccd0f93d` on `asus/v4-5-0-rc1`, squashed, the last two being #15910's
  fixes (its `b6080af8` and `e5437fda`) taken unchanged; Quattro's 0015 is `6c7d7001` alone. Fork
  branch `perf/webcam-guard-udev`.
- **Fixes:** Omarchy's webcam menu guard opens the camera devices to decide whether to show webcam
  entries, which powers up the camera (and on some systems wakes other devices). The change answers
  from udev data instead. 0015 (`6c7d7001`, "Read every udev record before asking the webcams")
  walks every node first, exits 0 on any recorded capture node, and asks the devices only if some
  node had no record. On RC it also trusts a capture record only from a real camera (a node with a
  parent device, so not a v4l2loopback node, whose role follows its producer) that this user can
  read and write; anything else is asked live.
- **Test:** open the Omarchy menu repeatedly: the webcam LED doesn't flicker, `sudo fuser
  /dev/video*` shows nothing while the menu opens, and the webcam entries still appear.
- **Measurements (G16, at `6c7d7001`, 2026-10-18):** stock 125 ms per call with the camera awake
  about 2.6 s; patched about 5.5 ms per call, camera stays suspended, same answer.
- **Upstream: open.** [omacom/omarchy#15910](https://github.com/omacom/omarchy/pull/15910) "Answer
  the webcam menu guard from udev instead of opening cameras". It replaced our
  omacom/omarchy#15670, closed unmerged on 2026-10-19 (maintainers can't push to an
  organization-owned fork), and carries our two commits unchanged plus one fix on top: udev keeps
  the role it recorded when a v4l2loopback node appeared, so an `exclusive_caps=1` loopback that
  ffmpeg streams into is recorded `:video_output:` and our guard answers **no** while the camera
  streams, and a loopback recorded `:capture:` keeps answering yes after its producer stops.
  #15910 trusts a `:capture:` record only from a node with a parent device (v4l2loopback nodes have
  none) and asks the device otherwise. Upstream checked it with ftrace in a VM (`quattro` opened the
  capture node twice per call, #15910 zero times, same answers); `screenrecording-test.sh`,
  `menu-test.sh`, `menu-guards-test.sh`, `menu-guard-budget-test.sh` and `./test/cli` pass. It
  notes an interaction with omacom/omarchy#15616 (udev's record doesn't carry I/O MC). Omarchy's
  review bot had two models disagree on bug fix versus enhancement; it waits on the maintainer.
- **Refreshed on RC (#330):** RC carries #15910's fixes, so the loopback bug above and the yes for
  a camera the user can't open are gone there. Quattro (frozen) still ships both until it moves to
  the 4.5 recipes.
- **Drop when:** #15910 (or an equivalent) is in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #30.

<a id="omarchy-0016-tailscale"></a>
### Tailscale panel (0016)

- **Component:** `omarchy`/`omarchy-settings`, patch 0016. Both channels, different versions:
  - **RC** (since 1.102, #250): the bar follows tailscaled's IPN bus (one `tailscale debug
    watch-ipn` per panel) and runs no client while the panel is closed; the open panel refreshes
    everything on its interval. Fork commits `cf5cf22a` + `2a1d84b0` + `d3e137d8` on
    `asus/v4-5-0-rc1`, squashed.
  - **Quattro:** polls only `tailscale status` while the panel is closed (fork branch
    `perf/tailscale-poll`, `1b780450`).
- **Fixes:** the Tailscale bar panel polled full Tailscale state even with the panel closed, which
  kept waking the CPU on battery.
- **Test:** with the panel closed, `sudo powertop` or `pidstat -p $(pgrep -d, tailscale) 5` shows
  fewer wakeups than stock; opening the panel still shows full peer state.
- **Upstream:** two parts.
  - **merged-unreleased:** the closed-panel light poll (`tailscale status --json --peers=false`,
    full fetch on open) was merged another way, in omacom/omarchy#7623 (`c872d57cf`, on `quattro`
    2026-10-22). v4.5.0-rc1, which RC builds from, doesn't have it (checked 2026-10-25). Our
    [omacom/omarchy#15671](https://github.com/omacom/omarchy/pull/15671) "Poll only Tailscale
    status while its panel is closed" (head `c5e37d6d`, Greptile 5/5) is still open.
  - **open:** the IPN-bus watcher is omacom/omarchy#9894 (open, "Fix Tailscale login and reconnect
    getting stuck after key expiry"; not ours), which adds an always-on watcher
    (`watch-ipn-bus?mask=18`, refresh on State, Prefs and LoginFinished, 150 ms debounce, 2 to 60
    s restart backoff, tests in `test/shell.d/tailscale-test.sh`) but keeps the 30 s
    `status --json` poll. Our delta on top of it: drop the closed-panel poll (keep at most a long
    safety refresh, and only if a test shows the watcher can miss a change), `--peers=false` while
    closed, `mask=2` is enough (bit 16 is a no-op since 1.104). omacom/omarchy#7819 (open, poll
    watchdog) edits the same `Service.qml`. Plan: carry #9894 whole (one patch citing it) plus our
    poll removal on top, so either can drop when upstream decides.
- **Design notes (from Tailscale's sources):** use the LocalAPI bus only as a trigger, then re-read
  the stable API, as Tailscale's own Linux systray (`client/systray`) does. `watch-ipn-bus` /
  `ipn.Notify` are explicitly unstable (tailscale commit `172124da8`); `Status` is stable; never
  parse the notification body beyond which fields are present. 1.104 rejects mask bits 1<<3 and
  1<<8 with HTTP 400 (tailscale/tailscale#21878); peer bits would wake the bar on every peer change.
  Ignore `Health`-only notifications (every few seconds); refresh on `State`, `Prefs` or
  `LoginFinished` with about 200 ms debounce. Prefer `tailscale debug localapi GET ...` or
  `curl --unix-socket` over `tailscale debug watch-ipn` (the CLI turns peer changes on and prints
  multi-line JSON). No root needed (`ipnserver.Permissions`). The stream ends when tailscaled
  restarts, and a slow reader gets one ErrMessage and is dropped (tailscale/tailscale#20062):
  restart with backoff and take the initial state on every connect; the stream is silent while the
  tailnet is idle, so no idle timeout (tailscale/tailscale#21220).
- **Drop when:** RC: once a 4.5 tag contains `c872d57cf`, 0016 shrinks to the IPN-bus watcher; it
  drops when #9894 (or an equivalent watcher) is released. Quattro: 0016 drops when a stable
  release has `c872d57cf`.
- **Notes:** formerly tracked in issue #31.

<a id="omarchy-0017-monitor-watch-logind"></a>
### Clamshell state from logind events (0017)

- **Component:** `omarchy`/`omarchy-settings`, patch 0017 (`bin/omarchy-hyprland-monitor-watch`).
  Both channels. Fork branch `perf/monitor-watch-logind` (`092904dd` plus fixup `58a8d2e1`).
- **Fixes:** while docked, the monitor watcher re-ran the whole clamshell sync (hyprctl, jq,
  flock) every 2 s as a backstop for lid drift, about 6% of a core for as long as an external
  display is attached. The change listens to logind's `PrepareForSleep(false)` and `LidClosed`
  changes instead.
- **Test (G16, needed before submitting):** HDMI attached and idle: `top` shows no 2 s loop and the
  watcher's CPU drops from about 6% of a core; close and open the lid while docked: the internal
  panel goes off and back on; suspend and resume while docked: the state is right after resume;
  `busctl monitor org.freedesktop.login1` shows `PropertiesChanged` for `LidClosed` (inferred from
  introspection so far); restart logind: the watcher restarts its monitor.
- **Upstream: not submitted.** Upstream `quattro` still has the `sleep 2` loop. Open PRs, not
  ours, that touch the watcher: omacom/omarchy#14711 "Lock when a closed-lid session loses its last
  external display" (conflicts; if it lands, rebase onto it), omacom/omarchy#15542 "Stop reloading
  for an internal panel no reload can fix" (merges cleanly), omacom/omarchy#14780 (tests only).
  Squash the fixup before opening.
- **Drop when:** an equivalent change is in an Omarchy release we build from.
- **Notes:** formerly tracked in issue #32.

#### Upstream report draft

omacom/omarchy, PR against `quattro`. Not opened; a human decides.

> **Title:** Reconcile clamshell state on logind events instead of a 2s poll
>
> While a laptop is docked, the monitor watcher re-runs the whole clamshell sync (hyprctl, jq,
> flock and friends) every 2 seconds, as a backstop for lid drift that the Hyprland binds can miss,
> mostly across suspend. That costs about 6% of a core for as long as an external display is
> attached.
>
> This listens to logind instead. Drift can happen at two moments: on resume, which logind signals
> with `PrepareForSleep(false)`, and when the `LidClosed` property changes. Each runs the same sync
> with the delayed retries a monitor change gets. Only a laptop listens, as before, when the
> backstop ran only on a docked laptop. The listener is started again if it exits, for example when
> logind restarts. logind announces `LidClosed` with `PropertiesChanged`; its introspection marks
> only `Docked` and `OnExternalPower` as not emitting.
>
> **Tests.** New `monitor-watch-events-test.sh`. The lid-inhibit, monitor-modeless and
> monitor-recovery tests are updated. `./test/all` shows no new failures against stock `quattro`.
> On hardware: lid close and open, and suspend and resume while docked, on an ASUS ROG Zephyrus G16
> (fill in after the G16 run).
>
> Overlaps #14711 in `bin/omarchy-hyprland-monitor-watch`. Whichever lands second needs a rebase.
>
> This pull request was written with Claude Code.

<a id="omarchy-0018-launcher-icon-index"></a>
### Launcher icon index throttle (0018, Quattro only)

- **Component:** `omarchy`/`omarchy-settings` 4.0.6-1.3, patch 0018
  (`shell/services/AppLibrary.qml`). Quattro only: RC replaced it with
  [general-0004](#omarchy-general-0004-app-library) in 1.109 (#299), and the fork reverted it on
  `asus/v4-5-0-rc1` (`e2ce62938`). Fork branch `perf/launcher-icon-index` (`0f5fc1a9` plus fixup
  `2dcec7e7`).
- **Fixes:** opening the launcher walked every icon theme with `find` (about 9,000 paths, 75 ms)
  and indexed each path in its own JS callback on the GUI thread while the menu animated in. 0018
  rescans on open at most once a minute (desktop-entry changes still rescan at once, and a change
  that fires during a scan queues one more) and indexes in a single pass.
- **Test:** open the launcher repeatedly: the animation is smooth and `find` over the icon themes
  runs at most once a minute (`pgrep -a find` or `execsnoop`); install a new app: its icon appears
  at once. No G16 run is recorded.
- **Upstream: not submitted**, and superseded by the plan below. Related open PRs, not ours:
  omacom/omarchy#6505 "queue in-flight icon index scans in AppLibrary" (conflicts, overlaps in
  intent), omacom/omarchy#14992 (complementary; now general-0004), omacom/omarchy#11610 and
  omacom/omarchy#9408 (merge cleanly). omacom/omarchy#15167 (merged, in v4.5.0-rc1) makes each scan
  one `find` pass per icon tree.
- **Plan (2026-10-22):** a once-a-minute timer is the wrong shape: it rescans when nothing changed
  and an icon that lands inside the window waits. Instead: (1) bring in #14992 (done on RC as
  general-0004); (2) replace the rescan on open with a cheap change check: compare the modification
  times of the icon theme caches (`icon-theme.cache`, regenerated by the pacman hook) and the user
  icon directories against the last scan's, a few `stat` calls instead of walking ~9,000 paths,
  which still covers the first-install race (the shell can start before packages place their
  icons) without a timer; (3) keep 0018's single-pass indexing. Steps 2 and 3 are not done yet and
  not submitted; test cases: no scan on an unchanged app list, no scan on open with unchanged
  caches, a scan after one changes, single-pass indexing; on the G16: no `find` on repeated opens,
  a new app's icon on the next open, no rescan after saving a dotfile in the home directory.
- **Drop when:** Quattro moves to 4.5 (general-0004 then covers it), or an equivalent is released.
- **Notes:** formerly tracked in issue #33.

<a id="omarchy-0024-stranded-lock"></a>
### Stranded lock recovered while voxtype's OSD runs (0024)

- **Component:** `omarchy`/`omarchy-settings`, patch 0024
  (`omarchy-hyprland-session-lock-stranded`). Both channels; refreshed to omacom/omarchy#15912 in
  #191 and #192 (#130). The OSD is told apart by its `-p` argument in `/proc/<pid>/cmdline` (fork
  commits `f87801d1` + `d528fca1`, squashed).
- **Fixes:** after a resume from suspend-then-hibernate while locked, the Omarchy shell died
  creating its lock surface (omacom/omarchy#11084), and the relaunched shell never took the orphaned
  lock back: both screens stayed on Hyprland's "lockscreen app died" failsafe until someone ran
  `omarchy-shell lock lock` from a TTY. The cause is in stock Omarchy:
  `omarchy-hyprland-session-lock-stranded` (omacom/omarchy#15020) answers "undetermined" while any
  other `quickshell`/`qs`/`hyprlock` runs, and voxtype's dictation OSD always runs as `qs -p
  /usr/share/voxtype/quickshell`, so recovery never happens with dictation installed. Hybrid NVIDIA
  laptops with an external monitor hit the crash more often. The fix skips voxtype's Quickshell in
  that check; any other Quickshell and hyprlock still block recovery.
- **Evidence (GA605KM, omarchy 4.0.5-1.1; the script and `shell/plugins/lock/Service.qml` were
  byte-identical to stock 4.0.5-1):**

  ```
  omarchy-shell: WARN qt.qpa.wayland: Could not create EGL surface (EGL error 0x3000)
  omarchy-shell: WARN: The Wayland connection experienced a fatal error: Invalid argument
  omarchy-shell: Omarchy shell exited with status 255; relaunching.

  $ omarchy-hyprland-session-locked; echo $?                     # 0 (locked)
  $ omarchy-hyprland-session-lock-stranded <shell pid>; echo $?  # 2 (undetermined)
  $ pgrep -u $UID -a -x 'quickshell|qs|hyprlock'
  2438 qs -p /usr/share/voxtype/quickshell
  63973 quickshell -n -p /usr/share/omarchy/shell
  ```
- **Test:** `test/shell.d/hyprland-session-lock-stranded-test.sh` (fails on the old script). On
  hardware with dictation installed, run the old and new checks against the live process list: the
  old one reports another locker, the new one doesn't. Then a locked hibernate with an HDMI
  monitor plugged in: the failsafe clears without a TTY.
- **Upstream: open.** [omacom/omarchy#15912](https://github.com/omacom/omarchy/pull/15912), which
  replaced our omacom/omarchy#15890 (from fork branch `pr/lock-stranded-voxtype`).
- **Drop when:** a release we build from contains #15912.
- **Notes:** formerly tracked in issue #102 (and #130 for the refresh).

<a id="omarchy-0025-widget-link"></a>
### G16 Control widget's dead link swapped for the plugin (0025)

- **Component:** `omarchy`/`omarchy-settings`, patch 0025 (a migration). RC only (since 1.105).
  Fork commits `8d8b946b` + `34f25e1a`, squashed.
- **Fixes:** the transitional `asus-zephyrus-g16-control` left a link
  (`~/.config/omarchy/plugins/omarchy-asus.g16`) to a widget that no longer exists once
  `asus-rog-nkey-winlock` replaces it. The migration swaps the link for the
  [omarchy-asus plugin](https://github.com/omarchy-asus/omarchy-asus-plugin), so `omarchy-update`
  alone finishes the move. The link goes only once the plugin is on the bar; until then the
  migration fails and stays pending, so a failed clone or enable is retried.
- **Test:** on an install with the old link, `omarchy update`: the plugin is installed and enabled,
  the old link is gone, the bar shows the plugin.
- **Upstream: ours-only** (our packages only).
- **Drop when:** no supported install can still have the old link. Bug: #275.

<a id="omarchy-0026-rtx-asleep-at-app-start"></a>
### The RTX stays asleep while apps start (0026)

- **Component:** `omarchy`/`omarchy-settings`, patch 0026 (`omarchy-launch-all-gpus`,
  `OMARCHY_DESKTOP_GPU_PINS`, migration `1792823623`). RC only (since 1.107). Fork commits
  `c02f91e3` + `8769c24c` + `02c9d61f` + `6ef8e273`, squashed.
- **Fixes:** nvidia-open resumes a runtime-suspended GPU for any call into the driver, so any app
  that lists Vulkan devices or opens surfaceless or device EGL at startup (GTK, Chromium, Electron)
  woke the RTX for about 20 s, and so did screen lock and unlock. On a hybrid whose iGPU drives the
  display (Turing and newer), Hyprland sets `VK_LOADER_DRIVERS_DISABLE=*nvidia*` and lists only
  Mesa's EGL vendor for the desktop. Games get every GPU back on each path they start by (terminal,
  login autostart, a game entry in the launcher, `omarchy-launch-all-gpus`). What still inherits
  the pins is listed in NOTES.md.
- **Test:** with the RTX `suspended`, start GTK and Chromium apps from the launcher and lock and
  unlock: `runtime_status` stays `suspended`; a game from Steam or the launcher still runs on the
  RTX.
- **Upstream: not submitted.**
- **Drop when:** the driver stops waking for device enumeration, or Omarchy ships an equivalent.
  Bug: #218.

<a id="omarchy-general-0001-floating-redraw"></a>
### Floating mode waits for the app's redraw (general-0001)

- **Component:** `omarchy`/`omarchy-settings`, patch general-0001. RC only (since 1.104).
- **Fixes:** a window moved onto a floating workspace on a monitor of another scale was drawn
  half: the floating mode floated and sized it 1 ms after the move, before the app redrew at the
  new scale. It now waits 100 ms (1 ms and 16 ms lose the size, 50 ms keeps it).
- **Test:** move a window onto a floating workspace on a monitor of another scale: it is drawn in
  full.
- **Upstream: not submitted** (the same 1 ms timer is on upstream's `quattro`).
- **Drop when:** an equivalent is released. Bug: #274.

<a id="omarchy-general-0002-sleep-monitor"></a>
### The sleep lock's monitor survives suspends (general-0002)

- **Component:** `omarchy`/`omarchy-settings`, patch general-0002. RC only (since 1.106). Fork
  commits `ddd356ee` + `3410746c` + `fbfcc302`, squashed.
- **Fixes:** `omarchy-sleep-lock.service` exited around every resume (logind rejected its delay
  inhibitor as "already running"), leaving restart gaps where a suspend could start unlocked. The
  monitor now lasts the session: it holds a delay inhibitor between suspends, locks and releases it
  on `PrepareForSleep(true)` and takes a new one on `PrepareForSleep(false)`; a rejected inhibitor
  waits for the resume instead of failing the unit; a suspend while it holds none still gets the
  lock.
- **Test:** several suspend and resume cycles: `systemctl --user status omarchy-sleep-lock` shows
  no exits or restarts, and the screen is locked on every resume.
- **Upstream: not submitted.** Related: omacom/omarchy#13782 (another contributor's open PR, which
  retries the rejected restart instead).
- **Drop when:** an equivalent is released. Bug: #206.

<a id="omarchy-general-0004-app-library"></a>
### The app library rescans only on real changes (general-0004)

- **Component:** `omarchy`/`omarchy-settings`, patch general-0004 (fork commit `f8df8d7a3`). RC
  only (since 1.109, #299); replaces [0018](#omarchy-0018-launcher-icon-index) there.
- **Fixes:** quickshell's `DesktopEntries` watches every ancestor of the applications directories,
  the home directory included, so any dotfile save re-ran the hidden-entries scan and the icon index
  (2-12% of a core with nothing installed). It now rescans only when the app list really changes
  (a key of id, NoDisplay, icon and name per entry). Upstream's commit and test, taken as is.
- **Test:** save a dotfile in the home directory: no rescan; install an app: it and its icon
  appear.
- **Upstream: open.** omacom/omarchy#14992 "Rescan the app library only when the app list changes"
  (another contributor's PR; its commit `00697bf8c3`). The once-on-open rescan (the first-install
  race) is still there; see the plan under [0018](#omarchy-0018-launcher-icon-index).
- **Drop when:** #14992 is in an Omarchy release we build from.

<a id="omarchy-pkgbuild-pin-settings"></a>
### omarchy pins omarchy-settings to its release

- **Component:** `recipes/omarchy`, `pkgbuild-pin-settings-release.diff` (a `pkgbuild-patch` line
  in `DELTA`). Both channels.
- **Fixes:** upstream's `depends=()` asks only for `omarchy-settings=${pkgver}`, so stock's
  omarchy-settings of the same pkgver could satisfy the patched omarchy, and the two halves of the
  cohort could be installed or published apart (#83). The diff adds
  `depends+=("omarchy-settings=${pkgver}-${pkgrel}")` in `package()`, so only the patched
  omarchy-settings of the same release satisfies it. It is set in `package()`, not in
  `depends=()`, so the clean chroot and CI (which only have stock omarchy-settings) still build.
- **Test:** `pacman -Qip <omarchy package file> | grep 'Depends On'` (or `pacman -Qi omarchy` on
  an installed system) lists `omarchy-settings=<pkgver>-<pkgrel>`, e.g. `omarchy-settings=4.5.0rc1-1.111`;
  `pacman -U` of that omarchy next to stock omarchy-settings of the same pkgver fails on the
  dependency. `bin/release-cohort check-recipes` checks that the pin is present
  (`tests/ci/release-cohort.sh`).
- **Upstream: ours-only.** Only a downstream that rebuilds one half needs it.
- **Drop when:** the omarchy recipes are dropped.

<a id="omarchy-pkgbuild-source-monitor-unit"></a>
### omarchy-settings ships the charger-swap monitor unit

- **Component:** `recipes/omarchy-settings`, `pkgbuild-source-monitor-unit.diff` (a
  `pkgbuild-patch` line in `DELTA`). Both channels. Same change as pkgs branch
  [`omarchy-settings-source-monitor`](https://github.com/omarchy-asus/omarchy-pkgs/tree/omarchy-settings-source-monitor).
- **Fixes:** omarchy-settings installs user units from an explicit list, so the charger-swap
  monitor that [0002](#omarchy-0002-usbc-power) adds would land only in
  `/usr/share/omarchy/default/systemd/user`, where systemd doesn't find it, and first-run and
  migration `1792174852` would enable a unit that doesn't exist. The diff installs
  `omarchy-powerprofiles-source-monitor.service` in `/usr/lib/systemd/user` when the source has
  it (inert off ROG laptops through its `ConditionPathExists`).
- **Test:** `pacman -Ql omarchy-settings | grep omarchy-powerprofiles-source-monitor.service`
  lists `/usr/lib/systemd/user/omarchy-powerprofiles-source-monitor.service`;
  `systemctl --user cat omarchy-powerprofiles-source-monitor.service` finds it; Omarchy's
  `config-test.sh`, run with the patched PKGBUILDs as the omarchy-pkgs checkout, no longer
  reports it as not shipped.
- **Upstream: not submitted.** It is the omacom/omarchy-pkgs companion of omacom/omarchy#15668,
  not opened yet (a human decides; see [0002](#omarchy-0002-usbc-power)).
- **Drop when:** 0002 drops, or an omarchy-settings release ships the unit.

<a id="pkgbuild-pkgdesc-label"></a>
### The "(omarchy-asus build)" label

- **Component:** `pkgbuild-pkgdesc-label.diff` in `recipes/omarchy`, `recipes/omarchy-settings`
  and `recipes/hyprland` (a `pkgbuild-patch` line in each `DELTA`). Both channels.
- **What:** appends `(omarchy-asus build)` to `pkgdesc` (in hyprland, for both `hyprland` and
  `hyprpm`), so `pacman -Qi` shows at once that a package is our patched build and not stock's.
- **Test:** `pacman -Qi omarchy omarchy-settings hyprland hyprpm | grep Description`: every line
  ends with `(omarchy-asus build)`.
- **Upstream: ours-only.**
- **Drop when:** each recipe is dropped (the label goes with it).

## G16 system files: omarchy-asus-g16

RC 1.0.0-103, Quattro 1.0.0-1. Static files for G16 fixes that the
[omarchy-asus fork](https://github.com/omarchy-asus/omarchy) otherwise sets up through an install
leaf or migration, byte-identical to the fork's, under `/usr/lib` instead of `/etc` with basenames
no Omarchy file uses (`recipes/omarchy-asus-g16/README.md`). Shipped since #4. The package enables
nothing; a non-GA605KM machine gets a warning. Delete leftover hand-written copies in `/etc` once
it is installed.

<a id="g16-touchpad-wake"></a>
### Touchpad wake (ASUF1209)

- **Component:** `omarchy-asus-g16`, `/usr/lib/udev/rules.d/99-omarchy-asus-g16-touchpad-wake.rules`.
  Both channels. Fork branch `asus/touchpad-wake` (`22acd8bf`).
- **Fixes:** the GA605KM's ASUF1209 I2C touchpad is armed as a wake source: a brush or click wakes
  the laptop from s2idle, and touches count as wakeup events (129k in one boot) while it is going
  down, which can abort a hibernate. The rule disarms only the touchpad; the keyboard, lid and power
  button still wake it.
- **Test:** install, then reboot or `sudo udevadm trigger --action=add --subsystem-match=i2c
  --sysname-match='i2c-ASUF1209:*'` (the package doesn't touch sysfs at install time);
  `cat /sys/bus/i2c/devices/i2c-ASUF1209:*/power/wakeup` prints `disabled`; suspend and click the
  touchpad: it stays asleep; a key or the lid still wakes it; hibernate with a hand on the touchpad:
  it doesn't abort.
- **Upstream: not submitted** to Omarchy. A kernel linux-input report was withdrawn after s2idle
  testing showed that only a click wakes the laptop.
- **Drop when:** Omarchy ships an equivalent rule in a release, or the kernel or firmware limits
  ASUF1209 wakeups to clicks.
- **Notes:** formerly tracked in issue #15.

<a id="g16-hibernate-mode"></a>
### HibernateMode=shutdown

- **Component:** `omarchy-asus-g16`,
  `/usr/lib/systemd/sleep.conf.d/omarchy-asus-g16-hibernate-mode.conf`. Both channels. Fork branch
  `asus/hibernate-mode` (`3a441d6d`).
- **Fixes:** in platform mode the kernel backs out of ACPI S4 when a wakeup event is pending; on
  the GA605KM that rollback powers the RTX back up mid-transition, the NVIDIA driver fails to
  restore its channels, and the laptop needs a hard reset. Shutdown mode writes the image and
  powers off, with no rollback path. (The separate power-off hang after the image is written is
  [nvidia 0001](#nvidia-0001-hibernate-power-off).)
- **Test:** `systemd-analyze cat-config systemd/sleep.conf | grep HibernateMode` shows `shutdown`;
  `systemctl hibernate` several times, with a USB device plugged in and the charger plugged and
  unplugged around it: every run powers off and resumes cleanly.
- **Upstream: not submitted** for the GA605KM. Related:
  [omacom/omarchy#8589](https://github.com/omacom/omarchy/issues/8589) (open; the same setting for a
  G14 GA403UV, waiting on how to gate it); omacom/omarchy#8017 used the same mechanism for another
  model.
- **Drop when:** Omarchy ships this for the GA605KM (or generic ROG), or the S4 rollback / NVIDIA
  restore bug is fixed in the kernel or driver.
- **Notes:** formerly tracked in issue #16.

<a id="g16-nvidia-powerd-start-limit"></a>
### nvidia-powerd start limit

- **Component:** `omarchy-asus-g16`,
  `/usr/lib/systemd/system/nvidia-powerd.service.d/20-omarchy-asus.conf`
  (`StartLimitIntervalSec=60`). Both channels. Fork branch `asus/nvidia-powerd-start-limit`
  (`2cd582fb`); pkgs branch
  [`omarchy-settings-nvidia-powerd`](https://github.com/omarchy-asus/omarchy-pkgs/tree/omarchy-settings-nvidia-powerd)
  (`25c4f5a4`). First proposed as an opt-in split package, now in the main package as a tested bug
  fix.
- **Fixes:** nvidia-utils caps `nvidia-powerd.service` at five starts with an unlimited window
  (`StartLimitIntervalSec=infinity`, `StartLimitBurst=5`). asusd starts it on every charger plug-in
  and stops it on every unplug, so from the sixth plug-in of a boot systemd refuses
  (`start-limit-hit`) and Dynamic Boost stays off until reboot.
- **Test:** `systemctl daemon-reload`; `systemctl show nvidia-powerd -p StartLimitIntervalUSec`
  shows 1min; plug and unplug the charger at least 7 times, a minute or more apart: after each
  plug-in `systemctl is-active nvidia-powerd` prints `active`, and `journalctl -u nvidia-powerd -b`
  has no "Start request repeated too quickly".
- **Upstream: not submitted.** The root cause belongs in asusctl (`manage_nvidia_powerd` starts and
  stops the unit on every plug event and ignores the failed start); an asusctl patch is drafted,
  never compiled or sent.
- **Drop when:** asusctl stops restarting the unit per plug event, nvidia-utils relaxes the limit,
  or `omarchy-settings` ships the drop-in in a release.
- **Notes:** formerly tracked in issue #17.

<a id="g16-rcu-nocbs"></a>
### rcu_nocbs=all

- **Component:** `omarchy-asus-g16`, `/usr/share/limine-entry-tool.d/omarchy-asus-g16-rcu-nocbs.conf`
  and the `95-omarchy-asus-g16-limine.hook` alpm hook. RC only (since 1.0.0-102).
- **Fixes:** linux-omarchy has lazy RCU built in, but it only batches callbacks on offloaded CPUs,
  and without `rcu_nocbs=` none are, so `call_rcu()` keeps idle CPUs' ticks running. Offloading all
  CPUs lets idle CPUs stop their tick (ChromeOS measured 0.58 to 0.41 W on an idle Chromebook).
- **Test:** `grep -o 'rcu_nocbs=[^ ]*' /proc/cmdline` prints `rcu_nocbs=all`, and `ps -e | grep -c
  rcuo` counts `rcuo` kthreads. The G16 boot A/B is in #229.
- **Upstream: ours-only** (a boot setting, not a bug). Omarchy's kernel could set
  `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y` instead; not proposed until the G16 numbers are in.
- **Drop when:** linux-omarchy turns on `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL`, or the A/B shows no
  saving.

<a id="g16-mt7925-auth-retries"></a>
### Wi-Fi back after a wake (mt7925)

- **Component:** `omarchy-asus-g16`,
  `/usr/lib/NetworkManager/conf.d/omarchy-asus-g16-mt7925-auth-retries.conf`. RC only (since
  1.0.0-103).
- **Fixes:** the G16's MT7925 times out the WPA four-way handshake once after most resumes;
  NetworkManager reads that as a possibly wrong password, asks a secret agent Omarchy doesn't run,
  and blocks autoconnect, so Wi-Fi stayed down until reconnected by hand. The drop-in gives
  `mt7925e` devices six tries instead of three (`match-device=driver:mt7925e`).
- **Test:** `NetworkManager --print-config | grep -A2 mt7925` prints the section; after a wake,
  `journalctl -b -u NetworkManager | grep -E "reauthenticating|asking for new key|no-secrets"`
  shows at most `reauthenticating` lines.
- **Upstream: not submitted.** Two parts (mt76 losing the first handshake after a wake;
  NetworkManager treating a handshake timeout as a wrong key when no agent can answer); a human
  decides whether either is reported.
- **Drop when:** either is fixed upstream. Bug: #196.

<a id="g16-keyboard-autosuspend"></a>
### EXPERIMENTAL built-in keyboard autosuspend

- **Component:** `omarchy-asus-g16`,
  `/usr/lib/udev/rules.d/99-omarchy-asus-g16-keyboard-autosuspend.rules`. RC only (since
  1.0.0-104). Goes with [9909](#kernel-9909-nkey-caps-led-only) in linux-omarchy.
- **Fixes:** the built-in N-Key keyboard (USB 0b05:19b6) keeps `power/control` at the USB
  default `on`, so it never runtime-suspends, and neither does the keyboard/Bluetooth xHCI
  (67:00.0); idlemask bit 16 read idle only with that xHCI and the PSP both suspended (#249).
  The rule sets `power/control=auto` and `autosuspend_delay_ms=2000`; a key press wakes it.
  Without 9909 a lit Num Lock still keeps it awake (usbhid's LED check).
- **Test:** `cat /sys/bus/usb/devices/3-4/power/control` prints `auto`; on 9.111 with Num Lock
  on and Caps Lock off, its `power/runtime_status` reads `suspended` a few seconds after the last
  key press (#249).
- **Upstream: ours-only** (a power setting for one laptop's keyboard).
- **Drop when:** the G16 test shows no gain, or the kernel autosuspends this keyboard by default.

## Our packages

<a id="pkg-asus-rog-nkey-winlock"></a>
### Win-lock helper (asus-rog-nkey-winlock)

- **Component:** `recipes/asus-rog-nkey-winlock/`. RC 0.1.0-103: `g16-winlockd`, a root service
  (C, sd-bus) that owns the keyboard's hidraw node and offers `Status`/`SetLocked` on the system bus
  (`io.github.omarchy_asus.WinLock1`, polkit for the active session), plus the `g16-winlock` user
  unit for the OSD and auto-unlock (#193, #282). Quattro 0.1.0-12: the user service
  `g16-winlock.service` with a hidraw udev rule, and the transitional `asus-zephyrus-g16-control`.
  RC's package replaces `asus-zephyrus-g16-control`; the bar widget is now the
  [omarchy-asus plugin](https://github.com/omarchy-asus/omarchy-asus-plugin) (#183), and
  [omarchy 0025](#omarchy-0025-widget-link) finishes the move. Shipped since #5.
- **Fixes:** Fn+Super toggles a firmware Win-key lock; while it is on Super sends nothing and
  nothing on screen says why. The helper shows a toast (or unlocks automatically). It needs
  [kernel 0568](#kernel-0568-winlock): without it, no reports reach hidraw.
- **Test:** press Fn+Super twice: a Win-lock OSD each time, and the journal logs on/off. RC:
  `busctl call` `Status` answers after the first press; `recipes/asus-rog-nkey-winlock/*.test.sh`.
- **Upstream: ours-only.** Related docs PR
  [omacom/omarchy#11045](https://github.com/omacom/omarchy/pull/11045) (documents the Fn+Super
  lock, open).
- **Open questions:** the fork has an Omarchy-shaped watcher too (omarchy-asus/omarchy#2,
  `omarchy-asus-rog-winlock.service`, installed by `install/hardware/asus/rog-winlock.sh`); a
  machine with both shows two toasts per press. Options: this package skips itself when the fork's
  service is present; drop it once the fork version is in use; or the fork's migration masks ours.
  On a G16 with both, press Fn+Super once: expect exactly one OSD. Quattro's older follow-ups
  (`find_hidraw()` may pick the wrong node; `TAG+="uaccess"` in a `99-` rule likely grants nothing;
  the default mode differs between the unit and `g16ctl`) were left out of #5 under the
  no-behaviour-change rule; RC's root service replaces that path.
- **Drop when:** never (a local feature), unless Omarchy ships an equivalent.
- **Notes:** formerly tracked in issue #20.

<a id="pkg-omarchy-asus-keyring"></a>
### Keyring and setup script (omarchy-asus-keyring, bin/omarchy-asus-setup)

- **Component:** `omarchy-asus-keyring` (RC 20261018-101, Quattro 20261018-1, any) and
  `bin/omarchy-asus-setup`. Shipped since #3.
- **Fixes:** switching a G16 to this repo meant adding the key, `custom-repos.conf` and the
  pre-refresh hook by hand, and a missed step could let `omarchy refresh pacman` (`-Syyuu`)
  downgrade our builds. The keyring installs `omarchy-asus.gpg`, `omarchy-asus-trusted` and an empty
  `omarchy-asus-revoked` into `/usr/share/pacman/keyrings/` (modelled on omarchy-keyring) and runs
  `pacman-key --populate omarchy-asus`. The script gates on a GA605 DMI match, shows the
  EXPERIMENTAL warning, pins the key fingerprint `0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88`,
  previews the signed database, writes the repo config and hook, installs the keyring and runs
  `pacman -Su` only after confirmation (`--dry-run`, `--uninstall`). One deliberate deviation from
  stock: it applies the hook directly instead of running `omarchy refresh pacman`, so nothing
  upgrades before the user has seen the list.
- **Test:** `omarchy-asus-setup --dry-run` prints every privileged step and changes nothing; run it
  for real; `pacman-key --list-keys 0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88` shows the key locally
  signed; the `Include` line sits above `[omarchy]` in `/etc/pacman.conf`; `pacman -Qi
  omarchy-asus-keyring` succeeds; `--uninstall` restores `pacman.conf`. Keep a fallback kernel and
  compare the fingerprint out of band first (trust on first use).
- **Upstream: ours-only** (repo infrastructure).
- **Open follow-up:** the manual path in LAPTOP-SETUP.md trusts the key but never installs
  `omarchy-asus-keyring`, unlike the script, so manual installs miss packaged key rotations and
  revocations; add the keyring install to it, followed by the full Omarchy upgrade (review finding,
  2026-10-18).
- **Drop when:** the repo is retired. Ship a revocation in `omarchy-asus-revoked` if the key is
  ever replaced.
- **Notes:** formerly tracked in issue #18.

<a id="pkg-omarchy-asus-g16-apply"></a>
### G16 fix applier (omarchy-asus-g16-apply)

- **Component:** `omarchy-asus-g16-apply` (RC 0.1.0-101, Quattro 0.1.0-9).
- **What:** a command run by hand. `--check` reports every known G16 fix; it applies the ones that
  live in the user's config or `/etc` on a stock Omarchy install, where they would otherwise need
  the fork, and the speaker level (`audio-master`), which no migration raises. With the patched
  omarchy, the migrations do most of it and nothing runs at login (#45, merged in #109).
- **Test:** `omarchy-asus-g16-apply --check`.
- **Upstream: ours-only.**
- **Drop when:** every fix it applies has shipped upstream.

<a id="pkg-omarchy-asus-g16-testd"></a>
### G16 test-session helper (omarchy-asus-g16-testd, held)

- **Component:** `omarchy-asus-g16-testd` 0.1.0-106. **Held** (`recipes/omarchy-asus-g16-testd/HOLD`):
  CI builds it, nothing publishes it, until the maintainer agrees to install it on the G16 and its
  G16 test passes (#277; allowlist gaps in #284).
- **What:** one root helper per G16 hardware test session: one polkit approval, then fixed
  allowlisted operations (EC reads, tracefs instances, A/B knobs, module swaps, boot drop-ins,
  freezing an app scope), each logged with a reason.
- **Test:** offline, `tests/channel/g16-testd.sh` runs
  `recipes/omarchy-asus-g16-testd/tests/test_g16_testd.py`: the helper against a fake root
  (`--fake`, every command only logged); the allowlists refuse what isn't on them; everything is
  put back on stop, expiry, SIGTERM and after a crash; another uid is refused; calls fail with no
  session open; `package()` installs exactly the expected files. On the G16 (its queued test):
  `g16-testd session start` shows one polkit dialog; `g16-testd call knob-set nmi-watchdog 0
  --reason test` then `g16-testd session stop` puts the knob back
  (`cat /proc/sys/kernel/nmi_watchdog`); `journalctl -u omarchy-asus-g16-testd` logs each call
  with its reason; `g16-testd available` exits non-zero once the session is stopped.
- **Upstream: ours-only.**
- **Drop when:** the G16 test kits no longer need root steps (or move to another mechanism); a
  test helper with no kit using it is removed with its recipe.

<a id="pkg-proton-experimental-asus"></a>
### Proton Experimental fullscreen fix (proton-experimental-asus, held)

- **Component:** `proton-experimental-asus` 11.0.20261014-101, patch
  `general-0001-winex11-Only-expect-a-ConfigureNotify-for-_NET_WM_FU.patch` (fork
  `asus/experimental_11.0` on omarchy-asus/wine). **Held**: a general (non-ASUS) fix that waits for
  the maintainer's approval to carry it and for its G16 test (#266).
- **Fixes:** in exclusive fullscreen on a monitor other than the game's chosen one, winex11 waits
  for a ConfigureNotify answering `_NET_WM_FULLSCREEN_MONITORS`, which Hyprland never sends, so
  pointer positions map through the wrong monitor (clicks about 80 px off on the G16). The fix waits
  only when the window manager lists that hint in `_NET_SUPPORTED`.
- **Test:** offline, `python3 -I recipes/proton-experimental-asus/tests/launcher.test.py` (the
  launcher against a fake Proton), and the build's `check()` fails unless both `winex11.so` builds
  load exactly the libraries Valve's do. Without a game: `recipes/proton-experimental-asus/tests/repro/`
  (README.md, "Reproducer") runs a test program in a private headless sway with two outputs laid
  out like the G16's; with the pointer at HDMI (400,400), (1280,720), (2000,1300), `./run.sh
  HEADLESS-2 <Proton files dir> -- 0 2560 1440 8 bc` logs clicks at 2559,320 2559,640 2559,1220 on
  stock Proton Experimental and at 400,400 1280,720 2000,1300 with the fix. On the G16 (#266): a
  game in exclusive fullscreen on the HDMI monitor with **Proton Experimental (omarchy-asus)**
  selected: hover and clicks land under the pointer, and the bottom edge is reachable.
- **Upstream: not submitted.** Valve's Proton 11.0 has the same code (wine commit `a63f42b3`);
  upstream wine doesn't wait there.
- **Drop when:** Valve's Proton Experimental ships the fix or reverts `a63f42b3` (then stock
  behaves the same). Until then the pin must follow each Proton Experimental update, or the fix
  is off (README.md, "Updating to a new Proton Experimental").

## Not carried

Work still in issues, not in any recipe on `main` today:

- Kernel stack in PR #288 (RC 7.2.8-9.105, on 9.104): 0809 amd_pmf hwmon power (#238) and 0570
  the GL9767 SD reader's runtime PM (#226). It merges after its G16 test.
- G16 idle power candidates: #249 (SoC floor), #227 (Wi-Fi power save, about 0.27 W in the screen
  test), #228 (Num Lock LED, about 0.20 W), #230 (display IPS); #225, #232 and #234 showed no effect
  beyond noise in two runs.
- G16 idle: Chrome profile writes keep the SSD busy (#326).
- G16 Control: hold charging while a weak charger can't carry the load (#165, in the omarchy-asus
  plugin).
- Bugs: HDMI on the RTX sometimes not detected after boot (#158); a Hyprland reload on battery
  blanks the panel twice (#204).
- The 9900 battery A/B is experiment #10. Tooling work (#309, #258, #212, #284) and the project
  status page (#47) are issues too.

## Dropped

| change | was | dropped in | why |
|---|---|---|---|
| general-0003, the lock's password field lost the keyboard after a suspend (#295) | omarchy RC | RC 4.5.0rc1-1.110 (#306) | the Hyprland seat fix ([seat-leave](#hyprland-seat-leave)) sends `wl_keyboard.leave`, so Qt re-activates the lock window with stock `LockView.qml`; reverted on the fork by `b5af08c6` |
| 0018, launcher icon index throttle | omarchy RC | RC 4.5.0rc1-1.109 (#299) | replaced by upstream's [#14992](#omarchy-general-0004-app-library); still on Quattro ([0018](#omarchy-0018-launcher-icon-index)) |
| `asus-zephyrus-g16-control`, the G16 Control widget package | asus-rog-nkey-winlock | RC (0.1.0-103 replaces it) | the widget is the omarchy-asus plugin (#183); RC's `asus-rog-nkey-winlock` replaces the transitional package |
| hid-asus Win-lock DKMS module (`recipes/hid-asus-winlock-dkms-reference/`) | out of tree | linux-omarchy 7.2.8-9.1 | the same patch is in the kernel as [0568](#kernel-0568-winlock); kept as a reference, not built |
