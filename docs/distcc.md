# Distributed builds with distcc (optional)

The build host can farm compiles out to an idle helper machine. It uses distcc
over SSH: no listening daemon, no firewall rule. The helper runs
`distccd --inetd` only when the build host connects with a dedicated
compile-only key.

This is off by default. Without the key directory below, `bin/build-pkg`
builds exactly as before.

## Requirements

- The helper has the **same gcc and binutils** as the build chroot. Two
  Omarchy machines on the same stable snapshot usually match. Check with
  `pacman -Q gcc binutils` on the helper and
  `pacman --root <chroot>/root --dbpath <chroot>/root/var/lib/pacman -Q gcc binutils`.
- The helper is reachable over SSH from the build host.
- You trust the helper: the object code it returns goes into the packages.

## Trust boundary

`makechrootpkg -U BUILD_USER` runs every recipe's `prepare()`, `build()` and
`package()` as the build user, so that code (and the upstream source it
compiles) can read the mounted key and copy it. The read-only mount stops it
being changed, not read. Treat the key as exposed to every build that mounts it:

- Mount it only for this repo's own recipes: the reviewed `recipes/` and the
  `bin/auto-update` rebuilds of them. Those builds already run the upstream
  source that ends up in the packages, which is worse than a stolen key if
  it is hostile.
- For anything else (an unreviewed pull request, a recipe you are trying
  out), leave the key out: `DISTCC_KEY_DIR= bin/build-pkg recipes/<name>`.
  An empty `DISTCC_KEY_DIR` disables the mount; a path uses that directory
  instead of the default.
- Use a key made for this and nothing else, and limit it on the helper as
  below. A copied key then gets an attacker no more than compiles as an
  unprivileged account, from the build host's addresses.
- To revoke it, delete its line from the helper's `authorized_keys`; make a
  new key the same way.

## Setup

On the **build host**, as the build user:

```bash
d=~/.local/share/omarchy-asus/distcc
mkdir -p "$d" && chmod 700 "$d"
ssh-keygen -t ed25519 -N '' -C 'omarchy-asus distcc (compile-only)' -f "$d/id_ed25519"
ssh-keyscan -t ed25519 <helper-address> > "$d/known_hosts"
ssh-keygen -lf "$d/known_hosts"   # compare with the helper, below
cat > "$d/ssh" <<'EOF'
#!/bin/sh
# DISTCC_SSH wrapper; paths are as seen inside the build chroot.
exec ssh -F none -i /distcc/id_ed25519 -o IdentitiesOnly=yes \
    -o UserKnownHostsFile=/distcc/known_hosts -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -o ConnectTimeout=5 "$@"
EOF
chmod 755 "$d/ssh"
```

On the **helper**, check that the fingerprint matches
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. Install distcc but don't
enable `distccd.service`. Create a dedicated unprivileged account for it (not
your own, no sudo, nothing of value in its home) and authorize the key in that
account's `~/.ssh/authorized_keys` for one command only:

```text
restrict,from="<build-host-addresses>",command="/usr/bin/distccd --inetd --nice 19 --jobs <helper-threads> --log-level warning" ssh-ed25519 AAAA... omarchy-asus distcc (compile-only)
```

- `restrict` turns off shells, port, agent and X11 forwarding, and PTYs.
- `command=` forces distccd. The client asks for
  `distccd --inetd --enable-tcp-insecure`; the forced command replaces that,
  so leave `--enable-tcp-insecure` out of it: without it distccd only runs
  compilers listed in `/usr/lib/distcc`, and it always refuses `-fplugin=` and
  `-specs=`.
- `from=` limits the source addresses.

The key can only compile, as that account. Compiler options can still make
gcc run other programs, so give the account nothing it would matter to lose.

In the **build chroot** (`/var/lib/omarchy-asus/chroot/root`), install
`distcc openssh` with `arch-nspawn ... pacman -S`, and create
`/etc/makepkg.conf.d/distcc.conf`:

```bash
BUILDENV=(distcc color !ccache check !sign)
DISTCC_HOSTS="localhost/<build-host-threads> <helper-account>@<helper-address>/<helper-threads>"
MAKEFLAGS="-j<build-host-threads + helper-threads>"
export DISTCC_SSH=/distcc/ssh
```

`DISTCC_SSH` names the wrapper and nothing else: `man distcc` says the value
is not split into words or run through a shell. distcc 3.4 does split it on
single spaces, but keeps at most 12 arguments and drops the rest without a
word, so options there are fragile. Put them in the wrapper.
`<helper-address>` must be the name `known_hosts` was made for.

`bin/build-pkg` mounts `~/.local/share/omarchy-asus/distcc` read-only at
`/distcc` when `id_ed25519` is there (see `DISTCC_KEY_DIR` above). If the
helper is off or busy, distcc compiles locally, so builds never fail because
of it. Linking, Rust and packaging always run on the build host.

## Persistent ccache (optional)

A compiler cache that survives the clean chroot makes small-patch kernel
rebuilds reuse almost every object. Set it up on the build host:

```bash
mkdir -p ~/.local/share/omarchy-asus/ccache
sudo arch-nspawn -C build/pacman.conf <chroot>/root pacman -S --needed ccache
```

Enable `ccache` in the chroot's `BUILDENV` (with distcc enabled too, makepkg
chains them as `CCACHE_PREFIX=distcc`), and create
`<chroot>/root/etc/makepkg.conf.d/ccache.conf`:

```bash
export CCACHE_DIR=/ccache
export CCACHE_MAXSIZE=40G
export CCACHE_BASEDIR=/build
export CCACHE_NOHASHDIR=1
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,locale
```

`bin/build-pkg` mounts the cache dir read-write at `/ccache` when it exists.
Create the directory before enabling ccache in the chroot: with ccache on and
nothing mounted at `/ccache`, compiles fail.
