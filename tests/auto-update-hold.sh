#!/bin/bash
# A recipe with recipes/<r>/HOLD is never built or published by bin/auto-update:
# bin/auto-update-state plans "attention" for it, and "unpublish" when a stale copy
# of it is in the repo db. Offline: a hand-made check-upstream JSON.
set -u
W=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
row() {  # row <recipe> <status> <repo version or null> [hold]
    local hold=${4:+\"$4\"}
    printf '{"name":"%s","ours":"1.0-1.1","base":"1.0-1","repo":%s,"local_only":false,"hold":%s,"upstream":"1.0-1","upstream_repo":"omarchy","recipe":"%s","status":"%s","dep_mismatch":[]}' \
        "$1" "$3" "${hold:-null}" "$1" "$2"
}
plan_action() {  # plan_action <rows json>
    printf '{"packages":[%s],"prs":[]}' "$1" >"$T/check.json"
    BUILD_NOT_BUILT=yes "$W/bin/auto-update-state" plan "$T/check.json" "$T/status.json" | cut -f2
}
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
expect "not built, no hold: build" "$(plan_action "$(row a not-built null)")" build
expect "not built, held: attention" "$(plan_action "$(row a not-built null 'waiting for the laptop')")" attention
expect "repo stale, held: attention" "$(plan_action "$(row a repo-stale '"0.9-1.1"' 'waiting')")" attention
expect "upstream moved, held, not in repo: attention" "$(plan_action "$(row a rebuild-needed null 'waiting')")" attention
expect "upstream moved, held, in repo: unpublish" "$(plan_action "$(row a rebuild-needed '"1.0-1.1"' 'waiting')")" unpublish
expect "upstream moved, no hold: rebase" "$(plan_action "$(row a rebuild-needed '"1.0-1.1"')")" rebase
exit $fails
