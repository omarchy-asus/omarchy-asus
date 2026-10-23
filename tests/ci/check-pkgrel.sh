#!/bin/bash
# ci/check-pkgrel keeps the two release channels' filenames apart (#201): the RC channel
# builds .101 and up (101 and up for our own packages), Quattro .1 to .99 (1 to 99).
#   1. in range: quattro 9.4, 12, 1.99; rc 9.101, 101, 1.250
#   2. out of range, refused with the reason: quattro 4.101, 101; rc 9.4, 13, 1.100
#   3. a pkgrel makepkg would refuse, an unknown channel and a missing argument
# The recipes themselves are checked against the target branch's channel by ci/check-recipes.
# Offline: no network, no makepkg.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
check() {  # check <want exit> <channel> <pkgrel>
    local rc=0 out
    out=$("$W/ci/check-pkgrel" "$2" "$3" 2>&1) || rc=$?
    if ((rc == $1)); then echo "ok: $2 $3 -> $rc${out:+ ($out)}"
    else echo "FAIL: $2 $3 -> exit $rc, want $1 ($out)"; fail=1; fi
}
echo "== 1. in range"
for r in 9.4 12 1.99 1; do check 0 quattro "$r"; done
for r in 9.101 101 1.250; do check 0 rc "$r"; done
echo "== 2. out of range"
for r in 4.101 101 1.100; do check 1 quattro "$r"; done
for r in 9.4 13 1.100 1.99; do check 1 rc "$r"; done
"$W/ci/check-pkgrel" rc 9.4 | grep -q 'rebase-recipe --channel rc'; r=$?
if ((r == 0)); then echo "ok: the rc refusal says how to fix it"; else echo "FAIL: the rc refusal names no fix"; fail=1; fi
echo "== 3. bad input"
check 1 rc 9.4.1
check 1 quattro 1a
check 2 beta 1.1
check 2 rc ''
exit $fail
