**EXPERIMENTAL. Built for and only meant for the ASUS ROG Zephyrus G16 GA605 (GA605KM).**

**RC channel.** These packages are built from the `next/omarchy-4.5` branch against Omarchy's release-candidate channel (`pkgs.omarchy.org/rc` and `rc-mirror.omarchy.org`). Use this repo only on a machine whose `[omarchy]` repo and mirrorlist are on Omarchy's rc channel too, and switch both together: `omarchy-asus-setup --channel rc` moves both to RC, `omarchy-asus-setup --channel quattro` moves both back to Omarchy stable and the `x86_64` release, downgrading to its versions. Mixing an RC repo with Omarchy stable (or the other way round) breaks upgrades: a failed migration holds back every later one.

This is a signed pacman repo of patched builds for one laptop model. Nobody has installed these packages yet. Keep a second kernel such as Arch's `linux` installed as a boot fallback.

The assets here are the repo itself: packages, signatures and the signed database. They are replaced in place as packages are rebuilt, so this isn't a versioned release. See README.md and LAPTOP-SETUP.md in https://github.com/omarchy-asus/omarchy-asus for what is included and how to set it up.
