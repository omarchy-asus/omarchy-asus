# hid-asus-winlock (DKMS)

The stock `hid-asus` drops the ROG N-Key keyboard's (0b05:19b6) Win-lock
notifications along with its AURA echo stream, so `bin/g16-winlock` never sees
Fn+Super toggle the lock. `winlock.patch` passes report 0x5d / opcode 0xbf
through to hidraw (`QUIRK_HID_WIN_LOCK`). Upstream submission:
`plans/hid-asus-winlock/`.

## How a build picks its source

`variants/*/` each hold an **unpatched** `hid-asus.c` + `hid-ids.h` taken from a
real kernel. For every kernel DKMS builds for, `build.sh` compiles each variant
as-is and compares it with that kernel's own stock `hid-asus.ko`: the machine
code (`.text`) and the device-ID table (`modinfo -F alias`) must be identical.
The first match gets `winlock.patch` and is built; that proves the patched
driver is the kernel's own driver plus the patch and nothing else (linux-omarchy
carries its own hid-asus patch, 0566, which a wrong source would silently drop).

No match means `build.sh` exits 1, DKMS installs nothing, and the stock driver
keeps running: the keyboard works, only the Win-lock toast is missing. Point
releases that did not touch hid-asus keep matching, so they need nothing.

(`srcversion` is not usable as the fingerprint: it also hashes build paths, and
an out-of-tree build of the exact stock source does not reproduce it. `.text`
does, byte for byte, with the same compiler; `.rodata` does not, it holds paths.)

| variant | source |
|---|---|
| `arch-v7.2.3` | Arch `v7.2.3-arch1` drivers/hid |
| `omarchy-v7.2.5-3` | kernel.org v7.2.5 + omarchy-pkgs 7b11c97 `0566-hid-asus-no-keyboard-init-reports-to-touchpads.patch` |

## When a kernel update refuses to build

`dkms status` shows the new kernel without hid-asus-winlock. Add its source:

    v=7.3.1      # upstream version the new kernel is based on
    d=variants/omarchy-v7.3.1-1 && mkdir -p $d && cd $d
    for f in hid-asus.c hid-ids.h; do
      curl -fo $f "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/hid/$f?h=v$v"
    done
    # then apply that kernel package's own drivers/hid/hid-asus.c patches, if any
    # (for linux-omarchy: grep the omarchy-pkgs PKGBUILD's patches at that version)

Check it matches before installing: `dkms build hid-asus-winlock/1 -k <kver>`
fails until the variant reproduces the stock driver. `winlock.patch` must still
apply; refresh it if hid-asus moved under it.

## Install

    sudo cp -r . /usr/src/hid-asus-winlock-1
    sudo dkms install hid-asus-winlock/1 -k <kver>     # once per installed kernel
    sudo limine-mkinitcpio                             # hid-asus loads from the
                                                       # initramfs, before root
Future kernels: pacman's 70-dkms-install hook builds it before
90-mkinitcpio-install builds the boot image, so nothing to do.

Verify after boot: `cat /sys/module/hid_asus/srcversion` equals
`modinfo -F srcversion hid-asus` (the DKMS copy), and Fn+Super shows the
g16-winlock toast.
