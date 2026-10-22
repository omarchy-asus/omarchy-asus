# asus-rog-nkey-winlock (and the transitional asus-zephyrus-g16-control)

This recipe builds two packages for the ASUS ROG Zephyrus G16 GA605 and its
ROG N-Key keyboard (USB `0b05:19b6`):

| package | contents |
|---|---|
| `asus-rog-nkey-winlock` | `g16-winlock` (Win-key lock OSD and auto-unlock), its hidraw udev rule and its user unit |
| `asus-zephyrus-g16-control` | **transitional**: the G16 Control bar widget is the omarchy-asus plugin now, [omarchy-asus/omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin). This package removes the old packaged copy and its install message says how to switch. |

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
| `/usr/lib/udev/rules.d/70-g16-winlock-hidraw.rules` | asus-rog-nkey-winlock: the keyboard's hidraw nodes get mode 0660, group `input`, and a `uaccess` ACL for the logged-in user |
| `/usr/lib/systemd/user/g16-winlock.service` | asus-rog-nkey-winlock: runs `g16-winlock watch` |
| `/usr/share/doc/asus-zephyrus-g16-control/README.md` | asus-zephyrus-g16-control (transitional): this file |

## Setup

`asus-rog-nkey-winlock` works on install. Nothing to enable:

- The package re-triggers the hidraw udev rules, so the keyboard node picks up
  the `uaccess` ACL for whoever is logged in at the seat. No reboot, and no
  `input` group.
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

- An older `/etc/udev/rules.d/99-g16-winlock-hidraw.rules` keeps applying
  next to the packaged `70-` rule. The content is identical, so that's
  harmless, but remove it once the package is in.
- `~/.config/systemd/user/g16-winlock.service` shadows the packaged unit in
  `/usr/lib/systemd/user/`. Drop-ins in `g16-winlock.service.d/` (such as
  `mode.conf`) apply to either one.
- A widget installed by hand under its old id keeps running from its own
  directory. The plugin has its own id (`io.github.omarchy-asus.plugin`), so the two do not
  collide, but they show the same panel.

To switch over:

1. Install the packages. Nothing changes yet.
2. Compare the files:
   ```bash
   diff /etc/udev/rules.d/99-g16-winlock-hidraw.rules /usr/lib/udev/rules.d/70-g16-winlock-hidraw.rules
   diff ~/.config/systemd/user/g16-winlock.service /usr/lib/systemd/user/g16-winlock.service
   diff /path/to/old/g16-winlock /usr/bin/g16-winlock
   ```
   The rule and the script should be identical (only the rule's file name
   changed). The unit should differ only in
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
4. The widget: see [omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin#readme),
   which also covers moving from `omarchy-power-tune`.

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
   ls -l /dev/hidraw*                         # the 19b6 nodes: crw-rw----+ root input (+ = ACL)
   getfacl /dev/hidrawN                       # a user:<you>:rw- line from uaccess
   g16-winlock status                         # "Cannot open ..." = rule not applied yet
   ```
   No ACL line: re-run the rule with
   `sudo udevadm trigger --action=change --subsystem-match=hidraw`.
3. Service:
   ```bash
   systemctl --user is-enabled g16-winlock.service   # enabled (vendor), or masked
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
   The first line names the node `watch` opened: the 19b6 hidraw node whose
   report descriptor declares report ID `0x5d` (the first 19b6 node if no
   descriptor can be read). No `Win-lock` lines means the kernel (step 1).
5. The OSD on its own: `omarchy-osd -m test`.

## Why the rule is `70-`, not `99-`

`TAG+="uaccess"` only grants the logged-in user access if it's set before
systemd's `73-seat-late.rules` runs. A `99-` rule sets it too late, so access
fell back to the `input` group. Omarchy 4.0.5 removes users from `input` on
purpose, so on a stock install `g16-winlock` couldn't open the keyboard and the
lock toast never appeared. The packaged rule is `70-` so `uaccess` takes effect.
The rule's content is unchanged.
