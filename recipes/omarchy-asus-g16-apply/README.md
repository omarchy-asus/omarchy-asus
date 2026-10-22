# omarchy-asus-g16-apply

> [!WARNING]
> **EXPERIMENTAL. For the ASUS ROG Zephyrus G16 GA605KM only.** The command
> refuses to apply anything on another model unless you pass `--force`.

Some G16 fixes in the [omarchy-asus fork](https://github.com/omarchy-asus/omarchy) (formerly `rdoupe-omarchy/omarchy-asus`)
aren't files a package can own. The fork applies them through an install leaf
or a migration: lines in your Hyprland, mpv and Chromium config, a mixer level,
a package to install, a drop-in in `/etc`, a user service to enable, or an
`/etc` file that Omarchy's installer wrote. `omarchy-asus-g16-apply` does the
same things, on request, on a stock Omarchy 4.0.5 install, where they would
otherwise need the fork. It doesn't edit any file of Omarchy's. With the
patched omarchy from this repo, the migrations do most of this (see below).

Installing the package changes nothing. It ships the command, the fork's files
it uses (unchanged), and one opt-in system unit that stays disabled until you
ask for it.

## With the patched omarchy (4.0.5-1.1 or later)

The `omarchy` and `omarchy-settings` packages from this repo (#58) carry the
fork's fixes. Their migrations and default files apply these during
`omarchy update`:

- hybrid-video: migration `1792123636` (`omarchy-refresh-hybrid-video`).
- hdmi-cursor: `default/hypr/hybrid-cursor.lua`.
- rtkit: migration `1789747667`.
- asusd-power-profiles: `omarchy-settings`' `10-omarchy-power-profiles.conf`
  drop-in, migration `1792122579`.
- initramfs-no-nvidia: migration `1787683023`.

Nothing needs to run at login, and there is no login service (#45). This
command reports those fixes as `present` once they're in place. If rtkit isn't
installed yet, `--check` notes that its migration installs it at the next
`omarchy update`. hybrid-video is `present` only once its mpv and Chromium
pins are actually in place. The marker of migration `1792123636` (under
`~/.local/state/omarchy/migrations`) isn't enough: a user created after
install gets every marker from `/etc/skel` although nothing pinned their
configs. Until the pins are there it's `missing`, and applying it writes them
in Omarchy's marked form, which the migration then leaves.

- **audio-master:** the migration only notifies, on purpose: raising the level
  during an update would make the speakers jump. Run
  `omarchy-asus-g16-apply audio-master` if you want it.
- **winlock:** `asus-rog-nkey-winlock` enables its unit itself.

If this command added its Hyprland lines or asusd drop-in before you installed
the patched omarchy, `--check` says they're now redundant. Delete the
`omarchy-asus-g16-apply` lines from `hyprland.lua`, and the
`20-omarchy-asus-power-profiles.conf` drop-in followed by
`sudo systemctl daemon-reload` (see [Undo](#undo)). Don't turn asusd's
settings back on: the patched omarchy's drop-in wants them off. Keep the mpv
and Chromium pins: `--check` shows this command's older ones as `needs repair`,
and applying hybrid-video hands them over to Omarchy (see
[hybrid-video](#hybrid-video-video-decode-on-the-igpu)).

The command remains for stock Omarchy 4.0.5.

## Use

```bash
omarchy-asus-g16-apply --check             # report every known G16 fix; changes nothing
omarchy-asus-g16-apply --check --dry-run   # the same, plus what applying would do
omarchy-asus-g16-apply                     # apply the default fixes that are missing (asks first)
omarchy-asus-g16-apply hdmi-cursor rtkit   # apply only these
omarchy-asus-g16-apply quiet-fans          # an opt-in fix is applied only when named
omarchy-asus-g16-apply --list
```

Run it as your normal user. System steps go through `sudo`.

`--check` lists, for each fix:

| status | meaning |
|---|---|
| `applied` | the change this command makes is in place |
| `present` | the fix is in place from somewhere else (a package, the fork, the right value already) |
| `present (local)` | you have your own setting for the same thing: **left alone**, whatever its value |
| `missing` | applying would add it (`missing (opt-in)`: only when named) |
| `needs repair` | something this command wrote is out of date (a render node pin after a BIOS or MUX change); applying updates or removes it |
| `n/a` | not this hardware, or the package it needs isn't installed |
| `upstream PR only` | can't be done without changing Omarchy's own scripts |

**Your settings win.** A fix is never applied over a setting of your own. If
any part of a fix is already set by hand (a `LIBVA_DRIVER_NAME` in your
Hyprland config, a `vaapi-device` in `mpv.conf`, any
`cursor.no_hardware_cursors`, a Master level other than Omarchy's 80 %, your
own asusd drop-in, a power manager that owns the profile, a local
`g16-winlock.service`, a renamed `nvidia.conf`), the whole fix is reported as
`present (local)` and skipped. Hyprland configs are found through symlinks
(a dotfile manager's linked `hyprland.lua` or `hypr` directory counts as
yours). On a machine that already carries these fixes by
hand, `--check` shows `present (local)` and applying does nothing.

`--check` exits 10 when a default fix is missing or needs repair, 0 otherwise.

## Default fixes

### hybrid-video: video decode on the iGPU

**What:** adds two lines to `~/.config/hypr/hyprland.lua` that load
`/usr/share/omarchy-asus-g16-apply/hypr/hybrid-video-env.lua`, then runs the
fork's leaf: `hwdec=vaapi` and `vaapi-device=<iGPU node>` at the top of
`~/.config/mpv/mpv.conf`, and `--render-node-override=<iGPU node>` in each
Chromium-family flags file you have, under a
`# omarchy-asus-g16-apply hybrid-video: ...` marker comment.

The pins are checked against the iGPU node every run. A pin this command
wrote (the Chromium line under its marker, the `vaapi-device` line in the
block under the mpv comment) that names another node, after a BIOS update
moves the PCI address, shows `needs repair`, and applying repins it in place.
After a MUX switch to the RTX (no iGPU node) those pins are removed instead,
with the Chromium marker and the mpv comment block, so a later switch back
shows `missing` and pins again.
A pin you wrote yourself is never changed.

With the patched omarchy, Omarchy owns the pins. It repins or removes only a
pin right under its marker comment
(`# Omarchy repins the next line if the iGPU moves. ...`), at Hyprland start
and in `omarchy-refresh-hybrid-video`. So each pin has one owner:

- Reported as present once the pins are in Omarchy's marked form: `mpv.conf`
  has `vaapi-device` under its marker, and every Chromium-family flags file
  you have has a `--render-node-override`. Pins already in Omarchy's marked
  form are Omarchy's, so they're never listed or touched here, even when they
  name an old node.
- Otherwise it's `missing` unless a setting of yours is there: pacman
  installed the patched omarchy and `omarchy update` hasn't run yet, the
  migration was skipped, or its marker
  (`~/.local/state/omarchy/migrations/1792123636.sh`) says it ran although
  nothing pinned your configs, as for a user created after install, who gets
  every marker from `/etc/skel`. Applying writes
  them in Omarchy's form (`hwdec=vaapi`, then the marker above
  `vaapi-device=<iGPU node>` under the mpv comment, and the marker above each
  `--render-node-override`). Nothing is added to `hyprland.lua`, because the
  patched omarchy's default files handle `LIBVA_DRIVER_NAME`.
- Pins this command wrote earlier (under its own Chromium marker, or the
  unmarked `vaapi-device` in the mpv comment's block) show `needs repair`.
  Applying repins them first if they're stale, then hands them over: in the
  Chromium files this command's marker is replaced with Omarchy's, and in
  `mpv.conf` Omarchy's marker goes above the `vaapi-device` line. From then
  on, `omarchy-refresh-hybrid-video` keeps them up to date.

**Why:** stock 4.0.5 sets `LIBVA_DRIVER_NAME=nvidia` because its display check
misses the Krackan iGPU (a non-VGA display controller with no `boot_vga`), and
render node numbering puts the RTX first. Every browser video and mpv clip then
wakes the RTX (AV1 1080p60: 0.36 s CPU on the iGPU vs 2.61 s in software;
YouTube on battery about 9 W instead of 14 W).

**Mirrors:** fork branch `asus/hybrid-video-decode` (`c0b4e886`). The mpv and
Chromium edits are the fork's `install/helpers/hybrid-video-decode.sh` and
`omarchy-hw-igpu-render-node`, shipped unchanged and run as the leaf
`install/user/hardware/hybrid-video-decode.sh` runs them, except that the
Chromium pin gets the marker line above it.

**Difference from the fork:** the fork changes `default/hypr/nvidia.lua` so it
no longer sets the variable. This package can't change that file, and a later
Hyprland config line can't unset a variable, so the Lua file sets
`LIBVA_DRIVER_NAME=radeonsi` (Mesa's AMD driver) under the same
`omarchy-hw-igpu-render-node` check, only for an AMD iGPU. The fork's
stale-pin cleanup at Hyprland start isn't mirrored: after a BIOS update or a
MUX switch, `--check` shows `needs repair` and running the command again fixes
the pins (only its own, unlike the fork's cleanup, which drops any stale
by-path pin). `omarchy refresh chromium` rewrites
`chromium-flags.conf` and drops the pin; run the command again after it. Stock
4.0.5's `omarchy-cmd-browser-handoff` doesn't know `--render-node-override`, so
with the pin it opens links by starting a browser process (about 165 ms)
instead of handing them to the running one; the fork's branch adds the flag to
its allowlist.

**Upstream:** [omacom/omarchy#11690](https://github.com/omacom/omarchy/pull/11690)
merged on `quattro` (not in a release), backport [#13902](https://github.com/omacom/omarchy/pull/13902);
mpv pin: issue [#14285](https://github.com/omacom/omarchy/issues/14285).

**When to remove:** when an Omarchy release stops forcing NVIDIA VA-API on the
G16 and pins mpv and Chromium. Delete the two `omarchy-asus-g16-apply
hybrid-video` lines from `hyprland.lua`; the mpv and Chromium lines are then
Omarchy's own format.

### hdmi-cursor: software cursor while HDMI runs on the RTX

**What:** adds two lines to `~/.config/hypr/hyprland.lua` that load the fork's
`hybrid-cursor.lua` (unchanged). It sets `cursor.no_hardware_cursors` to
software only while a monitor on the NVIDIA card is connected, and back to auto
when it's unplugged. A value you set yourself is left alone.

With the patched omarchy: reported as present (its
`default/hypr/hybrid-cursor.lua`).

**Why:** every hardware cursor update on the RTX's HDMI output fails ("cursor
blit failed", about 230 a minute) and grows Hyprland's memory.

**Mirrors:** fork branch `asus/hdmi-cursor` (`1531add7`), where
`default/hypr/nvidia.lua` requires the same file.

**Upstream:** aquamarine leak report drafted; Omarchy PR drafted, not opened.

**When to remove:** when aquamarine stops leaking on failed cross-GPU cursor
blits, or Omarchy ships the same switch.

### audio-master: ALC285 Master at 100 %

**What:** `amixer -c <ALC285 card> set Master 100% unmute`, only when Omarchy's
soft mixer is in use and Master is still at the 80 % Omarchy's installer set.
Your speakers get louder at the same slider setting.

**Why:** with the soft mixer, PipeWire never moves the hardware Master again,
so 80 % caps full volume 12.75 dB below full scale.

**Mirrors:** fork branch `asus/audio` (`69df7608`), the
`install/user/hardware/asus/fix-audio-mixer.sh` command. (The fork's migration
only tells existing installs about it; this command runs only when you ask.)
`alsa-restore.service` stores the level at shutdown.

**Upstream:** issue [omacom/omarchy#11046](https://github.com/omacom/omarchy/issues/11046).

**When to remove:** when Omarchy's ASUS leaf sets 100 %.

### rtkit

**What:** `omarchy-pkg-add rtkit`. When that run installs it, the command then runs
`systemctl --user try-restart xdg-desktop-portal.service`, then
`systemctl --user try-restart pipewire.service pipewire-pulse.service wireplumber.service`
(errors ignored). If rtkit was already installed, nothing is restarted.

With the patched omarchy: reported as present once migration `1789747667` has
installed it at `omarchy update`.

**Why:** nothing pulls rtkit in on x86_64, so PipeWire runs with no realtime
threads.

**Mirrors:** fork branch `asus/rtkit` (`ed04dd1c`), migration `1792162892`.
The restarts aren't in the fork's migration. They come from #12428's head
(`dac602f5`): the portal reads rtkit's realtime budget only once, so until it
restarts, PipeWire clients get a hard `RLIMIT_RTTIME` of 0
([omacom/omarchy#12443](https://github.com/omacom/omarchy/issues/12443)).
It isn't a dependency of any omarchy-asus package on purpose: a dependency
would install it on every machine that installs the package, with no choice
and no check.

**Upstream:** [omacom/omarchy#12428](https://github.com/omacom/omarchy/pull/12428).

**When to remove:** when Omarchy installs rtkit on x86_64.

### asusd-power-profiles: one owner for the power profile

**What:** installs the fork's asusd drop-in as
`/etc/systemd/system/asusd.service.d/20-omarchy-asus-power-profiles.conf`
(same content as the fork's `10-omarchy-power-profiles.conf`; a basename no
Omarchy package uses), reloads systemd, and turns the three settings off in the
running asusd, as the fork's migration does.

With the patched omarchy: reported as present (`omarchy-settings`'
`10-omarchy-power-profiles.conf` drop-in, migration `1792122579`).

**Why:** asusd switches the platform profile on every plug and unplug and
rewrites the EPP after every profile change, racing Omarchy's own restore.

**Skipped when:** another tool owns the power profile (the fork's
`powerprofiles-autoswitch-off` toggle, or a local `rog-power` unit), or any
asusd drop-in already sets these.

**Mirrors:** fork branch `asus/asusd-power-profiles` (`bbe45936`), migration
`1792122579`.

**Upstream:** [omacom/omarchy#15667](https://github.com/omacom/omarchy/pull/15667).

**When to remove:** when Omarchy ships the drop-in. Then delete
`/etc/systemd/system/asusd.service.d/20-omarchy-asus-power-profiles.conf`.

### winlock: enable the Win-lock helper

**What:** `systemctl --user enable --now g16-winlock.service`, once
`asus-rog-nkey-winlock` is installed.

**Why:** current builds of that package enable it for every user
(`graphical-session.target.wants`), so this is usually reported as applied; it
covers older builds that didn't. A masked unit counts as your own setting. The
Fn+Super toast also needs `linux-omarchy` 7.2.8-9.1 or later from this repo.

**When to remove:** with `asus-rog-nkey-winlock`.

## Opt-in fixes

### initramfs-no-nvidia

**What:** removes `/etc/mkinitcpio.conf.d/nvidia.conf` and rebuilds the
initramfs with `limine-mkinitcpio`. If the rebuild fails, the file is put back.
Runs only when that file still has exactly what Omarchy's installer wrote, and
only on a hybrid machine (the fork's `omarchy-hw-nvidia-only-display`, shipped
unchanged). It writes the fork's marker
`/var/lib/omarchy/migrations/1787683023`, so the fork's migration doesn't
rebuild a second time.

**Why:** on a hybrid laptop the iGPU provides early KMS; nvidia loaded in the
initramfs makes resume from hibernation fail (`nv_pmops_freeze returns -5`).
udev still loads the driver once the root is mounted.

**Why opt-in:** it deletes an `/etc` file Omarchy's installer wrote and
rebuilds the boot image. Keep a fallback kernel entry until the next boot and
one hibernate have worked.

**Mirrors:** fork branch `carry/initramfs-8263` (`97e14bd4`), migration
`1787683023`.

**Upstream:** [omacom/omarchy#8263](https://github.com/omacom/omarchy/pull/8263),
[#10065](https://github.com/omacom/omarchy/pull/10065) (not ours).

**When to remove:** when Omarchy stops early-loading nvidia on hybrids. Nothing
to undo.

### quiet-fans (EXPERIMENTAL)

**What:** enables `omarchy-asus-g16-quiet-fans.service`, a root service that
runs the fork's `omarchy-powerprofiles-asus-quiet-fans` helper (shipped
unchanged) whenever the power source or the power-profiles-daemon profile
changes: `on` on battery with the balanced profile, `off` otherwise. The helper
puts only the ASUS platform profile handler on quiet, and only from balanced,
so the fans stop at idle while the AMD handler keeps full clocks.

**Why:** balanced keeps the fans at 2,000-3,800 rpm at idle on battery; quiet
on the ASUS handler alone stopped them and saved about 0.8 W.

**Difference from the fork:** the fork calls the helper from inside
`omarchy-powerprofiles-set`, which this package can't change. The service
reacts to the same events instead and waits 3 s for Omarchy's own profile
switch, so it normally writes once per change, as the fork does. It runs as
root, so the fork's sudoers grant isn't used. Its trigger code is new and
hasn't run on the laptop yet.

**Skipped when:** another tool owns the power profile, or the fork's helper is
installed.

**Upstream:** not proposed.

**When to remove:** `sudo systemctl disable --now omarchy-asus-g16-quiet-fans.service`.
The ASUS handler goes back to balanced at the next profile change.

### g16-widget

**What:** adds the omarchy-asus plugin, an Omarchy bar widget
([omarchy-asus/omarchy-asus-plugin](https://github.com/omarchy-asus/omarchy-asus-plugin), id `io.github.omarchy-asus.panel`), with
`omarchy-plugin-add https://github.com/omarchy-asus/omarchy-asus-plugin --enable`. The old G16 Control widget under its old id
`omarchy-asus.g16` is removed first: the packaged copy's link (into
`/usr/share/omarchy/plugins`, from `asus-zephyrus-g16-control`) or the first plugin clone
(`omarchy-plugin-remove`). A widget of your own is left alone. Updates come with
`omarchy-plugin-update`; the shell reloads the plugin by itself.

## Reported, not applied

`--check` also reports fixes that come from packages (linux-omarchy,
nvidia-open-dkms and hyprland from this repo, aquamarine 0.15.1 from the
Omarchy mirror, and `omarchy-asus-g16`'s touchpad-wake, hibernate-mode and
nvidia-powerd files), and two fixes that can't be delivered without changing
Omarchy:

- **usbc-power** ([#15668](https://github.com/omacom/omarchy/pull/15668)) and
  **external-owner** ([#15669](https://github.com/omacom/omarchy/pull/15669)).
  Both change stock `omarchy-powerprofiles-set`. Omarchy's shell runs that
  script on every power-source change, finds it first on `PATH`, and has no
  hook. A second service that set the USB-C profile afterwards would race the
  shell and write the platform profile twice per plug; each write wakes the RTX
  for about 20 s, which is the cost these fixes exist to remove.

  The patched omarchy (4.0.5-1.3 or later) carries both as patches 0002 and
  0003, so with it installed `--check` reports them as `present`.

## Undo

- Hyprland: delete the `omarchy-asus-g16-apply` comment line and the line after it from `~/.config/hypr/hyprland.lua`.
- mpv/Chromium: delete the `vaapi-device`, `hwdec` and `--render-node-override` lines (and the mpv comment above them).
- asusd: `sudo rm /etc/systemd/system/asusd.service.d/20-omarchy-asus-power-profiles.conf && sudo systemctl daemon-reload`.
  asusd keeps the settings in `/etc/asusd/asusd.ron`; turn them back on with:

  ```sh
  busctl --system set-property xyz.ljones.Asusd /xyz/ljones xyz.ljones.Platform ChangePlatformProfileOnAc b true
  busctl --system set-property xyz.ljones.Asusd /xyz/ljones xyz.ljones.Platform ChangePlatformProfileOnBattery b true
  busctl --system set-property xyz.ljones.Asusd /xyz/ljones xyz.ljones.Platform PlatformProfileLinkedEpp b true
  ```
- winlock: `systemctl --user mask --now g16-winlock.service` (current builds enable it
  through a vendor link that `disable` leaves in place); `systemctl --user disable --now
  g16-winlock.service` only undoes a per-user enable on older builds.
- audio-master, rtkit, initramfs-no-nvidia: no undo needed; set Master, remove rtkit, or restore `nvidia.conf` by hand if you want the old state.
