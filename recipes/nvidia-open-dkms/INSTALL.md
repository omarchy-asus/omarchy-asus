# nvidia-open-dkms 615.78.08-1.1 (PR #1299 + PR #1412): install when the mirror moves to 615

> Historical note: this was the local-install procedure before the omarchy-asus repo existed. With the repo, the package arrives through pacman; see `LAPTOP-SETUP.md`.

Built 2026-10-16, **not installed**. The package is `nvidia-open-dkms-615.78.08-1.1-x86_64.pkg.tar.zst` in this directory.

## What it is

- Arch's `nvidia-open-dkms` 615.78.08-1 (pkgbase nvidia-utils, trimmed to the DKMS split), with the same two patches as the installed 610.57.04-1.2:
  - `0001`: NVIDIA/open-gpu-kernel-modules#1412 (expaso). `nv_pci_shutdown()` skips teardown while the GPU is still hibernate-suspended, so power-off after the hibernate image is written no longer hangs.
  - `0002`: NVIDIA/open-gpu-kernel-modules#1299 (lars76). NVPCF notifications are coalesced while the GPU is runtime-suspended and replayed after resume. The RTX no longer wakes from D3cold for every 1 % battery change.
- Rebase: both patches applied to 615.78.08 with line offsets only. They were regenerated without offsets, and their `+`/`-` lines are identical to the current PR diffs (`gh pr diff`, 2026-10-16).
- Neither fix is in 615:
  - `nv_pmops_thaw()` is still `return 0` and `nv_pci_shutdown()` is unchanged apart from context.
  - `rm_acpi_nvpcf_notify()` is byte-identical to 610.
  - 615's changes in `dynamic-power.c` are FBSR temp-file reservation and moving where `InHibernate` is cleared. They don't touch the idle state machine the NVPCF patch uses.
- Source tarball sha512 matches Arch's PKGBUILD (`5ced2c7e…`). Packaging is identical to Arch's `package_nvidia-open-dkms` except that `*.orig` files are deleted.
- Compile check (scratchpad, nothing installed or loaded): `make modules` succeeds against both `7.2.5-3-omarchy` and `7.2.3-arch1-3` headers.
  - All five modules are built, and `nvidia.ko` contains `RmDeferNvpcfNotifyIfIdle`, `RmQueueNvpcfReplay` and `RmReplayNvpcfNotify`.
  - The only warnings are objtool "'naked' return found in MITIGATION_RETHUNK build" lines. The running 610 DKMS build has the same warnings (13,768 in its make.log).

## When to install

Only together with the 615 userspace. `nvidia-utils` and `lib32-nvidia-utils` must be the same version as the kernel module, and this package depends on `nvidia-utils=615.78.08`.

- Pacman uses the Omarchy stable mirror, which is frozen at 610.57.04 (snapshot 2026-09-07, omacom/omarchy-mirror#7).
- Check `pacman -Sy && pacman -Si nvidia-utils | grep Version` (or wait for the next `-Syu` to list `nvidia-utils 615.78.08`).

## Install (when the mirror offers 615.78.08)

```bash
# 1. Upgrade everything except the three NVIDIA packages, which stay a consistent 610 set.
sudo pacman -Syu --ignore nvidia-utils,lib32-nvidia-utils,nvidia-open-dkms

# 2. One transaction: the patched module source + the repo's 615 userspace.
#    DKMS builds the module for every installed kernel with headers (watch for "dkms install" errors).
cd <build dir>
sudo pacman -U ./nvidia-open-dkms-615.78.08-1.1-x86_64.pkg.tar.zst $(pacman -Sp nvidia-utils lib32-nvidia-utils)

# 3. Check before rebooting.
pacman -Q nvidia-utils lib32-nvidia-utils nvidia-open-dkms   # all 615.78.08, dkms at -1.1
dkms status nvidia                                            # 615.78.08 installed for each kernel
grep -c NvpcfNotify /usr/src/nvidia-615.78.08/src/nvidia/arch/nvalloc/unix/src/osapi.c   # 1: patch present

# 4. Reboot.
```

After the reboot, check that the patches work without waking the RTX:
- **NVPCF:** on battery, `/sys/bus/pci/devices/0000:64:00.0/power/runtime_status` stays `suspended` across a 1 % battery drop.
- **Hibernate:** one hibernate cycle powers off instead of hanging on a black screen.

## Keeping pacman from replacing it

- **Without anything extra:** `615.78.08-1.1` sorts above the repo's `615.78.08-1`, so later `-Syu` runs keep it. It is replaced silently, without the patches, as soon as the repo ships `615.78.08-2` or any newer driver.
- **Recommended:** add `IgnorePkg = nvidia-open-dkms` under `[options]` in `/etc/pacman.conf`.
  - Pacman then never replaces it. When `nvidia-utils` moves to a new version, the upgrade stops with a dependency error (`nvidia-open-dkms: requires nvidia-utils=615.78.08`) instead of dropping the patches.
  - That error is the signal to rebuild for the new version, or to drop this package if both PRs are merged by then.
- Before rebuilding for a later driver, check whether NVIDIA merged either PR; the NVIDIA README says it folds accepted PRs into its own releases. Then repeat this directory's steps: copy the PKGBUILD, bump `pkgver`, keep `pkgrel=1.1`, update the checksum and regenerate the patches.

## Rollback (to the installed 610 build)

```bash
sudo pacman -U /var/cache/pacman/pkg/nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst \
               /var/cache/pacman/pkg/lib32-nvidia-utils-610.57.04-1-x86_64.pkg.tar.zst \
               <610 build dir>/nvidia-open-dkms-610.57.04-1.2-x86_64.pkg.tar.zst
# reboot
```

The stock 610 module is also cached as `/var/cache/pacman/pkg/nvidia-open-dkms-610.57.04-1-x86_64.pkg.tar.zst`. Keep these three files; don't `paccache -r` them away while this is pending.
