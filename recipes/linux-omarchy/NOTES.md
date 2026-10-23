# linux-omarchy (omarchy-asus build)

## Base

- Upstream recipe: `pkgbuilds/linux-omarchy` in omacom/omarchy-pkgs.
- Tracks linux-omarchy **7.2.8-9**, recipe last changed upstream in commit
  `cc664d884b8400accad0e02347c39d6b2cd6b688`
  ("Build linux-omarchy as the BORE kernel instead of a meta package").
- Our version: **7.2.8-9.104**. Builds both split packages from one pkgbase:
  `linux-omarchy` and `linux-omarchy-headers` (headers are required by DKMS
  modules such as nvidia-open-dkms).

## What we change

Compared with upstream, only:

1. `pkgrel=9` -> `pkgrel=9.104` (kernel release string becomes `7.2.8-9.104-omarchy`).
   History: 9.1 added 0568 and 9900; 9.2 added 0569 and 0807; 9.3 added 0481;
   9.4 added 0773; 9.5 added 0482; 9.101 is 9.5 moved into the RC channel's
   range (.101 and up, so no file shares a name with Quattro's; #201); 9.102 added 0810; 9.103 added 0808; 9.104 added 0809.
2. New patch `0568-hid-asus-pass-through-rog-nkey-win-lock-reports.patch`,
   added to `source=()` after `0567-...` and with matching entries in
   `b2sums` and `sha256sums`. It adds `QUIRK_HID_WIN_LOCK` to hid-asus for the
   ROG N-Key keyboard (USB 0b05:19b6, `ROG_NKEY_KEYBOARD2`) so Win-key lock
   reports (report 0x5d, opcode 0xbf 0x01) are passed to hidraw instead of
   being dropped with the AURA echo stream.

3. New patch `0569-i2c-designware-size-rx-fifo-threshold.patch` after 0568
   (backport from linux-next; see "0569" below).
4. New patch `0807-platform-x86-asus-armoury-ga605km-power-limits.patch`
   after `0806-...` (GA605KM power-limits entry; see "0807" below).
5. New patch `0481-drm-amd-display-power-backports.patch` after `0480-...`
   (three amdgpu display backports, CACP default off; see "0481" below).
6. New patch `0773-gpiolib-acpi-ignore-wake-on-gpio16-asus-ga605km.patch` after
   `0772-...` (GA605KM: ignore GPIO 16 wakeups; see "0773" below).
7. New patch `0482-drm-amd-display-replay-dmub-hpd-skipped-in-suspend.patch` after
   `0481-...` (USB4 dock monitors after a replug in suspend; see "0482" below).
8. New patch `0808-platform-x86-asus-wmi-restore-thermal-policy-after-hibernation.patch`
   after `0807-...` (asus-wmi writes its thermal policy and enabled fan curves
   back after hibernation; see "0808" below).
9. New patch `0809-platform-x86-amd-pmf-hwmon-apu-dgpu-socket-power.patch` after
   `0808-...` (amd_pmf hwmon: APU, dGPU and socket power; see "0809" below).
10. New patch `0810-drm-amd-display-panel-power-savings-apply-now.patch` after
   `0809-...` (a `panel_power_savings` write takes effect at once; see "0810" below).
11. `9900-EXPERIMENTAL-...` (see "EXPERIMENTAL: 9900" below).

Our patches have no `.sig` (upstream's patch signatures are made by the
Omarchy kernel maintainer's key); their checksums pin them instead.
Everything else (config, other patches, keys) is byte-identical to upstream.

## Upstream status of 0568

Not in mainline (`torvalds/linux` master) or the HID tree (`hid.git` for-next)
as of 2026-10-17: neither contains `QUIRK_HID_WIN_LOCK` or the 0xbf handling.
It was submitted to linux-input on 2026-09-10 (patchwork 14804337) and has had
no replies yet.

## 0569: i2c-designware RX FIFO threshold (backport from linux-next)

**What.** `0569-i2c-designware-size-rx-fifo-threshold.patch` is upstream
commit `e7d5d642c089` ("i2c: designware: size the RX FIFO threshold to the
queued transfer", Navon John Lukose, acked by Mika Westerberg, applied by Andi
Shyti to the i2c-host tree, in linux-next since 2026-10-10). The original
header and tags are kept. The patched file in 7.2.8 is byte-identical to
mainline, so the hunk applies unchanged.

**Why.** Mainline leaves `DW_IC_RX_TL` at 0 in master mode, so the controller
raises one RX_FULL interrupt per received byte. The G16 touchpad (I2C-HID on
the AMDI0010 DesignWare controller, 400 kHz) reads about 67 bytes per report
at 240 reports/s. On this laptop that was measured at about 12.6k interrupts/s
while touching (about 52 per report). With the patch RX_FULL fires once per
queued batch instead. The expected result is several times fewer interrupts
while the pad is in use (about 1-2 % of one core) and less wakeup/power cost.
It does not change touch latency (the 1.6 ms bus transfer dominates).

**Default behavior.** Yes, this changes behavior for every DesignWare I2C
controller in master mode (touchpad and any other device on those buses).
There is no knob. Risk: low to medium. The patch is small, reviewed and acked
upstream, and only changes when the RX interrupt fires; the last byte of a
transfer still triggers it. A regression would show as I2C timeouts or a dead
touchpad.

**Test on the laptop** (after booting `7.2.8-9.3-omarchy`):

```sh
uname -r                                   # 7.2.8-9.3-omarchy
grep -iE 'AMDI0010|designware' /proc/interrupts   # find the controller IRQ (N)
# Move a finger on the pad continuously for the 10 s:
N=3   # replace with the IRQ number from the line above
a=$(awk -v n="$N:" '$1==n{s=0;for(i=2;i<=NF;i++)if($i~/^[0-9]+$/)s+=$i;print s}' /proc/interrupts)
sleep 10
b=$(awk -v n="$N:" '$1==n{s=0;for(i=2;i<=NF;i++)if($i~/^[0-9]+$/)s+=$i;print s}' /proc/interrupts)
echo "$(( (b - a) / 10 )) IRQ/s"            # stock ~12600/s; expect a few thousand or fewer
journalctl -k -b | grep -iE 'i2c_designware|i2c-hid|controller timed out|timeout'   # expect nothing new
```

Then check move, tap/click, two-finger scroll, suspend and resume
(`systemctl suspend`), and hibernate: the touchpad must keep working and the
kernel log must stay clean. To roll back, boot the previous kernel.

**Remove when** the commit is in mainline and upstream linux-omarchy is
based on a kernel that contains it, or upstream linux-omarchy carries it
(the patch then fails to apply at fuzz 0, which shows it).

## 0773: gpiolib-acpi ignores GPIO 16 wakeups on the GA605KM (#151)

**What.** A DMI entry in `drivers/gpio/gpiolib-acpi-quirks.c` (vendor
`ASUSTeK COMPUTER INC.`, board `GA605KM`) with `.ignore_wake =
"AMDI0030:00@16"`, the same pattern as the existing `ignore_wake` entries. It
applies after 0771, which touches the same table.

**Why.** With an HDMI monitor connected (driven by the RTX), the G16 woke
about 95 ms after entering s2idle, on battery and on AC. The wake came from the
firmware `_AEI` event on GPIO 16 (`ACPI: PM: Wakeup unrelated to ACPI SCI`,
`GPIO 16 is active`), so lid-close and idle suspend left it awake with the
screens off (#132). Booting with `gpiolib_acpi.ignore_wake=AMDI0030:00@16`
fixed it on the G16: 10.5 s and 33 s of hardware sleep with HDMI connected,
44 s for a lid close, and the lid (GPIO 0) and keyboard still wake it. What
GPIO 16's `_AEI` handler is for has not been decoded (it needs an acpidump).

**Default behaviour and risk.** It changes behaviour only on a GA605KM: GPIO 16
can no longer wake the machine. Nothing else matches.

**Test** (on the G16, booted on this kernel, with the local
`/etc/limine-entry-tool.d/98-g16-test-gpio16.conf` drop-in removed first):
```bash
grep -o 'gpiolib_acpi[^ ]*' /proc/cmdline                     # expect nothing
journalctl -k -b | grep 'Ignoring wakeup on pin 16'             # expect one line
# HDMI connected: suspend, wait 60 s, wake with the power button
cat /sys/power/suspend_stats/last_hw_sleep                     # seconds, not ~95000 us
```
The kit's `0773` check covers the first two; its `suspend` check fails a
cycle that wakes at once.

**Upstream.** Not submitted (target: linux-gpio). Drop it once an equivalent
entry is merged.

## 0809: amd_pmf exposes APU, dGPU and socket power through hwmon (#238)

**What.** `0809-platform-x86-amd-pmf-hwmon-apu-dgpu-socket-power.patch` adds
`drivers/platform/x86/amd/pmf/hwmon.c`: a read-only hwmon device `amd_pmf`
with `power1_input` (APU), `power2_input` (dGPU) and `power3_input` (socket),
each with a label, in microwatts. The values are PMFW's metrics table fields
`apu_power`, `dgpu_power` and `socket_power` (on Rembrandt and Phoenix, whose
v1 table names it `current_socketpower`; socket is never APU + dGPU, which
would count the dGPU's draw as the SoC's). Registered only on the SoCs whose
table layout the driver knows (Rembrandt, Phoenix, family 1Ah models 20h and
60h; the G16's Krackan Point is 1Ah 60h).

**Why.** NVML and nvidia-smi resume the RTX from D3cold to answer (#216,
#171), so nothing could read the dGPU's power without spending it. PMFW
computes it from platform telemetry, which never touches the dGPU's PCI
device. The driver already reads the table, but only for Auto Mode, CnQF and
Smart PC, none of which runs on the G16 (static slider only, "No Smart PC
policy present").

**Default behaviour.** Nothing is sent to PMFW until someone reads a value.
A read asks PMFW for a fresh table at most once a second, into hwmon's own
buffer (allocated before the hwmon device is registered, so it outlives every
read), under the driver's metrics and update locks. The table address is set
before every transfer, and a failure to set it, or of the transfer, is returned
to the reader. The device is not registered when Smart PC, Auto Mode or CnQF
poll the table (they set its address once and rely on it); on the G16 none of
them runs. A failed registration only logs a warning. `amd_pmf.hwmon_support=0`
turns it off. Risk: low (read-only, at most three PMFW mailbox commands per second, only
while something reads it).

**Open.** Whether the GA605KM's PMFW fills `dgpu_power` at all is what the G16
test answers (#238): power2 should read about 0 with the RTX in D3cold, track
NVML's `power.draw` with it awake, and reading it must never change the RTX's
`runtime_status`.

**Check.** `tests/channel/linux-omarchy-amd-pmf-hwmon.sh` checks the recipe wiring
and, on the build host, applies 0800-0802 and 0809 to `amd/pmf` and compiles
the module with `W=1` against the installed linux-omarchy headers.

**Upstream.** Not submitted (target: platform-driver-x86). Draft it with
`bin/issue template upstream-report` once the G16 shows the data is useful.

## 0807: asus-armoury power limits for GA605KM

**What.** `0807-platform-x86-asus-armoury-ga605km-power-limits.patch` adds a
`power_limits` DMI entry for `DMI_BOARD_NAME` "GA605KM" in
`drivers/platform/x86/asus-armoury.h`, just before the GA605W entry:

| Attribute | AC (min-max) | DC (min-max) |
|---|---|---|
| ppt_pl1_spl | 15-80 W | 25-35 W |
| ppt_pl2_sppt | 35-80 W | 31-44 W |
| ppt_pl3_fppt | 35-80 W | 45-65 W |
| nv_dynamic_boost | 5-15 W | (none) |
| nv_temp_target | 75-87 C | 75-87 C |

`requires_fan_curve = true`. The values come from the model's ThrottleGear
configuration ('Ryzen' profile) and match the GA605W entry except for the
Dynamic Boost maximum (15 W here, 20 W on GA605W).

**Why.** Without an entry the stock kernel logs `No matching power limits
found for this system`, and the ppt_*, nv_dynamic_boost and nv_temp_target
attributes under `/sys/class/firmware-attributes/asus-armoury/` exist but
return `-ENODEV`. Tools that use the firmware-attributes interface (asusd,
ROG Control Center, scripts) cannot set CPU power limits on the G16.

**Why requires_fan_curve.** On BIOS 307 the EC applies SPL/SPPT/FPPT only
while the CPU custom fan curve is enabled (`pwm1_enable=1` on the
`asus_custom_fan_curve` hwmon). Measured under a 16-thread load on AC: a 25 W
write was ignored in auto fan mode (about 48 W socket power), and with the
curve on, the socket power tracked the limit exactly (25.0 W, then 40.0 W).
With the flag, asus-armoury returns `-EBUSY` for PPT writes until a custom
fan curve is active, instead of accepting a write the firmware ignores.

**Why no nv_tgp.** On this firmware WMI 0x00120098 is an offset above the
55 W base TGP (the firmware itself writes 0/10/35 W), but every upstream
entry uses absolute watts (for example GA605W 55-85). Which convention
upstream will keep is still open, so nv_tgp is left out instead of shipping a
range that may be wrong. Leaving out `nv_tgp_max` also hides `nv_tgp` and
`nv_base_tgp`.

**Default behavior.** Unchanged. asus-armoury writes nothing at probe or
resume; the entry only gives the attributes their ranges. Nothing in this repo
writes these attributes. Risk: low (DMI-scoped table entry, values inside the
firmware's own ranges, PPT gated by the fan curve). Known gap: asus-wmi's
"custom fan curve enabled" check also accepts a GPU-only curve, and on this
BIOS only the CPU curve opens the PPT gate; in that case a write succeeds but
is ignored, which is the same as today's legacy path.

**Test on the laptop** (after booting `7.2.8-9.3-omarchy`, on AC):

```sh
journalctl -k -b | grep -i armoury          # no "No matching power limits found"
A=/sys/class/firmware-attributes/asus-armoury/attributes
for a in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt nv_dynamic_boost nv_temp_target; do
  echo "$a $(cat $A/$a/min_value)-$(cat $A/$a/max_value) cur=$(cat $A/$a/current_value)"
done                                        # AC: 15-80, 35-80, 35-80, 5-15, 75-87
ls $A | grep nv_tgp                         # expect nothing
H=$(dirname "$(grep -l asus_custom_fan_curve /sys/class/hwmon/hwmon*/name)")
cat $H/pwm1_enable                          # 2 = auto
echo 25 | sudo tee $A/ppt_pl1_spl/current_value   # expect "Device or resource busy"
echo 90 | sudo tee $A/ppt_pl1_spl/current_value   # expect "Invalid argument"
# Does the sustained limit (SPL) bite? Start a CPU load and watch package power:
openssl speed -multi 16 -seconds 120 rsa2048 >/dev/null 2>&1 &
R=/sys/class/powercap/intel-rapl:0/energy_uj   # AMD package RAPL (root to read)
watch_pkg() { for i in $(seq 10); do e0=$(sudo cat $R); sleep 2; e1=$(sudo cat $R); echo "pkg $(( (e1 - e0) / 2000000 )) W"; done; }
watch_pkg                                   # baseline, about 48 W in performance
echo 1 | sudo tee $H/pwm1_enable            # CPU custom fan curve on
# Sustained limit (SPL) 25 W; SPPT/FPPT cannot go below 35 W on AC, so set them
# to that minimum. Short boosts may reach 35 W; the steady state should be SPL.
echo 25 | sudo tee $A/ppt_pl1_spl/current_value
for a in ppt_pl2_sppt ppt_pl3_fppt; do echo 35 | sudo tee $A/$a/current_value; done
watch_pkg                                   # expect ~25 W after the first seconds
for a in ppt_pl1_spl ppt_pl2_sppt ppt_pl3_fppt; do echo 40 | sudo tee $A/$a/current_value; done
watch_pkg                                   # expect ~40 W
echo 2 | sudo tee $H/pwm1_enable            # back to auto: the profile's own limit returns
```

On battery, repeat the range check: DC shows 25-35, 31-44 and 45-65. Whether
the DC limits bite on battery has not been measured yet.

**Remove when** an equivalent GA605KM entry is merged upstream (pdx86
for-next, then mainline) and reaches linux-omarchy. Revisit nv_tgp when
upstream settles the offset-or-absolute question.

## 0808: asus-wmi restores the thermal policy after hibernation (#185)

**What.** `asus_hotk_restore()` (the `.restore` callback, run only on resume
from hibernation) now calls `asus_wmi_restore_thermal_state()`: it writes
`throttle_thermal_policy_mode` back with `throttle_thermal_policy_write()`,
then re-enables and re-sends each custom fan curve that was enabled before
(a policy write clears their enabled flags). `.thaw` (hibernation aborted, no
power cycle) and `.resume` (s2idle) are unchanged.

**Why.** Hibernation here is `HibernateMode=shutdown`: the machine powers off
and the firmware boots again, so the EC starts from its own table. The restored
kernel still holds the mode from before (quiet, from omarchy's patch 0004 on
battery) but never sends it again, and userspace skips writing a value that
already reads quiet. The G16 then runs the balanced table (fans at about
2100/1800/3800 rpm on a 28 C idle, about 0.8 W) while every layer above the EC
reports quiet. The DSDT's 0x00120075 handler writes the fan-table byte FTBL
(EC RAM 0x06: 0 balanced, 1 turbo, 2 silent) on every call and `_WAK` never
touches it; reading 0x00120075 back always returns 0x00010003, so the kernel
cannot ask which table is active, only re-send it. Writing `quiet` over `quiet`
did bring the quiet table back on the G16 (#185, 2026-10-22).

Why only some resumes lose it (two clean hibernates kept quiet; a day of
suspend-then-hibernate did not) is still open. The patch doesn't depend on the
answer: after every hibernation resume the EC gets the kernel's state.

**Cost.** Each write runs the firmware's `_QD4`, which pokes the NVIDIA driver:
the RTX wakes for about 20 s once per hibernation resume.

**Default behavior.** Changes resume from hibernation on every asus-wmi laptop
with a throttle thermal policy: the policy the kernel already reports is sent
again. Nothing changes at boot, on s2idle, or for machines without the policy.

**Test on the laptop** (kit, see below): on battery with the quiet fan table,
`test --ec-table` shows the asus-wmi profile next to FTBL (read only, through
ec_sys's read-only debugfs file); `test --resume-profile --hibernates 6` must
keep the quiet table (FTBL silent, fans 0 on a cool idle, about 31-34 W under
load) after every hibernate.

**Upstream.** Not in mainline (`torvalds/linux` master, 7.3) as of 2026-10-22:
`asus_hotk_restore()` there has no thermal-policy write either. Not submitted
yet (target: platform-driver-x86).

## G16 test kit (g16-test/)

`g16-test/` holds the hardware test for this kernel. It travels with the kernel
PR and is not part of the package (it is not in `source=()`); `DELTA` keeps it
across rebases. 7.2.8-9.3 passed it on 2026-10-20 (PR #8). It reads the
expected version from the PKGBUILD, so it serves the next kernel's boot test
as is.

The kit installs the kernel next to whatever Omarchy channel the G16 is on, so test a build
from the matching channel: a Quattro build (`main`, `bin/build-pkg`) on Omarchy stable with
`[omarchy-asus]` on `x86_64`, an RC build (`next/omarchy-4.5`, `bin/build-pkg --channel rc`,
staged in the rc stage dir) on Omarchy rc with `[omarchy-asus]` on `rc-x86_64`. Switch both with
`omarchy-asus-setup --channel rc|quattro` first (README.md, "Release channels").

On the G16, from a clone of this repo:

```sh
gh pr checkout 8 && recipes/linux-omarchy/g16-test/deploy   # then reboot
recipes/linux-omarchy/g16-test/test                         # after the reboot
recipes/linux-omarchy/g16-test/test --temps                 # #42, on battery
recipes/linux-omarchy/g16-test/test --ec-table              # #185, read only
recipes/linux-omarchy/g16-test/test --resume-profile --hibernates 6   # #185, on battery
```

- `deploy` checks the machine (GA605 DMI) and the fallback kernel (Arch `linux`
  + `linux-headers` with nvidia DKMS built), fetches the packages (the newest
  CI artifact for the PR head, or `--from <dir|URL|host:path>` with a chroot
  build's stage dir; `.sig` files are verified), records a baseline of the
  running kernel, takes a snapper snapshot, installs with `pacman -U`, checks
  `dkms status` and reads (never writes) the Limine config: an entry boots the
  new kernel and the fallback entry is still there. `--dry-run` changes nothing.
- `test` runs every check from the sections above (kernel log against the
  baseline, Win-lock key press, touchpad IRQs per report, asus-armoury ranges
  and the fan-curve gate, `panel_power_savings`, one s2idle cycle that must
  reach at least 10 s of s0i3 (a suspend that wakes at once fails, #133),
  9900 knobs at their defaults, nvidia and runtime PM; hibernate with
  `--hibernate`), writes a report without host or user names to
  `~/omarchy-asus-g16-test-<kernel>-<date>.md` and offers to post it on the PR.
  `--temps [MIN]` is the #42 measurement (quiet fan table on battery,
  sustained load, `--ab` adds the balanced table); its report goes to #42.
- Editing the kit changes the recipe tree, so CI builds the kernel again
  (about 2.5-3 hours). Push kit changes together with recipe changes.

## Verification

`prepare()` applies every `*.patch` with `patch -Np1 --fuzz=0`, so a
successful `makepkg --nobuild` proves all patches apply cleanly. On 7.2.8 all
178 patches (including 0481, 0568, 0569, 0807 and 9900) apply at fuzz 0 with no
offsets (checked for 9.3 on 2026-10-18, after the rebase onto the DELTA layout). The two files touched by 0569 and
0807 were also compiled with `W=1` in the patched tree (no warnings).

## Rebasing on a new upstream version

`bin/auto-update` does this automatically from `DELTA`. By hand, run
`bin/rebase-recipe linux-omarchy --version <omarchy ver> --out <dir> --verify`. It
reproduces steps 1-5 below, taking the checksums of upstream's files from upstream's
PKGBUILD and hashing only our own patches. The manual steps:

1. Copy upstream's `pkgbuilds/linux-omarchy/` over this directory (keep this
   NOTES.md, the g16-test kit and our patches: 0481, 0482, 0568, 0569, 0773, 0807, 0810, 9900).
2. Add them back to `source=()`: 0481 after `0480`, 0482 after `0481`, 0568 and 0569 after the last `056x` patch,
   0807, 0808, 0809 and 0810 after the last `080x` patch (renumber if upstream took the numbers),
   9900 last.
3. Set `pkgrel=<upstream pkgrel>.1` and bump `.N` for later local changes.
4. Regenerate the sums for our patches (`b2sum` / `sha256sum` on each patch)
   and insert them at the matching positions in both arrays (or run
   `updpkgsums` and check that only our lines differ from upstream).
5. In a scratch copy, run `makepkg --nobuild --nodeps --skippgpcheck` and check
   that `prepare()` finishes (fuzz 0 is enforced). If one of our patches no
   longer applies, check whether upstream or mainline has picked up an
   equivalent change and drop or refresh the patch.
6. Once a fix like this lands upstream, drop this recipe and use the stock
   package.

Note: when upstream ships a higher pkgrel (e.g. 7.2.8-10), the stock package
outranks ours, so rebase promptly.

## Build notes

- Sources: kernel tarball and `.tar.sign` from cdn.kernel.org (fetched by
  makepkg before the build, not inside `build()`); the rest are local files.
  Nothing in `build()` needs network.
- All makedepends are in Arch core/extra (rust, rust-bindgen, rust-src,
  pahole, ...).
- PGP: the kernel tarball and patch signatures are checked against
  `validpgpkeys`; the public keys are in `keys/pgp/`. Import them into the
  build user's keyring or build with `--skippgpcheck` (checksums still apply).
- Config has DWARF5 debug info and BTF, no LTO: expect a build tree of about
  20-30 GB and roughly 30-60 minutes on 16 cores.

## EXPERIMENTAL: 9900 Zen 5c-first soft park (default off)

`9900-EXPERIMENTAL-zen5c-first-soft-park-default-off.patch` is a local carry
for battery testing on the ROG Zephyrus G16 GA605KM (Ryzen AI 300, Zen 5 +
Zen 5c). It is **experimental**, **compile-tested only**, and **not intended
for upstream**.

- Five changes combined into one patch: amd_hfi ITMT ranking knob, soft wakeup
  CPU preference, AMD workload-class tracking/steering, optional SMT packing,
  and NOHZ idle-load-balancer preference. Details are in the patch header.
- Every knob defaults OFF (static keys and sysfs). This package enables
  nothing: no kernel cmdline, udev rule or sysctl. With defaults the
  scheduler takes the stock code paths.
- Applied last, after all upstream patches and 0568, at fuzz 0 (regenerated
  against 7.2.8-9 without offsets).
- Remove it if the battery A/B testing shows no win, or move it to a
  separate `-experimental` kernel package.

## 0810: panel_power_savings applies when written (#172)

`0810-drm-amd-display-panel-power-savings-apply-now.patch` (ours, not upstream).
`panel_power_savings_store()` only updates the connector state and sends a
hotplug uevent; the level reaches the stream at the next commit that includes the
connector. aquamarine 0.15 (Hyprland) leaves the connector out of page flips and
only rescans connectors on a hotplug, so on the G16 a write (by hand or by
power-profiles-daemon's `amdgpu_panel_power` action) took effect only at the next
modeset: a DPMS cycle, a refresh-rate change or a resume. The first CACP
measurement in #172 wrote the levels that way, so it most likely measured
level 0 throughout.

The patch commits the connector and its CRTC unchanged right after the write (not
while the CRTC is off or during suspend). The connector state is the one just
written, so there is no modeset; the CRTC takes the new level and DC gets it as a
fast stream update. Mainline (7.4-rc1) has the same store function, so the patch
stays until upstream changes it.

Test: the g16-test kit's `0810` check puts a kprobe on `dmub_cacp_set_level`,
writes 1, and expects the probe to fire within 3 s (then writes 0 back). A check
that cannot run is a FAIL: the merge gate is this check passing.

## 0481: display power backports (dev build, default off)

`0481-drm-amd-display-power-backports.patch` combines three amdgpu display
backports for the GA605's OLED eDP. It sits right after `0480` and applies at
fuzz 0 with every later patch, including 9900.

1. Disable self-refresh on tearing flips (upstream 2e54a92e0136). This is also
   in 7.2.11 stable, so drop it once the base is 7.2.11 or later.
2. Tear down a dangling pipe on boot to fix s0i3 (mainline 98e08a815ef6).
3. CACP for OLED eDP, hand-ported from 7b0cc3085216. It adds
   `/sys/class/drm/card*-eDP-1/amdgpu/panel_power_savings` (0-4), which boots
   at 0 (off). Nothing in this repo changes that level: no kernel command line,
   no udev rule, and none of our Omarchy patches. power-profiles-daemon lists an
   `amdgpu_panel_power` action, but on the G16 it left the level at 0 on battery
   and in power-saver (#46). Level testing is done by hand on the laptop.

Status: booted on the G16 (7.2.8-9.3, PR #8 test, 2026-10-20). Not for
upstream submission. A staging-only fix (ISM flush before releasing the stream) was offered as an
optional fourth patch and is not carried.

Test (on the G16, after booting this kernel):
```bash
cat /sys/class/drm/card*-eDP-1/amdgpu/panel_power_savings   # expect 0
# s0i3: suspend, resume, then check the residency counter grew
sudo cat /sys/kernel/debug/amd_pmc/s0ix_stats
```

## 0482: amdgpu replays DMUB HPDs skipped during resume (#205)

**What.** `0482-drm-amd-display-replay-dmub-hpd-skipped-in-suspend.patch`, after
0481 (no later patch touches `amdgpu_dm.c`/`.h`). `dmub_hpd_callback()` still
skips a DMUB HPD that arrives while `adev->in_suspend` is set, but now records
its link in `dm->hpd_skipped_in_suspend`. A new DM `.complete` callback (it runs
after `amdgpu_device_resume()` has cleared `in_suspend`) queues
`dm->hpd_replay_work` on the HPD offload workqueue, which runs
`handle_hpd_irq_helper()` for each recorded link: the same path the HPD takes
outside suspend. It is queued on every resume, recorded links or not: an HPD
work item that saw `in_suspend` set may not have recorded its link yet, and
the workqueue is ordered, so the replay runs after it. `dm_suspend()` cancels a replay still pending; its links are
kept for the next resume. A replay logs `Replay DMUB HPD skipped in
suspend/resume: link_index=N`.

**Why.** With the G16 docked on a USB4 dock (two DP monitors), unplugging the
dock with the lid closed suspends it. Replugging the dock during suspend and
resuming left both monitors dark until the next suspend. `dm_resume()` probes
the connectors early in resume, when the thunderbolt driver has not set up the
dock's DP tunnels yet. The DPIA HPDs for the new tunnels arrive later, while
`in_suspend` is still set, and were dropped (`Skip DMUB HPD IRQ callback in
suspend/resume`). Nothing read the DPRX caps, so 12 s later the connection
manager tore the tunnels down (`(DP): not active, tearing down`) and dropped
the DP IN adapters until their next hotplug, which only a suspend brings.
Mainline and amd-staging-drm-next (2026-10-20) still drop these HPDs; there is
no fix to backport.

**Not covered.** #205's second failure (a DPIA link trained at RBR after a
resume although HBR3 is verified) has no root cause yet; `test --dock` records
every DP link's `link_settings` so the next occurrence has the data. The
thunderbolt side (a DP IN dropped after a DPRX timeout is not offered again
when a new DP OUT appears) is unchanged: with 0482 that timeout should no
longer happen after resume.

**Default behaviour and risk.** It changes behaviour only when an HPD was
skipped during suspend or resume: one extra detection per such link once
resume completes. On a link that did not change, detection finds the same
sink and sends no hotplug event. Runtime PM resume (dGPUs) does not run
`.complete`, so it behaves as before. Risk: low.

**Test** (on the G16, booted on this kernel, docked with the DP monitors on):
```bash
recipes/linux-omarchy/g16-test/test --dock   # the 0482 line walks through #205's steps
```
By hand: close the lid, unplug the dock, wait for the suspend, plug the dock
back in, open the lid. Then `journalctl -k -b | grep -E 'Skip DMUB HPD|Replay
DMUB HPD|not active, tearing down'` shows skips followed by replays and no
teardown, and both monitors are lit.

**Upstream.** Not submitted (target: amd-gfx). A draft report is on #205.
Drop it once upstream handles HPDs that arrive late in resume.
