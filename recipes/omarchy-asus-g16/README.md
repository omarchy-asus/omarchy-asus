# omarchy-asus-g16

> [!WARNING]
> **EXPERIMENTAL. For the ASUS ROG Zephyrus G16 GA605KM only.** Installing it on
> another machine prints a warning; the files still install.

Static system files for G16 fixes that the
[omarchy-asus fork](https://github.com/rdoupe-omarchy/omarchy-asus) otherwise
sets up through an omarchy install leaf or migration. With this package a stock
Omarchy 4.0.5 install gets them without rebuilding `omarchy` or
`omarchy-settings`.

Every file is byte-identical to the one the fork writes. Only the location
changes, from `/etc` to the matching vendor directory under `/usr/lib`, and the
basenames are ones no Omarchy package or migration uses. If Omarchy later ships
the same fix at its own path, pacman doesn't report a file conflict: the two
identical copies both apply until this package is removed.

The package doesn't enable, start, trigger or write anything at install time.
Its install script only warns when the DMI data doesn't name a GA605KM. It uses
the same check as the fork's gate: `omarchy-hw-asus-rog` plus
`omarchy-hw-match GA605KM`.

| package | file | fix |
|---|---|---|
| `omarchy-asus-g16` | `/usr/lib/udev/rules.d/99-omarchy-asus-g16-touchpad-wake.rules` | [touchpad wake](#touchpad-doesnt-wake-the-laptop) |
| `omarchy-asus-g16` | `/usr/lib/systemd/sleep.conf.d/omarchy-asus-g16-hibernate-mode.conf` | [hibernate mode](#hibernatemodeshutdown) |
| `omarchy-asus-g16-nvidia-powerd` (opt-in) | `/usr/lib/systemd/system/nvidia-powerd.service.d/20-omarchy-asus.conf` | [nvidia-powerd start limit](#nvidia-powerd-start-limit-opt-in) |

## Touchpad doesn't wake the laptop

**Fixes:** the firmware marks the ASUF1209 i2c-hid touchpad as a wake source,
and Linux arms it. While it is armed, every touch report counts as a wakeup
event (129k in one boot), and a touch during suspend or hibernate entry can
abort the transition. The rule disarms the touchpad as a wake source. The
keyboard, lid and power button still wake the laptop; a touchpad click no
longer does.

**Mirrors:** fork branch `asus/touchpad-wake` at `22acd8bf` (commits `98f530ca`
and its fixup). The file is the heredoc from
`install/hardware/asus/fix-asus-ga605km-touchpad-wake.sh`, which is identical
to the one in `migrations/1792116410.sh`.

**Path:** the fork writes `/etc/udev/rules.d/99-omarchy-asus-ga605km-touchpad-wake.rules`.
udev merges `/etc`, `/run` and `/usr/lib/udev/rules.d` by basename, so moving
the file to `/usr/lib` changes nothing unless another file with the same
basename exists, and none does. The new basename `99-omarchy-asus-g16-…` sorts
directly before the fork's `99-omarchy-asus-ga605km-…`, and no stock 4.0.5 rule
sorts between them. No stock 4.0.5 rule writes `power/wakeup` at all.

**Difference from the fork (timing only):** after writing the rule, the fork's
migration also disarms the touchpad in sysfs right away. The package doesn't,
so the rule takes effect at the next boot, or immediately after:

```bash
sudo udevadm trigger --action=add --subsystem-match=i2c --sysname-match='i2c-ASUF1209:*'
```

**Upstream:** not proposed to Omarchy. A kernel linux-input report was
withdrawn after s2idle testing showed that only a click wakes the laptop.

**When to remove:** when Omarchy ships this rule in a release, or when the
kernel or firmware limits ASUF1209 wakeups to clicks, as ASUS's Windows filter
driver does.

## `HibernateMode=shutdown`

**Fixes:** in the default platform mode the kernel asks the firmware for ACPI
S4 after writing the image, and backs out if a wakeup event is pending. On the
GA605KM that rollback powers the RTX back up in the middle of the transition,
the NVIDIA driver fails to restore its channels, and the laptop needs a hard
reset. Shutdown mode has no rollback path: it writes the image and powers off.

**Mirrors:** fork branch `asus/hibernate-mode` at `3a441d6d` (commits
`9f8eb529` and its fixup). The file is the heredoc from
`install/hardware/asus/fix-asus-ga605km-hibernate-mode.sh`, which is identical
to the one in `migrations/1792129283.sh`.

**Path:** the fork writes `/etc/systemd/sleep.conf.d/omarchy-asus-ga605km-hibernate-mode.conf`.
systemd-sleep reads `sleep.conf.d` from `/etc`, `/run` and
`/usr/lib` and merges the drop-ins by basename. A later name wins for the same
key, and the same basename in `/etc` masks the `/usr/lib` copy. Stock 4.0.5
ships no `sleep.conf.d` drop-in. The new basename sorts directly before the
fork's, so a hand-written drop-in keeps the order it had against the fork's
file. systemd-sleep reads the file at each hibernate, so nothing needs a
restart.

**Upstream:** not proposed by us. The same fix is reported in
[omacom/omarchy#8589](https://github.com/omacom/omarchy/issues/8589), which
waits on how to gate it. The separate power-off hang after the image is
written is NVIDIA/open-gpu-kernel-modules
[#1412](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1412), carried
in this repo's `nvidia-open-dkms`.

**When to remove:** when Omarchy ships `HibernateMode=shutdown` for the GA605KM
in a release, or when the NVIDIA driver survives the S4 rollback.

## nvidia-powerd start limit (opt-in)

> [!NOTE]
> **Behaviour change: this isn't live on the laptop today.** It's in a separate
> package, `omarchy-asus-g16-nvidia-powerd`, that nothing pulls in. Install it
> on purpose.

**Fixes:** nvidia-utils caps `nvidia-powerd.service` at five starts with an
unlimited window (`StartLimitIntervalSec=infinity`, `StartLimitBurst=5`). asusd
starts the service on every charger plug-in and stops it on every unplug. From
the sixth plug-in of a boot, systemd refuses the start (`start-limit-hit`) and
Dynamic Boost stays off until reboot. The drop-in sets a 60-second window. Five
crash restarts 10 s apart still trip the limit; plug-ins minutes apart don't
count against it.

**Mirrors:** fork branch `asus/nvidia-powerd-start-limit` at `2cd582fb`
(`default/systemd/system/nvidia-powerd.service.d/10-omarchy.conf`), shipped by
the pkgs branch `omarchy-settings-nvidia-powerd` (`25c4f5a4`) to
`/usr/lib/systemd/system/nvidia-powerd.service.d/10-omarchy.conf`.

**Path:** same directory, renamed to `20-omarchy-asus.conf` so it can never
collide with an `omarchy-settings` that ships `10-omarchy.conf`. Stock 4.0.5
has no other drop-in for this unit, so the order doesn't matter. If both are
installed, they set the same value. Arch's systemd pacman hook reloads units
when the drop-in is installed or removed. The new limit applies to the next
start; the package doesn't restart the service.

**Upstream:** not opened. The proper fix belongs in asusctl
(`manage_nvidia_powerd` ignores the failed start); a patch is drafted but not
posted.

**When to remove:** when asusctl or nvidia-utils handles the start limit, or
when `omarchy-settings` ships the drop-in in a release.

## Not packaged

Not packaged, so stock behaviour stays unchanged. These fixes live in the fork
and as upstream PRs only:

- `asus/asusd-power-profiles`: asusd hands profile and EPP control to one owner. Writes an `/etc` drop-in through a migration; [omacom/omarchy#15667](https://github.com/omacom/omarchy/pull/15667).
- `asus/usbc-power` and pkgs branch `omarchy-settings-source-monitor`: adapter-based power policy. Modifies the stock `omarchy-powerprofiles-set`; [#15668](https://github.com/omacom/omarchy/pull/15668).
- `asus/powerprofiles-external-owner`: a `powerprofiles-autoswitch-off` toggle in stock scripts; [#15669](https://github.com/omacom/omarchy/pull/15669).
- `asus/ga605km-quiet-fans`: battery fan profile. Hooks the stock power-profile script and needs a sudoers grant; not proposed.
- `asus/hdmi-cursor`: software cursor while HDMI runs on the RTX. Per-user Hyprland config; PR drafted.
- `asus/hybrid-video-decode`: VA-API, mpv and Chromium decode on the iGPU. Per-user environment and app config; [#11690](https://github.com/omacom/omarchy/pull/11690) is merged on `quattro`, backport [#13902](https://github.com/omacom/omarchy/pull/13902).
- `asus/audio`: ALC285 Master at 100 %. Edits the stock `fix-audio-mixer.sh`; issue [#11046](https://github.com/omacom/omarchy/issues/11046).
- `asus/rtkit`: rtkit on x86_64. Duplicates [#12428](https://github.com/omacom/omarchy/pull/12428).
- `carry/initramfs-8263`: no NVIDIA early load in the initramfs. A cherry-pick of [#8263](https://github.com/omacom/omarchy/pull/8263).
- `perf/*`: webcam guard via udev ([#15670](https://github.com/omacom/omarchy/pull/15670)), Tailscale polling ([#15671](https://github.com/omacom/omarchy/pull/15671)), monitor watch on logind, launcher icon index. All change stock scripts.

## Before installing on a machine that already has the fix by hand

A hand-written copy in `/etc` (an older touchpad rule or a `HibernateMode`
drop-in) keeps applying next to this package. With identical content that is
harmless. A copy with different keys or values may win on order. Delete
leftover copies once the package is in.

## Removal

```bash
sudo pacman -Rns omarchy-asus-g16 omarchy-asus-g16-nvidia-powerd
```

Removal deletes the files. The touchpad stays disarmed until the next boot. A
copy the fork's migration wrote to `/etc` isn't owned by this package and stays.
