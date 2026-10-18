#!/bin/bash
# A recipe with recipes/<r>/HOLD is never built or published by bin/auto-update:
# bin/auto-update-state plans "attention" for it, and "unpublish" when a stale copy
# of it is in the repo db. Offline: a hand-made check-upstream JSON.
#
# CI runs this with plain bash on ubuntu-24.04, which has no vercmp. The hold branch of
# bin/auto-update-state compares the repo copy with upstream (VerKey.__lt__ runs vercmp),
# so where vercmp is missing a sort -V stub stands in for it: enough for the plain
# versions below, not a general pacman vercmp.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
if ! command -v vercmp >/dev/null; then
    mkdir -p "$T/bin"
    cat >"$T/bin/vercmp" <<'EOF'
#!/bin/bash
if [[ $1 == "$2" ]]; then echo 0
elif [[ $(printf '%s\n' "$1" "$2" | sort -V | head -1) == "$1" ]]; then echo -1
else echo 1
fi
EOF
    chmod +x "$T/bin/vercmp"
    export PATH=$T/bin:$PATH
    echo "note: vercmp missing, using a sort -V stub"
fi
fails=0
row() {  # row <recipe> <status> <repo version or null> [hold] [ours] [upstream]
    local hold=${4:+\"$4\"}
    printf '{"name":"%s","ours":"%s","base":null,"repo":%s,"local_only":false,"hold":%s,"upstream":"%s","upstream_repo":"omarchy","recipe":"%s","status":"%s","dep_mismatch":[]}' \
        "$1" "${5:-1.0-1.1}" "$3" "${hold:-null}" "${6:-1.0-1}" "$1" "$2"
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
expect "repo stale and behind upstream, held: unpublish" "$(plan_action "$(row a repo-stale '"0.9-1.1"' 'waiting')")" unpublish
expect "upstream moved, held, not in repo: attention" "$(plan_action "$(row a rebuild-needed null 'waiting')")" attention
expect "upstream moved, held, in repo: unpublish" "$(plan_action "$(row a rebuild-needed '"1.0-1.1"' 'waiting')")" unpublish
expect "recipe current, held, older copy in repo: unpublish" "$(plan_action "$(row a repo-stale '"1.0-1.1"' 'waiting' 2.0-1.1 2.0-1)")" unpublish
expect "held, newer unpublished copy than upstream: attention" "$(plan_action "$(row a repo-stale '"2.0-1.2"' 'waiting' 2.0-1.1 2.0-1)")" attention
expect "upstream moved, no hold: rebase" "$(plan_action "$(row a rebuild-needed '"1.0-1.1"')")" rebase
exit $fails
