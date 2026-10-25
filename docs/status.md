# Project status

Checked 2026-10-25. Update this page when what the releases serve or the open work changes;
it replaces the old project status issue (#47).

**Goal:** point a G16 at this repo and get every fix from a regular `omarchy update`, and
later from a full installer. Fixes are carried here now and proposed upstream in parallel.

What each package carries, and its upstream state, is in [deltas.md](deltas.md). How the two
channels are built, published and kept current is in [releases.md](releases.md).

## What the releases serve

| Package | Quattro (`x86_64`, frozen) | RC (`rc-x86_64`) |
|---|---|---|
| linux-omarchy + headers | 7.2.8-9.4 | 7.2.8-9.103 |
| nvidia-open-dkms | 615.78.08-1.3 | 615.78.08-1.102 |
| hyprland + hyprpm | 0.56.2-4.2 | 0.56.2-4.103 |
| omarchy + omarchy-settings | 4.0.6-1.3 | 4.5.0rc1-1.111 |
| omarchy-asus-g16 | 1.0.0-1 | 1.0.0-103 |
| asus-rog-nkey-winlock | 0.1.0-12 | 0.1.0-103 |
| asus-zephyrus-g16-control (transitional) | 0.1.0-12 | 0.1.0-101 |
| omarchy-asus-g16-apply | 0.1.0-9 | 0.1.0-101 |
| omarchy-asus-keyring | 20261018-1 | 20261018-102 |

Held on RC (merged, not built): `omarchy-asus-g16-testd` and `proton-experimental-asus`
(their `HOLD` files give the reason). The RC release train is tracked in #339.

## Open work

| Work | State |
|---|---|
| The SD-card-reader kernel stack (PR #288, RC 7.2.8-9.105) | Waits for its G16 test. |
| The Hyprland seat-leave fix (#302) | Published on RC; open until the G16 confirms it. |
| HDMI on the RTX sometimes not detected (#158) | Parked until it happens again; `bin/g16-hdmi` records the hotplug path. |
| A key keeps repeating while a monitor or the charger is unplugged (#350) | Bug, open. |
| omarchy-asus plugin: panel blanks twice on a reload (#204), weak-charger hold (#165) | Fixes in the plugin; G16 tests queued. |
| G16 idle power: SoC floor (#249), SD reader (#226), Wi-Fi power save (#227), display S0i2 (#353), SSD writes (#326), battery CPU tuning (#328) | Experiments being measured on the G16. |
| `bin/g16-idlemask-bisect` hangs on a second RTX port removal (#352) | Bug. |
| Test-kit allowlist gaps (#284), one build path for releases (#258) | Tooling work. |
| Zen 5c-first soft park (#10) | Experimental, default off. |

## Waiting on the maintainer

- The queued G16 test sessions above.
- Yes/no on installing `omarchy-asus-g16-testd` on the G16, and on carrying the general
  Proton fix (`proton-experimental-asus`).
- Delete the retired `omarchy-asus/omarchy-pkgs` repo.
