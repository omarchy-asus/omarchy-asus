#!/bin/bash
# shellcheck disable=SC2034  # the globals are read by the bin/auto-update functions eval'd below
# The installed auto-update stops on a stale pipeline (#127). The real pipeline_drift and
# pipeline_guard run against a fake installed copy, its install stamp (the
# bin/install-auto-update format) and a fake bot clone:
#   1. installed copy, stamp and clone agree: no drift
#   2. a script changed on the base branch: drift, the reason names it
#   3. no install stamp: drift
#   4. an installed script edited after the install: drift, the reason names it
#   5. the base branch's installer lists a new script: drift, the reason names it
#   6. pipeline_guard on drift: returns 1, records "(pipeline)" attention naming the fix,
#      and runs no unpublish, publish or sync
#   7. pipeline_guard once the clone matches again: returns 0, the entry is gone
# Offline: no network, no sudo, no bwrap.
set -u
for t in jq python3 sha256sum; do
    command -v "$t" >/dev/null && continue
    # The runner ships them (.github/workflows/lint.yml): a skip there is a failure
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
for f in pipeline_drift pipeline_guard; do
    body=$(awk -v f="$f" 'index($0, f "() {") == 1, /^\}/' "$W/bin/auto-update")
    if [[ -z $body ]]; then echo "not ok - cannot extract $f() from bin/auto-update"; fails=1; continue; fi
    eval "$body"
done

# What they call, stubbed.
as_user() { "$@"; }
note() { echo "[$1] $2"; }
record() { "$W/bin/auto-update-state" record "$STATUS" testrun "$@"; }
sync_now() { echo sync >>"$T/calls"; }
ugit() { echo abc1234; }

mode=full failed=0 attention=0 BASE_BRANCH=main
LIB=$T/lib/bin CLONE=$T/clone STATUS=$T/status.json STAMP=$T/lib/installed
mkdir -p "$LIB" "$CLONE/bin"
# The installed scripts log to $T/calls when run: the guard must run none of them.
for f in auto-update publish; do
    printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$f" "$T/calls" >"$LIB/$f"
    chmod +x "$LIB/$f"
done
cp "$LIB/auto-update" "$LIB/publish" "$CLONE/bin/"
installer() { printf '#!/bin/bash\nscripts=(%s)\n' "$*" >"$CLONE/bin/install-auto-update"; }
installer auto-update publish
{ printf '# x\nsource %s\n' 0123456789abcdef0123456789abcdef01234567
  (cd "$LIB" && sha256sum -- auto-update publish); } >"$STAMP"
# Not in the stamp, so not part of the comparison: what the guard calls.
ln -s "$W/bin/auto-update-state" "$LIB/auto-update-state"
stub() {  # stub <name>: logs "<name> <args>" to $T/calls
    printf '#!/bin/bash\necho "%s $*" >>"%s"\n' "$1" "$T/calls" >"$LIB/$1"
    chmod +x "$LIB/$1"
}
stub unpublish
calls() { : >"$T/calls"; }
restore() { cp "$LIB/auto-update" "$LIB/publish" "$CLONE/bin/"; installer auto-update publish; }
has_entry() { jq -r --arg r "$1" '.recipes | has($r)' "$STATUS" 2>/dev/null || echo "no status.json"; }
entry_result() { jq -r --arg r "$1" '.recipes[$r].last.result // "none"' "$STATUS" 2>/dev/null || echo none; }
has() { if [[ $1 == *"$2"* ]]; then echo yes; else echo "no ('$1')"; fi; }

# 1. identical: no drift
rc=0; out=$(pipeline_drift "$STAMP" "$LIB" "$CLONE") || rc=$?
expect "1. identical: no drift" "$rc" 1
expect "1. identical: no reason" "$out" ""

# 2. a script changed on the base branch
echo '# changed' >>"$CLONE/bin/publish"
rc=0; out=$(pipeline_drift "$STAMP" "$LIB" "$CLONE") || rc=$?
expect "2. clone changed: drift" "$rc" 0
expect "2. clone changed: the reason names publish" "$(has "$out" "differ from bin/ on the base branch: publish")" yes
restore

# 3. no install stamp
mv "$STAMP" "$STAMP.away"
rc=0; out=$(pipeline_drift "$STAMP" "$LIB" "$CLONE") || rc=$?
expect "3. no stamp: drift" "$rc" 0
expect "3. no stamp: the reason says so" "$(has "$out" "no install stamp")" yes
mv "$STAMP.away" "$STAMP"

# 4. an installed script edited after the install
cp "$LIB/auto-update" "$T/auto-update.orig"
echo '# edited in place' >>"$LIB/auto-update"
rc=0; out=$(pipeline_drift "$STAMP" "$LIB" "$CLONE") || rc=$?
expect "4. installed copy edited: drift" "$rc" 0
expect "4. installed copy edited: the reason names it" "$(has "$out" "installed auto-update changed since install")" yes
cp "$T/auto-update.orig" "$LIB/auto-update"

# 5. a new script on the base branch
installer auto-update publish check-upstream
rc=0; out=$(pipeline_drift "$STAMP" "$LIB" "$CLONE") || rc=$?
expect "5. new script: drift" "$rc" 0
expect "5. new script: the reason names it" "$(has "$out" "new script(s) on the base branch: check-upstream")" yes
restore

# 6. pipeline_guard on drift: attention recorded, nothing published, unpublished or synced
echo '# changed' >>"$CLONE/bin/publish"
calls; attention=0
rc=0; pipeline_guard >"$T/out" 2>&1 || rc=$?
expect "6. guard on drift: returns 1" "$rc" 1
expect "6. guard on drift: attention" "$attention" 1
expect "6. guard on drift: \"(pipeline)\" attention recorded" "$(entry_result "(pipeline)")" attention
expect "6. guard on drift: the entry names the fix" \
    "$(has "$(jq -c '.recipes["(pipeline)"]' "$STATUS" 2>/dev/null)" "install-auto-update --apply")" yes
expect "6. guard on drift: the entry names the stamp's source" \
    "$(has "$(jq -c '.recipes["(pipeline)"]' "$STATUS" 2>/dev/null)" "source 0123456789ab")" yes
expect "6. guard on drift: no unpublish, publish or sync ran" "$(cat "$T/calls")" ""

# 7. the clone matches again: the entry goes
restore; calls
rc=0; pipeline_guard >"$T/out" 2>&1 || rc=$?
expect "7. guard, no drift: returns 0" "$rc" 0
expect "7. guard, no drift: \"(pipeline)\" cleared" "$(has_entry "(pipeline)")" false
expect "7. guard, no drift: nothing ran" "$(cat "$T/calls")" ""
exit $fails
