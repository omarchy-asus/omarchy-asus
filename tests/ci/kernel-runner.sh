#!/bin/bash
# The kernel job may run on the build host's self-hosted runner (docs/kernel-runner.md).
# That is only safe while: the runner is opt-in (KERNEL_RUNNER unset: ubuntu-24.04), a
# fork's PR never gets it, it is the only job that can, the hosted-only disk steps (sudo
# rm -rf, sudo mkdir) never run there, the container gets nothing more than a CPU weight
# and the read-only distcc key dir, and the root-owned build tree is removed after every
# run. Offline: grep/awk on the workflow, and ci/build-recipe's distcc block with fake
# pacman/install so nothing on this machine changes.
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
expect "c: host gets a CPU weight and nothing else first" \
    "$(grep -c -E '^[[:space:]]*host=\(--cpu-shares [0-9]+\)$' <<<"$build")" 1
expect "c: the only other addition is the key dir, read-only at /mnt/distcc" \
    "$(grep -E 'host\+=' <<<"$build" | grep -c -v -F 'host+=(-v "$OMARCHY_ASUS_CI_DISTCC:/mnt/distcc:ro")')" 0
expect "c: host is only filled on a self-hosted runner" \
    "$(awk '/RUNNER_KIND == self-hosted/ { s = 1 } /host=\(--cpu|host\+=/ && !s { bad++ } END { print bad + 0 }' <<<"$build")" 0

# d. cleanup
clean=$(step 'Clean up the build tree')
expect "d: cleanup runs pass or fail, on the self-hosted runner" \
    "$(grep -c "if: always() && runner.environment == 'self-hosted'" <<<"$clean")" 1
expect "d: cleanup removes only the job's build dir" \
    "$(grep -c 'docker run --rm -v "$DIR:/d" "$BUILDER_IMAGE" rm -rf /d/work /d/out' <<<"$clean")" 1
expect "d: cleanup is the kernel job's last step" \
    "$(awk '/^  kernel:/ { on = 1; next } /^  [^ ]/ { on = 0 } on && /^      - name: / { last = $0 } END { print last }' "$WF" | grep -c 'Clean up the build tree')" 1

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
exit $fails
