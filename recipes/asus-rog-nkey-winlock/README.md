# asus-rog-nkey-winlock

This recipe builds `asus-rog-nkey-winlock` for the ASUS ROG Zephyrus G16 GA605 and its
ROG N-Key keyboard (USB `0b05:19b6`): `g16-winlockd` (the root service that owns the
keyboard's hidraw node) and `g16-winlock` (Win-key lock OSD and auto-unlock, a user unit).

It replaces `asus-zephyrus-g16-control`, the transitional package left from when the G16
Control bar widget was packaged here: `pacman -Syu` removes it. The widget is the omarchy-asus
plugin now, [omarchy-asus/omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin),
and `omarchy-update` finishes the move: the omarchy package's migration (patch 0025, #275)
swaps the old widget's link (`~/.config/omarchy/plugins/omarchy-asus.g16`) for the plugin.

The omarchy-asus plugin (keyboard and Slash LEDs, per-charger settings, charge limit, the
Fn+Super switch) installs the Omarchy way:

```bash
omarchy-plugin-add https://github.com/omarchy-asus/omarchy-asus-plugin --enable
```

`omarchy-plugin-update` keeps it current, and the shell reloads it by itself.
`omarchy-asus-g16-apply g16-widget` does the same, and replaces the old packaged
widget's link if there is one.

## What g16-winlock does

Fn+Super toggles a firmware Win-key lock. While it is on, Super sends nothing,
and nothing on screen tells you why.

`g16-winlockd` is a small root service (C, sd-bus) that owns the keyboard's
hidraw node. udev starts `g16-winlockd@hidrawN.service` for each node of the
keyboard; the instance whose node declares report ID `0x5d` stays, the others
exit at once. It waits on the node (no timers, no polling) and turns each
`5D BF 01 xx` report into the D-Bus signal `LockChanged(b)` on the system bus
(`io.github.omarchy_asus.WinLock1`). It has two methods and nothing else:

- `Status() -> b`: the last state seen, from a `5D BF 01 xx` report or
  `SetLocked`'s read-back. Before either since the service started it returns
  `io.github.omarchy_asus.WinLock1.Error.Unknown` (see below).
- `SetLocked(b)`: SetFeature `5D BF 00 xx`, output report `01 01`, then after
  100 ms GetFeature `5D` to read the result back (the sequence
  AsusWinKeyActiveGuard uses on Windows); `Error.Failed` when the keyboard
  reads back the other state. Allowed for root and,
  through polkit (`io.github.omarchy-asus.winlock.set-locked`, `allow_active`),
  for the user of the active local session.

The keyboard can't be asked for the lock without changing it: feature report
`0x5D` answers the last command written to it, and after a boot that is
Aura's, with no `BF` in it. AsusWinKeyActiveGuard has the same limit: it only
reads the state back after its own `5D BF` write, and starts out assuming the
key is unlocked. So `Status()` knows the state once a Fn+Super has reported it
or a `SetLocked` has read it back (a later Fn+Super doesn't refresh the
feature reply, so it is only read right after the write), and `g16-winlock status` prints
`locked=unknown` (exit 3) until then.

Raw reports never leave the service, and the node stays `root:root 0600`.
The service runs with no capabilities, no network, a read-only filesystem and
hidraw as its only device.

`g16-winlock` opens no device. It follows `LockChanged` and calls the methods
(with `gdbus`, from glib2):

- `watch --mode=toast`: shows an Omarchy OSD ("Super locked" / "Super unlocked").
- `watch --mode=unlock`: shows the OSD and clears the lock straight away
  (`SetLocked(false)`).
- `lock`, `unlock`, `status`, `toggle`: one-shot control.

In `unlock` mode the watcher also clears the lock when the service starts
(boot, resume, upgrade), unless the service knows it is already off: a lock
kept over a reboot sends no report, so Super could otherwise stay locked
until the next Fn+Super.

The OSD uses `omarchy-osd`, then `omarchy-shell osd show`, and falls back to
`omarchy-notification-send` or `notify-send`.

## Kernel requirement

The stock `hid-asus` driver drops the Win-lock reports (report `0x5d`, opcode
`0xbf 0x01`) together with the keyboard's AURA echo stream, so `watch` never
sees them and no toast appears. `g16-winlockd` needs the `linux-omarchy` build from
this repo (7.2.8-9.1 or later), which carries
`0568-hid-asus-pass-through-rog-nkey-win-lock-reports.patch`, or any other
kernel with an equivalent change (for example the older `hid-asus-winlock`
DKMS module, which only builds for kernels whose stock `hid-asus` it
recognises). The requirement is an optional dependency and not a versioned
one, so the package keeps installing once a stock kernel has the fix. The
one-shot commands work with any kernel.

## What gets installed

| path | package |
|---|---|
| `/usr/lib/g16-winlockd` | asus-rog-nkey-winlock: the service |
| `/usr/lib/systemd/system/g16-winlockd@.service` | asus-rog-nkey-winlock: one instance per keyboard hidraw node, sandboxed |
| `/usr/lib/udev/rules.d/60-g16-winlockd.rules` | asus-rog-nkey-winlock: starts the instances; grants no access |
| `/usr/share/dbus-1/system.d/io.github.omarchy_asus.WinLock1.conf` | asus-rog-nkey-winlock: only root owns the name, anyone may call it |
| `/usr/share/polkit-1/actions/io.github.omarchy-asus.winlock.policy` | asus-rog-nkey-winlock: `SetLocked` for the active local session |
| `/usr/bin/g16-winlock` | asus-rog-nkey-winlock (Python 3, standard library and `gdbus`) |
| `/usr/lib/systemd/user/g16-winlock.service` | asus-rog-nkey-winlock: runs `g16-winlock watch` |

## Setup

`asus-rog-nkey-winlock` works on install. Nothing to enable:

- The package re-runs the hidraw udev rules and starts `g16-winlockd` for the
  keyboard that is already there. No reboot, and no `input` group. Coming from
  0.1.0-12 or older, it also takes back the access the old rule gave the node,
  and asks you to restart the user unit.
- `g16-winlock.service` ships enabled for every user
  (`/usr/lib/systemd/user/graphical-session.target.wants/`). It starts with your next
  desktop session (Omarchy's uwsm session activates `graphical-session.target`, so the
  OSD tools and Wayland variables are in its environment), or now with
  `systemctl --user start g16-winlock.service`.
- The default mode is `toast`: Fn+Super locks Super in the keyboard firmware,
  as designed, and you see an OSD saying so.

To change that:

1. Auto-unlock instead (Super can never stay locked): the bar widget's
   "On Fn+Super" switch writes a drop-in, or write it yourself at
   `~/.config/systemd/user/g16-winlock.service.d/mode.conf`:
   ```ini
   [Service]
   Environment=G16_WINLOCK_MODE=unlock
   ```
   then `systemctl --user restart g16-winlock.service`.
2. Turn it off for your user: `systemctl --user mask g16-winlock.service`.
   (`disable` does not remove a vendor-enabled unit; `mask` does.)

The bar widget is separate and optional: see the top of this file. Its settings
(per-charger keyboard, refresh rate, backlight and power limits) are documented in
[its README](https://github.com/omarchy-asus/omarchy-asus-plugin#readme).

## Moving from a manual install

Local copies win over the packaged files, so installing the packages changes
nothing until you remove those copies:

- An older `/etc/udev/rules.d/99-g16-winlock-hidraw.rules` keeps opening the
  keyboard's raw node to users. Nothing needs it any more: remove it.
- `~/.config/systemd/user/g16-winlock.service` shadows the packaged unit in
  `/usr/lib/systemd/user/`. Drop-ins in `g16-winlock.service.d/` (such as
  `mode.conf`) apply to either one.
- A widget installed by hand under its old id keeps running from its own
  directory. The plugin has its own id (`io.github.omarchy-asus.panel`), so the two do not
  collide, but they show the same panel.

To switch over:

1. Install the packages. Nothing changes yet.
2. Compare the files:
   ```bash
   diff ~/.config/systemd/user/g16-winlock.service /usr/lib/systemd/user/g16-winlock.service
   ```
   The unit should differ only in
   `ExecStart=` (`/usr/bin/g16-winlock watch`) and in the default mode, which
   is now `toast` (keep a `mode.conf` drop-in if you want `unlock`).
3. Remove the local copies:
   ```bash
   sudo rm /etc/udev/rules.d/99-g16-winlock-hidraw.rules
   rm ~/.config/systemd/user/g16-winlock.service
   systemctl --user daemon-reload
   systemctl --user disable g16-winlock.service    # drops your own link; the packaged unit stays enabled
   systemctl --user restart g16-winlock.service
   ```
4. The widget: see [omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin#readme).

## No toast? Checklist

Run these in the desktop session, from the top down. Each step depends on the
ones above it.

1. Kernel pass-through:
   ```bash
   uname -r                                   # 7.2.8-9.1-omarchy or later from this repo?
   modinfo -n hid_asus                        # .../updates/dkms/... = the old DKMS module
   dkms status hid-asus-winlock 2>/dev/null   # built for the running kernel?
   ```
   On a stock kernel with no DKMS build for it, the reports never reach hidraw
   and nothing below can help.
2. Device and service:
   ```bash
   grep -l 0B05 /sys/class/hidraw/hidraw*/device/uevent | xargs grep -l 19B6
   ls -l /dev/hidraw*                         # the 19b6 nodes: crw------- root root, no +
   systemctl list-units 'g16-winlockd@*'      # one active instance, for the 0x5d node
   journalctl -u 'g16-winlockd@*' -b          # "watching /dev/hidrawN", then Win-lock on/off
   g16-winlock status                         # locked=True/False, or locked=unknown before the first Fn+Super
   ```
   No instance: `sudo udevadm trigger --action=add --subsystem-match=hidraw`.
   `lock`/`unlock` refused with `AccessDenied`: polkit allows them only to the
   active local session (`loginctl show-session $XDG_SESSION_ID -p Active -p Remote`).
3. User unit:
   ```bash
   systemctl --user is-enabled g16-winlock.service   # enabled (vendor), or masked
   systemctl --user status g16-winlock.service
   systemctl --user cat g16-winlock.service   # which file wins, and does ExecStart exist?
   journalctl --user -u g16-winlock.service -b
   ```
   Every Fn+Super should log `Win-lock on/off` and an `osd rc=0` line.
4. Live test, with the user unit stopped:
   ```bash
   systemctl --user stop g16-winlock.service
   g16-winlock watch --mode=toast             # press Fn+Super twice
   ```
   No `Win-lock` lines while `journalctl -u 'g16-winlockd@*'` shows them: the
   bus (step 2). Neither shows them: the kernel (step 1).
5. The OSD on its own: `omarchy-osd -m test`.

## Why a service, and no access rule

Up to 0.1.0-12, `70-g16-winlock-hidraw.rules` gave the logged-in user the
keyboard's hidraw nodes (`uaccess`, group `input`): the keyboard's whole raw
stream, for a helper that needs one bit of state and two commands. From
0.1.0-13 the nodes stay root-only, `g16-winlockd` reads them, and the user gets
only `LockChanged`, `Status` and the polkit-gated `SetLocked`. The udev rule
that is left (`60-g16-winlockd.rules`) only starts the service.
