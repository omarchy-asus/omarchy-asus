# Distributed builds with distcc (optional)

The build host can farm compiles out to an idle machine on the tailnet. It
uses distcc over SSH: no listening daemon, no firewall rule. The helper runs
`distccd --inetd` only when the build host connects with a dedicated
compile-only key.

## Requirements

- The helper has the **same gcc and binutils** as the build chroot. Two
  Omarchy machines on the same stable snapshot usually match. Check with
  `pacman -Q gcc binutils` on the helper and
  `pacman --root <chroot>/root --dbpath <chroot>/root/var/lib/pacman -Q gcc binutils`.
- The helper is reachable over SSH from the build host.

## Setup

On the **build host**:

```bash
d=~/.local/share/omarchy-asus/distcc
mkdir -p "$d" && chmod 700 "$d"
ssh-keygen -t ed25519 -N '' -C 'omarchy-asus distcc (compile-only)' -f "$d/id_ed25519"
ssh-keyscan -t ed25519 <helper-address> > "$d/known_hosts"
```

On the **helper**, install distcc but don't enable `distccd.service`. Then
authorize the key for one command only:

```text
restrict,from="<build-host-addresses>",command="/usr/bin/distccd --inetd --nice 19 --jobs <helper-threads> --log-level warning" ssh-ed25519 AAAA... omarchy-asus distcc (compile-only)
```

`restrict` turns off shells, forwarding and PTYs; `command=` forces distccd;
`from=` limits the source addresses. The key can't do anything but compile.

In the **build chroot** (`/var/lib/omarchy-asus/chroot/root`), install
`distcc openssh` with `arch-nspawn ... pacman -S`, and create
`/etc/makepkg.conf.d/distcc.conf`:

```bash
BUILDENV=(distcc color !ccache check !sign)
DISTCC_HOSTS="localhost/<build-host-threads> <helper-user>@<helper-address>/<helper-threads>"
MAKEFLAGS="-j<build-host-threads + helper-threads>"
export DISTCC_SSH="ssh -i /distcc/id_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=/distcc/known_hosts -o BatchMode=yes -o ConnectTimeout=5"
```

`bin/build-pkg` mounts `~/.local/share/omarchy-asus/distcc` read-only at
`/distcc` when the key exists (override with `DISTCC_KEY_DIR`). If the helper
is off or busy, distcc compiles locally, so builds never fail because of it.
Linking, Rust and packaging always run on the build host.
