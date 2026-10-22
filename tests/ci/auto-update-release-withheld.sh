#!/bin/bash
# shellcheck disable=SC2034  # the globals are read by the bin/auto-update functions eval'd below
# A release that bin/sync-release withholds (exit 3: the channel is not complete, #201) is
# attention, not a failed run. The real sync_now and sync_state_check run against a stub
# bin/sync-release:
#   1. withheld: the run is not failed, sync-pending stays, and the end of the run records
#      "(release)" attention with the gaps from release-withheld
#   2. a later sync of the set goes through: "(release)" is dropped, nothing pending
#   3. a sync that fails otherwise (exit 1) after a withheld one: the run fails, and the end
#      of the run reports the pending sync, not a withheld release
# Offline: no network, no sudo, no bwrap.
set -u
for t in jq python3; do
    command -v "$t" >/dev/null && continue
    # The runner ships both (.github/workflows/lint.yml): a skip there is a failure
    [[ -n ${CI:-} ]] && { echo "FAIL: $t missing on CI"; exit 1; }
    echo "skip: $t missing"; exit 0
done
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected '$3', got '$2'"; fails=1; fi
}

# The functions under test, verbatim from bin/auto-update.
for f in sync_now sync_state_check; do
    body=$(awk -v f="$f" 'index($0, f "() {") == 1, /^\}/' "$W/bin/auto-update")
    if [[ -z $body ]]; then echo "not ok - cannot extract $f() from bin/auto-update"; fails=1; continue; fi
    eval "$body"
done

# What they call, stubbed.
as_user() { "$@"; }
note() { echo "[$1] $2"; }
record() { "$W/bin/auto-update-state" record "$STATUS" testrun "$@"; }

mode=full failed=0 attention=0 CHANNEL=rc GH_TAG=rc-x86_64
STATUS=$T/status.json CHANNEL_DATA=$T/data/channel-rc AU=$T/au LIB=$T/lib
mkdir -p "$CHANNEL_DATA" "$AU" "$LIB"
ln -s "$W/bin/auto-update-state" "$LIB/auto-update-state"
# sync-release: exits $STUB_SYNC_RC; 0 clears the journal and release-withheld as the real one
# does, 3 writes the gaps to release-withheld
cat >"$LIB/sync-release" <<EOF
#!/bin/bash
case \${STUB_SYNC_RC:-0} in
    0) rm -f "$CHANNEL_DATA/sync-pending" "$CHANNEL_DATA/release-withheld" ;;
    3) echo 'not-built linux-omarchy 7.2.8-9.4 (recipes/linux-omarchy)' >"$CHANNEL_DATA/release-withheld" ;;
esac
exit "\${STUB_SYNC_RC:-0}"
EOF
chmod +x "$LIB/sync-release"
exists() { if [[ -e $1 ]]; then echo yes; else echo no; fi; }
entry() { jq -r --arg r "$1" '.recipes[$r].last.result // "none"' "$STATUS" 2>/dev/null || echo none; }

# 1. withheld
touch "$CHANNEL_DATA/sync-pending"
STUB_SYNC_RC=3 sync_now >"$T/out" 2>&1
expect "1. withheld: the run is not failed" "$failed" 0
expect "1. withheld: sync-pending stays" "$(exists "$CHANNEL_DATA/sync-pending")" yes
expect "1. withheld: the note says so" "$(grep -c 'release withheld' "$T/out")" 1
sync_state_check >"$T/out" 2>&1
expect "1. end of run: not failed" "$failed" 0
expect "1. end of run: attention" "$attention" 1
expect "1. end of run: \"(release)\" attention recorded" "$(entry "(release)")" attention
expect "1. end of run: the entry names the gap" \
    "$(jq -r '.recipes["(release)"].last.message' "$STATUS" | grep -c 'not-built linux-omarchy')" 1

# 2. the whole set goes up
attention=0
STUB_SYNC_RC=0 sync_now >"$T/out" 2>&1
sync_state_check >"$T/out" 2>&1
expect "2. synced: not failed" "$failed" 0
expect "2. synced: no attention" "$attention" 0
expect "2. synced: \"(release)\" dropped" "$(jq -r '.recipes | has("(release)")' "$STATUS")" false

# 3. withheld, then a sync that fails otherwise
touch "$CHANNEL_DATA/sync-pending"
STUB_SYNC_RC=3 sync_now >"$T/out" 2>&1
STUB_SYNC_RC=1 sync_now >"$T/out" 2>&1
expect "3. failed sync: the run fails" "$failed" 1
expect "3. failed sync: release-withheld is dropped" "$(exists "$CHANNEL_DATA/release-withheld")" no
failed=0 attention=0
sync_state_check >"$T/out" 2>&1
expect "3. end of run: the pending sync fails the run" "$failed" 1
expect "3. end of run: not reported as withheld" "$(jq -r '.recipes | has("(release)")' "$STATUS")" false
exit $fails
