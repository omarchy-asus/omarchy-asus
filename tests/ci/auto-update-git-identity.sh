#!/bin/bash
# The bot commits with a fixed identity (#146). The real ugit() runs `git commit` in a
# temp clone the way as_user does under root: env -i with only HOME set, to an empty
# home, so no global or system git identity applies:
#   1. the commit succeeds
#   2. it carries the bot's name and email
# Offline: no network, no sudo.
set -u
command -v git >/dev/null || { [[ -n ${CI:-} ]] && { echo "FAIL: git missing on CI"; exit 1; }; echo "skip: git missing"; exit 0; }
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected '$3', got '$2'"; fails=1; fi
}

# The identity and ugit(), verbatim from bin/auto-update.
eval "$(grep -E '^AU_GIT_(NAME|EMAIL)=' "$W/bin/auto-update")"
body=$(grep -E '^ugit\(\) \{' "$W/bin/auto-update")
[[ -n $body ]] || { echo "not ok - cannot extract ugit() from bin/auto-update"; exit 1; }
eval "$body"

as_user() { env -i HOME="$T/home" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 "$@"; }
mkdir -p "$T/home"
CLONE=$T/clone
git init -q "$CLONE"
echo x >"$CLONE/f"
ugit add f

ugit commit --quiet -m "test" >"$T/out" 2>&1
expect "1. the commit succeeds" "$?" 0
expect "2. bot identity" "$(git -C "$CLONE" log -1 --format='%an <%ae>|%cn <%ce>' 2>/dev/null)" \
    "${AU_GIT_NAME:-?} <${AU_GIT_EMAIL:-?}>|${AU_GIT_NAME:-?} <${AU_GIT_EMAIL:-?}>"
((fails)) && { cat "$T/out"; echo FAILED; exit 1; }
echo "all passed"
