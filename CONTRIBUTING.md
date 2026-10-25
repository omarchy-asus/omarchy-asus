# Contributing

Everyone is welcome. You don't need permission, a big patch or a lot of Linux experience.
A good hardware report is as useful as a pull request. The house rules are in
[PRINCIPLES.md](PRINCIPLES.md).

## Report your hardware

The fastest way to get your ASUS laptop supported is to tell us about it. Open an
[issue](https://github.com/omarchy-asus/omarchy-asus/issues) with:

- **Model:** `cat /sys/class/dmi/id/product_name`
- **Kernel:** `uname -r`
- **Omarchy:** `omarchy version`
- **GPU:** `lspci -nn | grep -Ei 'vga|3d|display'`
- **What's broken:** what you did, what you expected, what happened. One problem per issue.
- **Logs:** the relevant part of `journalctl -b` (or `journalctl -b -1` for the previous
  boot, after a crash or hang), and `dmesg` for driver trouble.

Strip anything personal before you paste: hostnames, usernames, home paths, serial numbers,
MAC addresses, network names.

Things that already work on your model are worth reporting too. They tell us what not to touch.

## How a fix flows

1. **Upstream's shape first.** Omarchy fixes are developed in `omarchy-asus/omarchy`, a fork
   of [omacom/omarchy](https://github.com/omacom/omarchy), written the way Omarchy writes
   hardware support:
   - a **detector** in `bin/omarchy-hw-*` that says whether this machine needs the fix,
   - a **leaf** under `install/` that only runs when the detector matches,
   - a **migration** in `migrations/` so existing installs get it on `omarchy update`,
   - a **test** under `test/`.

   Each fix is developed on its own topic branch, rebased on the fork's `quattro`. `quattro`
   mirrors upstream's `quattro` and nothing else is committed there; a daily workflow on the
   fork's default branch `fork-tools` keeps it in sync. The topic branches are listed in the
   [fork-tools README](https://github.com/omarchy-asus/omarchy/tree/fork-tools). The v4.0.5
   backports the packages ship from are on `asus/v4-0-5`.

   Package changes follow [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)
   conventions in `omarchy-asus/omarchy-pkgs`.
2. **Packaged here when it has to be.** Kernel, driver and compositor fixes ship as patched
   builds from `recipes/` in this repo. Versions are upstream's plus `.1`.
3. **Every patch names its upstream.** The pull request that adds a patch adds its entry to
   [docs/deltas.md](docs/deltas.md), the record of every change we carry (what it fixes, how
   to test it, its upstream state, when to drop it), and updates the recipe's `DELTA` and
   `NOTES.md`. Name the upstream pull request, issue or mailing-list submission there (and in
   `UPSTREAM_PRS` for GitHub pull requests, which the daily check watches). If there is no
   upstream path yet, say why. A carried change gets no issue of its own; issues are for bugs
   and work.
4. **The upstream pull request is the goal.** A fix that only lives here is unfinished. When
   upstream releases it, we drop ours and move its docs/deltas.md entry to "Dropped".

## Pull requests

- **Small.** One fix per pull request. Easier to review, test and send upstream.
- **Tested on real hardware.** Say which model and what you checked. Compile-tested only is
  fine for a draft, not for a merge.
- **Explain the bug.** What breaks, why, and how the change fixes it. Link the issue
  (`Fixes #N`) and the upstream pull request.
- **No behaviour change without a reason.** Defaults stay stock unless the fix requires
  otherwise.
- **For recipes:** follow the rebase steps in the recipe's `NOTES.md`, keep the diff
  against upstream minimal, and make sure every patch applies at fuzz 0.

Suggestions of all kinds are welcome too: open an issue, even if it's just an idea.

## Review

- **The maintainers' own changes** (the maintainer's account and its agents) are reviewed
  inside clud's workflow: the `/do` and `/grind` reviewer and the integrator's `/clud-review`
  gate. They merge once Lint and Build are green on the PR.
- **Pull requests from external contributors** are reviewed by the maintainers, against these
  rules, [AGENTS.md](AGENTS.md) and [PRINCIPLES.md](PRINCIPLES.md), and need the maintainer's
  approving review. `bin/ai-review pr N --post` may be used for that review: inline findings
  you can answer or fix, on GitHub.

## Agents

Agents work through clud's built-in workflow: `clud do <issue>` for one issue and `clud grind`
for a list. Each change goes plan, work, review, integrate, land, and then publish for
packages. The stages, who fills each role, and the gates between them (Lint and Build
required on `main`) are in
[AGENTS.md, "Workflow"](AGENTS.md#workflow-from-issue-to-published-package).

Agents file and update issues through `bin/issue`, which checks for duplicates and scans for
personal information before anything is posted.

See also [PRINCIPLES.md](PRINCIPLES.md).
