#!/bin/bash
# The kernel job may run on the build host's self-hosted runner (docs/kernel-runner.md).
# That is only safe while: the runner is opt-in (KERNEL_RUNNER unset: ubuntu-24.04), a
# fork's PR never gets it (the runner's job-started hook refuses it even when the fork's
# own workflow asks for the runner), it is the only job that can, the hosted-only disk
# steps (sudo rm -rf, sudo mkdir) never run there, the container gets nothing more than a
# CPU weight, a name and the read-only distcc key dir, and the build container and its
# root-owned tree are removed after every run, with no host-wide docker prune. Offline:
# grep/awk on the workflow, build/kernel-runner-job-started.sh on fake events, and
# ci/build-recipe's distcc block with fake pacman/install so nothing here changes.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
WF=$W/.github/workflows/build-pr.yml
fails=0
expect() {
    if [[ $2 == "$3" ]]; then echo "ok - $1"; else echo "not ok - $1: expected $3, got $2"; fails=1; fi
}
# step <name>: the lines of the workflow step with that name
step() {
    awk -v n="- name: $1" '
        index($0, n) && /^      - name: / { on = 1; print; next }
        on && (/^      - / || /^  [^ ]/) { on = 0 }
        on { print }' "$WF"
}

# a. runner selection
runs_on=$(grep -E '^[[:space:]]*runs-on:' "$WF")
expect "a: exactly one runs-on reads vars.KERNEL_RUNNER" "$(grep -c 'vars.KERNEL_RUNNER' <<<"$runs_on")" 1
expect "a: every other runs-on is ubuntu-24.04" \
    "$(grep -v 'vars.KERNEL_RUNNER' <<<"$runs_on" | grep -c -v -E 'runs-on:[[:space:]]*ubuntu-24\.04[[:space:]]*$')" 0
kr=$(grep 'vars.KERNEL_RUNNER' <<<"$runs_on")
expect "a: it is the kernel job's" \
    "$(awk '/^  kernel:/ { on = 1; next } /^  [^ ]/ { on = 0 } on && /vars.KERNEL_RUNNER/' "$WF" | wc -l)" 1
expect "a: unset variable: ubuntu-24.04" "$(grep -c "vars.KERNEL_RUNNER != ''" <<<"$kr")" 1
expect "a: falls back to ubuntu-24.04" "$(grep -c "|| 'ubuntu-24.04' }}" <<<"$kr")" 1
expect "a: PRs only from this repository's own branches" \
    "$(grep -c 'github.event.pull_request.head.repo.full_name == github.repository' <<<"$kr")" 1
expect "a: or a maintainer's dispatch" "$(grep -c "github.event_name == 'workflow_dispatch'" <<<"$kr")" 1
expect "a: no other event is let through" "$(grep -o 'github.event_name' <<<"$kr" | wc -l)" 1

# b. hosted-only steps
expect "b: Free disk space runs on hosted runners only" \
    "$(step 'Free disk space' | grep -c "if: .*runner.environment == 'github-hosted'")" 1
disk=$(step 'Pick the build disk')
expect "b: Pick the build disk leaves the self-hosted runner before any sudo" \
    "$(awk '/RUNNER_KIND == self-hosted/ { s = 1 } s && /exit 0/ { print "exit"; exit } /sudo/ { print "sudo"; exit }' <<<"$disk")" exit
expect "b: self-hosted builds in the job's temp dir" \
    "$(grep -c 'dir=\$RUNNER_TEMP/omarchy-asus-build' <<<"$disk")" 2

# c. the container's extra arguments on the build host
build=$(step 'Build linux-omarchy')
expect "c: host=() starts empty" "$(grep -c -E '^[[:space:]]*host=\(\)$' <<<"$build")" 1
expect "c: host gets a CPU weight and the run's container name, nothing else first" \
    "$(grep -c -E '^[[:space:]]*host=\(--cpu-shares [0-9]+ --name "\$CONTAINER"\)$' <<<"$build")" 1
expect "c: the only other additions are the key dir, read-only at /mnt/distcc, and the runner's cache" \
    "$(grep -E 'host\+=' <<<"$build" | grep -v -F 'host+=(-v "$OMARCHY_ASUS_CI_DISTCC:/mnt/distcc:ro")' |
        grep -c -v -F 'host+=(-v "$OMARCHY_ASUS_CI_CCACHE:/mnt/ccache")')" 0
expect "c: host is only filled on a self-hosted runner" \
    "$(awk '/RUNNER_KIND == self-hosted/ { s = 1 } /host=\(--cpu|host\+=/ && !s { bad++ } END { print bad + 0 }' <<<"$build")" 0

# d. cleanup
clean=$(step 'Clean up the build tree')
expect "d: cleanup runs pass or fail, on the self-hosted runner" \
    "$(grep -c "if: always() && runner.environment == 'self-hosted'" <<<"$clean")" 1
cname='CONTAINER: omarchy-asus-kernel-${{ github.run_id }}-${{ github.run_attempt }}'
expect "d: build and cleanup name the same container" \
    "$(grep -c -F "$cname" <<<"$build")$(grep -c -F "$cname" <<<"$clean")" 11
expect "d: cleanup force-removes the build container before the tree" \
    "$(awk '/docker rm --force "\$CONTAINER"/ { print "rm"; exit } /rm -rf \/d\/work/ { print "tree"; exit }' <<<"$clean")" rm
expect "d: docker prune only in the hosted-only Free disk space step" \
    "$(grep -v -E '^[[:space:]]*#' "$WF" | grep -c 'docker [a-z]* *prune')$(step 'Free disk space' | grep -c 'docker [a-z]* *prune')" 11
expect "d: cleanup removes only the job's build dir" \
    "$(grep -c 'docker run --rm -v "$DIR:/d" "$BUILDER_IMAGE" rm -rf /d/work /d/out' <<<"$clean")" 1
expect "d: cleanup is the kernel job's last step" \
    "$(awk '/^  kernel:/ { on = 1; next } /^  [^ ]/ { on = 0 } on && /^      - name: / { last = $0 } END { print last }' "$WF" | grep -c 'Clean up the build tree')" 1

# f. the runner's job-started hook (build/kernel-runner-job-started.sh)
R=omarchy-asus/omarchy-asus WREF="omarchy-asus/omarchy-asus/.github/workflows/build-pr.yml@refs/pull/1/merge"
hev=$(mktemp -d)
# The hook refuses an account that can reach the system docker, which a hosted
# runner (where this test runs) can. The cases below run a copy whose socket and
# group are this test's own; f2 checks the real ones and that both refuse.
REAL_HOOK=$W/build/kernel-runner-job-started.sh
expect "f: the hook checks the system docker socket" "$(grep -c '\[\[ -w /var/run/docker.sock \]\]' "$REAL_HOOK")" 1
expect "f: the hook checks the docker group" "$(grep -c "grep -qx docker &&" "$REAL_HOOK")" 1
hook_copy() {  # hook_copy <socket> <group>: the hook with those in place of the real ones
    sed -e "s#/var/run/docker.sock#$1#g" -e "s#grep -qx docker#grep -qx $2#" "$REAL_HOOK" >"$hev/hook.sh"
}
hook_copy "$hev/no-such.sock" no-such-group-here
HOOK=$hev/hook.sh
printf '{"pull_request":{"head":{"repo":{"full_name":"%s"}}}}\n' "$R" >"$hev/own.json"
printf '{"pull_request":{"head":{"repo":{"full_name":"someone/omarchy-asus"}}}}\n' >"$hev/fork.json"
printf '{"pull_request":{"head":{"repo":null}}}\n' >"$hev/deleted.json"
# The hook runs under a fake Runner.Worker that, like the runner with an
# `if: always()` step, goes on to its next step whatever the hook returned. A
# refusal must kill that worker so the next step never runs. Each case runs in
# its own session (setsid), so the hook's fallback can't reach this test.
cat >"$hev/Runner.Worker" <<'EOF'
#!/bin/bash
bash "$HOOK" 2>"$OUT.err"
echo "next step ran (hook exit $?)" >"$OUT"
EOF
chmod +x "$hev/Runner.Worker"
hook() {  # hook <event> <payload> [VAR=value...]: accepted | refused | refused-but-ran-on
    local ev=$1 pl=$2; shift 2
    rm -f "$hev/out" "$hev/out.err"
    (env -i PATH="$PATH" HOOK="$HOOK" OUT="$hev/out" GITHUB_REPOSITORY="$R" GITHUB_JOB=kernel \
        GITHUB_WORKFLOW_REF="$WREF" GITHUB_EVENT_NAME="$ev" GITHUB_EVENT_PATH="$pl" "$@" \
        setsid -w "$hev/Runner.Worker"; true) >/dev/null 2>&1
    if [[ -f $hev/out ]] && grep -q 'hook exit 0' "$hev/out"; then echo accepted
    elif [[ -f $hev/out ]]; then echo refused-but-ran-on
    else echo refused; fi
}
expect "f: own branch's PR: accepted" "$(hook pull_request "$hev/own.json")" accepted
: >"$hev/docker.sock"; hook_copy "$hev/docker.sock" no-such-group-here
expect "f2: system docker socket writable: refused" "$(hook pull_request "$hev/own.json")" refused
hook_copy "$hev/no-such.sock" "$(id -gn)"
expect "f2: in the docker group: refused" "$(hook pull_request "$hev/own.json")" refused
hook_copy "$hev/no-such.sock" no-such-group-here
expect "f: dispatch: accepted" "$(hook workflow_dispatch /nonexistent)" accepted
expect "f: fork's PR: refused, and the job's next step never runs" "$(hook pull_request "$hev/fork.json")" refused
expect "f: PR whose head repository is gone: refused" "$(hook pull_request "$hev/deleted.json")" refused
expect "f: PR without a payload: refused" "$(hook pull_request /nonexistent)" refused
expect "f: pull_request_target: refused" "$(hook pull_request_target "$hev/own.json")" refused
expect "f: push: refused" "$(hook push "$hev/own.json")" refused
expect "f: another job: refused" "$(hook pull_request "$hev/own.json" GITHUB_JOB=build)" refused
expect "f: another repository: refused" "$(hook workflow_dispatch /nonexistent GITHUB_REPOSITORY=someone/omarchy-asus)" refused
expect "f: another workflow: refused" \
    "$(hook workflow_dispatch /nonexistent GITHUB_WORKFLOW_REF="$R/.github/workflows/lint.yml@refs/heads/main")" refused
hook pull_request "$hev/fork.json" >/dev/null
expect "f: the refusal says why and that it ends the job" \
    "$(grep -c -e "refused: pull request from 'someone/omarchy-asus'" -e 'ending the job (Runner.Worker [0-9]*)' "$hev/out.err")" 2
# Without a Runner.Worker above it, a refusal still stops what would run next.
rm -f "$hev/out"
(env -i PATH="$PATH" GITHUB_REPOSITORY=someone/omarchy-asus setsid -w bash -c \
    'bash "$1" 2>/dev/null; echo ran >"$2"' _ "$HOOK" "$hev/out"; true) >/dev/null 2>&1
expect "f: no Runner.Worker: fails closed (its process group is killed)" "$([[ -f $hev/out ]] && echo ran || echo stopped)" stopped
# A Runner.Worker further up is not this job's (this repo's CI runs this test on a
# hosted runner): a refusal must leave it alone and fall back to its own group.
mkdir -p "$hev/outer"
cat >"$hev/outer/Runner.Worker" <<'EOF'
#!/bin/bash
bash -c '(setsid -w bash -c "bash \"\$HOOK\" 2>/dev/null; echo ran >\"\$OUT.inner\""; :)'
echo survived >"$OUT"
EOF
chmod +x "$hev/outer/Runner.Worker"
rm -f "$hev/out" "$hev/out.inner"
(env -i PATH="$PATH" HOOK="$HOOK" OUT="$hev/out" GITHUB_REPOSITORY=someone/omarchy-asus \
    setsid -w "$hev/outer/Runner.Worker"; true) >/dev/null 2>&1
expect "f: a Runner.Worker above the parent and grandparent is not killed" \
    "$(cat "$hev/out" 2>/dev/null)" survived
expect "f: ...and the refusal still stops what runs after it" "$([[ -f $hev/out.inner ]] && echo ran || echo stopped)" stopped
expect "f: the installed hook's name ends in .sh (the runner picks the interpreter by extension)" \
    "$(grep -c 'ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/lib/omarchy-asus/kernel-runner-job-started\.sh"' "$W/docs/kernel-runner.md")" 1
rm -rf "$hev"

# e. ci/build-recipe's distcc block, run on its own with pacman and install faked
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/mnt/distcc" "$t/etc/makepkg.conf.d" "$t/bin"
printf '#!/bin/sh\necho "pacman $*" >>"%s/calls"\n' "$t" >"$t/bin/pacman"
printf '#!/bin/sh\necho "install $*" >>"%s/calls"\n' "$t" >"$t/bin/install"
printf '#!/bin/sh\necho 4\n' >"$t/bin/nproc"
chmod +x "$t/bin/"*
block() {
    awk '/^if \[\[ -f \/mnt\/distcc\/id_ed25519/ { on = 1 } on { print } on && /^fi$/ { exit }' "$W/ci/build-recipe" |
        sed -e "s#/mnt/distcc#$t/mnt/distcc#g" -e "s#/etc/makepkg.conf.d#$t/etc/makepkg.conf.d#g"
}
expect "e: ci/build-recipe has the distcc block" "$(block | grep -c '^fi$')" 1
run_block() { env PATH="$t/bin:$PATH" repo="$W" bash -euo pipefail -c "$(block)" 2>&1; }
run_block >/dev/null
expect "e: no key dir: no distcc config" "$(ls "$t/etc/makepkg.conf.d" | wc -l)" 0
: >"$t/mnt/distcc/id_ed25519"; : >"$t/mnt/distcc/known_hosts"
printf '# helpers\nacct@helper-a/8\n\nacct@helper-b/2\n' >"$t/mnt/distcc/hosts"
out=$(run_block)
conf=$t/etc/makepkg.conf.d/zz-distcc.conf
expect "e: key dir: distcc config written" "$([[ -f $conf ]] && echo 1)" 1
expect "e: localhost first, then the helpers, comments and blanks dropped" \
    "$(grep -c '^DISTCC_HOSTS="localhost/4 acct@helper-a/8 acct@helper-b/2"$' "$conf")" 1
expect "e: -j covers local and helper slots" "$(grep -c '^MAKEFLAGS="-j14"$' "$conf")" 1
expect "e: DISTCC_SSH is the wrapper at /distcc" "$(grep -c '^export DISTCC_SSH=/distcc/ssh$' "$conf")" 1
expect "e: distcc on, ccache off" "$(grep -c '^BUILDENV=(distcc color !ccache check !sign)$' "$conf")" 1
expect "e: the wrapper is this repo's build/distcc-ssh" \
    "$(grep -c "install -m 755 $W/build/distcc-ssh /distcc/ssh" "$t/calls")" 1
expect "e: the key is copied for the builder, mode 600" \
    "$(grep -c "install -o builder -g builder -m 600 $t/mnt/distcc/id_ed25519" "$t/calls")" 1
expect "e: says how many helpers and slots" "$(grep -c '2 helper(s), 10 slots on top of 4 here' <<<"$out")" 1

# g. ci/build-recipe's ccache block and its summary after makepkg, the same way (after the
# distcc block above ran); runuser stands in for `ccache --print-stats` with $t/stats
printf '#!/bin/sh\ncat "%s/stats"\n' "$t" >"$t/bin/runuser"; chmod +x "$t/bin/runuser"
stats() { printf 'cache_miss\t%s\ndirect_cache_hit\t%s\nfiles_in_cache\t%s\npreprocessed_cache_hit\t%s\n' "$@"; }
cblock() {
    awk '/^if \[\[ -d \/mnt\/ccache \]\]/ { on = 1 } on { print } on && /^fi$/ { exit }' "$W/ci/build-recipe" |
        sed -e "s#/mnt/ccache#$t/mnt/ccache#g" -e "s#/etc/makepkg.conf.d#$t/etc/makepkg.conf.d#g"
}
sblock() { awk '/^if declare -F ccache_stats/ { on = 1 } on { print } on && /^fi$/ { exit }' "$W/ci/build-recipe"; }
expect "g: ci/build-recipe has the ccache block" "$(cblock | grep -c '^fi$')" 1
expect "g: ci/build-recipe has the summary after makepkg" \
    "$(sed -n '/^as_builder makepkg /,$p' "$W/ci/build-recipe" | grep -c '^if declare -F ccache_stats')" 1
# the block, then makepkg (the stats become $t/stats.after, if there is one), then the summary
run_cblock() {
    env PATH="$t/bin:$PATH" WORK=/build bash -euo pipefail -c \
        "$(cblock); [[ -f $t/stats.after ]] && mv $t/stats.after $t/stats; $(sblock)" 2>&1
}
cconf=$t/etc/makepkg.conf.d/zz-zccache.conf
out=$(run_cblock)
expect "g: no cache dir: no ccache config" "$([[ -e $cconf ]] && echo 1 || echo 0)" 0
expect "g: no cache dir: no summary" "$(grep -c '==> ccache' <<<"$out")" 0
mkdir -p "$t/mnt/ccache"
stats 20 10 100 5 >"$t/stats"; stats 30 110 300 15 >"$t/stats.after"
out=$(run_cblock); rc=$?
expect "g: with distcc: ccache in front of distcc" "$(grep -c '^BUILDENV=(distcc color ccache check !sign)$' "$cconf")" 1
expect "g: PATH without /usr/sbin, so ccache hands distcc /usr/bin/gcc (#202)" \
    "$(grep -c '^export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin$' "$cconf")" 1
expect "g: the cache is the mounted dir" "$(grep -c "^export CCACHE_DIR=$t/mnt/ccache$" "$cconf")" 1
expect "g: the cache has a size limit" "$(grep -c '^export CCACHE_MAXSIZE=' "$cconf")" 1
expect "g: paths are hashed relative to the build tree, \$WORK" "$(grep -c '^export CCACHE_BASEDIR=/build$' "$cconf")" 1
expect "g: the working dir is not hashed" "$(grep -c '^export CCACHE_NOHASHDIR=1$' "$cconf")" 1
expect "g: the release builds' sloppiness (fresh tarballs: new mtimes and ctimes)" \
    "$(grep -c '^export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,locale$' "$cconf")" 1
expect "g: says it is on, with the files in the cache" "$(grep -c '^==> ccache: .* (100 files)$' <<<"$out")" 1
expect "g: logs this build's hits, misses and hit rate" \
    "$(grep -c '^==> ccache: 110 hits, 10 misses, 91.7% hit rate$' <<<"$out")" 1
expect "g: the summary exits 0" "$rc" 0
expect "g: its config loads after the distcc one" \
    "$(printf '%s\n' zz-zccache.conf zz-ci.conf zz-distcc.conf | LC_ALL=C sort | tail -1)" zz-zccache.conf
stats 0 0 0 0 >"$t/stats"; stats 0 0 0 0 >"$t/stats.after"
out=$(run_cblock)
expect "g: no compiles: a 0% hit rate, not a division by zero" \
    "$(grep -c '^==> ccache: 0 hits, 0 misses, 0.0% hit rate$' <<<"$out")" 1
rm "$t/stats"
out=$(run_cblock); rc=$?
expect "g: no stats: says so" "$(grep -c '^==> ccache: no stats$' <<<"$out")" 1
expect "g: no stats: the build still passes" "$rc" 0
rm "$t/etc/makepkg.conf.d/zz-distcc.conf"
run_cblock >/dev/null
expect "g: without distcc: ccache alone" "$(grep -c '^BUILDENV=(!distcc color ccache check !sign)$' "$cconf")" 1
exit $fails
