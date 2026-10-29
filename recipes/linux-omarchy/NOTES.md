# linux-omarchy (omarchy-asus build)

## Base

- Upstream recipe: `pkgbuilds/linux-omarchy` in omacom/omarchy-pkgs.
- Tracks linux-omarchy **7.2.8-9**, recipe last changed upstream in commit
  `cc664d884b8400accad0e02347c39d6b2cd6b688`
  ("Build linux-omarchy as the BORE kernel instead of a meta package").
- Our version: **7.2.8-9.112**. Builds both split packages from one pkgbase:
  `linux-omarchy` and `linux-omarchy-headers` (headers are required by DKMS
  modules such as nvidia-open-dkms).

## What we change

Compared with upstream, only:

1. `pkgrel=9` -> `pkgrel=9.112` (kernel release string becomes `7.2.8-9.112-omarchy`).
   History: 9.1 added 0568 and 9900; 9.2 added 0569 and 0807; 9.3 added 0481;
   9.4 added 0773; 9.5 added 0482; 9.101 is 9.5 moved into the RC channel's
   range (.101 and up, so no file shares a name with Quattro's; #201); 9.102 added 0810; 9.103 added 0808;
   9.106 added 9901 (9.104 and 9.105 are the test builds of the PR #288 stack); 9.107 added 9902 and 9903; 9.108 added 9904; 9.109 added 9905; 9.110 added 9906, 9907 and 9908; 9.111 added 9909 and 9910; 9.112 dropped 9900 (#10).
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
9. New patch `0810-drm-amd-display-panel-power-savings-apply-now.patch` after
   `0808-...` (a `panel_power_savings` write takes effect at once; see "0810" below).
10. `9901-EXPERIMENTAL-...` after all upstream patches, first of the 99xx series (see "EXPERIMENTAL: 9901" below).
11. `9902-EXPERIMENTAL-...` and `9903-EXPERIMENTAL-...` after 9901 (see "EXPERIMENTAL: 9902" and
    "EXPERIMENTAL: 9903" below).
12. `9904-EXPERIMENTAL-...` after 9903 (see "EXPERIMENTAL: 9904" below).
13. `9905-EXPERIMENTAL-...` after 9904 (see "EXPERIMENTAL: 9905" below).
14. `9906-EXPERIMENTAL-...` after 9905 (see "EXPERIMENTAL: 9906" below).
15. `9907-EXPERIMENTAL-...` after 9906 (see "EXPERIMENTAL: 9907" below).
16. `9908-EXPERIMENTAL-...` after 9907 (see "EXPERIMENTAL: 9908" below).
17. `9909-EXPERIMENTAL-...` after 9908 (see "EXPERIMENTAL: 9909" below).
18. `9910-EXPERIMENTAL-...` after 9909 (see "EXPERIMENTAL: 9910" below).

Our patches have no `.sig` (upstream's patch signatures are made by the
Omarchy kernel maintainer's key); their checksums pin them instead.
Everything else (config, other patches, keys) is byte-identical to upstream.

## Upstream status of 0568

Not in mainline (`torvalds/linux` master) or the HID tree (`hid.git` for-next)
as of 2026-10-17: neither contains `QUIRK_HID_WIN_LOCK` or the 0xbf handling.
It was submitted to linux-input on 2026-09-10 (patchwork 14804337) and has had
no replies yet. Since mainline dropped the `Assisted-by` trailer from the kernel
docs (`1e035297ffda`), v1 fails checkpatch; a v2 without it goes to linux-input
after v7.4-rc1 (checked 2026-10-26).

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
  nvidia and runtime PM; hibernate with
  `--hibernate`), writes a report without host or user names to
  `~/omarchy-asus-g16-test-<kernel>-<date>.md` and offers to post it on the PR.
  `--temps [MIN]` is the #42 measurement (quiet fan table on battery,
  sustained load, `--ab` adds the balanced table); its report goes to #42.
- Editing the kit changes the recipe tree, so CI builds the kernel again
  (about 2.5-3 hours). Push kit changes together with recipe changes.

## Verification

`prepare()` applies every `*.patch` with `patch -Np1 --fuzz=0`, so a
successful `makepkg --nobuild` proves all patches apply cleanly. On 7.2.8 all
178 patches (including 0481, 0568, 0569, 0807 and 9900, since dropped) apply at fuzz 0 with no
offsets (checked for 9.3 on 2026-10-18, after the rebase onto the DELTA layout). The two files touched by 0569 and
0807 were also compiled with `W=1` in the patched tree (no warnings).

## Rebasing on a new upstream version

`bin/auto-update` does this automatically from `DELTA`. By hand, run
`bin/rebase-recipe linux-omarchy --version <omarchy ver> --out <dir> --verify`. It
reproduces steps 1-5 below, taking the checksums of upstream's files from upstream's
PKGBUILD and hashing only our own patches. The manual steps:

1. Copy upstream's `pkgbuilds/linux-omarchy/` over this directory (keep this
   NOTES.md, the g16-test kit and our patches: 0481, 0482, 0568, 0569, 0773, 0807, 0810, 9901, 9902, 9903, 9904, 9905, 9906, 9907, 9908, 9909, 9910).
2. Add them back to `source=()`: 0481 after `0480`, 0482 after `0481`, 0568 and 0569 after the last `056x` patch,
   0807 and 0810 after the last `080x` patch (renumber if upstream took the numbers),
   9901, then 9902, 9903, 9904, 9905, 9906, 9907, 9908, 9909 and 9910, last.
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

## EXPERIMENTAL: 9901 DCN 3.5 S0i2-ready display idle (default off, #353)

`9901-EXPERIMENTAL-drm-amd-display-dcn35-s0i2-rdy-default-off.patch` (ours,
compile-tested only, applied after all upstream patches). It only touches
`drivers/gpu/drm/amd/display/dc/clk_mgr/dcn35/dcn35_clk_mgr.c`.

**What.** A new parameter `amdgpu.dcn35_s0i2` (bool, 0644, default 0). When it
is 1, `dcn35_update_clocks()` (`safe_to_lower`) and `dcn35_set_low_power_state()`
send `SetDisplayIdleOptimizations` with `df_request_disabled`,
`phy_ref_clk_off` and `s0i2_rdy` set when the active display count drops to 0,
before setting `DCN_PWR_STATE_LOW_POWER`. That is what DCN 3.1/3.14/3.15/3.16
do in the same places, and DCN 4.2 does it in its `set_low_power_state`. The
existing path back to mission mode sends 0, so leaving low power clears them.

**Why.** Stock DCN 3.5 sets `DCN_PWR_STATE_LOW_POWER` without sending anything,
and `dcn35_smu_enable_phy_refclk_pwrdwn()` has no caller, so the SMU never
hears that the display is idle. On the G16 the `amd_pmc` idlemask bits 5
(display idle) and 20 (IPS2, which needs bit 5) stay not idle even with the
screen off (#249). Mainline master is unchanged (checked 2026-10-25).

**Default behaviour.** None: with the parameter at 0 the driver takes the stock
path. The parameter is read on every transition, so a write takes effect the
next time the displays go off (turn the screen on and off again after
changing it). Nothing in this repo sets it.

**Test** (on the G16, booted on this kernel, on battery):
`g16-test/dcn35-s0i2-ab` runs the one-boot A/B: each phase writes the parameter, turns the
screen off for 30 s, samples the idlemask at 10 Hz and the socket and battery
power, then turns the screen back on and checks the journal for amdgpu or DMUB
errors. Pass: with 1, bit 5 (ideally bit 20 too) reads idle with the screen off
and socket power drops; the panel comes back; the journal is clean.

**Upstream.** Not submitted (target: amd-gfx), drafted after the G16 numbers.
**Remove** if the A/B shows no effect or a wake problem, or once upstream sends
the flags itself.

## EXPERIMENTAL: 9902 display idle with every CRTC off (default off, #353)

`9902-EXPERIMENTAL-drm-amd-display-idle-with-all-crtcs-off-default-off.patch`
(ours, compile-tested only, applied after 9901). It touches `amdgpu_dm.c`,
`amdgpu_dm.h`, `amdgpu_dm_crtc.c` and `amdgpu_dm_helpers.c`.

**What.** A new parameter `amdgpu.dm_idle_all_off` (bool, 0644, default 0) and
a helper `amdgpu_dm_idle_headless()`: true when `amdgpu_dm_is_headless()` is,
or, with the parameter at 1, when DC's current state has no stream. The three
places where the headless check gates allowing idle use it: the end of
`amdgpu_dm_commit_streams()`, the idle worker and
`dm_helpers_enable_periodic_detection()`. The paths that disallow idle are
unchanged, so a modeset (DPMS on) still leaves idle first.

**Why.** With the screen off (DPMS off) the G16's `amdgpu_dm_ips_status` reads
"Idle optimization: 0" and the IPS counters stop (#249, #353). The commit that
turns the CRTC off disallows idle, and the only re-allow after a modeset needs
`amdgpu_dm_is_headless()`, which is false while any connector is connected:
the internal panel always is. The ISM only re-allows on the vblank events of a
live CRTC.

**Default behaviour.** None: with the parameter at 0 the helper returns what
`amdgpu_dm_is_headless()` returns. The parameter is read on every check, so a
write takes effect at the next commit: turn the screen on and off again after
changing it. Nothing in this repo sets it.

**Known limit.** DC lowers the clocks (and asks for periodic detection) before
it swaps in the new state, so with the internal panel connected the periodic
detection worker usually doesn't start. A display plugged into an AMD-driven
port while every CRTC is off may then not be noticed until the screen comes
back on. Only the A/B turns the parameter on.

**Test.** `g16-test/dm-idle-all-off` (with 9901 and 9903; see below). Pass: with
both parameters at 1 and the screen off, idlemask bits 5 and 20 read idle; if
bit 16 does too and socket power drops, the screen-off blocker is found.

**Upstream.** Not submitted; an amd-gfx report is drafted after the G16
numbers. **Remove** if the A/B shows no effect, or once upstream re-allows
idle with every CRTC off itself.

## EXPERIMENTAL: 9903 SMU idlemask trace through s2idle (debug only, #353)

`9903-EXPERIMENTAL-amd-pmc-idlemask-trace-through-s2idle.patch` (ours,
compile-tested only, after 9902). It touches `drivers/platform/x86/amd/pmc/pmc.c`,
`drivers/gpu/drm/amd/amdgpu/amdgpu_device.c` and adds
`include/linux/platform_data/x86/amd-pmc.h`.

**What.** While `/sys/power/pm_debug_messages` is 1, each s2idle logs
`amd_pmc: SMU idlemask <stage>: 0x...` at these stages, in order:
`amdgpu-display` (after amdgpu's display IP suspend), `amdgpu-ip` (after the
rest of amdgpu's IP suspend), `prepare` (amd_pmc's s2idle prepare, before the
OS hint), `os-hint` (right after it) and the existing `s0i3` (amd_pmc's check).
amd_pmc exports `amd_pmc_trace_idlemask()`; amdgpu finds it with
`symbol_get()`, so it doesn't need amd_pmc loaded, and calls it only in s0ix.
Cezanne is skipped (its read needs an SMU version check). `amd_pmc_remove()`
clears `regbase` so a later trace can't read through a stale mapping.

**Why.** The G16's idlemask reads 0xffff9efd at the s0i3 check (bits 5, 16 and
20 idle), but with the screen off bit 16 never reads idle. The stages show
which step of the suspend sequence sets it.

**Default behaviour.** None: with `pm_debug_messages` at 0 nothing is read or
logged.

**Upstream.** Debug aid, not meant for upstream. **Remove** with 9902, or once
the first stage where bit 16 turns idle is known.

**Test** (9902 and 9903 together, on the G16 booted on this kernel, on
battery): `g16-test/dm-idle-all-off` needs one root prompt and takes about
5 minutes, hands off. Phases: (a) a baseline with the screen on; (b) both
`dcn35_s0i2` and `dm_idle_all_off` at 1 and the screen off for 30 s; (c) the
screen back on, then both at 0 and the screen off for 30 s (the control);
(d) `pm_debug_messages` at 1 and one 15 s s2idle, and the `SMU idlemask`
stage lines. It samples the idlemask at 10 Hz, `amdgpu_dm_ips_status`, socket
power and battery watts, restores everything on exit (Ctrl-C included), and a
watchdog turns the screen back on and the parameters off if it dies.

## EXPERIMENTAL: 9904 idlemask trace between amdgpu's suspend and amd_pmc's prepare (debug only, #353)

`9904-EXPERIMENTAL-idlemask-trace-between-amdgpu-suspend-and-lps0.patch` (ours,
compile-tested only, after 9903). It touches `kernel/power/suspend.c`,
`drivers/acpi/x86/s2idle.c`, `drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c` and 9903's
`include/linux/platform_data/x86/amd-pmc.h`.

**What.** More stages for 9903's trace, same line format (`SMU idlemask <stage>: 0x...`),
in the order an s2idle runs them: `suspend-late` (after every device's suspend_late),
`s2idle-prepare` (after the s2idle platform prepare), `amdgpu-noirq` (end of amdgpu's
suspend_noirq, s0ix only), `noirq` (after every device's suspend_noirq), then in
`acpi_s2idle_prepare_late` one after each LPS0 `_DSM` call: `dsm-screen-off-amd` and
`dsm-entry-amd` (AMD GUID), `dsm-screen-off` (Microsoft GUID func 3), `dsm-ms-entry`
(func 7) and `dsm-entry` (func 5). A `_DSM` that did not run (its mask is below 1 or lacks
the function) logs `SMU idlemask <stage>: not run (func N, mask M)`. The `_DSM` stages
are AMD machines only, and the `_DSM` calls themselves are unchanged. A header helper,
`amd_pmc_trace_idlemask_stage()`, looks up amd_pmc's trace with `symbol_get()`, so the
built-in callers don't depend on amd_pmc.

**Why.** On 9.107 the display bits (5, 16, 17-19, 20, 25) read idle at amd_pmc's
`prepare` but not at `amdgpu-ip`. This shows whether a device's late or noirq suspend
idles them, or the firmware's screen-off `_DSM`.

**Default behaviour.** None: with `pm_debug_messages` at 0 nothing is read or logged.

**Upstream.** Debug aid, not meant for upstream. **Remove** with 9903, or once the stage
that idles bit 16 is known.

**Test** (on the G16 booted on this kernel, any power): `g16-test/idlemask-trace` needs
one root prompt and takes about a minute. It sets `pm_debug_messages` to 1, suspends once
for 15 s (`rtcwake -m freeze`), puts it back, and reports one row per stage, which `_DSM`
calls ran, and the first stage where each of bits 5, 16, 17, 18, 19, 20 and 25 reads idle.

## EXPERIMENTAL: 9905 idlemask trace after each PCI device's noirq suspend (debug only, #353)

`9905-EXPERIMENTAL-idlemask-trace-after-each-pci-device-noirq-suspend.patch` (ours,
compile-tested only, after 9904). It touches `drivers/base/power/main.c` only.

**What.** In the noirq phase of an s2idle, 9903's trace once as the phase starts
(`SMU idlemask noirq-start: 0x...`) and after each PCI device's noirq suspend, with the
device and the power state the suspend left it in:
`SMU idlemask noirq 0000:65:00.0 D3hot: 0x...` (`pci_power_name()`: D0, D3hot, D3cold, ...).
The call is in `device_suspend_noirq()`, so an asynchronously suspended device logs from its
async thread when it finishes, and the lines are in the order the devices finished. Devices
skipped by direct_complete or syscore, and non-PCI devices, don't log. It goes through
9904's `amd_pmc_trace_idlemask_stage()`, so the PM core does not depend on amd_pmc.

**Why.** On 9.108 bit 16 (the runtime deep-idle blocker) and bits 17-19 turned idle between
`s2idle-prepare` and `amdgpu-noirq`, and bits 5, 20 and 25 by `noirq`, while amdgpu's own
noirq callback does nothing in s2idle on the G16. So it is another device's noirq suspend,
where the PCI core puts it into D3. The candidates are the PCI devices that stay in D0 at
runtime (the SMBus controller, the NVMe, the SD reader, the Wi-Fi, the GPU's audio and
crypto functions, an unbound function, and the xHCI controller with the keyboard and
Bluetooth). This names the device after whose D3 each bit reads idle.

**Default behaviour.** None: with `pm_debug_messages` at 0 nothing is read or logged.

**Upstream.** Debug aid, not meant for upstream. **Remove** with 9903 and 9904, or once the
device that holds bit 16 is known.

**Test** (on the G16 booted on this kernel, any power): `g16-test/idlemask-trace` (the same
one root prompt and 15 s suspend) also prints the per-device noirq rows in order and names
the first device after whose noirq suspend each of bits 5, 16, 17, 18, 19, 20 and 25 reads
idle.

## EXPERIMENTAL: 9906 runtime PM for the PSP function (default off, #249)

`9906-EXPERIMENTAL-ccp-psp-runtime-pm-default-off.patch` (ours, compile-tested only, after
9905). It touches `drivers/crypto/ccp/` only: `sp-pci.c`, `psp-dev.c`/`.h`, `tee-dev.c`,
`platform-access.c` and `dbc.c`.

**What.** ccp has no runtime PM: it never gives back the reference the PCI core takes in
`local_pci_probe()`, so the PSP function (1022:17E0, 65:00.2 on the G16) stays in D0 even
with `power/control` at `auto` (so an earlier `control=auto` A/B on a stock kernel never put
it in D3). Two module parameters:

- `ccp.psp_rpm_delay_ms` (int, 0644, default 0 = off). When it is > 0, for a PSP-only PCI
  function without SEV (no CCP engines, no SEV vdata: pspv5 parts like the G16's), the
  driver gives up the probe reference and uses autosuspend with that delay
  (`pm_runtime_set_autosuspend_delay`, `pm_runtime_use_autosuspend`,
  `pm_runtime_put_autosuspend`). With `power/control=auto` as well, the function goes to
  D3hot once no command has touched its registers for that long. A write applies at once
  to the bound function (no reprobe): > 0 drops the reference or changes the delay, 0 takes
  it back and resumes the function.
- `ccp.psp_rpm_debug` (bool, 0644, default off) logs `psp rpm: runtime suspend #N` and
  `psp rpm: runtime resume #N for <caller> (<task>)` (or `not for a ccp command`, for
  `power/control`, system sleep and the PCI core), to see who wakes it.

Every path that touches the function's registers holds a runtime PM reference
(`psp_pm_get()`/`psp_pm_put()`): `psp_mailbox_command()` (TEE ring init/destroy, SFS, the
extended commands), `psp_tee_process_cmd()` (every amdtee and amd-pmf call, held until the
reply is copied), `psp_send_platform_access_msg()` and `psp_ring_platform_doorbell()`
(I2C arbitration, HSTI), the dbc ioctl, and the `bootloader_version`/`tee_version` sysfs
attributes and their `is_visible()`. The reference is taken on these devices whether or
not runtime PM is on, so switching never unbalances a command in flight; on every other
ccp/PSP device the helpers do nothing. The PSP interrupt handler is not wrapped: a function
in D3hot can't raise MSI-X, and the handler only serves SEV.

The runtime_suspend callback sends the PSP nothing (it has no such command). The PCI core
then saves config space and sets D3hot (`pci_pm_runtime_suspend()` ->
`pci_finish_runtime_suspend()`; the G16's PSP node has no `_PS3`/`_PR3`, so it is the
PMCSR write that s2idle's noirq phase does too, after which the TEE ring works without a
re-init). runtime_resume has nothing to restore. The system-sleep callbacks are unchanged:
without `DPM_FLAG_SMART_SUSPEND` the PCI core resumes a runtime-suspended function before
its suspend callback, and the noirq D3hot follows as before.

Not through this function: the fTPM (`tpm_crb`, CRB registers at 0xFED40000) and amdgpu's
PSP block (MP0 C2PMSG registers through amdgpu's own MMIO BAR) never resume it. Whether the
PSP firmware serves them while its function is in D3hot is checked on the G16 (Windows
idles this function in S0 with both in use).

**Why.** SMU idlemask bit 16, the runtime deep-idle blocker, turns idle in s2idle's noirq
phase, where the PCI core moves this function to D3hot (9905, #353). This tries that at
runtime.

**Default behaviour.** None: with `psp_rpm_delay_ms` at 0 the probe reference is kept, so
the function never runtime-suspends whatever `power/control` says; with `power/control` at
`on` (the PCI core's default) a delay alone changes nothing either.

**Upstream.** Not submitted: an experiment. If D3hot releases bit 16 and the TEE, TPM and
display keep working, the shape for upstream is a ccp runtime-PM patch for PSP-only parts.
**Remove** if the G16 shows no effect.

**Test** (on the G16 booted on this kernel, on battery): `g16-test/psp-rpm` (one root
prompt, about 4 minutes): a 15 s baseline, then `psp_rpm_delay_ms=2000` and
`power/control=auto`, a check that the function reaches `runtime_status=suspended`, 60 s
screen on, then 30 s cells with the screen off (DPMS, verified by Hyprland and the eDP
connector's kernel DPMS state): display idle parameters 0 (c), display idle re-allowed
(9901/9902/9908, d) and the same with the PSP back in D0 (e). It reads the idlemask (bits 5,
16, 20), "Idle optimization", socket power, battery watts and the PSP's suspend/resume counts
and wakers, with 9908's idle trace in the screen-off cells; then, the PSP suspended again, one
fTPM PCR read and one firmware-version read (which resumes it), and everything goes back.

## EXPERIMENTAL: 9907 the SMU metrics table at runtime (debug only, #249)

`9907-EXPERIMENTAL-amd-pmc-smu-metrics-at-runtime.patch` (ours, compile-tested only, after
9906, on top of 9903's `pmc.c`). It touches `drivers/platform/x86/amd/pmc/pmc.c` only.

**What.** `/sys/kernel/debug/amd_pmc/smu_metrics_runtime` (0600). A read sends
`SMU_MSG_LOG_DUMP_DATA` (0x08) now and prints every field of the SMU metrics table:
`table_version`, `hint_count`, `s0i3_last_entry_status`, `timein_s0i2`, the S0i3, resume and
SW DRIPS times, `active_ips`, and both per-IP arrays (`timecondition_notmet_lastcapture` and
`_totaltime`, all 32 entries, named where the CPU's IP list names them). If the SMU rejects
the message, the first line says `rejected, table not refreshed: <error>` and the table is
printed as it was; it never retries. Writing `start` resets and starts the SMU's logging
(`SMU_MSG_LOG_RESET` and `SMU_MSG_LOG_START`, what s2idle's prepare does), so the next read
covers the time since. Without an s2idle since boot, the table is mapped from the SMU's DRAM
address queries only, with no logging reset.

**Why.** `smu_fw_info` shows only what the SMU last wrote, and the SMU writes the table when
amd_pmc sends the dump message on s2idle resume, so at runtime it is stale and
`timein_s0i2` is never printed.

**Safety.** The message is the one `amd_pmc_s2idle_restore()` sends from a running system,
over the same mailbox under amd_pmc's lock; nothing else uses that port. Whether the SMU
accepts it outside a suspend is what the first read on the G16 shows.

**Default behaviour.** None: nothing is sent unless the file is read or written.

**Upstream.** Debug aid, not meant for upstream. **Remove** with 9903.

**Test:** `g16-test/psp-rpm` restarts the logging at each phase and reads the file at its
end (the report's `SMU timein_s0i2` column, or the SMU's refusal).

## EXPERIMENTAL: 9908 display idle kept allowed with every CRTC off, and an idle trace (default off, #353)

`9908-EXPERIMENTAL-drm-amd-display-keep-idle-allowed-with-every-crtc-off-default-off.patch`
(ours, compile-tested only, after 9907, on top of 9902). It touches `amdgpu_dm.c`, `amdgpu_dm.h`,
`amdgpu_dm_crtc.c`, `dc/core/dc.c` and `dc/dc.h`.

**Why.** On 9.109 with `dm_idle_all_off=1` and `dcn35_s0i2=1`, the panel verified off (Hyprland
and the connector's kernel DPMS state), `amdgpu_dm_ips_status`'s "Idle optimization" read 0 for
the whole 30 s. 9902 allows idle once, at the end of the all-off commit, and nothing keeps it
allowed: every DC register access (`dm_read_reg_func()`/`dm_write_reg_func()` ->
`dc_exit_ips_for_hw_access()`), every display IRQ state change and the HPD and backlight paths
disallow it again; with no live CRTC no vblank event drives the ISM, which never allows idle for
a CRTC without a stream; and the CRTC's vblank-off can land after the commit's check.

**What.** With `dm_idle_all_off` set, a delayed work re-checks right after a commit that leaves
no stream, when the vblank IRQ count drops to 0, and then once a second while no stream comes
back. With the vblank IRQ count at 0, no stream, idle disallowed and the stock headless idle
worker not running, it allows idle again. It stops when a stream comes back (the next modeset
disallows idle first, as before), when the parameter is cleared, or in suspend (`dm_suspend()`
cancels it before taking dc_lock; `amdgpu_dm_fini()` disables it). Two debug parameters:

- `amdgpu.dm_idle_all_off_debug` (bool, 0644, default off): logs each re-allow
  (`dm_idle_all_off: idle re-allowed #N`).
- `amdgpu.dm_idle_trace` (bool, 0644, default off): logs every change of DC's idle
  optimizations (an allow or disallow that differs from the current state) with the call site,
  a four-entry call chain, the vblank IRQ count, the active CRTCs and the stream count. Calls
  that change nothing are not logged. Chatty with a display on: for short screen-off runs.

**Caveat.** As with the stock headless idle worker (which this leaves alone): with the panel off
and idle allowed, an external display plugged in may not be detected until the next disallow (a
register access, DPMS on). The re-check wakes a CPU once a second while every CRTC is off.

**Default behaviour.** None: with the three parameters at 0 the work is never queued and the
trace is one `READ_ONCE()`.

**Upstream.** Not submitted, with 9902. **Remove** with 9902.

**Test:** `g16-test/psp-rpm`, cells d and e (display idle re-allowed, the PSP runtime-suspended
and in D0), with `dm_idle_trace` and `dm_idle_all_off_debug` on in the screen-off cells.

## EXPERIMENTAL: 9909 the GA605KM keyboard declares only its Caps Lock LED (#249)

`9909-EXPERIMENTAL-hid-asus-ga605km-keyboard-caps-lock-led-only.patch` (ours, compile-tested
with W=1, after 9908). It touches `drivers/hid/hid-asus.c` only.

**Why.** On the G16, idlemask bit 16 (the runtime deep-idle blocker) read idle only with the PSP
runtime-suspended *and* the keyboard/Bluetooth xHCI (67:00.0) runtime-suspended (#249). That
xHCI stays awake because the built-in N-Key keyboard (USB 0b05:19b6) never autosuspends. Two
things hold it: its `power/control` is `on` (the USB default; omarchy-asus-g16's udev rule sets
`auto`), and usbhid's `hid_suspend()` refuses autosuspend while any declared LED is lit
(`ledcount && !ignoreled`). The keyboard is tenkeyless with only a Caps Lock light, but its
report descriptor declares Num Lock, Caps Lock, Scroll Lock, Compose and Kana, and Omarchy turns
Num Lock on at login (`numlock_by_default = true` in its Hyprland input defaults), so
`input::numlock` reads 1 and the count is never 0.

**What.** A new quirk, `QUIRK_ROG_NKEY_CAPS_LED_ONLY`, on the 0b05:19b6 entry. In
`asus_report_fixup()`, when the board is `GA605KM` (DMI board name), the descriptor is the
745-byte one this keyboard reports and the 18 bytes at offset 167 are exactly its LED items, they
are rewritten in place: bit 0 becomes padding, Caps Lock stays at bit 1, bits 2-4 join the three
padding bits. The output report keeps its size and layout, so the Caps Lock report the keyboard
gets is byte-identical. The kernel logs `Fixing up GA605KM keyboard LEDs: Caps Lock only` once
per probe.

**Effect.** `/sys/class/leds/input*::numlock` and `::scrolllock` (and compose/kana) are gone
for this keyboard; `::capslock` stays and works. Num Lock is still a modifier in the input
layer and the compositor. A lit Caps Lock still blocks autosuspend, by design (the light is
real, and the state is rare and visible).

**Default behaviour.** Unchanged on every other machine and keyboard: 0b05:19b6 is shared by many
ROG laptops' N-Key keyboards (some with a number pad), hence the DMI and exact-bytes match.

**Alternatives not taken.** `usbhid.ignoreled=1` is global: every USB HID keyboard would
autosuspend with its LEDs lit. Turning Omarchy's `numlock_by_default` off is upstream's choice
and would change number-pad keyboards.

**Upstream.** Not submitted; a candidate for the HID tree once the G16 test passes. **Remove**
when upstream fixes it, or if the G16 test shows no gain.

**Test:** on the G16 with the udev rule in omarchy-asus-g16 (`power/control=auto`):
`dmesg | grep 'Caps Lock only'`; `ls /sys/class/leds | grep -E 'num|scroll'` lists nothing for
the keyboard's input; with Num Lock on and Caps Lock off,
`cat /sys/bus/usb/devices/3-4/power/runtime_status` reads `suspended` a few seconds after the
last key press, and 67:00.0 too when no Bluetooth device is connected. Before 9.111, a live
try stands in for 9909 with `usbhid.ignoreled=1` for a 30 s window only (not packaged).

## EXPERIMENTAL: 9910 debugfs to send the SMU AllowZstates message (nothing sent by default, #249)

`9910-EXPERIMENTAL-amd-pm-smu-allow-zstates-debugfs.patch` (ours, compile-tested with W=1, after
9909). It touches `pm/amdgpu_dpm.c`, `pm/swsmu/amdgpu_smu.c`, `pm/swsmu/inc/amdgpu_smu.h` and
`pm/swsmu/smu14/smu_v14_0_0_ppt.{c,h}`.

**Why.** On the G16 every idlemask bit reads idle at runtime with the screen off and the PSP and
the keyboard xHCI suspended, but `timein_s0i2` stays 0. A static read of the SMU firmware's
runtime deep-idle gate (#249) found it also needs a Z-state enable that only the driver-mailbox
message AllowZstates (0x25) or the display's AllowZstatesEntry (display mailbox 0x15) appear to
feed. Linux's display code sends 0x15; nothing in Linux sends 0x25 (swsmu has
`SMU_MSG_AllowZstates`, but the 14.0.x message map has no entry for it).

**What.** A `MSG_MAP(AllowZstates, PPSMC_MSG_AllowZstates)` entry for SMU 14.0.x, and a debugfs
file `amdgpu_smu_allow_zstates` (0200, root only, write-only) in the amdgpu DRM debugfs
directory, created on MP1 14.0.0, 14.0.1, 14.0.4 (the G16) and 14.0.5. Writing `0` (disallow),
`8` (Z8) or `9` (Z9 and Z8; `ZStates_e` in `smu_v14_0_0_ppsmc.h`) sends the message with that
argument; anything else is `-EINVAL`, and during reset or suspend `-EBUSY`. Each write logs
`EXPERIMENTAL: SMU AllowZstates(N) sent: <ret>, arg register 0x...`.

**Default behaviour.** None: the message is only sent on a write to the file.

**What the display sends.** dcn35_smu.c already logs each AllowZstatesEntry through `smu_print()`
(`DC_LOG_SMU`, a `pr_debug`); turn it on at runtime with
`echo 'file dcn35_smu.c +p' > /sys/kernel/debug/dynamic_debug/control` and read
`[SMU_MSG]:dcn35_smu_set_zstate_support: SMC_MSG_AllowZstatesEntry msg = ..., param = 0x...` in
the journal (`-p` to turn it off).

**Upstream.** Not submitted; an experiment. **Remove** when the test is done, or turn it into a
proper send if AllowZstates turns out to be what gates runtime S0i2.

**Test:** on battery, screen off, PSP and keyboard xHCI suspended:
`echo 9 | sudo tee /sys/kernel/debug/dri/<amdgpu minor>/amdgpu_smu_allow_zstates`, then
`timein_s0i2` from 9907's `smu_metrics_runtime` and socket power; `echo 0` afterwards. The
SMU's state after a resume is not known: send again after each resume.

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
fuzz 0 with every later patch.

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
