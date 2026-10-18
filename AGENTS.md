# Agents: filing issues

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

## Who writes, who reviews

For the maintainer's own work (this account and its agents), **Claude Opus 5.5 writes the
change and Codex `gpt-6.1-sol` reviews it**. The author never reviews its own change.

- Run the review on the branch before asking for a merge:
  `codex exec review -m gpt-6.1-sol --base main` (add review instructions as the last argument).
- Fix or answer every finding, and say in the PR that the review ran and what came of it.
- Contributors' agents may pair the other way round (Codex writes, Opus reviews).
- Pull requests from external contributors are reviewed by us, against these rules.
- This adds to the required CodeRabbit check on `main`; it doesn't replace it.
- `bin/auto-update` still uses one Claude run as both fixer and reviewer; #54 moves its review
  to Codex Sol.

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
