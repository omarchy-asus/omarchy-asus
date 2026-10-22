# The kernel job on the build host's runner (optional)

On a GitHub-hosted runner the `kernel` job of `.github/workflows/build-pr.yml`
takes about 2.5 hours. It can run on a self-hosted runner on the build host
instead, where distcc sends compiles to the helper (docs/distcc.md). Every
other job stays on GitHub's runners.

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

If the runner is down, kernel jobs wait for it (up to a day). Unset the
variable to send them back to GitHub's runners.

## Trust boundary

The job runs workflow code and recipe code from the PR's branch. Branches on
this repository are pushed by the maintainer and `bin/auto-update`, the same
code the release builds run, so this is the trust level docs/distcc.md allows
the distcc key at. What keeps the rest of the build host out of reach:

- The runner is a dedicated system account, not the build user. It has no
  sudo, no signing key, no `gh` login, and can't read the build user's home.
- It is in the `docker` group, which is root-equivalent: workflow code from a
  branch could start a privileged container. That is the cost of building in
  the same container as CI. Don't register the runner on a repository whose
  branches you don't control.
- The runner's job-started hook, a root-owned copy of
  `build/kernel-runner-job-started.sh` that no workflow can change, ends any job
  that isn't build-pr.yml's `kernel` job on this repository, started by a
  `pull_request` from one of its own branches or a `workflow_dispatch`. This
  is what keeps a fork's PR off the runner: its copy of the workflow decides
  `runs-on`, not ours. Failing the hook would not be enough (the runner still
  runs a step marked `if: always()`), so a refusal kills the job's
  `Runner.Worker` and no step of that job runs. The runner reports the job
  failed and waits for the next. The hook's name must end in `.sh`: the runner
  picks its interpreter by the extension.
- As a second layer, the repository asks for approval before running any
  outside contributor's workflow (Settings, Actions, "Require approval for all
  external contributors").
- Its distcc key is its own (not the release builds' key), limited on the
  helper the same way, so it can be revoked on its own.

## Setup

On the **build host**, as root. `<runner>` is the account name; the runner
software comes from <https://github.com/actions/runner/releases> (check the
SHA-256 the release page lists):

```bash
useradd --system --create-home --home-dir /var/lib/<runner> --shell /usr/bin/nologin -G docker <runner>
chmod 700 /var/lib/<runner>
runuser -u <runner> -- bash -c '
    cd ~ && mkdir actions-runner && cd actions-runner &&
    curl -fsSLo r.tgz https://github.com/actions/runner/releases/download/v<ver>/actions-runner-linux-x64-<ver>.tar.gz &&
    echo "<sha256>  r.tgz" | sha256sum -c && tar xzf r.tgz && rm r.tgz'
```

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

Then turn it on:

```bash
gh variable set KERNEL_RUNNER -R omarchy-asus/omarchy-asus --body '["omarchy-asus-kernel"]'
```

Try it with a dispatch: `gh workflow run build-pr.yml --ref <branch> -f recipes=linux-omarchy -f rebuild=true`.
The kernel job's log says `kernel runner: workflow_dispatch on ... accepted`,
`distcc: ... mounted read-only` and
`==> distcc: 1 helper(s), <n> slots on top of <m> here`; the helper's
`journalctl -t distccd` shows the compiles.
