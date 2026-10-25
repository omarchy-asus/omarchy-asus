# The kernel jobs on the build host's runner

On a GitHub-hosted runner the `kernel` job of `.github/workflows/build-pr.yml`
takes about 2.5 hours. It can run on a self-hosted runner on the build host
instead, where distcc sends compiles to the helper (docs/distcc.md). The
kernel's release build (`.github/workflows/release.yml`, #258) runs there only.
Every other job stays on GitHub's runners.

One runner account on the build host, two registrations of it:

| registration (label) | runs | chosen by the repository variable |
|---|---|---|
| `omarchy-asus-kernel` | the PR check's `kernel` job (build-pr.yml) | `KERNEL_RUNNER` (optional: unset, the PR check builds on `ubuntu-24.04`) |
| `omarchy-asus-release` | the release build's `kernel` job (release.yml), dispatched on `main` | `RELEASE_RUNNER` (required: unset, the release refuses `linux-omarchy`; it never builds on a hosted runner) |

Two registrations so a release never queues behind a PR check in GitHub's
queue; one host lock (below) so their two kernel builds still never overlap.
Both have the same isolation: the same account, its rootless docker, the same
job-started hook, distcc key and compiler cache.

It is off unless the repository variable `KERNEL_RUNNER` is set. With it set:

- runs on this repository's own branches (and maintainer dispatches) use the
  runner it names; a fork's PR always gets `ubuntu-24.04`, so unreviewed code
  never runs on the build host. A fork's PR runs its own copy of the workflow,
  which could name the runner anyway, so the runner checks this itself before
  every job (`build/kernel-runner-job-started.sh`, below);
- the job is the same `docker run ... ci/build-recipe` container as on a hosted
  runner, at a lower CPU weight (`--cpu-shares 256`), so a person at the build
  host comes first;
- the build tree is the job's own temp dir, and a last step removes the build
  container (by the name the run gave it, in case a cancelled run left it
  compiling) and then the tree, pass or fail (the container writes it as root);
- the packages go only to the run's unsigned artifact, as on a hosted runner.
  Nothing touches the stage dirs, the chroots, the local repo or the releases.

`tests/ci/kernel-runner.sh` checks all of this.

If the runner is down, kernel jobs wait for it (up to a day). Unset
`KERNEL_RUNNER` to send PR checks back to GitHub's runners; a kernel release
waits for the build host, or is not dispatched.

## The release kernel job

`release.yml`'s `kernel` job is named `build (linux-omarchy)`, like the
other recipes' build jobs, because that is the job `bin/release-sign` checks
for the `release-<channel>-linux-omarchy` artifact. It builds exactly as the
PR check's kernel job does on the build host (the same container,
`ci/build-recipe --release`, the CPU weight, the run's container name, the
distcc key dir and compiler cache from the runner's environment, the
cleanup), then uploads the packages and their `SHA256SUMS` in the same layout
as the other recipes. The run's attest, check and result jobs cover it, and
`nvidia-compat` builds the NVIDIA module against the headers it just built.
`tests/ci/release-workflow.sh` compares the two jobs line by line.

## The host lock

Both kernel jobs take one lock, `ci/kernel-lock`, around their build: a
`flock` on the file `OMARCHY_ASUS_CI_LOCK` names in the runner's `.env` (the
same file in both registrations' `.env`). Next to it:

- `<lock>.holder` records who holds it: `kind` (`pr` or `release`), the run
  ID and attempt, the workflow, the job, the build container's name, the
  holding process and since when. `ci/kernel-lock holder` prints it, with
  `state=held` or `state=free` (a record left by a killed holder shows as
  `stale_...` on a free lock).
- `<lock>.queue` is a release's place in line. A release takes it first and
  keeps it until it is done: while it is held no PR job takes the lock, and a
  second release waits behind the first.

A job's steps are separate processes, so the lock is held by a small
background process that `ci/kernel-lock` starts without the job's token. It
lets go when the job's last steps ask (`ci/kernel-lock release`, after the
cleanup), or when the job's `Runner.Worker` is gone (a cancelled or killed
job). A lock never looks free while a build container still runs:
`release` removes the job's own container first, and keeps the lock if it
won't go; and a new holder that finds the previous holder's container still
there (its job was killed before its cleanup ran) waits up to 10 minutes for
it, then removes it, before it builds.

With `OMARCHY_ASUS_CI_LOCK` unset a PR check builds without the lock (with
one registration there is nothing to overlap with) and says so; a release
refuses.

## Preemption

PR checks absorb the wait, not releases. The release kernel job:

1. takes the release queue (`ci/kernel-lock queue`);
2. if a PR check's kernel job holds the lock, cancels that PR run
   (`ci/kernel-preempt cancel`). The holder record is written by the runner
   account, which also runs branch code, so a run is only cancelled when
   GitHub lists it as this repository's `build-pr.yml`;
3. waits for the lock (the cancelled job's cleanup removes its container and
   lets go), builds, uploads, cleans up and lets go;
4. pass or fail, re-runs the cancelled run's failed and cancelled jobs
   (`ci/kernel-preempt rerun`, `gh run rerun --failed`) once it has finished,
   unless a newer `build-pr.yml` run on its branch has replaced it
   (re-running the old one would cancel the newer one).

A PR job never preempts anything: it waits for the lock, and gives way while a
release is queued. A release never preempts a release; it waits its turn.

Only steps 2 and 4 get the job's token in their environment, which can cancel
and re-run runs (`actions: write`, no `contents: write`); the lock, build and
upload steps get none, and the build container holds no credentials
(`tests/ci/build-recipe-no-secrets.sh`, `tests/ci/release-workflow.sh`).
`tests/ci/kernel-lock.sh` tests the lock and these decisions.

## Trust boundary

The job runs workflow code and recipe code from the PR's branch. Branches on
this repository are pushed by the maintainer and its own release workflow, the same
code the release builds run, so this is the trust level docs/distcc.md allows
the distcc key at. What keeps the rest of the build host out of reach:

- The runner is a dedicated system account, not the build user. It has no
  sudo, no signing key, no `gh` login, and can't read the build user's home.
- It is not in the `docker` group (that would be root-equivalent: any
  workflow could start a privileged container). It runs its own rootless
  dockerd (rootlesskit, pasta networking): root in its containers is the
  runner account's own uid on the host, and the rest of the container's uids
  are its subuid range. A privileged container from branch code gets no more
  than the runner account has. The system docker socket refuses it.
- The runner's job-started hook, a root-owned copy of
  `build/kernel-runner-job-started.sh` that no workflow can change, run by
  both registrations, ends any job that isn't build-pr.yml's `kernel` job on
  this repository, started by a `pull_request` from one of its own branches or
  a `workflow_dispatch`, or release.yml's `kernel` job dispatched on `main`. This
  is what keeps a fork's PR off the runner: its copy of the workflow decides
  `runs-on`, not ours. Failing the hook would not be enough (the runner still
  runs a step marked `if: always()`), so a refusal kills the job's
  `Runner.Worker` and no step of that job runs. The runner reports the job
  failed and waits for the next. The hook's name must end in `.sh`: the runner
  picks its interpreter by the extension.
- As a second layer, the repository asks for approval before running any
  outside contributor's workflow (Settings, Actions, "Require approval for all
  external contributors").
- Its distcc key is its own (not the chroot release builds' key), limited on
  the helper the same way, so it can be revoked on its own.
- The release registration runs main's code only, but under the same account
  as PR jobs, at the same time while it waits for the lock. Its token can
  cancel and re-run runs while its job lasts; a PR job's own steps run as the
  same account and could read it. That is the trust level above (this
  repository's own branches only), and the token can't push code, sign or
  publish. The compiler cache and distcc key are shared the same way. The
  packages it builds are not trusted for being on the build host:
  `bin/release-sign` checks GitHub's record of the run before signing
  (docs/releases.md).

## Setup

On the **build host**, as root. `<runner>` is the account name; the runner
software comes from <https://github.com/actions/runner/releases> (check the
SHA-256 the release page lists):

```bash
useradd --system --create-home --home-dir /var/lib/<runner> --shell /usr/bin/nologin <runner>
chmod 700 /var/lib/<runner>
runuser -u <runner> -- bash -c '
    cd ~ && mkdir actions-runner && cd actions-runner &&
    curl -fsSLo r.tgz https://github.com/actions/runner/releases/download/v<ver>/actions-runner-linux-x64-<ver>.tar.gz &&
    echo "<sha256>  r.tgz" | sha256sum -c && tar xzf r.tgz && rm r.tgz'
```

Its rootless docker. Arch's docker package doesn't ship
`dockerd-rootless.sh`; take it from moby's `contrib/` at the tag of the
installed docker (`docker-v<ver>`), read it, and install it root-owned. The
subuid range must not overlap another user's in `/etc/subuid`:

```bash
pacman -S --needed rootlesskit passt
install -o root -g root -m 755 dockerd-rootless.sh /usr/local/bin/dockerd-rootless.sh
usermod --add-subuids <start>-<start+65535> --add-subgids <start>-<start+65535> <runner>
loginctl enable-linger <runner>    # its user services run without a login
runuser -u <runner> -- bash -c 'mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/docker.service' <<'EOF'
[Unit]
Description=Docker (rootless) for the kernel CI runner

[Service]
Environment=PATH=/usr/local/bin:/usr/bin
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=implicit
ExecStart=/usr/local/bin/dockerd-rootless.sh
Restart=on-failure
Delegate=yes
Type=notify
NotifyAccess=all
KillMode=mixed

[Install]
WantedBy=default.target
EOF
runuser -u <runner> -- env XDG_RUNTIME_DIR=/run/user/$(id -u <runner>) systemctl --user enable --now docker.service
echo "DOCKER_HOST=unix:///run/user/$(id -u <runner>)/docker.sock" >> /var/lib/<runner>/actions-runner/.env
```

pasta makes the containers' connections from the host's own network stack,
so the helper sees the build host's address (its `from=` limit still holds).
`docker info` as the runner lists `name=rootless` under security options.

Register it with a one-hour token (repository admin):

```bash
token=$(gh api -X POST repos/omarchy-asus/omarchy-asus/actions/runners/registration-token --jq .token)
runuser -u <runner> -- /var/lib/<runner>/actions-runner/config.sh --unattended \
    --url https://github.com/omarchy-asus/omarchy-asus --token "$token" \
    --name <name> --labels omarchy-asus-kernel --no-default-labels --replace
```

`--no-default-labels` keeps it off any job that asks for plain `self-hosted`;
its only label is `omarchy-asus-kernel`, so that is the one `KERNEL_RUNNER`
names. Install the job-started hook where the runner can read but not change
it, and turn on approval for outside contributors' workflows:

```bash
install -D -o root -g root -m 755 build/kernel-runner-job-started.sh /usr/local/lib/omarchy-asus/kernel-runner-job-started.sh
echo "ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/omarchy-asus/kernel-runner-job-started.sh" >> /var/lib/<runner>/actions-runner/.env
gh api -X PUT repos/omarchy-asus/omarchy-asus/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
```

Re-run the `install` line when the hook changes. Then the service: `cd /var/lib/<runner>/actions-runner && ./svc.sh install <runner> && ./svc.sh start`.

distcc, with a key made for the runner (docs/distcc.md, Setup, has the
helper's side: the same `restrict,from=...,command="/usr/local/bin/distccd-gate ..."`
line, for this key):

```bash
runuser -u <runner> -- bash -c '
    d=~/distcc; mkdir -p "$d"
    ssh-keygen -t ed25519 -N "" -C "omarchy-asus CI distcc (compile-only)" -f "$d/id_ed25519"
    ssh-keyscan -t ed25519 <helper-address> > "$d/known_hosts"
    echo "<helper-account>@<helper-address>/<helper-threads>" > "$d/hosts"'
echo "OMARCHY_ASUS_CI_DISTCC=/var/lib/<runner>/distcc" >> /var/lib/<runner>/actions-runner/.env
```

The runner's `.env` puts `OMARCHY_ASUS_CI_DISTCC` in every job's environment;
the build step mounts that directory read-only at `/mnt/distcc`, and
`ci/build-recipe` copies the key for the container's builder user and turns
distcc on with the hosts in `hosts`. Without `.env` the job builds with the
build host's CPUs only. Restart the service after changing `.env`.

A compiler cache of the runner's own makes repeat kernel builds fast: a PR
that changes a few patches recompiles a few objects, not all ~25,000 (the
release chroot's warm rebuilds take ~10 minutes against ~1 hour cold). It is
not the release builds' cache: branch code can write to it, so only CI builds
read it. The container's builder user writes it, so it is world-writable
inside the runner's private home:

```bash
runuser -u <runner> -- install -d -m 1777 /var/lib/<runner>/ccache
echo "OMARCHY_ASUS_CI_CCACHE=/var/lib/<runner>/ccache" >> /var/lib/<runner>/actions-runner/.env
```

The build step mounts it at `/mnt/ccache` and `ci/build-recipe` puts ccache
in front of distcc (15 GB limit), with the release builds' hash settings
(docs/distcc.md, "Persistent ccache"): `CCACHE_BASEDIR` is the build tree
(`$WORK`, default `/build`), `CCACHE_NOHASHDIR=1`, and `CCACHE_SLOPPINESS`
ignores the header mtimes and ctimes that every fresh tarball extraction
changes. After makepkg the log has this build's
`==> ccache: <n> hits, <n> misses, <n>% hit rate`. Its files belong to the
runner's subuids; to empty it, remove them from a container:
`docker run --rm -v /var/lib/<runner>/ccache:/c <image> sh -c 'rm -rf /c/*'`.

The host lock, in the runner's home, named in its `.env`:

```bash
runuser -u <runner> -- install -d -m 700 /var/lib/<runner>/lock
echo "OMARCHY_ASUS_CI_LOCK=/var/lib/<runner>/lock/kernel.lock" >> /var/lib/<runner>/actions-runner/.env
```

Then turn it on:

```bash
gh variable set KERNEL_RUNNER -R omarchy-asus/omarchy-asus --body '["omarchy-asus-kernel"]'
```

Try it with a dispatch: `gh workflow run build-pr.yml --ref <branch> -f recipes=linux-omarchy -f rebuild=true`.
The kernel job's log says `kernel runner: workflow_dispatch on ... accepted`,
`distcc: ... mounted read-only`, `ccache: ... mounted` and
`==> distcc: 1 helper(s), <n> slots on top of <m> here`, and after the build
the ccache hit rate; the helper's `journalctl -t distccd` shows the compiles.

### The release registration

A second registration of the same account, in its own directory, with its own
label and service. Its `.env` is the first one's (the same rootless docker,
hook, distcc key dir, compiler cache and lock file):

```bash
runuser -u <runner> -- bash -c '
    cd ~ && mkdir actions-runner-release && cd actions-runner-release &&
    curl -fsSLo r.tgz https://github.com/actions/runner/releases/download/v<ver>/actions-runner-linux-x64-<ver>.tar.gz &&
    echo "<sha256>  r.tgz" | sha256sum -c && tar xzf r.tgz && rm r.tgz'
token=$(gh api -X POST repos/omarchy-asus/omarchy-asus/actions/runners/registration-token --jq .token)
runuser -u <runner> -- /var/lib/<runner>/actions-runner-release/config.sh --unattended \
    --url https://github.com/omarchy-asus/omarchy-asus --token "$token" \
    --name <name>-release --labels omarchy-asus-release --no-default-labels --replace
install -o <runner> -g <runner> -m 600 /var/lib/<runner>/actions-runner/.env /var/lib/<runner>/actions-runner-release/.env
cd /var/lib/<runner>/actions-runner-release && ./svc.sh install <runner> && ./svc.sh start
gh variable set RELEASE_RUNNER -R omarchy-asus/omarchy-asus --body '["omarchy-asus-release"]'
```

Keep the two `.env` files the same when one changes, and restart both
services. Try it with a release dispatch (nothing publishes from the release
workflow): `gh workflow run release.yml --ref main -f channel=rc -f recipes=linux-omarchy`.
The kernel job's log says `kernel runner: workflow_dispatch on ... accepted`,
`kernel lock: release queue taken`, `kernel lock: held by this job (release run ...)`,
and, when a PR check's kernel build held the lock, `preempting it` and, after
the build, `re-running run ...`.
