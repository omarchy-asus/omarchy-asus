# Project status

Checked 2026-10-25. Update this page when the open work or what waits on the maintainer
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
| G16 on battery: CPU boost, EPP and frequency cap A/B (#328) | Experiment. |

## Waiting on the maintainer

- The queued G16 test sessions, including the SD-card-reader kernel stack (PR #288).
- Yes/no on installing `omarchy-asus-g16-testd` on the G16, and on carrying the general
  Proton fix (`proton-experimental-asus`).
- Delete the retired `omarchy-asus/omarchy-pkgs` repo.
