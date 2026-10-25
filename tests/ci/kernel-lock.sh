#!/bin/bash
# The build host's kernel lock (ci/kernel-lock) and preemption (ci/kernel-preempt), offline:
#   1. two holders never overlap (three jobs at once), and the holder is recorded
#   2. a killed holder leaves a stale record and a free lock; the next holder waits for the
#      killed job's build container, then removes it; a job whose Runner.Worker is gone
#      lets go
#   3. release removes the job's own build container before letting go
#   4. a queued release comes first: PR jobs give way to it
#   5. the preemption decision: a release preempts a PR holder, a PR never preempts, a
#      release never preempts a release, nothing to preempt on a free lock
#   6. the holder process keeps no token; OMARCHY_ASUS_CI_LOCK unset: a PR builds without the
#      lock, a release refuses
#   7. ci/kernel-preempt with gh stubbed: cancels only a run GitHub lists as build-pr.yml, and
#      re-runs it (--failed) once finished, unless a newer run on its branch replaced it
# Usage: tests/ci/kernel-lock.sh [keep]
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
KL=$W/ci/kernel-lock KP=$W/ci/kernel-preempt
S=$(realpath "$(mktemp -d)")
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; [[ $keep == 1 ]] || rm -rf "$S"; }
keep=0; [[ ${1:-} == keep ]] && { keep=1; echo "state: $S"; }
trap cleanup EXIT
fail=0
check() {
    local name=$1; shift
    if "$@"; then echo "ok - $name"; else echo "not ok - $name"; fail=1; fi
}
has() { grep -qF -- "$1" <<<"$2"; }
# wait_for <seconds> <command...>: until the command succeeds
wait_for() { local n=$(( $1 * 10 )); shift; until "$@"; do (( n-- > 0 )) || return 1; sleep 0.1; done; }

# A fake docker: containers are files under $S/containers; calls are logged.
mkdir -p "$S/bin" "$S/containers"
cat >"$S/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >>"$S/docker.log"
case "\$1 \$2" in
    "container inspect") [[ -e "$S/containers/\$3" ]] ;;
    "rm --force") rm -f "$S/containers/\$3" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$S/bin/docker"
export PATH=$S/bin:$PATH
export OMARCHY_ASUS_CI_LOCK=$S/lock/kernel.lock KERNEL_LOCK_POLL=0.1 KERNEL_LOCK_REPORT=1000
mkdir -p "$S/lock"
export GITHUB_REPOSITORY=omarchy-asus/omarchy-asus

# job <name>: a fake job, its Runner.Worker stand-in (a sleep) and its own state dir
declare -A watch=()
job() {
    sleep 1000 & watch[$1]=$!; pids+=("$!")
    mkdir -p "$S/state/$1"
}
# as <name> <kind> <run> <args...>: ci/kernel-lock in job <name>'s environment
as() {
    local n=$1 kind=$2 run=$3; shift 3
    local wf=build-pr.yml; [[ $kind == release ]] && wf=release.yml
    KERNEL_LOCK_WATCH=${watch[$n]} KERNEL_LOCK_STATE=$S/state/$n GITHUB_RUN_ID=$run GITHUB_RUN_ATTEMPT=1 \
        GITHUB_JOB=kernel GITHUB_WORKFLOW_REF="omarchy-asus/omarchy-asus/.github/workflows/$wf@refs/heads/main" \
        "$KL" "$@"
}
held() { [[ -s $S/state/$1/lock.ready ]]; }
cname() { echo "omarchy-asus-kernel-$1-1"; }

echo "== 1. one holder at a time"
for j in a b c; do job "$j"; done
# each job: take the lock, log start, work, log end, let go
work() {
    local n=$1 run=$2
    as "$n" pr "$run" acquire pr "$(cname "$run")" 2>/dev/null || { echo "$n acquire failed" >>"$S/overlap.log"; return; }
    echo "start $n" >>"$S/overlap.log"; sleep 0.6; echo "end $n" >>"$S/overlap.log"
    as "$n" pr "$run" release 2>/dev/null
}
work a 101 & w1=$!; work b 102 & w2=$!; work c 103 & w3=$!
wait "$w1" "$w2" "$w3"
log=$(cat "$S/overlap.log")
check "three jobs: each built once" test "$(grep -c '^start' <<<"$log")$(grep -c '^end' <<<"$log")" = 33
check "three jobs: never two at once (start, end, start, end, ...)" \
    test "$(awk '{ print $1 }' <<<"$log" | tr '\n' ' ')" = "start end start end start end "
check "after release: free" grep -qx 'state=free' <<<"$("$KL" holder)"
check "after release: no record left" test ! -e "$S/lock/kernel.lock.holder"

as a pr 201 acquire pr "$(cname 201)" 2>/dev/null
out=$("$KL" holder)
check "holder: held" grep -qx 'state=held' <<<"$out"
check "holder: records the kind" grep -qx 'kind=pr' <<<"$out"
check "holder: records the run" grep -qx 'run_id=201' <<<"$out"
check "holder: records the job and workflow" \
    bash -c 'grep -qx "job=kernel" <<<"$1" && grep -q "^workflow=.*build-pr.yml" <<<"$1"' _ "$out"
check "holder: records the build container" grep -qx "container=$(cname 201)" <<<"$out"
hpid=$(sed -n 's/^pid=//p' <<<"$out")
check "holder: records a live holder process" kill -0 "$hpid"
as b pr 202 acquire pr "$(cname 202)" 2>"$S/b.err" & bw=$!
sleep 1
check "a second job waits while the first holds it" bash -c '! [[ -s $1 ]]' _ "$S/state/b/lock.ready"
check "the waiter says who holds it" has "held by pr run 201" "$(cat "$S/b.err")"
as a pr 201 release 2>/dev/null
wait "$bw"
check "the second job gets it once the first lets go" held b
check "the record names the second job" grep -qx 'run_id=202' <<<"$("$KL" holder)"
as b pr 202 release 2>/dev/null

echo "== 2. killed holders"
: >"$S/containers/$(cname 301)"
as a pr 301 acquire pr "$(cname 301)" 2>/dev/null
kill -KILL "$(cat "$S/state/a/lock.pid")"
wait_for 5 bash -c '"$1" holder | grep -qx state=free' _ "$KL"
out=$("$KL" holder)
check "killed holder: the lock is free" grep -qx 'state=free' <<<"$out"
check "killed holder: its record is left, marked stale" grep -qx 'stale_run_id=301' <<<"$out"
# the killed job's container is still there: the next holder waits for it, then removes it
: >"$S/docker.log"
KERNEL_LOCK_CONTAINER_WAIT=2 as b pr 302 acquire pr "$(cname 302)" 2>"$S/b.err"; rc=$?
check "next holder: gets the lock" test "$rc" = 0
check "next holder: waited for the killed job's container" has "$(cname 301) is still there" "$(cat "$S/b.err")"
check "next holder: then removed it" grep -qx "docker rm --force $(cname 301)" "$S/docker.log"
check "next holder: the container is gone before it builds" test ! -e "$S/containers/$(cname 301)"
as b pr 302 release 2>/dev/null
# a container that goes away by itself while the next holder waits is not removed by it
: >"$S/containers/$(cname 303)"
as a pr 303 acquire pr "$(cname 303)" 2>/dev/null
kill -KILL "$(cat "$S/state/a/lock.pid")"
(sleep 1; rm -f "$S/containers/$(cname 303)") &
: >"$S/docker.log"
KERNEL_LOCK_CONTAINER_WAIT=20 as b pr 304 acquire pr "$(cname 304)" 2>/dev/null
check "a container that goes by itself: waited for, not force-removed" bash -c '! grep -q "rm --force" "$1"' _ "$S/docker.log"
as b pr 304 release 2>/dev/null
# the job's Runner.Worker ends (a cancelled or killed job): the holder lets go
job d
as d pr 305 acquire pr "$(cname 305)" 2>/dev/null
kill "${watch[d]}"
check "the job's Runner.Worker ends: the lock is let go" \
    wait_for 5 bash -c '"$1" holder | grep -qx state=free' _ "$KL"

echo "== 3. release removes the build container first"
: >"$S/containers/$(cname 401)"; : >"$S/docker.log"
as a pr 401 acquire pr "$(cname 401)" 2>/dev/null
as a pr 401 release 2>/dev/null
check "release: force-removes the job's own container" grep -qx "docker rm --force $(cname 401)" "$S/docker.log"
check "release: then the lock is free" grep -qx 'state=free' <<<"$("$KL" holder)"
# a container that won't go: the lock is kept (the job's end lets it go, and the next holder waits)
cat >"$S/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >>"$S/docker.log"
[[ "\$1 \$2" == "container inspect" ]]
EOF
as a pr 402 acquire pr "$(cname 402)" 2>/dev/null
as a pr 402 release 2>"$S/a.err"; rc=$?
check "a container that won't go: release fails" test "$rc" = 1
check "...and keeps the lock" grep -qx 'state=held' <<<"$("$KL" holder)"
check "...and says why" has "still there: keeping the lock" "$(cat "$S/a.err")"
kill -KILL "$(cat "$S/state/a/lock.pid")"
cat >"$S/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >>"$S/docker.log"
case "\$1 \$2" in
    "container inspect") [[ -e "$S/containers/\$3" ]] ;;
    "rm --force") rm -f "$S/containers/\$3" ;;
    *) exit 1 ;;
esac
EOF
rm -f "$S/state/a/"*
wait_for 5 bash -c '"$1" holder | grep -qx state=free' _ "$KL"

echo "== 4. a queued release comes first"
job r; job r2
as a pr 501 acquire pr "$(cname 501)" 2>/dev/null
as r release 502 queue 2>/dev/null
check "release: queued while a PR holds the lock" test -s "$S/state/r/queue.ready"
as b pr 503 acquire pr "$(cname 503)" 2>/dev/null & bw=$!
as r release 502 acquire release "$(cname 502)" 2>/dev/null & rw=$!
sleep 0.5
as a pr 501 release 2>/dev/null
wait "$rw"
check "the PR lets go: the queued release gets the lock, not the waiting PR" grep -qx 'kind=release' <<<"$("$KL" holder)"
check "the waiting PR still waits" bash -c '! [[ -s $1 ]]' _ "$S/state/b/lock.ready"
as r2 release 504 queue 2>/dev/null & r2w=$!
sleep 0.5
check "a second release waits for the queue" bash -c '! [[ -s $1 ]]' _ "$S/state/r2/queue.ready"
check "a release must queue before it takes the lock" \
    bash -c 'KERNEL_LOCK_STATE=$2 "$1" acquire release omarchy-asus-kernel-9-1 2>&1 | grep -q "takes the queue first"' _ "$KL" "$S/state/none"
as r release 502 release 2>/dev/null
wait "$r2w"
check "the first release done: the second takes the queue" test -s "$S/state/r2/queue.ready"
sleep 0.5
check "...and the PR still gives way while it is queued" bash -c '! [[ -s $1 ]]' _ "$S/state/b/lock.ready"
as r2 release 504 release 2>/dev/null
wait "$bw"
check "no release queued: the PR gets the lock" grep -qx 'run_id=503' <<<"$("$KL" holder)"

echo "== 5. who preempts whom"
pt() { as "$1" "$2" 0 preempt-target "$2" 2>/dev/null; }
check "a release finds a PR holding it: preempts that PR run" test "$(pt r release)" = 503
check "a PR finds a PR holding it: never preempts" test -z "$(pt a pr)"
as b pr 503 release 2>/dev/null
as r release 601 queue 2>/dev/null; as r release 601 acquire release "$(cname 601)" 2>/dev/null
check "a release finds a release holding it: never preempts" test -z "$(pt r2 release)"
check "a PR finds a release holding it: never preempts" test -z "$(pt a pr)"
as r release 601 release 2>/dev/null
check "a free lock: nothing to preempt" test -z "$(pt r release)"
# a holder that was killed leaves its record; with the lock free there is nothing to preempt
as a pr 602 acquire pr "$(cname 602)" 2>/dev/null
kill -KILL "$(cat "$S/state/a/lock.pid")"; rm -f "$S/state/a/"*
wait_for 5 bash -c '"$1" holder | grep -qx state=free' _ "$KL"
check "a stale PR record: nothing to preempt" test -z "$(pt r release)"

echo "== 6. tokens and an unconfigured runner"
GH_TOKEN=secret-x GITHUB_TOKEN=secret-y as a pr 701 acquire pr "$(cname 701)" 2>/dev/null
hpid=$(cat "$S/state/a/lock.pid")
check "the holder process has no GH_TOKEN or GITHUB_TOKEN" \
    bash -c '! tr "\0" "\n" <"/proc/$1/environ" | grep -qE "^(GH_TOKEN|GITHUB_TOKEN)="' _ "$hpid"
as a pr 701 release 2>/dev/null
out=$(OMARCHY_ASUS_CI_LOCK='' as a pr 702 acquire pr "$(cname 702)" 2>&1); rc=$?
check "no lock configured: a PR builds without it" test "$rc" = 0
check "...and says so" has "building without the build host's lock" "$out"
out=$(OMARCHY_ASUS_CI_LOCK='' as r release 703 queue 2>&1); rc=$?
check "no lock configured: a release refuses" test "$rc" = 1
check "...and says what is missing" has "OMARCHY_ASUS_CI_LOCK is not set" "$out"
out=$(OMARCHY_ASUS_CI_LOCK='' as r release 703 acquire release "$(cname 703)" 2>&1); rc=$?
check "no lock configured: a release's acquire refuses too" test "$rc" = 1
out=$(as a pr 704 acquire pr 'x; rm -rf /' 2>&1); rc=$?
check "a container name that isn't the run's: refused" test "$rc" = 1

echo "== 7. ci/kernel-preempt"
cat >"$S/bin/gh" <<EOF
#!/bin/bash
echo "gh \$*" >>"$S/gh.log"
case "\$1 \$2" in
    "api repos/omarchy-asus/omarchy-asus/actions/runs/"*) cat "$S/gh.path" ;;
    "run cancel") exit 0 ;;
    "run view") cat "$S/gh.\$(sed -n 's/.*--json \([a-zA-Z]*\).*/\1/p' <<<"\$*")" ;;
    "run list") cat "$S/gh.latest" ;;
    "run rerun") exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$S/bin/gh"
kp() { KERNEL_LOCK_STATE=$S/state/r KERNEL_PREEMPT_POLL=0 GH_TOKEN=x "$KP" "$@"; }
as a pr 801 acquire pr "$(cname 801)" 2>/dev/null
echo .github/workflows/build-pr.yml >"$S/gh.path"; : >"$S/gh.log"
out=$(kp cancel 2>/dev/null); rc=$?
check "cancel: a PR check's run holds it: cancelled" grep -qx 'gh run cancel 801 -R omarchy-asus/omarchy-asus' "$S/gh.log"
check "cancel: prints cancelled=<run> for the re-run step" test "$out" = cancelled=801
check "cancel: exits 0" test "$rc" = 0
echo .github/workflows/release.yml >"$S/gh.path"; : >"$S/gh.log"
out=$(kp cancel 2>&1)
check "cancel: a record naming a run that isn't build-pr.yml: not cancelled" bash -c '! grep -q "run cancel" "$1"' _ "$S/gh.log"
check "...and says so" has "not cancelling it" "$out"
as a pr 801 release 2>/dev/null; : >"$S/gh.log"
out=$(kp cancel 2>/dev/null)
check "cancel: nothing holds it: no gh call that changes anything, nothing printed" \
    bash -c '[[ -z $1 ]] && ! grep -qE "run (cancel|rerun)" "$2"' _ "$out" "$S/gh.log"
echo .github/workflows/build-pr.yml >"$S/gh.path"
echo completed >"$S/gh.status"; echo fix/x >"$S/gh.headBranch"; echo 801 >"$S/gh.latest"; : >"$S/gh.log"
kp rerun 801 >/dev/null 2>&1; rc=$?
check "rerun: re-runs the failed and cancelled jobs" grep -qx 'gh run rerun 801 --failed -R omarchy-asus/omarchy-asus' "$S/gh.log"
check "rerun: exits 0" test "$rc" = 0
echo 999 >"$S/gh.latest"; : >"$S/gh.log"
out=$(kp rerun 801 2>&1)
check "rerun: a newer run on the branch replaced it: not re-run" bash -c '! grep -q "run rerun" "$1"' _ "$S/gh.log"
check "...and says so" has "was replaced by run 999" "$out"
echo in_progress >"$S/gh.status"; echo 801 >"$S/gh.latest"; : >"$S/gh.log"
KERNEL_PREEMPT_WAIT=0 kp rerun 801 >/dev/null 2>&1; rc=$?
check "rerun: the run hasn't finished in time: fails, nothing re-run" \
    bash -c '[[ $1 == 1 ]] && ! grep -q "run rerun" "$2"' _ "$rc" "$S/gh.log"
echo .github/workflows/release.yml >"$S/gh.path"; echo completed >"$S/gh.status"; : >"$S/gh.log"
kp rerun 801 >/dev/null 2>&1; rc=$?
check "rerun: a run that isn't build-pr.yml: refused" \
    bash -c '[[ $1 == 1 ]] && ! grep -q "run rerun" "$2"' _ "$rc" "$S/gh.log"
kp rerun 'x' >/dev/null 2>&1; rc=$?
check "rerun: not a run ID: refused" test "$rc" = 1

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
