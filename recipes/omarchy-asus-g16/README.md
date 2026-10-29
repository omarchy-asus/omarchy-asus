# omarchy-asus-g16

> [!WARNING]
> **EXPERIMENTAL. For the ASUS ROG Zephyrus G16 GA605KM only.** Installing it on
> another machine prints a warning; the files still install.

Static system files for G16 fixes that the
[omarchy-asus fork](https://github.com/omarchy-asus/omarchy) otherwise
sets up through an omarchy install leaf or migration. With this package a stock
Omarchy 4.0.5 install gets them without rebuilding `omarchy` or
`omarchy-settings`.

Every file is byte-identical to the one the fork writes. Only the location
changes, from `/etc` to the matching vendor directory under `/usr/lib`, and the
basenames are ones no Omarchy package or migration uses. If Omarchy later ships
the same fix at its own path, pacman doesn't report a file conflict: the two
identical copies both apply until this package is removed.

The package doesn't enable or start anything at install time. Its install
script warns when the DMI data doesn't name a GA605KM, and the Limine entries
are rebuilt (`limine-update`) when the kernel command-line drop-in arrives,
changes or goes, so the next boot matches the package. A running
NetworkManager is asked to reread its configuration on install, upgrade and
removal. It uses
the same check as the fork's gate: `omarchy-hw-asus-rog` plus
`omarchy-hw-match GA605KM`.

| package | file | fix |
|---|---|---|
| `omarchy-asus-g16` | `/usr/lib/udev/rules.d/99-omarchy-asus-g16-touchpad-wake.rules` | [touchpad wake](#touchpad-doesnt-wake-the-laptop) |
| `omarchy-asus-g16` | `/usr/lib/systemd/sleep.conf.d/omarchy-asus-g16-hibernate-mode.conf` | [hibernate mode](#hibernatemodeshutdown) |
| `omarchy-asus-g16` | `/usr/lib/systemd/system/nvidia-powerd.service.d/20-omarchy-asus.conf` | [nvidia-powerd start limit](#nvidia-powerd-start-limit) |
| `omarchy-asus-g16` | `/usr/share/limine-entry-tool.d/omarchy-asus-g16-rcu-nocbs.conf`, `/usr/share/libalpm/hooks/95-omarchy-asus-g16-limine.hook` | [`rcu_nocbs=all`](#rcu_nocbsall) |
| `omarchy-asus-g16` | `/usr/lib/NetworkManager/conf.d/omarchy-asus-g16-mt7925-auth-retries.conf` | [Wi-Fi back after a wake](#wi-fi-stays-down-after-a-wake) |
| `omarchy-asus-g16` | `/usr/lib/udev/rules.d/99-omarchy-asus-g16-keyboard-autosuspend.rules` | [built-in keyboard autosuspend](#built-in-keyboard-autosuspend) (EXPERIMENTAL) |

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

## nvidia-powerd start limit

> [!NOTE]
> This is a fix, not a restyle: without it, Dynamic Boost stays off from the
> sixth charger plug-in of a boot (seen on a GA605KM). It was split into an
> opt-in package at first. It now ships in the main package, because it's a
> tested bug fix with a one-key change.

**Fixes:** nvidia-utils caps `nvidia-powerd.service` at five starts with an
unlimited window (`StartLimitIntervalSec=infinity`, `StartLimitBurst=5`). asusd
starts the service on every charger plug-in and stops it on every unplug. From
the sixth plug-in of a boot, systemd refuses the start (`start-limit-hit`) and
Dynamic Boost stays off until reboot. The drop-in sets a 60-second window. Five
crash restarts 10 s apart still trip the limit; plug-ins minutes apart don't
count against it.

**Mirrors:** fork branch `asus/nvidia-powerd-start-limit` at `2cd582fb`
(`default/systemd/system/nvidia-powerd.service.d/10-omarchy.conf`), shipped by
the [omarchy-asus/omarchy-pkgs](https://github.com/omarchy-asus/omarchy-pkgs) branch `omarchy-settings-nvidia-powerd` (`25c4f5a4`) to
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

## `rcu_nocbs=all`

**Fixes:** linux-omarchy is built with `CONFIG_RCU_NOCB_CPU=y` and
`CONFIG_RCU_LAZY=y` (lazy on by default), but lazy RCU only batches callbacks
on offloaded CPUs, and without `rcu_nocbs=` none are. While a CPU that isn't
offloaded has callbacks queued, `rcu_needs_cpu()` keeps its 1000 Hz tick
running when it goes idle, so every `call_rcu()` (closing files, freeing
sockets, exiting tasks) costs a few to a few dozen idle ticks on that CPU.
Offloaded, the callbacks move to the `rcuo` kthreads, idle CPUs stop their tick,
and non-urgent callbacks wait up to 10 s. ChromeOS measured 0.58 → 0.41 W
package power on an idle Chromebook with lazy RCU. The G16 boot A/B is in #229.

**This one isn't a fork mirror:** the fork has no equivalent. The file is a
limine-entry-tool drop-in in the tool's vendor directory, which it reads before
`/etc/limine-entry-tool.d/` and `/etc/default/limine`, so a local setting still
wins. It appends ` rcu_nocbs=all` to the default command line. The package's
alpm hook runs `limine-update` when the drop-in is installed or changed, and
`post_remove` runs it after removal. The parameter takes effect at the next
boot.

**Check:** `grep -o 'rcu_nocbs=[^ ]*' /proc/cmdline` prints `rcu_nocbs=all`, and
`ps -e | grep -c rcuo` counts one or more `rcuo` kthreads.

**Cost:** callback processing moves to kthreads, and `synchronize_rcu()`
callers that aren't exempted from laziness can wait longer. Android and ChromeOS
ship this setting.

**Upstream:** not applicable as a kernel bug. Omarchy's kernel could set
`CONFIG_RCU_NOCB_CPU_DEFAULT_ALL=y` instead; not proposed until the G16 numbers
are in.

**When to remove:** if linux-omarchy turns on `CONFIG_RCU_NOCB_CPU_DEFAULT_ALL`,
or if the A/B shows no saving.

## Wi-Fi stays down after a wake

**Fixes (#196):** the G16's MediaTek MT7925 (`mt7925e`) authenticates and
associates after a resume, then times out the WPA four-way handshake
(`Reason: 15=4WAY_HANDSHAKE_TIMEOUT`). It happens once on most cold boots too,
and the next try usually connects within a second. NetworkManager reads a
handshake timeout on a `wpa-psk` connection as a possibly wrong password: it
retries while `connection.auth-retries` (3 by default) has tries left, then
asks a secret agent for a new key (`disconnected during association, asking
for new key`). Omarchy runs no secret agent, so that request fails (`No agents
were available for this request`), the device fails with `no-secrets`, and
NetworkManager blocks autoconnect for the connection until a secret agent
registers, which on Omarchy never happens. After two timeouts in a row Wi-Fi stayed down until it was
reconnected by hand.

The drop-in gives devices on the `mt7925e` driver six tries instead of three,
in its own `[connection-…]` section matched with `match-device=driver:mt7925e`,
so no other Wi-Fi card and no other connection setting changes. A connection
with its own `auth-retries` keeps it.

**This one isn't a fork mirror:** the fork has no equivalent.

**Path:** NetworkManager reads `conf.d` from `/usr/lib`, `/run` and `/etc` and
merges files by basename, so only an `/etc` file with this basename would mask
it; no Omarchy file uses it. A matching `[connection-…]` section only answers
for the keys it sets, so Omarchy's `[connection]` keys (`wifi.powersave`)
still apply.

**Check:** `NetworkManager --print-config | grep -A2 mt7925` prints the
section. After a wake,
`journalctl -b -u NetworkManager | grep -E "reauthenticating|asking for new key|no-secrets"`
shows at most `reauthenticating` lines.

**Cost:** a password that is really wrong on a connection that worked before
fails after six handshake timeouts instead of three, so it takes a few
seconds longer to give up. A new connection is unaffected: NetworkManager asks for its key at the first failure.

**Upstream:** not reported. Two parts: the lost first handshake after a wake
(mt76, kernel) and NetworkManager treating a handshake timeout as a wrong key
when no agent can answer. Tracked in #196; a human decides whether either is
reported.

**When to remove:** when mt7925 keeps its first handshake after a wake, or when
NetworkManager stops treating a handshake timeout as a wrong key.

## Built-in keyboard autosuspend

> [!WARNING]
> EXPERIMENTAL (#249): waits on its G16 test. It needs linux-omarchy 7.2.8-9.111 or later
> (patch 9909) to make a difference while Num Lock is on.

**Fixes:** the G16's SoC can't reach its runtime deep idle while the xHCI that carries the
built-in keyboard and Bluetooth (67:00.0) is awake, and that xHCI stays awake because the
keyboard (USB 0b05:19b6) never runtime-suspends. The USB core leaves a keyboard's
`power/control` at `on`. The rule sets it to `auto`, with a 2 s autosuspend delay (the USB
default, set explicitly). The keyboard supports remote wakeup: a key press wakes it.

usbhid also refuses to suspend a keyboard while one of its declared LEDs is lit. This keyboard
declares Num Lock, Scroll Lock, Compose and Kana LEDs it doesn't have, and Omarchy turns Num
Lock on at login. linux-omarchy 9909 makes it declare only its real Caps Lock light. A lit Caps
Lock still keeps it awake, by design. A connected Bluetooth device keeps the same xHCI awake.

**This one isn't a fork mirror:** the fork has no equivalent.

**Path:** `/usr/lib/udev/rules.d/99-omarchy-asus-g16-keyboard-autosuspend.rules`. No Omarchy
rule writes this keyboard's `power/control`; systemd's `60-autosuspend.rules` only covers
devices its hwdb lists, and this keyboard isn't one of them.

**Timing:** the rule takes effect at the next boot, or immediately after:

```bash
sudo udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=0b05 --attr-match=idProduct=19b6
```

**Check:** `cat /sys/bus/usb/devices/3-4/power/control` prints `auto`; with Num Lock on and
Caps Lock off, `power/runtime_status` reads `suspended` a few seconds after the last key press.

**Cost:** the first key press after a pause wakes the keyboard (a few milliseconds). If it ever
drops that key, remove the package or write `on` to `power/control`.

**Not chosen:** `usbhid.ignoreled=1` would do the LED half without a kernel patch, but it is
global: every USB HID keyboard would autosuspend with its LEDs lit. Turning Omarchy's
`numlock_by_default` off is upstream's choice and changes keyboards with a number pad.

**Upstream:** ours-only (a power setting for one laptop's keyboard). The kernel half may go to
the HID tree once the G16 test passes.

**When to remove:** if the G16 test shows no gain, or when the kernel autosuspends this
keyboard by default.

## Not packaged

Not packaged, so stock behaviour stays unchanged. These fixes live in the fork
and as upstream PRs only:

- `asus/asusd-power-profiles`: asusd hands profile and EPP control to one owner. Writes an `/etc` drop-in through a migration; [omacom/omarchy#15667](https://github.com/omacom/omarchy/pull/15667).
- `asus/usbc-power` and omarchy-asus/omarchy-pkgs branch `omarchy-settings-source-monitor`: adapter-based power policy. Modifies the stock `omarchy-powerprofiles-set`; [#15668](https://github.com/omacom/omarchy/pull/15668).
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
sudo pacman -Rns omarchy-asus-g16
```

Removal deletes the files and rebuilds the Limine entries without
`rcu_nocbs=all`, which stays in effect until the next boot. The touchpad stays
disarmed, and the keyboard on autosuspend, until the next boot. A
copy the fork's migration wrote to `/etc` isn't owned by this package and stays.
