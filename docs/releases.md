# Releases: keeping the channels current

Each channel is kept current with upstream once a day by Steward's
Rebase onto upstream workflow, scheduled once per channel:

- **Quattro**: `main`, built against Omarchy stable, published to the `x86_64` release.
- **RC**: `next/omarchy-4.5`, built against Omarchy rc in its own chroot, published to the
  `rc-x86_64` release.

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

| | Quattro | RC |
|---|---|---|
| branch | `main` | `next/omarchy-4.5` |
| upstream dbs (`bin/check-upstream`) | `pkgs.omarchy.org/stable`, `stable-mirror.omarchy.org` | `pkgs.omarchy.org/rc`, `rc-mirror.omarchy.org` |
| chroot | `/var/lib/omarchy-asus/chroot` (`build/pacman.conf`) | `/var/lib/omarchy-asus/chroot-rc` (`build/pacman-rc.conf`) |
| stage dir, local repo | `stage`, `repo/x86_64` | `stage-rc`, `repo/rc-x86_64` |
| release | `x86_64` | `rc-x86_64` |
| state | the data dir | `channel-rc/` of the data dir |

Both channels have the same gates: holds (`recipes/<r>/HOLD`), signing and signature checks,
checksums, the personal-information scan, release cohorts, and no regression.

- **The release tooling comes from `main`.** `bin/`, `ci/`, `build/`, `.github/`, `tests/` and the
  build docs on `next/omarchy-4.5` must be `main`'s (`ci/tooling-sync list`; the G16 kit's test
  and `bin/g16-check` stay per channel). When `main` moves, a "Tooling from main" PR into
  `next/omarchy-4.5` (made with `ci/tooling-sync apply origin/main`) brings the RC branch along.
  On RC PRs the lint fails only tooling the PR itself changes away from `main`, and warns while
  the branch lags behind it.
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

`recipes/<r>/DELTA` declares how a recipe differs from upstream, so a rebase is mechanical. `bin/rebase-recipe --help` documents the format. There are three shapes today:

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
