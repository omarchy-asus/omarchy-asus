#!/bin/bash
# Removing a recipe retires its published packages (#82): bin/auto-update-state plans
# "unpublish" for a repo db entry with no recipe, whatever its check-upstream status,
# unless KEEP_PUBLISHED names it, or check-upstream reports inventory_errors (or the
# check JSON has no inventory_errors key) and the entry is not stale. Offline: a
# hand-made check-upstream JSON.
#
# CI runs this with plain bash on ubuntu-24.04, which has no vercmp. bin/auto-update-state
# only calls vercmp when it compares two versions (VerKey.__lt__): every case here has a
# single row, so max() over the upstream versions never compares, and recipe rows have no
# hold, so the hold branch (which compares the repo copy with upstream) is skipped.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
row() {  # row <name> <status> <version> [upstream json, default null]: a db entry with no recipe
    printf '{"name":"%s","ours":"%s","base":null,"repo":"%s","local_only":false,"hold":null,"upstream":%s,"upstream_repo":null,"recipe":null,"status":"%s","dep_mismatch":[]}' \
        "$1" "$3" "$3" "${4:-null}" "$2"
}
recipe_row() {  # recipe_row <recipe> <status> <version>: a recipe present on the base branch
    printf '{"name":"%s","ours":"%s","base":null,"repo":"%s","local_only":false,"hold":null,"upstream":"1.0-1","upstream_repo":"omarchy","recipe":"%s","status":"%s","dep_mismatch":[]}' \
        "$1" "$3" "$3" "$1" "$2"
}
plan_out() {  # plan_out <rows json> [inventory_errors fragment; empty omits the key]
    local inv=${2-'"inventory_errors":[]'}
    printf '{"packages":[%s],"prs":[]%s}' "$1" "${inv:+,$inv}" >"$T/check.json"
    KEEP_PUBLISHED=${KEEP:-} SKIP_RECIPES='' BUILD_NOT_BUILT=yes \
        "$W/bin/auto-update-state" plan "$T/check.json" "$T/status.json"
}
plan_action() {  # plan_action <rows json> [inventory_errors fragment]
    plan_out "$@" | cut -f2
}
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
expect "deleted local-only recipe (bad-pkgrel): unpublish" \
    "$(plan_action "$(row gone-local bad-pkgrel 1.0-3)")" unpublish
expect "deleted local-only recipe: the in-repo column names the package for bin/unpublish" \
    "$(plan_out "$(row gone-local bad-pkgrel 1.0-3)" | cut -f4)" gone-local
expect "removed recipe, current: unpublish" \
    "$(plan_action "$(row gone current 1.0-1.1 '"1.0-1"')")" unpublish
expect "removed recipe, not-upstream: unpublish" \
    "$(plan_action "$(row gone not-upstream 1.0-1)")" unpublish
expect "removed recipe, rebuild-needed: unpublish" \
    "$(plan_action "$(row gone rebuild-needed 1.0-1.1 '"2.0-1"')")" unpublish
expect "removed recipe kept by KEEP_PUBLISHED: attention" \
    "$(KEEP="other gone-local" plan_action "$(row gone-local bad-pkgrel 1.0-3)")" attention
expect "removed recipe, inventory errors: attention" \
    "$(plan_action "$(row gone current 1.0-1.1 '"1.0-1"')" '"inventory_errors":["somerecipe"]')" attention
expect "removed recipe, no inventory_errors key: attention" \
    "$(plan_action "$(row gone current 1.0-1.1 '"1.0-1"')" '')" attention
expect "removed recipe, stale, inventory errors: still unpublish (stale pins block updates)" \
    "$(plan_action "$(row gone rebuild-needed 1.0-1.1 '"2.0-1"')" '"inventory_errors":["somerecipe"]')" unpublish
expect "removed recipe, stale, no inventory_errors key: still unpublish" \
    "$(plan_action "$(row gone upstream-older 1.0-1.1 '"0.9-1"')" '')" unpublish
expect "recipe still present, current: current" \
    "$(plan_action "$(recipe_row a current 1.0-1.1)")" current
exit $fails
