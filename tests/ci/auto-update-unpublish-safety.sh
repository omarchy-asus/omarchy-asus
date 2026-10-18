#!/bin/bash
# shellcheck disable=SC2034  # the globals are read by the bin/auto-update functions eval'd below
# Withdrawals in bin/auto-update fail closed (#89). The real unpublish_now, retry_unpublish,
# pending_edit and upstream_dbs_check run against stub bin/unpublish and bin/revdep-check:
#   1. a good build/revdeps.conf: the retained DKMS package is compiled against the stock
#      headers, then the kernel is withdrawn
#   2. (a) the conf unreadable (a directory): nothing is withdrawn, a "(dkms check)"
#      attention entry is recorded
#   3. the conf readable again: the next withdrawal clears that entry
#   4. (b) a retried headers removal gets the same check, and a DKMS package that fails it
#      goes too
#   5. (b) a retry with the conf unreadable: nothing withdrawn, the run fails, still pending
#   6. (c) degraded upstream dbs record "(upstream dbs)"; recovered dbs clear it
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
for f in unpublish_now retry_unpublish pending_edit upstream_dbs_check; do
    body=$(awk -v f="$f" 'index($0, f "() {") == 1, /^\}/' "$W/bin/auto-update")
    if [[ -z $body ]]; then echo "not ok - cannot extract $f() from bin/auto-update"; fails=1; continue; fi
    eval "$body"
done

# What they call, stubbed.
as_user() { "$@"; }
note() { echo "[$1] $2"; }
record() { "$W/bin/auto-update-state" record "$STATUS" testrun "$@"; }
sync_now() { echo sync >>"$T/calls"; }
# shellcheck disable=SC2086  # one name per word
repo_names() { printf '%s\n' $REPO_NAMES; }
pkg_file() { echo "$T/repo/$2-1-1-x86_64.pkg.tar.zst"; }

mode=full failed=0 attention=0 REPO_NAMES=
CLONE=$T/ws STATUS=$T/status.json RUN=$T/run REPO_DIR=$T/repo PENDING_UNPUB=$T/pending
DATA=$T/data AU=$T/au LIB=$T/lib
mkdir -p "$CLONE/build" "$RUN" "$REPO_DIR" "$DATA" "$AU" "$LIB"
ln -s "$W/bin/auto-update-state" "$LIB/auto-update-state"
stub() {  # stub <name> <exit code variable>: logs "<name> <args>" to $T/calls
    printf '#!/bin/bash\necho "%s $*" >>"%s"\nexit "${%s:-0}"\n' "$1" "$T/calls" "$2" >"$LIB/$1"
    chmod +x "$LIB/$1"
}
stub unpublish STUB_UNPUBLISH_RC
stub revdep-check STUB_REVDEP_RC
unset STUB_UNPUBLISH_RC STUB_REVDEP_RC

conf_good() {
    rm -rf "$CLONE/build/revdeps.conf"
    echo 'linux-omarchy dkms:nvidia-open-dkms headers=linux-omarchy-headers' >"$CLONE/build/revdeps.conf"
}
conf_unreadable() {  # a directory: unreadable even for root
    rm -rf "$CLONE/build/revdeps.conf"
    mkdir "$CLONE/build/revdeps.conf"
}
calls() { : >"$T/calls"; }
unpub_line() { grep '^unpublish' "$T/calls"; }
has_entry() { jq -r --arg r "$1" '.recipes | has($r)' "$STATUS" 2>/dev/null || echo "no status.json"; }
entry_result() { jq -r --arg r "$1" '.recipes[$r].last.result // "none"' "$STATUS" 2>/dev/null || echo none; }

# 1. good conf: revdep-check, then unpublish
conf_good; calls; REPO_NAMES="linux-omarchy linux-omarchy-headers nvidia-open-dkms"
rc=0; unpublish_now linux-omarchy,linux-omarchy-headers "test" >"$T/out" 2>&1 || rc=$?
expect "1. good conf: exit 0" "$rc" 0
expect "1. good conf: the DKMS check runs before the withdrawal" \
    "$(cut -d' ' -f1 "$T/calls" | paste -sd' ')" "revdep-check unpublish sync"
expect "1. good conf: the DKMS package builds against stock headers, so it stays" \
    "$(unpub_line)" "unpublish linux-omarchy linux-omarchy-headers"

# 2. (a) unreadable conf: no withdrawal, attention recorded
conf_unreadable; calls
rc=0; unpublish_now linux-omarchy,linux-omarchy-headers "test" >"$T/out" 2>&1 || rc=$?
expect "2. unreadable conf: unpublish_now fails" "$((rc != 0))" 1
expect "2. unreadable conf: bin/unpublish not run" "$(grep -c '^unpublish' "$T/calls")" 0
expect "2. unreadable conf: \"(dkms check)\" attention recorded" "$(entry_result "(dkms check)")" attention
expect "2. unreadable conf: the note says nothing was withdrawn" \
    "$(grep -c 'NOT withdrawing linux-omarchy linux-omarchy-headers' "$T/out")" 1

# 3. conf readable again: the entry goes
conf_good; calls
rc=0; unpublish_now linux-omarchy,linux-omarchy-headers "test" >"$T/out" 2>&1 || rc=$?
expect "3. recovered conf: exit 0" "$rc" 0
expect "3. recovered conf: \"(dkms check)\" cleared" "$(has_entry "(dkms check)")" false

# 4. (b) a retry gets the DKMS check; a failing DKMS package is withdrawn with the headers
conf_good; calls; printf 'linux-omarchy-headers\n' >"$PENDING_UNPUB"
REPO_NAMES="linux-omarchy-headers nvidia-open-dkms" failed=0
export STUB_REVDEP_RC=1
retry_unpublish >"$T/out" 2>&1
unset STUB_REVDEP_RC
expect "4. retry: revdep-check runs" "$(grep -c '^revdep-check' "$T/calls")" 1
expect "4. retry: the failing DKMS package goes with the headers" \
    "$(unpub_line)" "unpublish linux-omarchy-headers nvidia-open-dkms"
expect "4. retry: run not failed" "$failed" 0
expect "4. retry: nothing pending" "$(cat "$PENDING_UNPUB")" ""

# 5. (b) a retry with the conf unreadable: nothing withdrawn, failed, still pending
conf_unreadable; calls; printf 'linux-omarchy-headers\n' >"$PENDING_UNPUB"
REPO_NAMES="linux-omarchy-headers nvidia-open-dkms" failed=0
retry_unpublish >"$T/out" 2>&1
expect "5. retry, unreadable conf: bin/unpublish not run" "$(grep -c '^unpublish' "$T/calls")" 0
expect "5. retry, unreadable conf: run failed" "$failed" 1
expect "5. retry, unreadable conf: still pending" "$(cat "$PENDING_UNPUB")" linux-omarchy-headers

# 6. (c) degraded dbs record "(upstream dbs)"; recovered dbs clear it
echo '{"degraded":true,"upstream_dbs":[{"repo":"core","stale":true,"age":7200}],"expired":[]}' >"$T/check.json"
attention=0
upstream_dbs_check "$T/check.json" >"$T/out" 2>&1
expect "6. degraded dbs: attention" "$attention" 1
expect "6. degraded dbs: \"(upstream dbs)\" recorded" "$(entry_result "(upstream dbs)")" attention
echo '{"degraded":false}' >"$T/check.json"
upstream_dbs_check "$T/check.json" >"$T/out" 2>&1
expect "6. recovered dbs: \"(upstream dbs)\" cleared" "$(has_entry "(upstream dbs)")" false
exit $fails
