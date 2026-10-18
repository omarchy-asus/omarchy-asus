# asus-rog-nkey-winlock, asus-zephyrus-g16-control

This recipe builds two packages for the ASUS ROG Zephyrus G16 GA605 and its
ROG N-Key keyboard (USB `0b05:19b6`):

| package | contents |
|---|---|
| `asus-rog-nkey-winlock` | `g16-winlock` (Win-key lock OSD and auto-unlock), its hidraw udev rule and its user unit |
| `asus-zephyrus-g16-control` | the "G16 Control" bar widget for the Omarchy shell (plugin id `omarchy-asus.g16`): keyboard and Slash LEDs, refresh rate, charge limit, and the Fn+Super mode switch |

## What g16-winlock does

Fn+Super toggles a firmware Win-key lock. While it is on, Super sends nothing,
and nothing on screen tells you why. `g16-winlock` reads the keyboard's
Win-lock reports from hidraw and:

- `watch --mode=toast`: shows an Omarchy OSD ("Super locked" / "Super unlocked").
- `watch --mode=unlock`: shows the OSD and clears the lock straight away
  (HID SetFeature `5D BF 00 00` followed by output report `01 01`, the same
  sequence AsusWinKeyActiveGuard uses on Windows).
- `lock`, `unlock`, `status`, `toggle`: one-shot control over hidraw.

The OSD uses `omarchy-osd`, then `omarchy-shell osd show`, and falls back to
`omarchy-notification-send` or `notify-send`.

## Kernel requirement

The stock `hid-asus` driver drops the Win-lock reports (report `0x5d`, opcode
`0xbf 0x01`) together with the keyboard's AURA echo stream, so `watch` never
sees them and no toast appears. `watch` needs the `linux-omarchy` build from
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
| `/usr/bin/g16-winlock` | asus-rog-nkey-winlock (Python 3, standard library only) |
| `/usr/lib/udev/rules.d/99-g16-winlock-hidraw.rules` | asus-rog-nkey-winlock: the keyboard's hidraw nodes get mode 0660, group `input` |
| `/usr/lib/systemd/user/g16-winlock.service` | asus-rog-nkey-winlock: runs `g16-winlock watch` |
| `/usr/share/omarchy/plugins/omarchy-asus.g16/` | asus-zephyrus-g16-control: `manifest.json`, `Panel.qml`, `g16ctl` |

## Setup

Neither package enables anything for you.

1. hidraw access: pacman reloads the udev rules on install, but the rule only
   applies once the keyboard's hidraw nodes are created again. Reboot, or run
   `sudo udevadm trigger --subsystem-match=hidraw`. Your user has to be in the
   `input` group.
2. The service:
   ```bash
   systemctl --user enable --now g16-winlock.service
   ```
   The unit sets `Environment=G16_WINLOCK_MODE=unlock` (auto-unlock). The bar
   widget's "On Fn+Super" switch writes a drop-in that overrides it
   (`~/.config/systemd/user/g16-winlock.service.d/mode.conf`), and enables and
   restarts the service. You can write that drop-in by hand:
   ```ini
   [Service]
   Environment=G16_WINLOCK_MODE=toast
   ```
3. The bar widget: Omarchy's shell loads third-party plugins only from
   `~/.config/omarchy/plugins/<id>/`, so link the packaged copy there and
   enable it:
   ```bash
   mkdir -p ~/.config/omarchy/plugins
   ln -s /usr/share/omarchy/plugins/omarchy-asus.g16 ~/.config/omarchy/plugins/omarchy-asus.g16
   omarchy plugin enable omarchy-asus.g16
   ```
   The link follows package upgrades. Remove it before you uninstall the
   package.

## Moving from a manual install

Local copies win over the packaged files, so installing the packages changes
nothing until you remove those copies:

- `/etc/udev/rules.d/99-g16-winlock-hidraw.rules` masks the packaged rule of
  the same name, and both sort at the same position.
- `~/.config/systemd/user/g16-winlock.service` shadows the packaged unit in
  `/usr/lib/systemd/user/`. Drop-ins in `g16-winlock.service.d/` (such as
  `mode.conf`) apply to either one.
- A widget installed by hand under its old id keeps running from its own
  directory. The packaged widget has a new id (`omarchy-asus.g16`), so the two
  do not collide, but they show the same panel.

To switch over:

1. Install the packages. Nothing changes yet.
2. Compare the files:
   ```bash
   diff /etc/udev/rules.d/99-g16-winlock-hidraw.rules /usr/lib/udev/rules.d/99-g16-winlock-hidraw.rules
   diff ~/.config/systemd/user/g16-winlock.service /usr/lib/systemd/user/g16-winlock.service
   diff /path/to/old/g16-winlock /usr/bin/g16-winlock
   diff -r ~/.config/omarchy/plugins/<old-id> /usr/share/omarchy/plugins/omarchy-asus.g16
   ```
   The rule and the script should be identical. The unit should differ only in
   `ExecStart=` (`/usr/bin/g16-winlock watch`). The widget should differ only in
   its id, its author, the way `Panel.qml` finds `g16ctl` (next to itself
   instead of a fixed path under the old id), and `g16ctl`'s fallback path for
   `g16-winlock`.
3. Remove the local copies:
   ```bash
   sudo rm /etc/udev/rules.d/99-g16-winlock-hidraw.rules
   rm ~/.config/systemd/user/g16-winlock.service
   systemctl --user daemon-reload
   systemctl --user reenable g16-winlock.service   # re-points default.target.wants at the packaged unit
   systemctl --user restart g16-winlock.service
   ```
4. Swap the widget: disable the old id, move its directory out of
   `~/.config/omarchy/plugins/`, then link and enable `omarchy-asus.g16`
   (Setup step 3). The old id's widget settings in `shell.json` are not carried
   over. The G16 Control widget keeps no per-widget settings, so nothing is lost
   beyond its place in the bar.

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
2. Device and access:
   ```bash
   grep -l 0B05 /sys/class/hidraw/hidraw*/device/uevent | xargs grep -l 19B6
   ls -l /dev/hidraw*                         # the 19b6 nodes: crw-rw---- root input
   id -nG | tr ' ' '\n' | grep -x input
   g16-winlock status                         # "Cannot open ..." = rule or group missing
   ```
3. Service:
   ```bash
   systemctl --user is-enabled g16-winlock.service
   systemctl --user status g16-winlock.service
   systemctl --user cat g16-winlock.service   # which file wins, and does ExecStart exist?
   journalctl --user -u g16-winlock.service -b
   ```
   Every Fn+Super should log `Win-lock on/off` and an `osd rc=0` line.
4. Live test, with the service stopped:
   ```bash
   systemctl --user stop g16-winlock.service
   g16-winlock watch --mode=toast             # press Fn+Super twice
   ```
   No `Win-lock` lines means the kernel (step 1), or that `watch` opened a
   19b6 hidraw node other than the one that carries report `0x5d` (step 2
   lists them all).
5. The OSD on its own: `omarchy-osd -m test`.
