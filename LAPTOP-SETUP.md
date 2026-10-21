# Using the omarchy-asus repo on an Omarchy laptop

> [!WARNING]
> **EXPERIMENTAL. Built for and only meant for the ASUS ROG Zephyrus G16 GA605 (GA605KM).**
> Nobody has installed these packages yet. The kernel carries untested patches, including an experimental scheduler series that is compiled in but switched off.
> Don't add this repo to any other machine. On a G16, use it only if you can recover from a kernel or driver that won't boot (this repo replaces `linux-omarchy`, so keep a second kernel such as Arch's `linux` installed as a boot fallback).

`omarchy-asus` is a signed pacman repo of ASUS-patched builds. It is listed ahead of
`[omarchy]` and `[core]`, so `omarchy update` installs the patched builds in place of
the stock ones. Packages are served from the `x86_64` release of
[omarchy-asus/omarchy-asus](https://github.com/omarchy-asus/omarchy-asus/releases/tag/x86_64).

There are two ways to set it up. They give the same result:

- **One step:** run `bin/omarchy-asus-setup` (below).
- **Manual:** follow sections 1 to 4. Section 5 is for removing it again.

Read [Switching an existing install](#switching-an-existing-install) first either way.

## One-step setup

Download the script, read it, then run it as your normal user. It calls `sudo` itself where it needs root.

```bash
curl -fLO https://raw.githubusercontent.com/omarchy-asus/omarchy-asus/main/bin/omarchy-asus-setup
less omarchy-asus-setup                  # read it before you run it
bash omarchy-asus-setup --dry-run        # optional: print every privileged step without running it
bash omarchy-asus-setup
```

The script:

1. Stops unless the DMI product or board name contains `GA605`. `--force` skips this check, and
   also lets the upgrade in step 8 go ahead when no snapshot could be taken.
2. Prints the EXPERIMENTAL warning and asks you to confirm. If no fallback kernel is installed, it
   offers to install Arch's `linux` and `linux-headers` first (from the databases you already have,
   so no partial upgrade), and DKMS builds the NVIDIA module for both kernels. It also warns if
   `IgnorePkg` holds back a package this repo ships.

   It also looks for an out-of-tree hid-asus DKMS source in `/usr/src` (see step 4 of
   [Switching an existing install](#switching-an-existing-install)). When no package owns the
   source and the running kernel is the omarchy-asus `linux-omarchy` (a `.N` pkgrel such as
   `7.2.8-9.1`, which carries patch 0568), it offers to retire it. It runs
   `dkms remove <module>/<version> --all` when the module is registered, then moves the source to
   `/usr/local/src/dkms-disabled/`. It never deletes it: an existing backup gets a
   `.before-omarchy-asus` name instead. It prints the command that undoes the move. On any other
   kernel, or when a package owns the source, it only warns, as before.

   For each fallback kernel you have installed (`linux`, `linux-lts`, `linux-zen`,
   `linux-hardened`), it warns when:
   - its `-headers` package is missing;
   - `dkms status` shows no installed NVIDIA build for its kernel release;
   - `/boot/limine.conf` has no entry for it (read with `sudo -n`, so it never asks for a
     password);
   - the login records (`last -x reboot`, or `wtmpdb last reboot`) show it has never booted. It
     suggests you boot it once before the switch.

   These only warn and don't stop the script: login records can be rotated, and a kernel that has
   never booted may still be fine.
3. Downloads `keys/omarchy-asus.asc` over HTTPS. If the key isn't exactly the one with fingerprint
   `0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88` (hardcoded in the script), it stops. Otherwise it runs
   `pacman-key --add` and `pacman-key --lsign-key`.
4. Lists the packages in the repo's signed database next to the versions you have installed.
5. Writes `/etc/pacman.d/custom-repos.conf` and the pre-refresh hook with the same content as
   sections 2 and 3. Any other repos you keep in `custom-repos.conf` stay. It then applies the hook, so
   the `Include` line sits above the first of `[omarchy]` and `[core]`.
6. Installs `omarchy-asus-keyring`, which ships the key in `/usr/share/pacman/keyrings/` so that
   `pacman-key --populate omarchy-asus` works, like `archlinux-keyring` and `omarchy-keyring`.
   This step runs `pacman -Sy`.
7. If you run your own power manager (a `rog-power.service` in `~/.config/systemd/user`,
   `/etc/systemd/user` or `/etc/systemd/system`), asks before the upgrade which owner of the
   power profile to keep, so they don't both switch it on every charger change. Keeping yours sets
   Omarchy's `powerprofiles-autoswitch-off` toggle, and the patched Omarchy leaves the profile to
   it. Handing over to Omarchy disables `rog-power.service` and moves it aside (and the toggle, if
   set) under a `.before-omarchy-asus` backup name, checks that
   `omarchy-powerprofiles-source-monitor` is enabled, lists the root helpers and sudoers rules
   that came with your tool without touching them, and prints the undo commands. After a hand-over,
   running setup again skips this step.
8. Lists what the system upgrade would change, marking the packages from `[omarchy-asus]`, and
   upgrades only if you say yes. The upgrade runs through `omarchy update`, which asks once more,
   takes a snapshot and runs Omarchy's migrations. Since Omarchy 4.0.5 a pacman hook stops a bare
   `pacman -Syu`, so the script doesn't run one.

   Before it offers the upgrade, the script takes its own snapper snapshot
   (`snapper -c root create -c number -d 'before omarchy-asus'`) and checks that it appears in
   `snapper -c root list`. If snapper has no `root` config or the snapshot fails, it doesn't offer
   the upgrade (`--force` overrides this). `omarchy update` carries on without a snapshot when its
   own fails, and the snapshot is the only way back from a bad driver or Omarchy migration: every
   kernel shares `nvidia-open-dkms`, Hyprland and the omarchy packages, so a fallback kernel doesn't
   help there. `--dry-run` prints the snapper command, and still refuses when snapper isn't
   configured.

   Before the upgrade, the script also checks every `/etc` file that the repo's upgraded packages install
   against the repo's signed files database. A file that no package owns stops pacman's upgrade with
   an `exists in filesystem` conflict, and `omarchy update` passes `--overwrite` only for
   `/usr/share/omarchy`. An example is the asusd drop-in
   `/etc/systemd/system/asusd.service.d/10-omarchy-power-profiles.conf`, installed by hand for #21,
   which `omarchy-settings 4.0.5-1.1` now ships.
   - If the file is byte-identical to the packaged copy, the script says so. During `omarchy update`
     it moves the file to `/var/lib/omarchy-asus/replaced/`, so the package installs the same bytes,
     and it names each path it took over. If the upgrade doesn't install the file, it goes back.
   - If the file differs, the script shows the diff and stops before the upgrade. Nothing is
     overwritten. Decide yourself (move the file aside or make it match), then run the script again.
9. Optional, and only if the system is fully upgraded: offers to install `omarchy-asus-g16`,
   `asus-rog-nkey-winlock` and `omarchy-asus-g16-apply`.

   Before it installs them, the script checks their `/etc` files against the signed files database,
   with the same rule as the upgrade in item 8.
   - If a file that no package owns is byte-identical to the packaged copy, the script hands it to
     the package with `pacman --overwrite <that path>`.
   - If the file differs, the script shows the diff and doesn't install the G16 packages. Nothing
     changes. Move the file aside or make it match, then run the script again.

   If you have your own Win-lock setup, it offers to move it aside:
   - Your own `~/.config/systemd/user/g16-winlock.service`, which would shadow the packaged unit.
     It runs `systemctl --user disable` first, so the old `default.target.wants` link goes away,
     then moves the unit to `g16-winlock.service.before-omarchy-asus`.
   - That unit's `g16-winlock.service.d/` drop-in. It shows the settings in it, then moves it to
     `g16-winlock.service.d.before-omarchy-asus`. A drop-in with no hand-made unit behind it (the
     G16 Control widget writes one for the packaged unit) stays. A `mode.conf` written by
     `g16ctl winlock-mode` (the G16 Control widget's Win-lock mode) is never moved aside. If an
     older run of the script already moved the unit, a drop-in is moved only if it predates that
     move. If a hand-made drop-in that gets moved also holds a G16 Control `mode.conf`, that
     `mode.conf` is put back, so the mode you chose stays.
   - An `/etc/udev/rules.d/*g16-winlock*.rules` file. With sudo, it moves it aside with the same
     suffix and reloads udev.
   - A `~/.local/bin/g16-winlock` that shadows `/usr/bin/g16-winlock`. It warns about this one
     even when it is the only local Win-lock piece left. It only warns; it doesn't move it.

   Nothing is deleted except the old unit's dangling links. An existing backup is never overwritten: a numbered
   `.before-omarchy-asus.N` name is used instead. Each piece it moves is listed with the command
   that undoes it, and `--dry-run` prints every step. It then shows `omarchy-asus-g16-apply --check`,
   and applies the missing default fixes if you say yes. Fixes you already have in your own form
   are left alone. With the patched omarchy installed, most rows show `present` because its
   migrations already applied them; only the speaker level (`audio-master`) and the opt-ins
   remain manual. See [`recipes/omarchy-asus-g16-apply/README.md`](recipes/omarchy-asus-g16-apply/README.md).

   It also looks for local copies of fixes `omarchy-asus-g16` ships:
   - A rule of your own in `/etc/udev/rules.d` that disarms the ASUF1209 touchpad wake
     (`power/wakeup`), which no package owns. With sudo, it offers to move it aside with the same
     `.before-omarchy-asus` suffix, and an existing backup is never overwritten. It reloads udev,
     re-triggers the touchpad and lists the command that undoes it. `omarchy-asus-g16` ships the
     same rule as `/usr/lib/udev/rules.d/99-omarchy-asus-g16-touchpad-wake.rules`.
   - A `HibernateMode=` line in `/etc/systemd/sleep.conf` or `/etc/systemd/sleep.conf.d/*.conf`.
     It only reports it, with its file and line number, because the file may hold other settings
     you want to keep. `omarchy-asus-g16` sets `HibernateMode=shutdown` in
     `/usr/lib/systemd/sleep.conf.d/omarchy-asus-g16-hibernate-mode.conf`. Delete the line yourself
     once you don't need it. A value other than `shutdown` gets a warning, because it can override
     the packaged one.

   `--dry-run` prints the move without making it.

> [!IMPORTANT]
> The fingerprint check is trust on first use. The script, the key and this page all come from
> the same GitHub account, so the check proves only that the downloaded key matches the script.
> Before you trust the key, compare the fingerprint with one you got another way. The key is also
> published on a keyserver that isn't GitHub:
>
> ```bash
> curl -fsS https://keys.openpgp.org/vks/v1/by-fingerprint/0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88 \
>   | gpg --show-keys --with-fingerprint
> ```
>
> Both copies must show `0B44 FF7C CDD9 29F6 1BE4  A2E4 36FE 6B28 AB24 EC88`. You can also ask the
> maintainer.

The script applies the hook itself and does not run `omarchy refresh pacman`. That command ends in
`pacman -Syyuu --noconfirm`, which would upgrade before you saw the list. Later
`omarchy refresh pacman` runs keep the repo in place, through the hook.

You can run the script again safely: steps that are already done are left alone.

To undo everything (the same steps as section 5), run `bash omarchy-asus-setup --uninstall`.
Before its `-Syuu` prompt it prints the NVIDIA/open-gpu-kernel-modules#1412 hibernate warning
from section 5. After the `-Syuu` it offers to remove the packages that only this repo ships. The
default is no.

## Release channels

Our repo has two channels, each pinned to one of Omarchy's (README.md, "Release channels"):
Quattro (the `x86_64` release) goes with Omarchy stable, RC (the `rc-x86_64` release, Omarchy 4.5
release candidates) with Omarchy rc. Never mix them: Omarchy's migrations may install packages only
its matching repo has, and one failed migration holds back every later one. The first setup picks
the channel that matches your `[omarchy]` server. To switch later, move both together:

```bash
bash omarchy-asus-setup --channel rc        # [omarchy] to Omarchy rc, [omarchy-asus] to rc-x86_64
bash omarchy-asus-setup --channel quattro   # both back; pacman -Syyuu downgrades to the Quattro versions
```

It checks that the target release's signed database exists, takes a snapshot (`--force` goes on
without one), rewrites the `[omarchy-asus]` server in `/etc/pacman.d/custom-repos.conf`, then runs
Omarchy's own `omarchy-channel-set` (it rewrites `/etc/pacman.conf` and the mirrorlist, the hook
from section 3 puts the Include line back, runs `pacman -Syyuu` and the migrations). `--dry-run`
prints the steps. If the upgrade or a migration fails, the switch stays marked unfinished
(`~/.local/state/omarchy-asus/channel-switch-pending`): fix the error and run the same command
again, and it runs the switch again instead of reporting it done.

## Switching an existing install

Do it in this order on a G16 that already runs stock Omarchy. The script does step 2 and the upgrade
at the end of step 3. Do the rest by hand: in particular, remove the `IgnorePkg` entries yourself
before you run the script. The script only warns about them.

0. **Make sure you can get back if this fails.** Keep a fallback kernel installed with its headers
   (`sudo pacman -S linux linux-headers`). Check that `dkms status` lists an installed nvidia build
   for it and that the Limine boot menu has an entry for it, then boot it once before the switch.

   A fallback kernel only covers a bad kernel. The driver, Hyprland and the omarchy packages are
   shared by every kernel, so for those the snapshot taken before the upgrade is the only way back.
   Check `sudo snapper list` and take one (`sudo snapper -c root create -d 'before omarchy-asus'`);
   the script does this itself before it offers the upgrade.

   Section 4 of [`bin/g16-check`](bin/g16-check) ("Way back") reports all of this read-only, as
   PASS or WARN, including whether a snapshot newer than the last pacman transaction exists.
1. **Read-only audit.** Write down what you have now:

   ```bash
   pacman -Q linux-omarchy linux-omarchy-headers nvidia-utils lib32-nvidia-utils nvidia-open-dkms hyprland hyprpm aquamarine
   grep -n IgnorePkg /etc/pacman.conf
   dkms status
   ```

2. **Add the key, `custom-repos.conf` and the hook before any `omarchy refresh pacman`.** A refresh
   rewrites `/etc/pacman.conf` and runs `pacman -Syyuu`. Without the `Include` line, the `-uu`
   downgrades the patched builds back to stock.
3. **Remove the `IgnorePkg` entries** for `nvidia*`, `hyprland` and `aquamarine`, then upgrade with
   `omarchy update`, or say yes to the script's prompt. nvidia, hyprland/hyprpm and
   linux-omarchy with its headers update in one transaction, and DKMS rebuilds nvidia for the new kernel.

   Before you upgrade by hand, check for `/etc` files that the repo packages but no package owns
   (section 2 of [`bin/g16-check`](bin/g16-check) lists them). If you upgrade without the script and
   pacman reports `<path> exists in filesystem` for one of them, compare it with the packaged copy
   first. Only if they are identical, run
   `sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu --overwrite <that path>` (one path, never a
   glob). `omarchy update` can't do it for you: it passes `--overwrite` only for `/usr/share/omarchy`.
4. **Out-of-tree hid-asus module.** If you used an out-of-tree hid-asus DKMS module for Win-lock, it
   no longer builds against the patched kernel, so expect one DKMS error. The patched kernel has
   the fix built in, so removing the module first makes no difference to how the laptop behaves:
   `sudo dkms remove <module>/<version> --all`.

   `dkms remove` is not enough when the source dir was installed by hand. Arch's DKMS hook adds
   every `/usr/src/<name>-<version>/dkms.conf` again on each kernel update, so the module comes
   back (and prints a build error every update). Check who owns it; `bin/g16-check` also reports
   which case applies:

   ```bash
   pacman -Qo /usr/src/<module>-<version>
   ```

   If a package owns it, remove that package instead:

   ```bash
   sudo pacman -Rns <package>
   ```

   If no package owns it, move the source out of `/usr/src`:

   ```bash
   sudo mkdir -p /usr/local/src/dkms-disabled
   sudo mv /usr/src/<module>-<version> /usr/local/src/dkms-disabled/
   ```

   Once the patched kernel is running, `omarchy-asus-setup` offers to do this move for you (see
   step 2 of the script, above).

   Move it rather than delete it: it may be your only copy of the patch. Move it out of
   `/usr/src`, because a renamed dir inside `/usr/src` still matches the hook.
5. **Reboot and check.** [`bin/g16-check`](bin/g16-check) (read-only) checks most of this and
   prints PASS/WARN/FAIL; `bin/g16-check --live` also waits for Fn+Super. By hand:
   - `uname -r` ends in `-9.1-omarchy`.
   - Fn+Super toggles the Win-lock.
   - An external display looks right after you unplug and replug HDMI.
   - Hibernate and resume work.
6. **Remove leftovers** from the earlier workarounds: locally built packages, DKMS sources
   (see step 4: move unowned ones out of `/usr/src`) and stale `IgnorePkg` lines.

## Manual setup

Sections 1 to 4 do by hand what the script does. Section 4 is a good check after either method.
Section 5 undoes the setup, by hand or with `omarchy-asus-setup --uninstall`.

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
On Omarchy's rc channel, use the RC release instead (`.../releases/download/rc-$arch`; see
[Release channels](#release-channels)).

## 3. Hook: `~/.config/omarchy/hooks/pre-refresh-pacman.d/add-omarchy-asus-repo`

This hook is based on Omarchy's `add-custom-repo.sample`. Since Omarchy 4.0.5 that sample inserts the
repo above `[omarchy]`; earlier versions inserted it above `[core]`, which is below `[omarchy]`.
`[omarchy-asus]` must come before **every** repo it overrides, including `[omarchy]` (for
linux-omarchy). The hook therefore inserts above whichever of `[omarchy]` and `[core]` comes first,
on any version. Make it executable (`chmod +x`).

Don't enable a second hook that inserts the same `Include` line, such as an older copy of the
sample. Hooks run in name order, and the first one to add the line decides where it goes.

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

This removes only the `[omarchy-asus]` section from `custom-repos.conf`. The file and its `Include`
line are deleted only if no other repos are left in it. `omarchy-asus-setup --uninstall` does the
same.

Read this before the final `pacman -Syuu` line. Going back downgrades `nvidia-open-dkms` to the
stock build, and the stock build lacks the NVIDIA/open-gpu-kernel-modules#1412 fix. On a GA605KM
the machine can then hang at power-off after it writes the hibernate image (#11).
Suspend-then-hibernate is the default lid action, so the battery can drain overnight. You have two
options. Keep a locally patched driver: for example, add `nvidia-open-dkms` to `IgnorePkg` in
`/etc/pacman.conf` before you run `-Syuu`. Or disable hibernation until NVIDIA/open-gpu-kernel-modules#1412 lands.
`omarchy-asus-setup --uninstall` prints this warning before its `-Syuu` prompt.

```bash
rm ~/.config/omarchy/hooks/pre-refresh-pacman.d/add-omarchy-asus-repo
f=/etc/pacman.d/custom-repos.conf
sudo sed -i '/^\[omarchy-asus\]$/,/^\[/{/^\[omarchy-asus\]$/d;/^\[/!d}' "$f"   # drop only our section
if ! grep -q '[^[:space:]]' "$f"; then   # no other repos left: remove the file and its Include line
  sudo sed -i '\|^Include = /etc/pacman.d/custom-repos.conf$|{$d;N;/\n$/d;D}' /etc/pacman.conf
  sudo rm "$f"
fi
pacman -Q omarchy-asus-keyring && sudo pacman -R omarchy-asus-keyring   # if installed
sudo pacman-key --delete 0B44FF7CCDD929F61BE4A2E436FE6B28AB24EC88
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syuu   # -uu downgrades the omarchy-asus builds back to stock
```

The `-Syuu` returns `hyprland` and `hyprpm` to the stock builds.

Packages that only this repo ships stay installed, and they stop getting updates. These are
`omarchy-asus-g16` (it sets `HibernateMode=shutdown`, #16), `omarchy-asus-g16-apply`,
`asus-rog-nkey-winlock` and `asus-zephyrus-g16-control`. Removing `omarchy-asus-g16` restores the
stock hibernate mode. List what is left, then remove what you don't want:

```bash
pacman -Qm
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Rns <pkgs>
```

`omarchy-asus-setup --uninstall` offers to remove these leftovers after the `-Syuu`. The default
is no.
