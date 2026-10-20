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
| `/usr/lib/udev/rules.d/70-g16-winlock-hidraw.rules` | asus-rog-nkey-winlock: the keyboard's hidraw nodes get mode 0660, group `input`, and a `uaccess` ACL for the logged-in user |
| `/usr/lib/systemd/user/g16-winlock.service` | asus-rog-nkey-winlock: runs `g16-winlock watch` |
| `/usr/share/omarchy/plugins/omarchy-asus.g16/` | asus-zephyrus-g16-control: `manifest.json`, `Service.qml`, `Panel.qml`, `bridge/g16_bridge.py` |

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

The bar widget (`asus-zephyrus-g16-control`) is separate and optional:

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

### Per power source: keyboard, refresh rate, panel overdrive

The widget applies these itself on every plug and unplug (it replaces
`omarchy-power-tune`, which was written for this widget). They live in
`~/.config/omarchy/power-tune.conf`, as plain `KEY=VALUE` lines (never run as a
script):

| key | values | what |
|---|---|---|
| `KBD_AC`, `KBD_BATTERY` | `off` `low` `med` `high` | keyboard backlight; the panel's "On AC" / "On battery" rows write these |
| `HZ_AC`, `HZ_BATTERY`, `HZ_GAMING` | Hz | the internal panel's refresh rate |
| `PANEL_OVERDRIVE_AC`, `PANEL_OVERDRIVE_BATTERY` | `0` `1` | asus-armoury panel overdrive, through asusd |
| `INTERNAL_OUTPUT` | `eDP-1`, or `desc:<EDID description>` | which output is the panel (default: the first `eDP`) |
| `BITDEPTH` | `8` `10` | carried on every modeset (default: the panel's current format) |
| `BRIGHT_BATTERY` | % | on leaving the barrel, dim the screen to this if it's brighter (once, not a cap); back on the barrel the old level returns unless you've gone brighter |
| `BRIGHT_DEVICE` | e.g. `amdgpu_bl1` | the backlight for that (default: the first one that isn't `nvidia_*`), set through logind |

| `PPT_AC`, `PPT_USBC`, `PPT_WEAK_BARREL` | `"SPL SPPT FPPT"` in W, e.g. `"25 30 40"` | CPU power limits on that source (asus-armoury, through asusd), clamped to the firmware's range |
| `BOOST_AC`, `BOOST_USBC`, `BOOST_WEAK_BARREL` | W | NVIDIA Dynamic Boost on that source |

"AC" means the barrel charger. A USB-C charger gets the battery settings:
UPower calls both chargers AC, so the widget tells them apart by asus-armoury's
`charge_mode` (bit 0 barrel, bit 1 USB-C). A barrel that drops out three or
more times in 30 s (a third-party adapter that can't carry the load) is a
**weak barrel**: it keeps the AC settings and gets `PPT_WEAK_BARREL` until it's
unplugged for good. Power-source changes apply once the source has been stable
for 1.5 s, so a flapping adapter doesn't flip the refresh rate back and forth.

**Power limits and the fan curve.** On the GA605KM (BIOS 307) the firmware only
applies PPT limits while the CPU custom fan curve is on; in auto fan mode a
written limit is stored but ignored. So on a source with limits the widget
enables asusd's stored CPU curve for the current profile, then writes the
limits; leaving it turns the curve off and writes the defaults back. The fans
follow that curve while limits apply. The values the G16 used with rog-power:
`PPT_USBC="25 30 40"`, `PPT_WEAK_BARREL="45 55 65"`, `BOOST_WEAK_BARREL=5`
(the OEM barrel left at stock).

A key that isn't set is left alone, so with no file nothing is enforced. The
refresh pin (the panel's 60/240/Auto switch, stored in
`~/.local/state/omarchy/power-tune-hz`) wins over gaming mode
(`power-tune-gaming`), which wins over the power source. For a key binding:

```bash
python3 /usr/share/omarchy/plugins/omarchy-asus.g16/bridge/g16_bridge.py gaming toggle
python3 /usr/share/omarchy/plugins/omarchy-asus.g16/bridge/g16_bridge.py hz 60   # or: hz auto
```

A monitor hotplug or `hyprctl reload` re-applies `monitors.lua`, which puts the
panel back on its native rate; the widget sets the rate again after both.

**Coming from `omarchy-power-tune`:** the settings file and state files are the
same, so nothing needs converting. Stop the old service so two programs don't
set the same things: `systemctl --user disable --now power-tune.service`. Its
overdrive and refresh jobs are covered here; anything else you added to it is
not.

The widget also works without asusd: the keyboard and Slash tabs hide, and the
refresh rate, charge limit and Fn+Super switch stay.

### How it works: one Python bridge, nothing polls

`Service.qml` (manifest kind `service`) holds the widget's state once, however
many bars show it. Everything that touches the machine is one process,
`bridge/g16_bridge.py`. It uses only the Python standard library and
PyGObject's Gio, both on stock Omarchy, and it spawns nothing. It talks to:
- asusd and UPower over D-Bus, and follows their `PropertiesChanged` signals;
- Hyprland over its IPC sockets, including the event socket;
- the keyboard LED's `brightness_hw_changed` (Fn+F2/F3) and the settings
  files, through inotify.

It sends a JSON state line whenever something changes and takes commands on
stdin. Under a shell that doesn't hand out services, each widget starts its own
copy after 10 s.

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
  directory. The packaged widget has a new id (`omarchy-asus.g16`), so the two
  do not collide, but they show the same panel.

To switch over:

1. Install the packages. Nothing changes yet.
2. Compare the files:
   ```bash
   diff /etc/udev/rules.d/99-g16-winlock-hidraw.rules /usr/lib/udev/rules.d/70-g16-winlock-hidraw.rules
   diff ~/.config/systemd/user/g16-winlock.service /usr/lib/systemd/user/g16-winlock.service
   diff /path/to/old/g16-winlock /usr/bin/g16-winlock
   diff -r ~/.config/omarchy/plugins/<old-id> /usr/share/omarchy/plugins/omarchy-asus.g16
   ```
   The rule and the script should be identical (only the rule's file name
   changed). The unit should differ only in
   `ExecStart=` (`/usr/bin/g16-winlock watch`) and in the default mode, which
   is now `toast` (keep a `mode.conf` drop-in if you want `unlock`). The widget should differ only in
   its id and author, and in that `g16ctl`, the `gdbus monitor` and
   `omarchy-power-tune` are replaced by the bridge (above).
3. Remove the local copies:
   ```bash
   sudo rm /etc/udev/rules.d/99-g16-winlock-hidraw.rules
   rm ~/.config/systemd/user/g16-winlock.service
   systemctl --user daemon-reload
   systemctl --user disable g16-winlock.service    # drops your own link; the packaged unit stays enabled
   systemctl --user restart g16-winlock.service
   ```
4. If you ran `omarchy-power-tune`, stop it:
   `systemctl --user disable --now power-tune.service` (see "Per power source").
5. Swap the widget: disable the old id, move its directory out of
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
