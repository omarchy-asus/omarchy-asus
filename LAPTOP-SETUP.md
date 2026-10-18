# Using the omarchy-asus repo on an Omarchy laptop

> [!WARNING]
> **EXPERIMENTAL. Built for and only meant for the ASUS ROG Zephyrus G16 GA605 (GA605KM).**
> Nobody has installed these packages yet. The kernel carries untested patches, including an experimental scheduler series that is compiled in but switched off.
> Don't add this repo to any other machine. On a G16, use it only if you can recover from a kernel or driver that won't boot (this repo replaces `linux-omarchy`, so keep a second kernel such as Arch's `linux` installed as a boot fallback).

`omarchy-asus` is a signed pacman repo of ASUS-patched builds. It is listed ahead of
`[omarchy]` and `[core]`, so `omarchy update` installs the patched builds in place of
the stock ones. Packages are served from the `x86_64` release of
[omarchy-asus/omarchy-asus](https://github.com/omarchy-asus/omarchy-asus/releases/tag/x86_64).

## 1. Import and locally sign the repo key

Key: `omarchy-asus package signing key`, ed25519, sign-only, no expiry.

Fingerprint: **`0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88`**

```bash
curl -fLo /tmp/omarchy-asus.asc \
  https://raw.githubusercontent.com/omarchy-asus/omarchy-asus/main/keys/omarchy-asus.asc
gpg --show-keys --with-fingerprint /tmp/omarchy-asus.asc   # must show 0B44 FF7C CDD9 29F6 1BE4  A2E4 36FE 6B28 AB24 EC88
sudo pacman-key --add /tmp/omarchy-asus.asc
sudo pacman-key --lsign-key 0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88
```

## 2. `/etc/pacman.d/custom-repos.conf`

```ini
[omarchy-asus]
SigLevel = Required
Server = https://github.com/omarchy-asus/omarchy-asus/releases/download/$arch
```

`SigLevel = Required` covers both the packages and the database, because both are signed.

## 3. Hook: `~/.config/omarchy/hooks/pre-refresh-pacman.d/add-omarchy-asus-repo`

This hook is based on Omarchy's `add-custom-repo.sample`. That sample inserts the repo above `[core]`, but
`[omarchy-asus]` must come before **every** repo it overrides, including `[omarchy]`
(for linux-omarchy). The hook therefore inserts above whichever of `[omarchy]` and `[core]`
comes first. Make it executable (`chmod +x`).

```bash
#!/bin/bash
# Put the omarchy-asus repo ahead of every other repo so its patched builds win
# over the stock ones. See LAPTOP-SETUP.md in
# https://github.com/omarchy-asus/omarchy-asus.
CONF=/etc/pacman.conf
SNIPPET=/etc/pacman.d/custom-repos.conf
MARKER="Include = $SNIPPET"

[[ -r $SNIPPET ]] || exit 0
grep -qxF "$MARKER" "$CONF" && exit 0

sudo sed -i -E "0,/^\[(omarchy|core)\]$/s||$MARKER\n\n&|" "$CONF"
```

Apply it now with `omarchy refresh pacman`, or by running the hook directly. After that it runs on every
refresh.

## 4. Verify

```bash
grep -n -B1 -A1 'custom-repos' /etc/pacman.conf     # Include line sits above the first of [omarchy]/[core]
sudo pacman -Sy
pacman -Sl omarchy-asus                              # lists the repo's packages
pacman -Si omarchy-asus/nvidia-open-dkms | grep -E 'Version|Repository|Packager'
```

If the laptop already has a locally built `nvidia-open-dkms 615.78.08-1.1`, pacman won't
reinstall it, because the version is the same. To check that the local build has the same content as the repo build,
compare the source-tree digest with the one in the recipe's notes (`afe75821…b113a` for
615.78.08-1.1):

```bash
cd /usr/src/nvidia-615.78.08 && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum
```

If the digests differ, `sudo pacman -S omarchy-asus/nvidia-open-dkms` installs the repo copy.

Remove any `IgnorePkg = nvidia-open-dkms` line once the repo is in use. The repo
rebuilds the package when nvidia-utils moves, or drops it so the stock build flows through,
and IgnorePkg would block both.

## 5. Back out

```bash
rm ~/.config/omarchy/hooks/pre-refresh-pacman.d/add-omarchy-asus-repo
sudo sed -i '\|^Include = /etc/pacman.d/custom-repos.conf$|{N;/\n$/d;s|.*\n||}' /etc/pacman.conf   # or: omarchy refresh pacman
sudo rm /etc/pacman.d/custom-repos.conf
sudo pacman-key --delete 0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88
sudo pacman -Syuu        # -uu downgrades the omarchy-asus builds back to stock
```
