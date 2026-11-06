#!/bin/bash
# ci/check-pkgrel: since the Omarchy 4.5 stable switch (#411) both channels are on main's one
# line, .101 and up (101 and up for our own packages); Quattro's old .1 to .99 is never built.
#   1. in range on either channel: 9.101, 101, 1.250
#   2. out of range on either, refused with the reason: 9.4, 13, 1.100, 1.99
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
for c in quattro rc; do for r in 9.101 101 1.250; do check 0 "$c" "$r"; done; done
echo "== 2. out of range"
for c in quattro rc; do for r in 9.4 13 1.100 1.99 1; do check 1 "$c" "$r"; done; done
"$W/ci/check-pkgrel" quattro 9.4 | grep -q 'rebase-recipe'; r=$?
if ((r == 0)); then echo "ok: the refusal says how to fix it"; else echo "FAIL: the refusal names no fix"; fail=1; fi
echo "== 3. bad input"
check 1 rc 9.4.1
check 1 quattro 1a
check 2 beta 1.1
check 2 rc ''
exit $fail
