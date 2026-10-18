# omarchy-asus auto-update service

A daily systemd timer keeps the omarchy-asus repo current with upstream:

- Arch packages come through the Omarchy stable mirror.
- `linux-omarchy` comes from `[omarchy]`.

When upstream moves past a package's base version, the service has two outcomes:

- It rebases our patches onto the new upstream recipe. The PR goes through a chroot build, a verified AI review (`bin/ai-review`) and an agent review. It merges and publishes only when every gate passes.
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
  └─ auto-update (root, root-owned copy)
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
                             → headless agent: fixes or answers the blocking findings (edits only
                               recipes/<r>/, never our patches/DELTA), second-opinion verdict
                             → fixes pushed? rebuild + ai-review of the new head (≤ MAX_FIX_ROUNDS)
                               (a fix outside NOTES.md is never auto-merged: a human merges)
                             → one PR comment with the results
                             → gates all pass: squash-merge, bin/publish, bin/sync-release
                               otherwise: PR stays open (next run resumes it), stale package
                               unpublished meanwhile
            build      recipe on the branch not in the repo db: build, publish, sync
            unpublish  stale and nothing to rebuild from
            attention  listed in the status, no automatic change (e.g. upstream merged one of
                       our patches' PRs: flagged, never dropped automatically)
```

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

`bin/auto-update --plan` lists the checks a pending build would trigger. To run one by
hand (it uses sudo for the chroot steps):

```bash
bin/revdep-check --headers ~/.local/share/omarchy-asus/repo/x86_64/linux-omarchy-headers-<ver>-x86_64.pkg.tar.zst \
                 --dkms ~/.local/share/omarchy-asus/repo/x86_64/nvidia-open-dkms-<ver>-x86_64.pkg.tar.zst
```

### Merge gates (all of them)

- The chroot build of the exact PR head succeeded, including its reverse-dependency checks (below).
- Every patch applied at fuzz 0 (offsets are fine).
- The change is a recipe bump. Our patch files and `DELTA` are byte-identical to the base branch.
- The agent's fix commits changed nothing in the recipe but `NOTES.md`. Its edit limits are only
  a prompt, so anything else (PKGBUILD, sources, checksums, install files) waits for a human.
- There are no flags. A flag is raised when upstream merged or closed one of the PRs our patches carry (`UPSTREAM_PRS`). It is also raised when a release contains a fix that a `fixed-upstream` line names. And it is raised when an exact-version dependency of the recipe as proposed (`depends=(x=ver)`) no longer matches upstream; this is re-checked on every run.
- `bin/ai-review` reviewed the head, and no finding is blocking: a P0/P1 finding blocks unless the verifier refuted it, and an unverified one (verifier failed) blocks too.
- The agent's second opinion approves (`REQUIRE_AGENT_APPROVAL=yes`). If `claude` is missing or `REVIEW_CMD` is empty, the PR waits for a human.
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

- **The code that runs as root is a root-owned copy.** `bin/install-auto-update --apply` copies the scripts to `/usr/local/lib/omarchy-asus/bin`, owned by root and not writable by group or others. `auto-update` refuses to run as root from anywhere else, so it never runs the user-writable workspace or the bot clone. Changes to `bin/` reach the service only when the user re-runs the installer after review. The run logs a note when the installed copy differs from the branch.
- **The config is root-owned too.** `/etc/omarchy-asus/auto-update.conf` must be `root:root` and not group/world-writable, or the run refuses to start. It names `BUILD_USER` and holds no secrets.
- **Every step except the chroot build runs as `BUILD_USER`** through `runuser -u BUILD_USER -- env -i ...`, with a fixed environment. That covers git, fetching upstream, rebase, `makepkg --nobuild`, gpg signing, `repo-add`, `gh`, `bin/ai-review` (codex and the verifier, on the user's own logins) and the agent. The signing key, the local repo, the bot clone, logs and status stay in `~BUILD_USER/.local/share/omarchy-asus`, and root never writes there:
  - the log is written by a user-side `tee`
  - the lock is a user-side `flock`, held through a pipe to root's process
- **The chroot build is the same as the interactive one.** `makechrootpkg -c -u -r /var/lib/omarchy-asus/chroot -U BUILD_USER` runs in the user's work dir with `SUDO_USER=BUILD_USER`, which is what `sudo makechrootpkg` sees today. makepkg runs as the user (or as the chroot's builduser), never as root. The recipe is copied and its PGP-verified sources are fetched as the user.
- **GitHub access is scoped.** Under systemd, gh cannot reach the desktop keyring. Use a fine-grained token limited to omarchy-asus/omarchy-asus (Contents and Pull requests read/write) in a `0600` file owned by `BUILD_USER`, and set `GH_TOKEN_FILE`. Git pushes use it through `gh auth git-credential`.
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
- **`bin/sync-release`** reads the release assets once. It uploads only new or changed files: packages and signatures first, the db last. It deletes stale assets after the new db is up, and it refuses to overwrite an existing package filename that has different bytes.
- **Upstream recipe fetches:** Arch's GitLab (not GitHub). omarchy-pkgs is a blobless clone with one fetch, run only when the kernel needs a rebase.

## Install

Prerequisites:

1. The build chroot: `bin/mkchroot` (once, with sudo).
2. The signing key in `~/.local/share/omarchy-asus` (as today).
3. `gh` access for the user (see `GH_TOKEN_FILE`).
4. `codex` logged in with ChatGPT (`codex login`) for `bin/ai-review`, and `claude` for its verifier and the agent step.
   `VERIFIER=openrouter:<model>` with `OPENROUTER_API_KEY_FILE` uses OpenRouter for verification instead.

```bash
bin/install-auto-update                         # print the plan
sudo bin/install-auto-update --apply            # install the copy, units, config (timer off)
sudoedit /etc/omarchy-asus/auto-update.conf     # EXTRA_PATH, GH_TOKEN_FILE, ...
sudo systemctl start omarchy-asus-auto-update.service   # first run, watched:
journalctl -fu omarchy-asus-auto-update
sudo systemctl enable --now omarchy-asus-auto-update.timer
```

Try it without root first:

- `bin/auto-update --plan` checks and prints the plan.
- `bin/auto-update --dry-run` also rebases and runs `makepkg --nobuild`. It does not build, push or publish.

Both run as you.

Status: `~/.local/share/omarchy-asus/status.md` (human) and `status.json` (machine). Logs are in `logs/auto-update-*.log`. A failed run shows in `systemctl --failed`.

## Uninstall

```bash
sudo bin/install-auto-update --uninstall --apply
```

This stops and disables the timer, removes the units and `/usr/local/lib/omarchy-asus`. It keeps the config, the chroot and the user's state.

## ai-review for every PR (user timer)

`bin/ai-review` replaces CodeRabbit for every repo the user can reach, not only for the
pipeline's own PRs. `systemd/omarchy-asus-ai-review.{service,timer}` are **user** units
(codex and claude run on the user's own logins): every 10 minutes, `bin/ai-review sweep --post`
reviews each open PR of the user and its organisations whose head has no `ai-review`
status yet, and posts one review plus the `ai-review` commit status. Branch protection
requires `ai-review` in place of `CodeRabbit`.

```bash
install -Dm644 -t ~/.config/systemd/user systemd/omarchy-asus-ai-review.{service,timer}
systemctl --user daemon-reload && systemctl --user enable --now omarchy-asus-ai-review.timer
bin/ai-review sweep --dry-run          # what the next run would review
bin/ai-review pr N --repo OWNER/REPO   # one PR, printed, nothing posted
```

GitHub traffic per sweep: one search per owner, then one PR view and one status read per
open PR; a review adds two status writes and one review post.
