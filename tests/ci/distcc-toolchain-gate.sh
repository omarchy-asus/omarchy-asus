#!/bin/bash
# build/distcc-ssh (the chroot's DISTCC_SSH wrapper) and build/distccd-gate (the helper's
# forced command), offline (#163). pacman, ssh and distccd are stubs: pacman prints the
# versions in $GCC/$BINUTILS, ssh plays sshd and runs the gate with the requested command
# in SSH_ORIGINAL_COMMAND, distccd records its arguments.
#   1. same gcc and binutils: distccd runs with --inetd and the gate's own arguments only
#   2. the helper's gcc differs: refused, both versions named, distccd not run
#   3. the helper's binutils differs: refused
#   4. no versions sent (an older wrapper): refused
#   5. the helper can't read its versions: refused
#   6. the chroot can't read its versions: the wrapper exits 1 without running ssh
#   7. the wrapper passes distcc's arguments through, the versions last
#   8. with distcc installed: a real compile goes to the "helper" on a match, and is
#      compiled locally (distcc's fallback) on a mismatch
# Usage: tests/ci/distcc-toolchain-gate.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
mkdir -p "$S/chroot" "$S/helper"
# pacman -Q gcc binutils, from the environment; $NOPACMAN makes it fail
cat >"$S/pacman" <<'STUB'
#!/bin/bash
[[ -z ${NOPACMAN:-} ]] || exit 1
printf 'gcc %s\nbinutils %s\n' "$GCC" "$BINUTILS"
STUB
chmod +x "$S/pacman"
cp "$S/pacman" "$S/chroot/pacman"; cp "$S/pacman" "$S/helper/pacman"
# ssh: everything from "distccd" on is the requested command; the helper's versions come
# from HELPER_GCC/HELPER_BINUTILS (default: the chroot's), and NOPACMAN applies to the helper
# only through HELPER_NOPACMAN.
cat >"$S/chroot/ssh" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/ssh-args"
while [[ \$# -gt 0 && \$1 != distccd ]]; do shift; done
exec env SSH_ORIGINAL_COMMAND="\$*" GCC="\${HELPER_GCC:-\$GCC}" BINUTILS="\${HELPER_BINUTILS:-\$BINUTILS}" \
    NOPACMAN="\${HELPER_NOPACMAN:-}" PATH="$S/helper:\$PATH" "$W/build/distccd-gate" --nice 19 --jobs 4
STUB
cat >"$S/helper/distccd" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$S/distccd-args"
STUB
chmod +x "$S/chroot/ssh" "$S/helper/distccd"
export GCC=16.2.1+r23-1 BINUTILS=2.47-4
unset HELPER_GCC HELPER_BINUTILS HELPER_NOPACMAN NOPACMAN SSH_ORIGINAL_COMMAND
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
connect() {  # connect: run the wrapper as distcc does; rc in $rc, stderr in $S/err
    rm -f "$S/ssh-args" "$S/distccd-args"
    PATH=$S/chroot:$PATH "$W/build/distcc-ssh" -l builder helper distccd --inetd --enable-tcp-insecure 2>"$S/err"
    rc=$?
}
ran() { [[ -e $S/distccd-args ]] && paste -sd' ' "$S/distccd-args" || echo "not run"; }

echo "== 1. same toolchain"
connect; expect "$rc" 0 "connects"
expect "$(ran)" "--inetd --nice 19 --jobs 4" "distccd runs with the gate's arguments, not the client's"

echo "== 2. helper gcc differs"
HELPER_GCC=15.2.1-1 connect; expect "$rc" 1 "refused"
expect "$(ran)" "not run" "distccd not run"
expect "$(cat "$S/err")" "distccd-gate: refused: build chroot has gcc-16.2.1+r23-1,binutils-2.47-4, this helper has gcc-15.2.1-1,binutils-2.47-4" "names both"

echo "== 3. helper binutils differs"
HELPER_BINUTILS=2.46-1 connect; expect "$rc" 1 "refused"
expect "$(ran)" "not run" "distccd not run"

echo "== 4. no versions sent"
rm -f "$S/distccd-args"
SSH_ORIGINAL_COMMAND="distccd --inetd --enable-tcp-insecure" PATH=$S/helper:$PATH "$W/build/distccd-gate" --jobs 4 2>"$S/err"
expect "$?" 1 "refused"
expect "$(ran)" "not run" "distccd not run"
grep -q 'sent no toolchain versions' "$S/err"; expect $? 0 "says why"
# a smuggled word that matches only by substring is not a version
SSH_ORIGINAL_COMMAND="distccd x-omarchy-asus-toolchain=gcc-$GCC,binutils-$BINUTILS" PATH=$S/helper:$PATH \
    "$W/build/distccd-gate" 2>/dev/null
expect "$?" 1 "a word that only contains the marker is refused"

echo "== 5. helper can't read its versions"
HELPER_NOPACMAN=1 connect; expect "$rc" 1 "refused"
expect "$(ran)" "not run" "distccd not run"

echo "== 6. chroot can't read its versions"
NOPACMAN=1 connect; expect "$rc" 1 "wrapper fails"
expect "$([[ -e $S/ssh-args ]] && echo ran || echo "not run")" "not run" "ssh not run"

echo "== 7. arguments passed through"
connect
expect "$(tail -7 "$S/ssh-args" | paste -sd' ')" \
    "-l builder helper distccd --inetd --enable-tcp-insecure omarchy-asus-toolchain=gcc-$GCC,binutils-$BINUTILS" \
    "distcc's arguments, then the versions"
grep -qx StrictHostKeyChecking=yes "$S/ssh-args"; expect $? 0 "host key checked"
grep -qx ControlMaster=auto "$S/ssh-args"; expect $? 0 "jobs share one connection (#221)"

echo "== 8. a real distcc compile"
if command -v distcc >/dev/null && command -v distccd >/dev/null && [[ -d /usr/lib/distcc ]] && command -v gcc >/dev/null; then
    # the helper's distccd is the real one here
    rm "$S/helper/distccd"
    # gcc is the real compiler, as in the chroot: no ccache or distcc shims from the caller's
    # PATH (a shell with CCACHE_PREFIX=distcc sends distcc's local fallback back into distcc,
    # which stops with exit 111, "invoked itself recursively", #214) and none of its distcc
    # settings (DISTCC_FALLBACK=0 would turn the fallback off)
    clean=
    IFS=: read -ra dirs <<<"$PATH"
    for d in "${dirs[@]}"; do
        case $d in /usr/lib/ccache*|/usr/lib/distcc*|/usr/lib64/ccache*|/usr/lib64/distcc*) ;; *) clean+=${clean:+:}$d ;; esac
    done
    PATH=$clean
    unset CCACHE_PREFIX _DISTCC_SAFEGUARD $(compgen -e DISTCC_)
    echo 'int twice(int x) { return 2 * x; }' >"$S/a.c"
    real() {  # real <log>: compile a.c through distcc to the ssh host "helper" only
        rm -f "$S/a.o"; mkdir -p "$S/distcc-dir"; rm -rf "$S/distcc-dir"/*
        (cd "$S" && PATH=$S/chroot:$PATH DISTCC_HOSTS=@helper/1 DISTCC_SSH=$W/build/distcc-ssh \
            DISTCC_DIR=$S/distcc-dir DISTCC_VERBOSE=1 distcc gcc -c a.c -o a.o 2>"$S/$1")
    }
    real match.log; expect "$?" 0 "match: compiled"
    grep -q 'compile a.c on @helper/1 completed ok' "$S/match.log"; expect $? 0 "match: on the helper"
    HELPER_GCC=1.0-1 real mismatch.log; expect "$?" 0 "mismatch: compiled"
    grep -q 'distccd-gate: refused' "$S/mismatch.log"; expect $? 0 "mismatch: the gate refused"
    grep -q 'compile a.c on localhost completed ok' "$S/mismatch.log"; expect $? 0 "mismatch: compiled locally"
else
    echo "skip: distcc or gcc not installed"
fi

((fail)) && { echo "FAILED"; exit 1; }
echo "all passed"
