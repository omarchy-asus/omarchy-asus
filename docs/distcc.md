# Distributed builds with distcc (optional)

The build host can farm compiles out to an idle helper machine. It uses distcc
over SSH: no listening daemon, no firewall rule. The helper runs
`distccd --inetd` only when the build host connects with a dedicated
compile-only key.

This is off by default. Without the key directory below, `bin/build-pkg`
builds exactly as before.

## Requirements

- The helper has the **same gcc and binutils** as the build chroot, down to
  the package release. This is checked on every connection (Toolchain check,
  below): on a mismatch the helper refuses and every job compiles on the build
  host, so a helper that falls behind (or gets ahead) costs speed, not
  packages. Compare them with `pacman -Q gcc binutils` on the helper and
  `pacman --root <chroot>/root --dbpath <chroot>/root/var/lib/pacman -Q gcc binutils`.
  The chroot follows the Omarchy snapshot in `build/pacman.conf`, so keep the
  helper on the same one.
- The helper is reachable over SSH from the build host.
- You trust the helper: the object code it returns goes into the packages.

## Trust boundary

`makechrootpkg -U BUILD_USER` runs every recipe's `prepare()`, `build()` and
`package()` as the build user, so that code (and the upstream source it
compiles) can read the mounted key and copy it. The read-only mount stops it
being changed, not read. Treat the key as exposed to every build that mounts it:

- Mount it only for this repo's own recipes: the reviewed `recipes/` and the
  unattended upstream rebases of them. Those builds already run the upstream
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
- The PR check's kernel job can use the helper too, from the build host's
  runner, with a key of its own and only for this repository's own branches
  (docs/kernel-runner.md).

## Setup

On the **build host**, as the build user:

```bash
d=~/.local/share/omarchy-asus/distcc
mkdir -p "$d" && chmod 700 "$d"
ssh-keygen -t ed25519 -N '' -C 'omarchy-asus distcc (compile-only)' -f "$d/id_ed25519"
ssh-keyscan -t ed25519 <helper-address> > "$d/known_hosts"
ssh-keygen -lf "$d/known_hosts"   # compare with the helper, below
install -m 755 build/distcc-ssh "$d/ssh"   # from this checkout
```

`build/distcc-ssh` is the `DISTCC_SSH` wrapper; its paths are as seen inside
the build chroot. `bin/build-pkg` mounts the key dir only while `$d/ssh` is
byte for byte the `build/distcc-ssh` next to the `bin/` it runs from (for the
root-run pipeline, the installed copy), so re-run the `install` line when the
wrapper changes. Until then builds run without distcc and say so.

On the **helper**, check that the fingerprint matches
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. Install distcc but don't
enable `distccd.service`. Install the gate as root, from a checkout of this
repo: `install -o root -g root -m 755 build/distccd-gate /usr/local/bin/distccd-gate`.
Create a dedicated unprivileged account for it (not your own, no sudo, nothing
of value in its home) and authorize the key in that account's
`~/.ssh/authorized_keys` for one command only:

```text
restrict,from="<build-host-addresses>",command="/usr/local/bin/distccd-gate --nice 19 --jobs <helper-threads> --log-level warning" ssh-ed25519 AAAA... omarchy-asus distcc (compile-only)
```

- `restrict` turns off shells, port, agent and X11 forwarding, and PTYs.
- `command=` forces the gate, which runs `distccd --inetd` with the arguments
  given here (Toolchain check, below). The client asks for
  `distccd --inetd --enable-tcp-insecure`; the forced command replaces that,
  so `--enable-tcp-insecure` is never used: without it distccd only runs
  compilers listed in `/usr/lib/distcc`, and it always refuses `-fplugin=` and
  `-specs=`.
- `from=` limits the source addresses.

The key can only compile, as that account. Compiler options can still make
gcc run other programs, so give the account nothing it would matter to lose.

In **each build chroot** (`/var/lib/omarchy-asus/chroot/root`, and the RC
channel's `/var/lib/omarchy-asus/chroot-rc/root` once `bin/mkchroot --channel rc`
has made it), install `distcc openssh` with `arch-nspawn <chroot>/root pacman -S`,
and create `/etc/makepkg.conf.d/distcc.conf`:

```bash
BUILDENV=(distcc color !ccache check !sign)
DISTCC_HOSTS="<helper-account>@<helper-address>/<helper-threads> localhost/<local-slots>"
MAKEFLAGS="-j<helper-threads + local-slots>"
export DISTCC_SSH=/distcc/ssh
# with the key mounted, distcc compiles ccache's preprocessor output as it is;
# an if, not &&: a file that ends in a false test fails makepkg's source check
if [[ -d /distcc ]]; then export CCACHE_NOCPP2=1; fi
```

The helper comes first. distcc fills `DISTCC_HOSTS` from the left, so the
helper takes the first `<helper-threads>` jobs and the build host the rest, and
`make -j` covers both. With `localhost/<n>` first, the helper only got the jobs
the build host's own slots didn't take, and a release build, mostly ccache hits
by then, rarely runs more than `n` real compiles at once: a whole 7.2.8-9.4
kernel build sent it 4 jobs out of about 25,500 (#221).

The build host still preprocesses every file the helper compiles, so leave it
CPU for that: `<local-slots>` below its thread count (12 of 16 here). And
`CCACHE_NOCPP2` stops ccache preprocessing a second time: by default ccache
runs the preprocessor for its hash and then hands distcc the source, which
preprocesses it again. distcc already compiles preprocessed source on the
helper; this does the same for the jobs it keeps. It is set only when the key
is mounted, so builds without distcc keep ccache's default.

A cold compile of the kernel's `fs/` tree in the RC chroot (1,422 jobs; a
16-thread build host, an 8-thread helper):

| setup | seconds | on the helper |
|---|---|---|
| build host only, `-j24` | 214 | 0 |
| helper first, `localhost/16`, `-j24` | 202 | 485 |
| helper first, `localhost/12`, `-j20`, `CCACHE_NOCPP2` | 172 | 511 |

The wrapper shares one SSH connection between jobs (`ControlMaster`, socket in
the build's own `/tmp`), so a job costs a new session on that connection
rather than a new SSH handshake. Each session still runs the helper's forced
command, so every job is still checked against the toolchain (below).

`DISTCC_SSH` names the wrapper and nothing else: `man distcc` says the value
is not split into words or run through a shell. distcc 3.4 does split it on
single spaces, but keeps at most 12 arguments and drops the rest without a
word, so options there are fragile. Put them in the wrapper.
`<helper-address>` must be the name `known_hosts` was made for.

`bin/build-pkg` mounts `~/.local/share/omarchy-asus/distcc` read-only at
`/distcc` when `id_ed25519` is there (see `DISTCC_KEY_DIR` above). Without
`openssh` in the chroot the wrapper can't connect and every job would compile
on the build host, so `bin/build-pkg` leaves the key out and says
`distcc: off: the <channel> chroot has no /usr/bin/ssh` (#221). If the
helper is off, busy or refuses, distcc compiles locally. Linking, Rust and
packaging always run on the build host.

## Toolchain check

distcc preprocesses on the build host and compiles on the helper with the
helper's own `gcc`. If the two differ, the build breaks or, worse, builds
differently: with the chroot on GCC 16 and the helper on another gcc,
hyprland 0.56.2-4.2 failed with dozens of `redefinition of ...` errors in
libstdc++'s `<stop_token>` and `cc1plus: note: unrecognized command-line
option`, and its package was unpublished (#163).

So every connection is checked against both sides' installed versions as they
are at that moment (the chroot is updated at the start of each build, the
helper whenever it is upgraded):

1. `build/distcc-ssh`, inside the chroot, adds
   `omarchy-asus-toolchain=gcc-<ver>,binutils-<ver>` (from
   `pacman -Q gcc binutils`) to the command it asks the helper for. If it
   can't read them, it doesn't connect.
2. `build/distccd-gate`, the helper's forced command, compares that with its
   own `pacman -Q gcc binutils` and starts distccd only if they are the same.
   A mismatch, or no versions at all (an older wrapper), is refused with a
   `distccd-gate: refused: ...` line in the build log.
3. distcc treats a refusal like an unreachable helper: it compiles that job on
   the build host and leaves the helper alone for a minute (its backoff)
   before trying again.

## Recipes kept off distcc

A recipe with a `NO_DISTCC` file (its first line is the reason) never gets the
key mounted, so all of its compiles run on the build host; ccache still
applies. Use it for builds that distcc can't help or that break under it, such
as precompiled headers: distcc compiles each file on its own and can't use a
`.gch` made on the build host. hyprland has one. List the file in the recipe's
`DELTA` `keep` line so `bin/rebase-recipe` carries it over.

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
