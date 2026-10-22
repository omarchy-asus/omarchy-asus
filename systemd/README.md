# omarchy-asus auto-update service

A daily systemd timer keeps the omarchy-asus repo current with upstream, on both release
channels (see "Release channels" below):

- **Quattro**: `main`, built against Omarchy stable, published to the `x86_64` release.
- **RC**: `next/omarchy-4.5`, built against Omarchy rc in its own chroot, published to the
  `rc-x86_64` release.

On each channel, Arch packages come through that channel's Omarchy mirror, and `linux-omarchy`
comes from its `[omarchy]`.

When upstream moves past a package's base version, the service has two outcomes:

- It rebases our patches onto the new upstream recipe. The PR goes through a chroot build and a verified AI review (`bin/ai-review`), plus the Claude fixer. `bin/ai-review` is this pipeline's own review gate, because no clud reviewer runs in the unattended loop. It merges and publishes only when every gate passes.
- Otherwise, it removes the package from the repo so the stock build flows through.

Nothing here is installed by default. `bin/install-auto-update` prints what it would do. It changes the system only with `--apply`, run through sudo by the user.

## Why a stale package must go immediately

pacman takes the **first** repo that has a package name, whatever the version. `[omarchy-asus]` is listed first, so an old build here never yields to a newer stock one:

- `nvidia-open-dkms` pins `nvidia-utils=<ver>`. When the mirror moves `nvidia-utils`, `omarchy update` fails on the dependency.
- A kernel or Hyprland build that is left behind silently holds the system back.

So every failure path ends in `bin/unpublish` + `bin/sync-release` in the same run. This includes:

- patches that no longer apply
- a failed build
- an inconsistent upstream recipe
- a PR that waits for a human
- an exact-version dependency (`depends=(x=ver)`) that no longer matches

Falling back to stock is always better than a stale pin.

## What one run does

```
timer (daily, 04:30 + up to 2h, Persistent, skipped on battery)
  └─ auto-update (root, root-owned copy): one run per channel in SERVE_CHANNELS, Quattro first
       (below for Quattro; the RC run is the same on its own branch, state and release)
       ├─ as BUILD_USER: refresh the bot clone ($DATA/auto-update/checkout) of omarchy-asus/omarchy-asus main
       ├─ as BUILD_USER: bin/check-upstream --json
       │     rebuild-needed / not-built / repo-stale / dep-mismatch / local / merged upstream PRs
       └─ per recipe (kernel last):
            rebase     bin/rebase-recipe: upstream recipe at exactly the version upstream ships
                       (Arch packaging git tag, or the omarchy-pkgs commit with that pkgver/pkgrel)
                       + recipes/<r>/DELTA, pkgrel = upstream + ".1", checksums from upstream's
                       sums (our files hashed locally), makepkg --nobuild = all patches apply
                       ├─ fails: unpublish + sync, status, exit 1
                       └─ ok: branch auto-update/<r>, push, PR (ready for review)
                             → chroot build of the PR head (root: makechrootpkg only)
                             → bin/ai-review on the head: codex finds, a second model verifies (review + `ai-review` status)
                             → headless Claude fixer: fixes or answers the blocking findings (edits only
                               recipes/<r>/, never our patches/DELTA); Codex reviews its commits
                             → fixes pushed? rebuild + ai-review of the new head (≤ MAX_FIX_ROUNDS)
                               (a fix outside NOTES.md is never auto-merged: a human merges)
                             → one PR comment with the results
                             → gates all pass: squash-merge (--admin: bypasses only the approval ruleset), bin/publish, bin/sync-release
                               otherwise: PR stays open (next run resumes it), stale package
                               unpublished meanwhile
            build      recipe on the branch not in the repo db: build, publish, sync
            unpublish  stale and nothing to rebuild from, or in the repo db with no recipe
                       (recipe removed; KEEP_PUBLISHED exempts); while check-upstream reports
                       inventory_errors (a recipe that failed to parse), only if it is stale
            attention  listed in the status, no automatic change (e.g. upstream merged one of
                       our patches' PRs: flagged, never dropped automatically)
```

### Release channels

The service serves every channel in `SERVE_CHANNELS` (in `auto-update.conf`; default
`"quattro rc"`), one after the other. Each channel gets its own `bin/auto-update --channel <c>`
run: its own bot clone, lock, log, status and journals, so a failure on one channel never
stops or rolls back the other. The unit fails when either run fails.

| | Quattro | RC |
|---|---|---|
| base branch, bot clone of | `main` | `next/omarchy-4.5` |
| upstream dbs (`bin/check-upstream`) | `pkgs.omarchy.org/stable`, `stable-mirror.omarchy.org` | `pkgs.omarchy.org/rc`, `rc-mirror.omarchy.org` |
| chroot | `/var/lib/omarchy-asus/chroot` (`build/pacman.conf`) | `/var/lib/omarchy-asus/chroot-rc` (`build/pacman-rc.conf`) |
| stage dir, local repo | `stage`, `repo/x86_64` | `stage-rc`, `repo/rc-x86_64` |
| release | `x86_64` | `rc-x86_64` |
| rebase PR branches | `auto-update/<r>` into `main` | `auto-update-rc/<r>` into `next/omarchy-4.5` |
| state (bot clone, runs, status, lock, journals) | data dir, as before | `channel-rc/` of the data dir |
| log | `logs/auto-update-<run>.log` | `logs/auto-update-rc-<run>.log` |

The RC run has every gate the Quattro run has, unchanged: holds (`recipes/<r>/HOLD` on
`next/omarchy-4.5`), so an untested kernel stays staged until it has booted on a G16;
signing and signature checks; checksums; the personal-information scan of the release and of
everything pushed or posted; release cohorts; the reverse-dependency checks; and the merge gates
below, with `bin/ai-review` (Codex) as the review gate of its unattended rebase PRs.

What differs for RC:

- **The pipeline comes from `main`.** Root runs one set of scripts, installed from `main`. The
  RC run's drift guard compares them with `bin/` and `build/` of `main`, not of
  `next/omarchy-4.5`, so the RC branch's own copy of `bin/` never stops (or runs) anything.
- **The RC chroot is the service's to make.** Before the first build (or kernel withdrawal) that
  needs it, the RC run checks that `/var/lib/omarchy-asus/chroot-rc` exists and uses the servers
  of the installed `build/pacman-rc.conf`; otherwise it runs `bin/mkchroot --channel rc` (as
  root, from the root-owned copy). If that fails, the run records a `(chroot)` failure, the
  RC builds fail and their stale packages are withdrawn, as for any failed build. The Quattro
  chroot is still made by hand (Install, below).
- **The first RC publish creates the `rc-x86_64` release** (`bin/sync-release --channel rc`, with
  `build/release-notes-rc.md`). Until then, every recipe on `next/omarchy-4.5` is "not built"
  on RC, so the first RC run builds and publishes all of them, kernel included, unless a recipe
  is held there. The release is made, and anything put on it, only once the whole set is
  published locally (whole channel or nothing, below): until the kernel, built last, is done,
  the RC channel has no release rather than a release without our kernel.
- `BASE_BRANCH` in the config applies to Quattro only. `SKIP_RECIPES`, `KEEP_PUBLISHED`,
  `MERGE_MODE`, the ai-review settings and the rest apply to both channels.

`SERVE_CHANNELS=quattro` runs exactly the Quattro-only service, in one process at the paths
above. `bin/auto-update --channel rc --plan` (or `--dry-run`) tries the RC run as you.

### Reverse-dependency CI

`build/revdeps.conf` maps a kernel recipe to the DKMS packages that must compile against
it (today: `linux-omarchy  dkms:nvidia-open-dkms`). After every chroot build,
`bin/revdep-check` runs in a throwaway snapshot of the clean chroot. It installs `dkms`,
then the DKMS package (with `-dd`, because its runtime dependencies such as
`nvidia-utils=<ver>` don't matter for compiling), then the headers. The dkms pacman hook
builds the module for that kernel, and `dkms status` must report it installed;
otherwise `dkms build` is re-run for an exit code and make.log is logged.

- **A kernel build** compiles every listed DKMS package against its new headers. It uses
  our published package, or the staged build of the DKMS recipe. If the module doesn't
  build, the kernel counts as a failed build: it is not published, the PR stays open, and
  the stale kernel is unpublished.
- **A DKMS build** (`nvidia-open-dkms`) compiles against the headers of the kernel we
  publish, or stock `linux-omarchy-headers` from `[omarchy]` if we carry none. If that
  fails, it is not published.
- **A cached build** (a resumed PR's head, or a merged tree built for its PR) is reused only
  while its counterpart is the one it was checked against: the DKMS package file for a
  kernel, the published headers file or the stock headers version for a DKMS package. The
  stage markers record a key of that counterpart; when it changed, the checks run again
  before the build counts as good or is published.
- **Withdrawing our kernel** (a failed build or rebase, a stale pin) would hand users the
  stock kernel with the DKMS package we still publish. So the retained DKMS package is first
  compiled against the stock headers; if that fails (or its file is missing), it is
  withdrawn together with the kernel.

### Upstream db freshness

`bin/check-upstream` reads the upstream pacman dbs to see what users would get without us.
When a fetch fails it uses the cached copy and marks the run **degraded**: the run notes
which dbs are stale and how old they are, and records an attention item. A cached copy
older than `DB_MAX_STALE` seconds (default 86400, set in `auto-update.conf`) is
**expired**: nothing is built or rebased on it, and every published package that overrides
upstream is withdrawn so the stock build flows through (local-only recipes, with a
`LOCAL_ONLY` file, are not affected). Once the db is reachable again, the usual plan builds them back.

`bin/auto-update --plan` lists the checks a pending build would trigger. To run one by
hand (it uses sudo for the chroot steps):

```bash
bin/revdep-check --headers ~/.local/share/omarchy-asus/repo/x86_64/linux-omarchy-headers-<ver>-x86_64.pkg.tar.zst \
                 --dkms ~/.local/share/omarchy-asus/repo/x86_64/nvidia-open-dkms-<ver>-x86_64.pkg.tar.zst
```

### Release cohorts

`build/cohorts.conf` lists packages that ship only together (today: `omarchy` and
`omarchy-settings`); members share one `pkgver-pkgrel`. A chroot build that passes its
reverse-dependency checks writes `$STAGE_DIR/.staged-<r>` with the recipe tree it built.
A member is published only once every partner is staged from its recipe on the base branch
(the marker matches that tree) at the same version; then all members go out in one
`bin/publish` call, which refuses an incomplete cohort on its own. Until then the built
member is held back: nothing is published, the stale pair is unpublished so the stock
packages flow through, and the recipe is recorded as attention, not failed. The next run
publishes it from the staged build, without rebuilding, once the partner is built.
A partner already in the repo db at exactly the same version also counts: the built member
publishes next to it, the same rule `bin/publish` and `bin/release-cohort check-publish`
apply. Without it the member waited forever, because a partner published earlier is never
rebuilt (#127). A partner in the db at a different version still holds the member back, and
a lone member never publishes next to a partner at another version.
`bin/unpublish` withdraws every member of a cohort, never one alone.

### Merge gates (all of them)

- The chroot build of the exact PR head succeeded, including its reverse-dependency checks (below).
- Every patch applied at fuzz 0 (offsets are fine).
- The change is a recipe bump. Our patch files and `DELTA` are byte-identical to the base branch.
- The agent's fix commits changed nothing in the recipe but `NOTES.md`. Its edit limits are only
  a prompt, so anything else (PKGBUILD, sources, checksums, install files) waits for a human.
- There are no flags. A flag is raised when upstream merged or closed one of the PRs our patches carry (`UPSTREAM_PRS`). It is also raised when a release contains a fix that a `fixed-upstream` line names. And it is raised when an exact-version dependency of the recipe as proposed (`depends=(x=ver)`) no longer matches upstream; this is re-checked on every run.
- `bin/ai-review` reviewed the head, and no finding is blocking: a P0/P1 finding blocks unless the verifier refuted it, and an unverified one (verifier failed) blocks too. This is the review gate for this pipeline (#77). If `codex` is missing or not logged in, or the review errors or times out, `bin/ai-review` exits non-zero and the head counts as not reviewed ("ai-review has not reviewed the head"). The PR stays open for a human, the stale package is unpublished meanwhile, and the next run retries. `AI_REVIEW=off` removes this gate entirely, so PRs then merge on the build and recipe gates alone. Use it only for testing, together with `MERGE_MODE=pr`.
- Optionally (`REQUIRE_AGENT_APPROVAL=yes`) the Claude fixer's own verdict approves too. It is not the review: the fixer is the author of its fix commits, and the review gate is the Codex `ai-review` above.
- `MERGE_MODE=auto`.

After the merge, the run publishes only if `recipes/<r>` in the merge commit is the tree it built.
`--match-head-commit` pins the PR head, not the base. If the base branch changed the same recipe
during the build and review, the squash merge holds a recipe that was never built. Then nothing
is published, the stale package is unpublished, and the next run builds the base branch's recipe.

Every PR comment and thread reply goes through the same denylist scan as the release
(`bin/sync-release --pii-scan-text`). If the body has a hit, the denylist is missing or the scan
fails, a placeholder naming the run is posted instead. The original stays in the run dir.
Messages name run files by run id and file name, never by absolute path.

### Recipe deltas

`recipes/<r>/DELTA` declares how a recipe differs from upstream, so a rebase is mechanical. `bin/rebase-recipe --help` documents the format. There are three shapes today:

- `hyprland`: Arch's PKGBUILD plus a patch appended to `prepare()` (`patch <file> prepare`).
- `linux-omarchy`: upstream's PKGBUILD. `prepare()` applies every `*.patch` in `source=()` order, so the delta is where each patch goes (`patch <file> after 0567-*`, `patch <file> end`).
- `nvidia-open-dkms`: our trimmed PKGBUILD is a template (`mode template`). Only pkgver, pkgrel and checksums follow upstream, and `arch/PKGBUILD` is refreshed for review.

Rebasing each recipe onto its current base reproduces the committed recipe. The two known exceptions are checksum formatting and nvidia's `SKIP` sums for our patches, which become real sums. Local-only packages (`recipes/<r>/LOCAL_ONLY`, plain pkgrel) have no DELTA. They are only built when the repo db lacks the recipe's version.

## Privilege model

`makechrootpkg` needs root. Nothing else does. The design keeps the two apart:

- **The code that runs as root is a root-owned copy.** `bin/install-auto-update --apply` copies the scripts to `/usr/local/lib/omarchy-asus/bin`, owned by root and not writable by group or others, and the chroots' `build/pacman.conf` and `build/pacman-rc.conf` to `/usr/local/lib/omarchy-asus/build` (root reads them: `bin/build-pkg` refuses a chroot on other servers, and `bin/mkchroot` makes the RC chroot from them). `auto-update` refuses to run as root from anywhere else, so it never runs the user-writable workspace or the bot clone. Changes to `bin/` reach the service only when the user re-runs the installer after review. `bin/install-auto-update --apply` records the source commit and the sha256 of every installed script and build file in `/usr/local/lib/omarchy-asus/installed`. Each run, right after refreshing the bot clone and before any retry, unpublish, publish or sync, compares the installed scripts and build files (and the stamp) with `bin/` and `build/` of `main` (the Quattro clone at `BASE_BRANCH`; the RC run exports them from `main` into its run dir). On any difference (a changed or new script, an installed file changed since install, or no stamp) it records a `(pipeline)` attention entry that names the fix (review the branch, then `sudo bin/install-auto-update --apply`), does nothing else and exits 1. A stale copy once unpublished omarchy because its check-upstream predated release cohorts (#127). The entry clears on the first run after the reinstall.
- **The config is root-owned too.** `/etc/omarchy-asus/auto-update.conf` must be `root:root` and not group/world-writable, or the run refuses to start. It names `BUILD_USER` and holds no secrets.
- **Every step except the chroot build runs as `BUILD_USER`** through `runuser -u BUILD_USER -- env -i ...`, with a fixed environment. That covers git, fetching upstream, rebase (its recipe code runs in the sandbox below), gpg signing, `repo-add`, `gh`, `bin/ai-review` (codex and the verifier, on the user's own logins) and the agent. The signing key, the local repo, the bot clone, logs and status stay in `~BUILD_USER/.local/share/omarchy-asus`, and root never writes there:
  - the log is written by a user-side `tee`
  - the lock is a user-side `flock`, held through a pipe to root's process
- **Recipe code runs in `bin/recipe-sandbox`.** A PKGBUILD is shell code from upstream, and `makepkg --printsrcinfo`, `--nobuild` and `--verifysource` run it. The sandbox is bubblewrap with a cleared environment, no `/home`, `/root` or `/run`, no `GH_TOKEN`, and only the recipe, work and srcdest dirs bound; it has network only for source downloads. `GH_TOKEN_FILE` and `OPENROUTER_API_KEY_FILE` are hidden too when they live elsewhere. So a compromised upstream recipe cannot read the signing key, the gh or codex logins or the token file. It needs the `bubblewrap` package and unprivileged user namespaces; without `bwrap` the run refuses to start.
- **Nothing is pushed before the PII scan.** Every commit (messages, author and committer, file paths, patch text) and the PR title and body go through the release's denylist scan and a check for local absolute paths (home dir, data dir, bot clone) before the first push or GitHub write. A hit in the rebase commit pushes nothing, opens no PR, unpublishes the stale package and records `class=pii`; a hit in a fixer commit drops that commit, the gates run on the unchanged head, and the PR waits for a human (the fixer's answers to the review may rest on the dropped edits).
- **The chroot build is the same as the interactive one.** `makechrootpkg -c -u -r /var/lib/omarchy-asus/chroot -U BUILD_USER` runs in the user's work dir with `SUDO_USER=BUILD_USER`, which is what `sudo makechrootpkg` sees today. makepkg runs as the user (or as the chroot's builduser), never as root. The recipe is copied and its PGP-verified sources are fetched as the user.
- **GitHub access is scoped.** Under systemd, gh cannot reach the desktop keyring. Use a fine-grained token limited to omarchy-asus/omarchy-asus (Contents, Pull requests and Commit statuses read/write; `bin/ai-review` posts the `ai-review` status) in a `0600` file owned by `BUILD_USER`, and set `GH_TOKEN_FILE`. Git pushes use it through `gh auth git-credential`.
- **The agent cannot act on its own.** It runs as the user with read tools plus `Edit`/`Write` limited to `recipes/<r>/**`. It has no shell and no web access. Its verdict is one gate among several. The mechanical gates (our patches untouched, fuzz 0, build of the exact head) cannot be overridden by a review, so a prompt injection in upstream content can at most block a merge.
- **Sandboxing is light.** The unit has no `ProtectSystem` or `NoNewPrivileges`, because nspawn, btrfs snapshots, bind mounts and `sudo -u` inside makechrootpkg need them off. It runs at `Nice=10` with idle I/O, the build itself at `nice 19` / `ionice -c3`. It is skipped on battery (`ConditionACPower`).

If even a root-owned copy is too much, there is an alternative. Run the unit as `User=BUILD_USER` with `MERGE_MODE=pr`, and do the chroot builds by hand. A NOPASSWD sudoers rule for makechrootpkg is **not** a safe middle ground: its `-d` bind mounts turn it into passwordless root.

## GitHub traffic

Throttling is the main external constraint, so every GitHub call is bounded:

- **No change upstream:** no GitHub API calls. The upstream dbs are cached 1h. The `UPSTREAM_PRS` state comes from the unauthenticated API and is cached 24h. The bot clone does one `git fetch`.
- **Per rebased recipe and run:**
  - one push, and one PR create (or a list call when the branch already exists)
  - per reviewed head: one PR view, one status read, two status writes, one review post (no polling)
  - at most `REPLY_LIMIT` thread replies
  - one summary comment and one merge
- **`bin/sync-release`** reads the release assets once. It uploads only new or changed files: packages and signatures first, the db last. It refuses to overwrite an existing package filename that has different bytes, and it refuses a local db whose signature does not verify against the signing key.
- **One publication at a time.** `bin/publish`, `bin/unpublish` and `bin/sync-release` share one lock (`publish.lock` in the data dir). A second caller waits up to `PUBLISH_LOCK_WAIT` seconds, then exits 75 without touching the repo or the release.
- **Publish and unpublish are staged.** They build the new repo next to the current one and check every signature before they swap it in. If a step fails, the previous repo stays in place as it was.
- **A journal marks a release that may lag.** `bin/publish` and `bin/unpublish` write `sync-pending` in the data dir before they change the local repo. `bin/sync-release` removes it only after it has checked that the release matches the local repo. While it exists, `auto-update` syncs first on its next run and reports the run as failed (as attention when the release was withheld, below), so a crash between publish and sync is retried.
- **Whole channel or nothing (#201).** Before anything goes up, `bin/sync-release` checks the local db against the recipes of the channel's branch (`bin/check-upstream --complete`, offline): every package of every recipe that isn't held must be in it at the recipe's version. If one is missing or behind, the db goes up only when it adds nothing to the db the release already serves, or when it withdraws a package the release serves: a withdrawal lets the stock build flow through where our stale copy would block or break updates, so it is never held back, and any build in the same db goes up with it (with a warning). Otherwise nothing is uploaded, the release keeps the set it had, and the sync exits 3 with the gaps listed (and written to `release-withheld` in the channel's data dir). `auto-update` takes that as attention, not a failure: it records a `(release)` entry with the gaps, and the run's later syncs put the whole set up once the last recipe is published. A recipe whose `makepkg --printsrcinfo` fails counts as a gap. So a channel never gets a new build next to a recipe that is still unbuilt or behind (on the first RC publish, or when a bump is published while another recipe is still building), except in the sync that carries a withdrawal.
- **One publisher per release.** `bin/sync-release` records the release db it last uploaded in `release-db.sha256` in the data dir (each db is recorded before its upload, so a sync that dies mid-upload is not taken for another publisher). If the release's db has changed since then (another host or a manual upload), it refuses to sync. After checking the release by hand, `SYNC_ADOPT_REMOTE=1 bin/sync-release` adopts it. `auto-update` never sets this.
- **Each release channel has its own state.** The data-dir files above (`sync-pending`, `release-db.sha256`, `prune-candidates`) are the Quattro channel's; `--channel rc` keeps its own in `channel-rc/` of the data dir, next to its own local repo (`repo/rc-x86_64`) and stage dir (`stage-rc`). The publication lock is shared. `auto-update` serves both channels, one run each ("Release channels" above), and the RC run's own status, journals and pending removals are in `channel-rc/` too.
- **The PII scan fails closed.** An archive that the scan cannot read counts as a hit, and nothing is uploaded.
- **Superseded assets are kept for a while.** Release assets that the new db no longer lists are deleted only after `PRUNE_GRACE_HOURS` (default 72 h), so a client that still has the previous db can download what it lists.
- **Upstream recipe fetches:** Arch's GitLab (not GitHub). omarchy-pkgs is a blobless clone with one fetch, run only when the kernel needs a rebase.

## Install

Prerequisites:

1. The Quattro build chroot: `bin/mkchroot` (once, with sudo). The RC chroot needs nothing:
   the service makes it (`bin/mkchroot --channel rc`) before its first RC build.
2. The signing key in `~/.local/share/omarchy-asus` (as today).
3. `gh` access for the user (see `GH_TOKEN_FILE`).
4. `codex` logged in with ChatGPT (`codex login`) for `bin/ai-review`, and `claude` for its verifier and the agent step.
   `VERIFIER=openrouter:<model>` with `OPENROUTER_API_KEY_FILE` uses OpenRouter for verification instead.
5. `bubblewrap` (`pacman -S bubblewrap`) with unprivileged user namespaces enabled (the Arch default), for `bin/recipe-sandbox`.

```bash
bin/install-auto-update                         # print the plan
sudo bin/install-auto-update --apply            # install the copy, units, config (timer off)
sudoedit /etc/omarchy-asus/auto-update.conf     # EXTRA_PATH, GH_TOKEN_FILE, ...
sudo systemctl start omarchy-asus-auto-update.service   # first run, watched:
journalctl -fu omarchy-asus-auto-update
sudo systemctl enable --now omarchy-asus-auto-update.timer
```

Re-run `sudo bin/install-auto-update --apply` after every merge that touches `bin/` (or the
installed `build/pacman*.conf`). Until then the service stops with `(pipeline)` attention and
publishes or unpublishes nothing.

**After merging the RC channel support** (the PR that made the timer serve RC), that is the one
thing to do: review `main`, then `sudo bin/install-auto-update --apply` from that checkout. The
config is kept, and its default `SERVE_CHANNELS` serves RC too; the next timer run makes the RC
chroot, builds `next/omarchy-4.5`, creates the `rc-x86_64` release and publishes to it.

Try it without root first:

- `bin/auto-update --plan` checks and prints the plan.
- `bin/auto-update --dry-run` also rebases and runs `makepkg --nobuild`. It does not build, push or publish.

Both run as you.

Status: `~/.local/share/omarchy-asus/status.md` (human) and `status.json` (machine); the RC channel's are in `channel-rc/` of that dir. Logs are in `logs/auto-update-*.log` (`auto-update-rc-*.log` for RC). A failed run shows in `systemctl --failed`.

## Uninstall

```bash
sudo bin/install-auto-update --uninstall --apply
```

This stops and disables the timer, removes the units and `/usr/local/lib/omarchy-asus`. It keeps the config, the chroots and the user's state.

## ai-review

`bin/ai-review` runs on the user's Codex login, from a local checkout; there is no review
service. `bin/auto-update` keeps it as the review gate of its rebase PRs (decided in #77),
because it runs unattended and no clud reviewer runs in that loop. The required `ai-review`
status is gone from main (#76), so the gate lives in auto-update's own merge decision (see
"Merge gates"), not in branch protection. For the maintainer's own work, which clud's `/do` and
`/grind` workflow reviews (see AGENTS.md, "Who writes, who reviews"), `bin/ai-review` is only an
optional second opinion. It stays available for outside contributors' PRs.
`bin/ai-review sweep --dry-run` lists open PRs whose head has no `ai-review` status yet.
