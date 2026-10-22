#!/bin/bash
# bin/auto-update serves the release channels in SERVE_CHANNELS (default "quattro rc"), one
# run per channel. The real bin/auto-update, bin/env.sh and bin/auto-update-state run --plan
# from a temp copy of bin/ against a stub check-upstream (it logs the channel and the repo
# dir it was given) and a stub recipe-sandbox:
#   1. default: a quattro run, then an rc run; each one's check sees its own channel and
#      local repo, and the rc run keeps its log, lock and status apart (channel-rc/)
#   2. SERVE_CHANNELS=quattro: one quattro run in this process, at today's paths
#   3. --channel rc: the rc run only
#   4. the quattro run fails: the rc run still runs, and the exit is 1
#   5. an unknown channel in SERVE_CHANNELS, or --channel: refused (64), nothing runs
#   6. the RC branch does not exist on the hub (a reset release cycle): the rc run reports it
#      and stops, nothing checked, exit 0
# Offline: no network, no sudo, no bwrap.
set -u
for t in jq python3 flock column git; do
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

L=$T/lib/bin D=$T/data WS=$T/workspace CONF=$T/auto-update.conf
mkdir -p "$L" "$D" "$WS/recipes" "$WS/build"
cp "$W/bin/auto-update" "$W/bin/env.sh" "$W/bin/auto-update-state" "$L/"
cat >"$L/recipe-sandbox" <<'STUB'
#!/bin/bash
while (($#)) && [[ $1 != -- ]]; do shift; done
shift; exec "$@"
STUB
# check-upstream: logs "<channel> <repo dir>" (as env.sh resolves them) and fails when told to
cat >"$L/check-upstream" <<STUB
#!/bin/bash
source "\$(dirname "\$0")/env.sh"
echo "\$CHANNEL \${REPO_DIR#"\$DATA"/}" >>"$T/checks"
[[ -e $T/fail-\$CHANNEL ]] && exit 1
echo '{"packages": [], "prs": []}'
STUB
chmod +x "$L"/*
export OMARCHY_ASUS_DATA=$D
run() {  # run <SERVE_CHANNELS or -> [args]: bin/auto-update --plan; output in $T/out
    local serve=$1; shift
    if [[ $serve == - ]]; then : >"$CONF"; else printf 'SERVE_CHANNELS="%s"\n' "$serve" >"$CONF"; fi
    : >"$T/checks"
    rc=0
    "$L/auto-update" --plan --workspace "$WS" --config "$CONF" "$@" >"$T/out" 2>&1 || rc=$?
}
checks() { paste -sd, "$T/checks"; }
has() { if grep -qF -- "$1" "$T/out"; then echo yes; else echo no; fi; }

# 1. default: both channels, quattro first
run -
expect "1. default: exit 0" "$rc" 0
expect "1. default: quattro's check, then rc's, each on its own repo" "$(checks)" "quattro repo/x86_64,rc repo/rc-x86_64"
expect "1. default: the rc run names its branch and release" "$(has "channel rc: next/omarchy-4.5, Omarchy rc, release rc-x86_64")" yes
expect "1. default: an rc log apart" "$(compgen -G "$D/logs/auto-update-rc-*.log" >/dev/null && echo yes || echo no)" yes
expect "1. default: the rc lock in channel-rc" "$([[ -e $D/channel-rc/auto-update.lock ]] && echo yes || echo no)" yes
expect "1. default: the quattro lock where it always was" "$([[ -e $D/auto-update.lock ]] && echo yes || echo no)" yes

# 2. quattro only: one run, in this process, nothing of rc
rm -rf "$D"; mkdir -p "$D"
run quattro
expect "2. quattro only: exit 0" "$rc" 0
expect "2. quattro only: one check, quattro's" "$(checks)" "quattro repo/x86_64"
expect "2. quattro only: no per-channel dispatch" "$(has "serving the")" no
expect "2. quattro only: no channel-rc state" "$([[ -e $D/channel-rc ]] && echo yes || echo no)" no
expect "2. quattro only: no rc log" "$(compgen -G "$D/logs/auto-update-rc-*" >/dev/null && echo yes || echo no)" no

# 3. --channel rc
run - --channel rc
expect "3. --channel rc: exit 0" "$rc" 0
expect "3. --channel rc: rc's check only" "$(checks)" "rc repo/rc-x86_64"

# 4. the quattro run fails: rc still runs
touch "$T/fail-quattro"
run "quattro rc"
expect "4. quattro fails: exit 1" "$rc" 1
expect "4. quattro fails: rc still checked" "$(checks)" "quattro repo/x86_64,rc repo/rc-x86_64"
rm -f "$T/fail-quattro"

# 5. unknown channels
run "quattro beta"
expect "5. unknown channel in SERVE_CHANNELS: exit 64" "$rc" 64
expect "5. unknown channel in SERVE_CHANNELS: nothing ran" "$(checks)" ""
run - --channel beta
expect "5. unknown --channel: refused" "$([[ $rc -ne 0 ]] && echo yes || echo no)" yes
expect "5. unknown --channel: nothing ran" "$(checks)" ""

# 6. no next/omarchy-4.5 on the hub: a local bare repo with main only
git init -q --bare "$T/hub.git"
git init -q "$T/src"
git -C "$T/src" -c user.name=test -c user.email=test@invalid commit -q --allow-empty -m main
git -C "$T/src" push -q "$T/hub.git" HEAD:refs/heads/main
printf 'GIT_URL=file://%s\n' "$T/hub.git" >"$CONF"
: >"$T/checks"
rc=0; "$L/auto-update" --plan --channel rc --config "$CONF" >"$T/out" 2>&1 || rc=$?
expect "6. no RC branch: exit 0" "$rc" 0
expect "6. no RC branch: reported" "$(has "next/omarchy-4.5 does not exist")" yes
expect "6. no RC branch: nothing checked" "$(checks)" ""
exit $fails
