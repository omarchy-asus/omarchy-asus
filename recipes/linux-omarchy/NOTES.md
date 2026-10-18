# linux-omarchy (omarchy-asus build)

## Base

- Upstream recipe: `pkgbuilds/linux-omarchy` in omacom/omarchy-pkgs.
- Tracks linux-omarchy **7.2.8-9**, recipe last changed upstream in commit
  `cc664d884b8400accad0e02347c39d6b2cd6b688`
  ("Build linux-omarchy as the BORE kernel instead of a meta package").
- Our version: **7.2.8-9.3**. Builds both split packages from one pkgbase:
  `linux-omarchy` and `linux-omarchy-headers` (headers are required by DKMS
  modules such as nvidia-open-dkms).

## What we change

Compared with upstream, only:

1. `pkgrel=9` -> `pkgrel=9.3` (kernel release string becomes `7.2.8-9.3-omarchy`).
   History: 9.1 added 0568 and 9900; 9.2 added 0569 and 0807; 9.3 added 0481.
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
6. `9900-EXPERIMENTAL-...` (see "EXPERIMENTAL: 9900" below).

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
   NOTES.md and our patches: 0481, 0568, 0569, 0807, 9900).
2. Add them back to `source=()`: 0481 after `0480`, 0568 and 0569 after the last `056x` patch,
   0807 after the last `080x` patch (renumber if upstream took the number),
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
   no udev rule, no power-profiles action. Level testing is done by hand on the
   laptop.

Status: compile-tested only, not booted. Not for upstream submission. A
staging-only fix (ISM flush before releasing the stream) was offered as an
optional fourth patch and is not carried.

Test (on the G16, after booting this kernel):
```bash
cat /sys/class/drm/card*-eDP-1/amdgpu/panel_power_savings   # expect 0
# s0i3: suspend, resume, then check the residency counter grew
sudo cat /sys/kernel/debug/amd_pmc/s0ix_stats
```
