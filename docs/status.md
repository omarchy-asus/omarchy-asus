# Project status

Checked 2026-10-28. Update this page when the open work or what waits on the maintainer
changes; it replaces the old project status issue (#47).

**Goal:** point a G16 at this repo and get every fix from a regular `omarchy update`, and
later from a full installer. Fixes are carried here now and proposed upstream in parallel.

Elsewhere:

- What each release serves, every change it carries, and the held packages:
  [deltas.md](deltas.md).
- The work still in issues before it can be carried (the SD-card-reader kernel stack, the G16
  idle-power candidates, the plugin fixes, the HDMI bugs, tooling):
  [deltas.md, "Not carried"](deltas.md#not-carried).
- How the two channels are built, published and kept current: [releases.md](releases.md);
  the RC release train is tracked in #339.

## Open work not listed there

| Work | State |
|---|---|
| The Hyprland seat-leave fix (#302) | Published on RC; open until the G16 confirms it. |
| A key keeps repeating while a monitor or the charger is unplugged (#350) | Bug, open. |
| `bin/g16-idlemask-bisect` hangs on a second RTX port removal (#352) | Bug, open. |
| G16 idle: the display never tells the SMU it is ready for S0i2 (#353) | Experiment, default-off kernel switch. |
| G16 idle SoC floor (#249) | Experiment. The "about 4 W floor" rests on the gpu_metrics sensor, which over-reads at idle; on battery the console alone with the screen off draws about 2.5 W and the desktop with the screen off about 6.1 W. The 3.6 W gap (Hyprland and the display pipeline, the kernel, or a device the desktop keeps awake) is still being split. |
| G16 idle kernel experiments, default-off, stacked for #249: PSP runtime PM, SMU metrics at runtime and display idle with every CRTC off (PR #370, 9.110); the built-in keyboard's autosuspend and the SMU AllowZstates debugfs file (PR #371, 9.111) | Both wait on their G16 test and merge only after it. |

## Waiting on the maintainer

- The queued G16 test sessions, including the SD-card-reader kernel stack (PR #288).
- Yes/no on installing `omarchy-asus-g16-testd` on the G16, and on carrying the general
  Proton fix (`proton-experimental-asus`).
- Delete the retired `omarchy-asus/omarchy-pkgs` repo.
