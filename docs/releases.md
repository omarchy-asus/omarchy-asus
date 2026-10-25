# Releases: keeping the channels current

The RC channel is kept current with upstream once a day by Steward's Rebase onto upstream
workflow, on one schedule: **RC** from `main`, the channel's trunk, built against Omarchy rc in
its own chroot and published to the `rc-x86_64` release.

**Quattro is frozen** (#309) on what `x86_64` serves until the Omarchy 4.5 stable switch. Its
schedule is disabled: nothing is rebuilt or published to it, and the build and publish scripts
refuse the quattro channel unless `OMARCHY_ASUS_ALLOW_QUATTRO=1` (`bin/sync-release --dry-run`
still reads it). It keeps serving its current packages, never stock over our patch.

**At the 4.5 stable switch**, when Omarchy ships 4.5 to stable and our Quattro channel moves with
it, Quattro picks up the trunk: rc-built packages are promoted to stable as the exact same files
(one filename, one set of bytes), after a G16 test for the kernel and NVIDIA. That promotion step
is not built yet; #309 has the plan.

On each channel, Arch packages come through that channel's Omarchy mirror, and `linux-omarchy`
comes from its `[omarchy]`.

There is no systemd timer or service for this, and there must not be one. Until October 2026 a
root timer (`bin/auto-update`) did this work; it was removed so that every rebase, build and
publish is a run with its own page, not a cron job to dig through logs for. Don't add, install or
start a timer, service or cron job that builds or publishes.

## What one run does

1. **Check:** `bin/check-upstream --json` compares every package we carry with what upstream
   ships now; `bin/auto-update-state plan` turns that into one action per recipe: `rebase`
   (upstream moved), `build` (on the branch but not in the repo db), `unpublish` (in the db
   with no recipe), `attention` (something for a person: a merged upstream PR, an expired db,
   a held recipe) or `current`. Nothing to do ends the run.
2. **Rebase and build:** each moved recipe is rebuilt from upstream's new recipe plus its
   `DELTA` (`bin/rebase-recipe --verify`), one commit per recipe, then built in the channel's
   chroot (`bin/build-pkg`).
3. **Fix or check:** an agent fixes what didn't rebase or build, or checks what did.
4. **Review, PR, CI, merge:** a second model reviews the change; the pull request goes into the
   channel's branch and merges once CI passes.
5. **Publish:** `bin/publish` signs what was built and `bin/sync-release` puts it on the channel's
   release, through every safeguard below, and updates the release's train issue (below); the
   run ends when the release serves it.

`unpublish` and `attention` rows are reported for a person; the run withdraws nothing by itself.
When a patch stops applying or a build fails, our last build stays published.

## Never stock over our patch (#201)

On our channels you always get our patched build. A package leaves the repo only when its
recipe is removed, because Omarchy or the original upstream has folded our fix in.

pacman takes the **first** repo that has a package name, whatever the version. `[omarchy-asus]`
is listed first, so while we publish a package, a newer stock one never replaces it. Every
failure path therefore keeps our last good build and records why:

- patches that no longer apply, or an inconsistent upstream recipe
- a failed build, reverse-dependency check, merge or publish
- a pull request that waits for a review or a merge, or a release-cohort partner not built yet
- an upstream db past its grace period

Users stay one upstream bump behind until the fix lands, never without our patch. The cost:
when a package of ours pins an exact version (`nvidia-open-dkms` needs `nvidia-utils=<ver>`)
and the mirror moves that dependency, `omarchy update` fails on the dependency until the
recipe is rebased. The day's run raises it as attention (`dep-mismatch`).

## Release channels

| | RC | Quattro |
|---|---|---|
| branch | `main` (the trunk) | none: frozen until the 4.5 stable switch (#309) |
| upstream dbs (`bin/check-upstream`) | `pkgs.omarchy.org/rc`, `rc-mirror.omarchy.org` | `pkgs.omarchy.org/stable`, `stable-mirror.omarchy.org` |
| chroot | `/var/lib/omarchy-asus/chroot-rc` (`build/pacman-rc.conf`) | `/var/lib/omarchy-asus/chroot` (`build/pacman.conf`) |
| stage dir, local repo | `stage-rc`, `repo/rc-x86_64` | `stage`, `repo/x86_64` |
| release | `rc-x86_64` | `x86_64` |
| state | `channel-rc/` of the data dir | the data dir |

Both channels have the same gates: holds (`recipes/<r>/HOLD`), signing and signature checks,
checksums, the personal-information scan, release cohorts, and no regression.

- **The release tooling comes from `main`.** `main` carries the recipes, the tests and all the
  tooling (`bin/`, `ci/`, `build/`, `.github/`, `tests/`), so a change to any of them is one PR
  into `main`; there is no per-branch copy to keep in step. `tests/channel/` holds `main`'s
  recipe tests and runs in the lint with the rest.
- **Each chroot carries our packager** (`PACKAGER="omarchy-asus"` in
  `/etc/makepkg.conf.d/packager.conf`). `bin/mkchroot [--channel rc]` makes or updates a chroot
  and writes it; rerun it on an older chroot.

## Release trains (#212)

Each release has one open tracking issue, its **train**: "Release train: x86_64 (Quattro
channel)" or "Release train: rc-x86_64 (RC channel)". It is the record of what the release
carries, and the train's tag and release notes are cut from it, not from the db by hand.

- **Every sync rewrites it.** After a sync that went through, and after a withheld one,
  `bin/sync-release` runs `bin/release-train update`, which opens the issue if no train is open.
  It lists every package the release serves with its version, its recipe, its status (ready,
  our last build while the recipe waits, held, no recipe) and the recipe's last issue and pull
  request; what waits for the next train (not built yet, behind its version, held, blocked by a
  regression); for a withheld sync, the regression; and the recipe changes since the last cut.
  It also records the recipes commit the sync checked. The body goes through the
  personal-information scan first. A failed update is a warning: the release is already
  settled. `RELEASE_TRAIN=off` skips it.
- **Cutting a train:** `bin/release-train [--channel rc] cut NAME` (try `--dry-run` first), from
  a checkout of the channel's branch, tags the recorded commit `train/<release>/NAME` with the
  notes as its message, pushes the tag, comments the notes on the issue and closes it. The next
  sync opens the next train, whose changes start at that tag. The cut marks the issue first, so
  a cut that stops half way (push, comment or close) is finished by rerunning it with the same
  name, and syncs leave the issue alone until then.
- `update` and `cut` hold the publication lock (`publish.lock`, shared with `bin/publish`,
  `bin/unpublish` and `bin/sync-release`), so a sync never rewrites the issue during a cut.
  Text with control characters (other than newline and tab) is refused before the scan.
- `bin/release-train notes` prints the notes from the open issue (on the release and changes,
  without the waiting list); `find` prints its number; `render --db DB` prints a body offline.

## Release builds on GitHub (#258, nothing publishes from them yet)

Release builds are moving off the build host's chroots onto the same `ci/build-recipe`
container the PR check uses (#258). The first piece is `.github/workflows/release.yml`: it builds
and records, and **publishes nothing**. No signing key, secret or release upload is anywhere in
it. The second is the signer on the build host, `bin/release-sign` (below), which checks a run's
record with GitHub before it hands the packages to `bin/publish`. The daily rebase onto upstream
runs it only for the recipes `build/release-path.conf` lists, and it lists none yet, so the chroot
path (`bin/build-pkg`, then `bin/publish`) stays the live publisher (below, "Switching a recipe to
the release path").

```
release workflow (GitHub)  ->  bin/release-sign (build host)  ->  bin/publish  ->  bin/sync-release
builds, records, attests       checks the run, stages             signs, repo db    the release
```

```bash
gh workflow run release.yml --ref main -f channel=rc -f recipes="omarchy-asus-keyring"
```

- **Refused before anything builds** (`ci/release-plan`): a ref other than `main`, the Quattro
  channel (frozen, #309), `linux-omarchy` while the repository variable `RELEASE_RUNNER` does not
  name the build host's release runner (it never builds on a hosted runner), a held recipe (`recipes/<r>/HOLD`), an unknown recipe, and release cohorts whose recipes disagree
  (`bin/release-cohort check-recipes`). Every later job is also skipped off `main`.
- **Eligibility** (`ci/release-eligibility`): the daily rebase's own decision for the requested
  recipes, made by its scripts: `bin/check-upstream` against the channel's upstream dbs, with the
  channel's published db as the local repo, then `bin/auto-update-state plan`. Only `build` (not in
  the release, or the release holds another version) and `current` pass; `rebase` (upstream
  moved past the recipe) and `attention` (upstream-older, bad-pkgrel, dep-mismatch, held, an
  expired upstream db, ...) fail the run. Upstream PR states are not read here. `check-upstream`
  runs `makepkg --printsrcinfo` in `bin/recipe-sandbox`, so this job's container gets user
  namespaces and its own `/proc` (it holds no token).
- **Build:** one job per recipe (but the kernel) on `ubuntu-24.04`, `ci/build-recipe --channel rc --release` in the
  PR check's container, so the channel's package sources (`build/pacman-rc.conf`), the devtools
  makepkg config and the packager (`omarchy-asus`) are the chroot's. As in the chroot, build dependencies come from the channel's Omarchy and Arch repos,
  never from `[omarchy-asus]`. `NO_DISTCC` is honoured where distcc is on (the build host's
  runner). The build step holds no token; `tests/ci/build-recipe-no-secrets.sh` covers this
  workflow too.
- **The kernel** (`linux-omarchy`) builds on the build host's release runner (the
  `omarchy-asus-release` registration, named by `RELEASE_RUNNER`), in a job named
  `build (linux-omarchy)` like the others, exactly as the PR check's kernel job builds it there:
  the same container with `--release`, the runner's distcc helper and compiler cache, a low CPU
  weight. It takes the build host's kernel lock first, so it never overlaps a PR check's kernel
  build; a PR check holding the lock is cancelled and re-run after the release build (PR checks
  absorb the wait, not releases). docs/kernel-runner.md has the lock, the preemption and the
  runner's setup.

  ```bash
  gh workflow run release.yml --ref main -f channel=rc -f recipes="linux-omarchy"
  ```
- **Recorded:** the artifact `release-rc-<recipe>` holds the packages (no `-debug` ones) and their
  `SHA256SUMS`, kept 14 days, and the attest job makes a build-provenance attestation for every
  package (`gh attestation verify <file> -R omarchy-asus/omarchy-asus`). That job is the only one
  that can request an OIDC token, and it runs no recipe code.
- **Checked as if it would publish** (`ci/release-check`), and the run fails otherwise: every
  package matches its `SHA256SUMS`; pkgrel is in the channel's range (`ci/check-pkgrel`); no
  release cohort member ships without its partner, in the run or in the channel's published db
  (`bin/release-cohort check-publish`); no release (either channel) already serves a different
  file by the same name. When `nvidia-open-dkms` or `linux-omarchy` builds, the module is compiled
  against the headers (`ci/nvidia-compat`), each side from this run when it built, else the
  channel's published package. The regression check (`bin/sync-release`)
  stays at publish time: it needs the local db.

### The signer: `bin/release-sign`

```bash
bin/release-sign --channel rc --dry-run <run ID>   # every check, then list the files
bin/release-sign --channel rc <run ID>             # the same, then bin/publish --channel rc
bin/sync-release --channel rc --dry-run            # the caller's next step, as after any publish
```

The runner that builds also runs PR jobs under one account, so a package on its own proves
nothing. The signer believes only GitHub's record of the run, read through the API, and refuses
(exit 1, nothing staged or published) unless every check passes. A check it can't make (an API
error, a missing or malformed field, no attestation) is a refusal.

- **Who:** the build user. Never root, never the runner account. The runner account's name is
  local configuration, never in the repo: `OMARCHY_ASUS_RUNNER_USER`, or the first line of
  `~/.local/share/omarchy-asus/runner-user` (`RUNNER_USER`, `bin/env.sh`). With neither set it
  refuses.
- **Channel:** `rc` only. Quattro is refused (frozen, #309), with no override.
- **The run:** in `omarchy-asus/omarchy-asus`, head repository too (a fork's run is refused);
  workflow path exactly `.github/workflows/release.yml`; event `workflow_dispatch` (a run from
  `pull_request`, `pull_request_target`, `push` or anything else is refused); head branch
  `main`, and its commit is on `main` (`compare/main...<sha>` is `identical` or `behind`, so a
  commit off `main` is refused whatever the branch name says); completed, conclusion `success`.
- **Jobs:** `attest`, `result` and the `build (<recipe>)` job of every artifact it uses
  concluded `success` (latest attempt).
- **Artifacts:** every artifact of the run is `release-rc-<recipe>` (any other name, another
  channel's included, is refused), its name unique in the run, not expired, and from this run,
  commit and repository. Each is downloaded on its own (the artifact's zip, not
  `gh run download`) and read into its own directory, so the layout never depends on how many
  artifacts the run has. The zip's SHA-256 is the digest GitHub recorded. Its entries are regular files with
  plain names (no directories, links or path components): `SHA256SUMS` and exactly the
  `*.pkg.tar.zst` files it lists, no more, no fewer, each with the SHA-256 it lists, and no file
  in two artifacts. `SHA256SUMS` lines are `<sha256>  <name>`, nothing else.
- **Attestations:** `gh attestation verify` for every file with `--signer-workflow
  omarchy-asus/omarchy-asus/.github/workflows/release.yml --source-ref refs/heads/main
  --source-digest <the run's commit> --signer-digest <the same>`, and its answer must name this
  run (one of its attempts), that workflow at `refs/heads/main`, the commit, and the file by name
  and digest.
- **Then** it copies the files into the channel's stage dir (`stage-rc`; a file already there
  with other bytes is refused) and runs `bin/publish --channel rc` on exactly those files. The
  signing is `bin/publish`'s: the signer never signs or reads the key itself.
- **Runs no recipe or artifact code:** no `makepkg`, no PKGBUILD, no install scriptlets. The only
  archive it opens is the artifact zip, read with `bsdtar` into a private temp dir that is
  removed on exit. It is a command, run once per release: no unit, timer or cron job.

`tests/ci/release-sign.sh` covers every refusal and the hand-off, offline, with `gh` stubbed.

### Switching a recipe to the release path

`build/release-path.conf` is the switch: one recipe per line. A recipe listed there is no longer
built in the chroot by the daily rebase onto upstream; after its merge the release workflow builds
it on `main` and `bin/release-sign` checks that run and publishes it. It holds only on the rc
channel from `main`. With the file empty (as committed: comments only) or missing, every recipe
builds in the chroot as before. A release cohort (`build/cohorts.conf`) is listed whole or not at
all.

A recipe is listed only after the two paths have been compared for it and match:

1. **Build it on the new path:** run the release workflow for that recipe on `main`, and note the
   run ID once it has succeeded.

   ```bash
   gh workflow run release.yml --ref main -f channel=rc -f recipes="omarchy-asus-keyring"
   ```
2. **Compare** that run with what the rc release serves today:

   ```bash
   bin/compare-build-paths --channel rc omarchy-asus-keyring <run ID>
   ```

   It downloads the run's `release-rc-<recipe>` artifact (its digest and `SHA256SUMS` checked,
   into a directory of its own) and the packages the rc release serves from that recipe (through
   `ci/fetch-release`: the signed db, then each package's signature), and compares each package:
   the version first, then the `.PKGINFO` fields (dependencies, optdepends, provides, conflicts,
   replaces, backup and the rest), the file list with type, mode, owner and link target, the
   install scriptlet, and file sizes. A file whose size moved by more than 64 bytes and 1% is a
   difference (`--size-bytes`, `--size-percent`); less is reproducibility noise. Build date,
   packager, `.BUILDINFO` and file contents (build ID notes, embedded dates) are expected to
   differ and aren't failed; the files whose contents differ are listed for information. A
   package only one side has is a difference. When the release serves another version than the
   run built, it says so first and compares the rest anyway; compare again once both are at the
   same version. It only reads the archives (`bsdtar`), never runs anything from them, and
   changes nothing. Exit 0: only expected differences; 1: differences, printed as a diff
   (`- release`, `+ new path`); 3: it couldn't compare (the run isn't a successful release
   workflow run on `main`, no such artifact, a digest or signature that doesn't check out).
3. **Switch it** in a pull request that adds the recipe to `build/release-path.conf` and names the
   run and the comparison's result. `linux-omarchy` also needs the build host's release runner
   (docs/kernel-runner.md, "The release registration") and `RELEASE_RUNNER` naming it.

`tests/ci/compare-build-paths.sh` covers it offline, with small fabricated packages: identical
builds, a dropped file, a changed dependency, scriptlet or mode, a size beyond the threshold, a
package on one side only, a version mismatch, and the refusals.

## Reverse-dependency checks

`build/revdeps.conf` maps a kernel recipe to the DKMS packages that must compile against
it (today: `linux-omarchy  dkms:nvidia-open-dkms`). `bin/revdep-check` runs in a throwaway
snapshot of the clean chroot. It installs `dkms`,
then the DKMS package (with `-dd`, because its runtime dependencies such as
`nvidia-utils=<ver>` don't matter for compiling), then the headers. The dkms pacman hook
builds the module for that kernel, and `dkms status` must report it installed;
otherwise `dkms build` is re-run for an exit code and make.log is logged.

- **A kernel build** compiles every listed DKMS package against its new headers. It uses
  our published package, or the staged build of the DKMS recipe. If the module doesn't
  build, the kernel is not published, and our last kernel stays published.
- **A DKMS build** (`nvidia-open-dkms`) compiles against the headers of the kernel we
  publish, or stock `linux-omarchy-headers` from `[omarchy]` if we carry none. If that
  fails, it is not published.
- **Withdrawing our kernel** (its recipe removed) would hand users the
  stock kernel with the DKMS package we still publish. So the retained DKMS package is first
  compiled against the stock headers; if that fails (or its file is missing), it is
  withdrawn together with the kernel.

The daily workflow doesn't run these checks by itself yet: run them by hand before publishing a
kernel or DKMS build, and withdraw nothing without them:

```bash
bin/revdep-check --headers <repo>/linux-omarchy-headers-<ver>-x86_64.pkg.tar.zst \
                 --dkms <repo>/nvidia-open-dkms-<ver>-x86_64.pkg.tar.zst
```

## Upstream db freshness

`bin/check-upstream` reads the upstream pacman dbs to see what users would get without us.
When a fetch fails it uses the cached copy and marks the run **degraded**: the run notes
which dbs are stale and how old they are, and records an attention item. A cached copy
older than `OMARCHY_ASUS_DB_MAX_STALE` seconds (default 86400) is
**expired**: nothing that overrides upstream is built or rebased on it, and what we publish
stays (local-only recipes, with a `LOCAL_ONLY` file, are not affected). Once the db is
reachable again, the usual plan resumes.

## Release cohorts

`build/cohorts.conf` lists packages that ship only together (today: `omarchy` and
`omarchy-settings`); members share one `pkgver-pkgrel`. Members go out together in one
`bin/publish` call, which refuses an incomplete cohort on its own: until every partner is built
at the same version, the built member is held back and the pair we published before stays.
A partner already in the repo db at exactly the same version also counts: the built member
publishes next to it (`bin/release-cohort check-publish`), since a partner published earlier
is never rebuilt (#127). A partner in the db at a different version still holds the member back, and
a lone member never publishes next to a partner at another version.
`bin/unpublish` withdraws every member of a cohort, never one alone.

## Recipe deltas

`recipes/<r>/DELTA` declares how a recipe differs from upstream, so a rebase is mechanical. `bin/rebase-recipe --help` documents the format. Why each change is carried, how to test it and when to drop it is in [deltas.md](deltas.md), one entry per change; the upstream pull requests in `recipes/<r>/UPSTREAM_PRS` are what the daily `bin/check-upstream` watches. There are three shapes today:

- `hyprland`: Arch's PKGBUILD plus a patch appended to `prepare()` (`patch <file> prepare`).
- `linux-omarchy`: upstream's PKGBUILD. `prepare()` applies every `*.patch` in `source=()` order, so the delta is where each patch goes (`patch <file> after 0567-*`, `patch <file> end`).
- `nvidia-open-dkms`: our trimmed PKGBUILD is a template (`mode template`). Only pkgver, pkgrel and checksums follow upstream, and `arch/PKGBUILD` is refreshed for review.

Rebasing each recipe onto its current base reproduces the committed recipe. The two known exceptions are checksum formatting and nvidia's `SKIP` sums for our patches, which become real sums. Local-only packages (`recipes/<r>/LOCAL_ONLY`, plain pkgrel) have no DELTA. They are only built when the repo db lacks the recipe's version.

## Publishing safeguards

`bin/publish`, `bin/unpublish` and `bin/sync-release` keep a channel's release consistent, whoever runs
them:

- **`bin/sync-release`** reads the release assets once. It uploads only new or changed files: packages and signatures first, the db last. It refuses to overwrite an existing package filename that has different bytes, and it refuses a local db whose signature does not verify against the signing key.
- **One publication at a time.** `bin/publish`, `bin/unpublish` and `bin/sync-release` share one lock (`publish.lock` in the data dir). A second caller waits up to `PUBLISH_LOCK_WAIT` seconds, then exits 75 without touching the repo or the release.
- **Publish and unpublish are staged.** They build the new repo next to the current one and check every signature before they swap it in. If a step fails, the previous repo stays in place as it was.
- **A journal marks a release that may lag.** `bin/publish` and `bin/unpublish` write `sync-pending` in the data dir before they change the local repo. `bin/sync-release` removes it only after it has checked that the release matches the local repo. While it exists, the next `bin/sync-release` has a sync to finish, so a crash between publish and sync is retried.
- **No regression (#201).** A ready package goes up on the next sync, with whatever must ship with it (release cohorts, the kernel and its DKMS package); one that is not ready keeps our last build until it is. Before anything goes up, `bin/sync-release` checks the local db against the recipes of the channel's branch and the previous release (`bin/check-upstream --complete --previous`, offline): the previous release is this channel's own, and for RC also the Quattro release. The db is a regression, and is withheld, when it lacks our build of a package the previous release served while a recipe (held or not) still ships it, or when such a package is missing and a recipe cannot be read. Then nothing is uploaded, the release keeps the set it had, and the sync exits 3 with those packages listed (and written to `release-withheld` in the channel's data dir). A later sync puts the db up once they are built. A recipe behind its version, a net-new recipe not built yet, and a removed recipe's package (upstream replaced our patch) are no regression. A previous release that exists but cannot be read refuses the sync (exit 1).
- **One publisher per release.** `bin/sync-release` records the release db it last uploaded in `release-db.sha256` in the data dir (each db is recorded before its upload, so a sync that dies mid-upload is not taken for another publisher). If the release's db has changed since then (another host or a manual upload), it refuses to sync. After checking the release by hand, `SYNC_ADOPT_REMOTE=1 bin/sync-release` adopts it.
- **Each release channel has its own state.** The data-dir files above (`sync-pending`, `release-db.sha256`, `prune-candidates`) are the Quattro channel's; `--channel rc` keeps its own in `channel-rc/` of the data dir, next to its own local repo (`repo/rc-x86_64`) and stage dir (`stage-rc`). The publication lock is shared.
- **The PII scan fails closed.** An archive that the scan cannot read counts as a hit, and nothing is uploaded.
- **Superseded assets are kept for a while.** Release assets that the new db no longer lists are deleted only after `PRUNE_GRACE_HOURS` (default 72 h), so a client that still has the previous db can download what it lists.

## ai-review

`bin/ai-review` runs on the user's Codex login, from a local checkout; there is no review
service, and it is not a required check on any branch (#76). For the maintainer's own work it is
an optional second opinion (AGENTS.md, "Who writes, who reviews"); it stays available for outside
contributors' PRs. `bin/ai-review sweep --dry-run` lists open PRs whose head has no `ai-review`
status yet.
