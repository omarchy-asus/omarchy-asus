# Agents: workflow, review and issues

The issues on [omarchy-asus/omarchy-asus](https://github.com/omarchy-asus/omarchy-asus/issues)
are the single tracker for all omarchy-asus work: kernel, nvidia, hyprland, the G16 packages,
and fixes that only exist upstream. Every Claude/Codex session files here.

## Rules

1. **Search before filing, every time:** `bin/issue find <words...> [--all]`. If an issue already
   covers it, add to it with `bin/issue comment N --body-file F`.
2. **File with the helper:** `bin/issue file --title T --label L [--label L2] --body-file F`.
   It re-runs the duplicate check (refuses on a close match; `--force` overrides and says so in
   the body), checks the labels exist, requires the body sections below, scans for personal
   information, and signs the issue with `--agent NAME` / `$AGENT_NAME`. Try `--dry-run` first.
3. **Never file on upstream projects** (omacom/omarchy, basecamp, NVIDIA, hyprwm, Arch, kernel
   mailing lists, ...). Draft the report here instead (`bin/issue template upstream-report`,
   labels `delta:upstream-only` + `upstream:not-submitted`); a human decides. The helper refuses
   any `--repo` other than this one.
4. **No personal information:** no hostnames, usernames, home paths, emails, private/tailnet
   IPs or personal device names, in titles, bodies or your agent name (use a role, e.g.
   `laptop-claude`). Say "the G16", `<build dir>`. Cite patchwork/lore by message or series ID,
   not URLs that embed email addresses. The helper aborts on denylist hits and on text with control characters other than newline and tab.
5. **Go easy on the API:** the helper caches the issue and label lists for 5 minutes under
   `~/.local/share/omarchy-asus/cache` (one `gh` call each); `--refresh` only when you need it.
   Don't loop `gh` calls per issue; batch your filings.
6. **Labels are created by a human.** `bin/issue labels` lists them.

## Workflow: from issue to published package

Run the work through **clud's built-in workflow**: `clud do <issue URL>` for one issue,
`clud grind` (or `/grind <meta issue | issue list>`) for several. clud takes each goal through
its capped roles (planner, worker, reviewer, integrator, lander; see the
[clud README](https://github.com/zackees/clud#clud-grind--burn-down-issues-to-merged-prs)). Don't
re-implement them by hand. If `/grind` or `/do` is missing from a session, clud's setup didn't
run (`~/.claude/agents/grind-*.md` absent): relaunch through `clud grind` / `clud do` rather than
working around it.

This repo fixes how those roles are filled and adds a sixth stage, publishing:

| Stage (clud role) | Who | Does | Gate before the next stage |
|---|---|---|---|
| 1. Plan (planner) | any agent | `bin/issue find`; read the code, the recipe's `NOTES.md`/`DELTA` and upstream; pick one fix per PR | an issue exists (or is filed) for the change |
| 2. Work (worker) | Claude Opus 5.5 | edit on a branch in its own worktree (`git worktree add ... hub/main`); fork fixes go on the fork branch first, then into the recipe as patches | the change is committed |
| 3. Review (reviewer) | clud's `grind-reviewer` | reviews and corrects the worker's output against the goal and these rules (What reviewers flag, below) | the reviewer accepts the change |
| 4. Integrate (integrator) | **one branch at a time** | rebase on `hub/main`; `ci/lint-scripts`; the offline tests (`tests/ci/*.sh`, `tests/test_*.py`, and the recipe's own); `bin/rebase-recipe <r> --version <v> --verify` or `makepkg --verifysource` for recipe changes; clud's `/clud-review` gate; push; open a ready PR (never a draft) | the PR is open and pushed |
| 5. Land (lander) | the integrator's PR | wait for **every required check**: Lint `scripts` and `recipes`, Build `result` (clud's `pr_merge_watch`). Resolve every review thread. Then `gh pr merge N --squash --admin`. A red check goes back to stage 4 (at most 10 rounds; then file an issue and stop) | merged on `main` |
| 6. Publish (this repo) | the build host only | packages only. `bin/build-pkg recipes/<r>` in the clean chroot (root via the build host's sudo; never a host build); `bin/publish <staged files>` (cohort members in build/cohorts.conf, e.g. omarchy + omarchy-settings, go in one call); `bin/sync-release --dry-run`, then `bin/sync-release` (the PII scan must pass); check the live channel with a throwaway pacman config (`pacman -Sl omarchy-asus`, `-Sw` verifies signatures) | the release serves the new version |

On top of clud's caps, these hold across all stages:

- **Merges wait for CI.** Lint `scripts` and `recipes` and Build `result` are required on
  `main` with admins included, so `--admin` can't merge past a pending or red check, and it
  shouldn't try.
- **A recipe change bumps `pkgrel`.** If the package content changes, the version changes:
  the release refuses a filename it already has with different bytes, and pacman caches by
  filename.
- **Held recipes** (`recipes/<r>/HOLD`, first line the reason) are merged but not built or
  published, by hand or by `bin/auto-update`, until the hold is removed in its own PR.
- **Untested kernels** stay staged, not published, until they have booted on a G16.
- **One channel per branch.** `main` is the Quattro channel (the `x86_64` release, Omarchy
  stable); `next/omarchy-4.5` is the RC channel (the `rc-x86_64` release, Omarchy rc). Stage 6
  for an RC change passes `--channel rc` to `bin/mkchroot`, `bin/build-pkg`, `bin/publish` and
  `bin/sync-release`; the default is Quattro. The `bin/auto-update` timer publishes both
  channels, from scripts installed from `main` (systemd/README.md, "Release channels").
  README.md "Release channels" has the pairing.
- **Findings outside the task** (a flaky test, an unrelated bug) are filed with `bin/issue`,
  not fixed in passing.
- **Never** publish from a branch, publish a build made outside the chroot, or put
  personal information in anything pushed, posted or uploaded.

## Who writes, who reviews

**clud's workflow is the review.** For the maintainer's own work (this account and its agents),
the `/do` and `/grind` roles above write, review and land the change; their reviewer and the
integrator's `/clud-review` gate are the review, and there is no separate review step. We are
admin: once the required CI checks are green, the lander merges with `--admin`.

- `/grind` asks which model fills each role. The session model is fine; a different model for
  the reviewer is optional (under `clud --unified` a Codex model such as `gpt-6.1-sol` can
  fill it).
- `bin/ai-review` (#50) is no longer a gate and the `ai-review` status is not required on any
  omarchy-asus repo. It stays available as an optional second opinion, and for outside
  contributors' PRs (Code Review Rules below). The exception is `bin/auto-update`: it is still
  the review gate of its unattended rebase PRs, where no clud reviewer runs (#77,
  systemd/README.md "Merge gates"). If codex is unavailable, those PRs wait for a human.
- Pull requests from external contributors are reviewed by us, against these rules, and need
  the maintainer's approving review.

## Labels

| label | meaning |
|---|---|
| `delta:kernel` / `delta:nvidia` / `delta:hyprland` | a change carried in linux-omarchy / nvidia-open-dkms / hyprland+hyprpm |
| `delta:package` | a whole package shipped by omarchy-asus |
| `delta:upstream-only` | not packaged here; tracked as an upstream PR/issue only |
| `delta:candidate` | might be carried; not yet |
| `experimental` | default-off, compile-tested only, or untested on hardware |
| `upstream:open` / `upstream:merged-unreleased` / `upstream:not-submitted` | state of the upstream PR/issue |
| `bug` | something broken in our packages or tooling |

Use one `delta:*` (or `bug`) plus one `upstream:*` where it applies.

## Body

Markdown headings, all required (`bin/issue template delta|bug|upstream-report` prints one):

- `## What happened` (bug) or `## What it fixes` (delta)
- `## Evidence / How to test`
- `## Upstream status`: upstream PR/issue number and state, or why it isn't submitted.

Title style for carried changes: `Delta: <component> <what> (<patch no.>)`, e.g.
`Delta: hid-asus Win-lock pass-through (0568)`.

## References and closing

- Refer to this repo's PRs and issues as `#N`, upstream ones as `owner/repo#N`
  (e.g. `NVIDIA/open-gpu-kernel-modules#1299`), commits by short SHA.
- Put `Fixes #N` / `Refs #N` in PR descriptions so issues link and close.
- Close an issue only when the fix is merged here or the delta is dropped; say which PR or
  commit. When upstream merges but hasn't released, keep it open and move the label to
  `upstream:merged-unreleased`; close once a release we build from contains it and the patch
  is dropped from the recipe.

## Without this checkout

`bin/issue` is preferred (it does the duplicate and PII checks). If you can't run it, do the same
by hand and scan your text for personal information yourself:

```sh
R=omarchy-asus/omarchy-asus
gh issue list -R $R --state all --search "winlock in:title,body" --json number,title,state,labels
gh label list -R $R
gh issue create -R $R --title "..." --label delta:kernel --label upstream:open --body-file body.md
gh issue comment N -R $R --body-file comment.md
```

End the body with `Filed by <agent role>`.

## Code Review Rules

Our own work is reviewed inside clud's workflow (Who writes, who reviews, above): no `ai-review`
status, no review threads on GitHub. Your own account's PRs merge with
`gh pr merge N --squash --admin` once the required CI checks are green. `--admin` bypasses the
approval ruleset, not CI. Every review thread must be resolved.

Outside contributors' PRs need the maintainer's approving review. `bin/ai-review` can help with
that review, so the contributor sees every finding on GitHub:

1. `bin/ai-review pr N --checkout .` on their head (or without `--checkout`: a temporary clone),
   settle findings with `--reply answers.json` (`{"<id>": "why this is not a defect"}`), then
   `bin/ai-review pr N --checkout . --post`: one review (inline comments, answers, the
   reviewer's checks).
2. Everything ai-review posts goes through the secret and PII scan first. A hit posts nothing;
   fix the text it came from (usually your code), not the scan.

What reviewers flag:

- Flag only what breaks: wrong behaviour with a concrete trigger, fail-open safety checks
  (signing, checksums, the PII scan, merge/publish gates), privilege mistakes between root
  and `BUILD_USER`, and packages that would conflict with or shadow stock Omarchy files.
- Personal information in a tracked file or anything posted to GitHub is P1 (see rule 4).
- Upstream content in a rebased recipe is upstream's: flag it only when it is unsafe to sign
  and ship (new download hosts, disabled checksum or signature checks, new install scripts).
- No style, naming or formatting findings; CI and shellcheck own those.
