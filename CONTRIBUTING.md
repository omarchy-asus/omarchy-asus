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
   of [basecamp/omarchy](https://github.com/basecamp/omarchy), written the way Omarchy writes
   hardware support:
   - a **detector** in `bin/omarchy-hw-*` that says whether this machine needs the fix,
   - a **leaf** under `install/` that only runs when the detector matches,
   - a **migration** in `migrations/` so existing installs get it on `omarchy update`,
   - a **test** under `test/`.

   Package changes follow [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)
   conventions in `omarchy-asus/omarchy-pkgs`.
2. **Packaged here when it has to be.** Kernel, driver and compositor fixes ship as patched
   builds from `recipes/` in this repo. Versions are upstream's plus `.1`.
3. **Every patch names its upstream.** Add the pull request, issue or mailing-list
   submission to the recipe's `NOTES.md` (and `UPSTREAM_PRS` for GitHub pull requests). If
   there is no upstream path yet, say why.
4. **The upstream pull request is the goal.** A fix that only lives here is unfinished. When
   upstream releases it, we drop ours.

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

Every change is reviewed by someone other than its author.

- **The maintainers' own changes** (the maintainer's account and its agents): Claude Opus 5.5
  writes the change, and Codex `gpt-6.1-sol` reviews it before it merges.
- **Contributors using agents** may pair them the other way round: Codex writes, and Claude
  Opus reviews.
- **Pull requests from external contributors** are reviewed by the maintainers, against these
  rules, [AGENTS.md](AGENTS.md) and [PRINCIPLES.md](PRINCIPLES.md).

This review comes on top of the required CodeRabbit check on `main`.

## Agents

Claude, Codex and other coding agents file and update issues through `bin/issue`, which
checks for duplicates and scans for personal information before anything is posted. The
rules are in [AGENTS.md](AGENTS.md).

See also [PRINCIPLES.md](PRINCIPLES.md).
