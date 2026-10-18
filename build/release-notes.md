**EXPERIMENTAL. Built for and only meant for the ASUS ROG Zephyrus G16 GA605 (GA605KM).**

This is a signed pacman repo of patched builds for one laptop model. Nobody has installed these packages yet. The kernel carries untested patches, including an experimental scheduler series that is compiled in but switched off. Don't add this repo to any other machine. On a G16, use it only if you can recover from a kernel or driver that won't boot (this repo replaces `linux-omarchy`, so keep a second kernel such as Arch's `linux` installed as a boot fallback).

The assets here are the repo itself: packages, signatures and the signed database. They are replaced in place as packages are rebuilt, so this isn't a versioned release. See README.md and LAPTOP-SETUP.md in https://github.com/omarchy-asus/omarchy-asus for what is included and how to set it up.
