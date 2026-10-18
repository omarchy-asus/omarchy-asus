# linux-omarchy (omarchy-asus build)

## Base

- Upstream recipe: `pkgbuilds/linux-omarchy` in omacom/omarchy-pkgs.
- Tracks linux-omarchy **7.2.8-9**, recipe last changed upstream in commit
  `cc664d884b8400accad0e02347c39d6b2cd6b688`
  ("Build linux-omarchy as the BORE kernel instead of a meta package").
- Our version: **7.2.8-9.1**. Builds both split packages from one pkgbase:
  `linux-omarchy` and `linux-omarchy-headers` (headers are required by DKMS
  modules such as nvidia-open-dkms).

## What we change

Compared with upstream, only:

1. `pkgrel=9` -> `pkgrel=9.1` (kernel release string becomes `7.2.8-9.1-omarchy`).
2. New patch `0568-hid-asus-pass-through-rog-nkey-win-lock-reports.patch`,
   added to `source=()` after `0567-...` and with matching entries in
   `b2sums` and `sha256sums`. It adds `QUIRK_HID_WIN_LOCK` to hid-asus for the
   ROG N-Key keyboard (USB 0b05:19b6, `ROG_NKEY_KEYBOARD2`) so Win-key lock
   reports (report 0x5d, opcode 0xbf 0x01) are passed to hidraw instead of
   being dropped with the AURA echo stream.

The patch has no `.sig` (upstream's patch signatures are made by the Omarchy
kernel maintainer's key); its checksums pin it instead. Everything else
(config, other patches, keys) is byte-identical to upstream.

## Upstream status of the patch

Not in mainline (`torvalds/linux` master) or the HID tree (`hid.git` for-next)
as of 2026-10-17: neither contains `QUIRK_HID_WIN_LOCK` or the 0xbf handling.
lore.kernel.org search was not reachable, so whether it has been posted to
linux-input is unknown.

## Verification

`prepare()` applies every `*.patch` with `patch -Np1 --fuzz=0`, so a
successful `makepkg --nobuild` proves all patches apply cleanly. On 7.2.8 all
174 patches (including 0568) apply at fuzz 0 with no offsets.

## Rebasing on a new upstream version

1. Copy upstream's `pkgbuilds/linux-omarchy/` over this directory (keep this
   NOTES.md and the 0568 patch).
2. Add `0568-hid-asus-pass-through-rog-nkey-win-lock-reports.patch` back to
   `source=()` after the last `056x` patch.
3. Set `pkgrel=<upstream pkgrel>.1`.
4. Regenerate the sums for the new patch (`b2sum` / `sha256sum` on the patch)
   and insert them at the matching position in both arrays (or run
   `updpkgsums` and check that only the 0568 lines differ from upstream).
5. In a scratch copy, run `makepkg --nobuild --nodeps --skippgpcheck` and check
   that `prepare()` finishes (fuzz 0 is enforced). If 0568 no longer applies,
   check whether upstream or mainline has picked up an equivalent change and
   drop or refresh the patch.
6. Once a fix like this lands upstream, drop this recipe and use the stock
   package.

Note: when upstream ships a higher pkgrel (e.g. 7.2.8-10), the stock package
outranks ours, so rebase promptly.

## Build notes

- Sources: kernel tarball and `.tar.sign` from cdn.kernel.org (fetched by
  makepkg before the build, not inside `build()`); the rest are local files.
  Nothing in `build()` needs network.
- All makedepends are in Arch core/extra (rust, rust-bindgen, rust-src,
  pahole, ...).
- PGP: the kernel tarball and patch signatures are checked against
  `validpgpkeys`; the public keys are in `keys/pgp/`. Import them into the
  build user's keyring or build with `--skippgpcheck` (checksums still apply).
- Config has DWARF5 debug info and BTF, no LTO: expect a build tree of about
  20-30 GB and roughly 30-60 minutes on 16 cores.
