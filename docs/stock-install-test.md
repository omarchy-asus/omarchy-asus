# Clean stock-install test on a G16

> [!WARNING]
> **EXPERIMENTAL.** This test wipes the laptop's disk. Use a G16 (GA605KM) whose data you have
> backed up or don't need. The packages run day to day on a G16 that was switched over from an older
> install; this procedure is how we find out whether they work on a fresh one.

This test answers one question: does a **fresh** Omarchy 4.0.5 install on an ASUS ROG Zephyrus G16
GA605KM, switched to the omarchy-asus repo with `bin/omarchy-asus-setup`, end up with every fix
working and nothing broken? A fresh install has none of the hand-made workarounds an older laptop
carries, so a pass here means the packages work on their own.

You need:

- an ASUS ROG Zephyrus G16 GA605KM, on AC power;
- a USB stick (8 GB or more) with the Omarchy **4.0.5** ISO (check its checksum against the one on
  the Omarchy download page);
- wired or Wi-Fi network access;
- an external HDMI monitor (for the HDMI checks), optional but recommended;
- about an hour.

## 1. Install stock Omarchy 4.0.5

1. In the firmware setup (F2 at power-on), note the BIOS version (shown on the main page). Leave
   Secure Boot as you normally have it and write down whether it is on.
2. Boot the ISO (Esc at power-on for the boot menu) and do a normal install: whole disk, default
   options, disk encryption as you prefer.
3. Reboot into the new install and log in to the desktop.
4. Do **not** install anything else, restore dotfiles, or change settings yet. The point is a
   stock system.
5. Write down the baseline (keep the output for the report):

   ```bash
   pacman -Q omarchy linux-omarchy nvidia-open-dkms nvidia-utils hyprland aquamarine
   uname -r
   ```

6. Optional baseline check: download `g16-check` (section 3 below) and run it once now. On stock
   Omarchy, section 1 should FAIL on the kernel (no patch 0568) and section 3 should FAIL on the
   repo. Section 2 should be all `clear`. If section 2 shows anything `present` on a fresh install,
   that is a bug in `g16-check`: report it.

## 2. Switch to the omarchy-asus repo

Follow [LAPTOP-SETUP.md](../LAPTOP-SETUP.md#one-step-setup). In short:

```bash
sudo pacman -S linux                     # fallback kernel, so you can boot if ours fails
curl -fLO https://raw.githubusercontent.com/omarchy-asus/omarchy-asus/main/bin/omarchy-asus-setup
less omarchy-asus-setup                  # read it first
bash omarchy-asus-setup
```

Answer the prompts:

1. **Switch the machine?** yes. Compare the printed key fingerprint with
   `0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88` as given in the README or by the maintainer.
2. **Upgrade now?** yes. `omarchy update` asks once more, takes a snapshot and installs the
   patched builds (linux-omarchy and headers, nvidia-open-dkms, hyprland/hyprpm,
   omarchy/omarchy-settings).
3. **Install the G16 packages and review the fixes?** yes. Then **apply the missing default fixes?**
   yes.

Save the whole terminal output of the setup run for the report (`script -q setup.log` before you
start captures it).

Then **reboot**. In the Limine menu, pick the default `linux-omarchy` entry.

## 3. Run g16-check

```bash
curl -fLO https://raw.githubusercontent.com/omarchy-asus/omarchy-asus/main/bin/g16-check
less g16-check
bash g16-check --live | tee g16-check.txt
```

Run it from a terminal **inside the Hyprland session** (the Win-lock service is a user service of
the desktop session). With `--live` it waits 15 seconds for you to press **Fn+Super twice**.

`g16-check` changes nothing. It replaces your user name and host name with `<user>` and `<host>`
in its output, so the file can go into an issue. It exits 1 if any check FAILs.

## 4. Expected results

### g16-check

| section | check | expected on a passing test |
|---|---|---|
| 1 | running kernel | PASS: `7.2.8-9.1-omarchy` (or a later `-N.M-omarchy`) |
| 1 | linux-omarchy package | PASS: the omarchy-asus build |
| 1 | hid_asus module | PASS: in-tree (`kernel/drivers/hid/...`), no DKMS copy |
| 1 | hidraw node | PASS: one `0b05:19b6` node declares report ID `0x5d` |
| 1 | node access | PASS for reading and writing (the packaged udev rule's uaccess ACL) |
| 1 | udev rule, helper, service | PASS: `/usr/lib/udev/rules.d/70-g16-winlock-hidraw.rules`, `/usr/bin/g16-winlock`, `g16-winlock.service` active |
| 1 | `--live` | PASS: `seen: on off` (the patched hid-asus passes the Win-lock report through) |
| 2 | omarchy-asus-g16-apply lines in hyprland.lua | `clear`: the patched omarchy and omarchy-settings apply hybrid-video and hdmi-cursor through their own migrations and default files, so applying the default fixes adds no lines to hyprland.lua. The section's heading still says "before the patched omarchy 4.0.5-1.1"; the 4.0.6 builds count the same |
| 2 | every other local workaround | `clear` on a fresh install |
| 3 | repo order | PASS: `[omarchy-asus]` before `[omarchy]` and `[core]`, SigLevel Required |
| 3 | key | PASS: in pacman's keyring, validity `f` |
| 3 | packages | PASS: linux-omarchy(-headers), nvidia-open-dkms, hyprland, hyprpm, omarchy, omarchy-settings, omarchy-asus-keyring, omarchy-asus-g16, asus-rog-nkey-winlock, omarchy-asus-g16-apply from `[omarchy-asus]`; no WARN about stock builds or unknown versions |
| 3 | omarchy-asus-g16-apply --check | PASS: every default fix `applied` or `present` |

### Each fix, by hand

| fix | package | how to test | expected |
|---|---|---|---|
| Win-lock pass-through (patch 0568) | linux-omarchy | press Fn+Super | an on-screen "Super locked" toast; press again: "Super unlocked". Super-key shortcuts work again after the second press |
| NVPCF notify while runtime-suspended | nvidia-open-dkms | plug and unplug the charger a few times with the RTX idle; then `journalctl -k -b \| grep -i -E 'nvpcf\|nvrm'` | no NVRM errors or warnings; the RTX goes back to sleep (`cat /sys/bus/pci/devices/0000:*/power/runtime_status` for the NVIDIA device shows `suspended` after a minute idle) |
| hibernate power-off | nvidia-open-dkms + omarchy-asus-g16 (`HibernateMode=shutdown`) | `systemctl hibernate`, then power on | the laptop powers off fully, resumes to the locked session, and the RTX works (`nvidia-smi`) |
| nvkms semaphore leak | nvidia-open-dkms | normal use for a day with an external monitor; note Hyprland's memory (`ps -o rss= -C Hyprland`) morning and evening | no steady growth of hundreds of MB |
| HDMI reconnect render offset | hyprland | with windows on the external monitor's workspace, unplug HDMI, wait 10 s, plug it back | the windows are where they were, not off-screen |
| touchpad wake | omarchy-asus-g16 | `cat /sys/bus/i2c/devices/i2c-ASUF1209:*/power/wakeup`; suspend with a finger resting on the touchpad | `disabled`; suspend is not aborted |
| nvidia-powerd start limit | omarchy-asus-g16 | plug the charger in and out 7 times, then `systemctl is-active nvidia-powerd` | `active` |
| default fixes from omarchy-asus-g16-apply (iGPU video decode, HDMI cursor, speaker level, rtkit, asusd, Win-lock service) | omarchy-asus-g16-apply | `omarchy-asus-g16-apply --check`; play a video in mpv and run `nvidia-smi` | every default fix `applied`/`present`; no mpv process on the RTX; speakers at the expected volume |
| fallback kernel | (Arch `linux`) | reboot and pick the `linux` entry in Limine once | the system boots (Win-lock toast won't work there: expected) |

Anything that doesn't match the "expected" column is a failure, even if `g16-check` passes.

## 5. What to record

Put all of this in the report. Scrub it first: no serial numbers, MAC addresses, user or host
names, home paths, or IP addresses (`g16-check` output is already scrubbed of user and host names).

- BIOS version, Secure Boot on or off, disk encryption on or off.
- The baseline `pacman -Q` and `uname -r` from section 1.
- `g16-check.txt` from section 3 (the whole file).
- The setup log from section 2, or at least the package list it printed and any warning or error.
- For each row of "Each fix, by hand": pass, fail, or not tested, with a line of what you saw.
- For any failure: `journalctl -b -p warning` and `journalctl -k -b` excerpts around it (trim them
  to the relevant lines), and `omarchy-asus-g16-apply --check` output.

## 6. Where to file the results

File on [omarchy-asus/omarchy-asus](https://github.com/omarchy-asus/omarchy-asus/issues) with
`bin/issue` from a checkout of this repo (on any machine; it needs `gh` logged in). See
[AGENTS.md](../AGENTS.md) for the rules.

1. Search first, and add to an existing issue when one already covers it:

   ```bash
   bin/issue find stock install test
   bin/issue find <fix name>                 # e.g. winlock, hibernate, HDMI
   bin/issue comment N --body-file report.md
   ```

2. A **test report** (everything passed, or a summary of several results) goes in one new issue:

   ```bash
   bin/issue template bug > report.md        # fill in the three sections
   bin/issue file --title "Stock-install test: Omarchy 4.0.5 on GA605KM, <date>" \
     --label experimental --body-file report.md --dry-run
   bin/issue file --title "Stock-install test: Omarchy 4.0.5 on GA605KM, <date>" \
     --label experimental --body-file report.md
   ```

   Put the per-fix table under `## What happened`, the `g16-check` output under
   `## Evidence / How to test`, and `ours` (or the upstream issue number) under `## Upstream status`.

3. Each **failure** gets its own issue with the `bug` label (plus the matching `delta:*` label:
   `delta:kernel` for Win-lock, `delta:nvidia`, `delta:hyprland`, `delta:package` for the G16
   packages), and a link back to the test-report issue. Reference the delta's existing issue
   (`Refs #N`) when there is one.

`bin/issue` refuses text with personal information in it; fix the text, don't work around the scan.
