#!/bin/bash
# ci/channel, offline, with a gh that fails if called:
#   1. main (the RC trunk, #309), next/omarchy-4.5 and a PR stacked on another PR's branch are
#      all rc (Quattro is frozen: no branch builds it), without asking GitHub;
#   2. --conf and --tag name each channel's pacman.conf and release tag; an unknown channel
#      or option exits non-zero and prints nothing.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok: $what"; else echo "FAIL: $what"; fails=$((fails + 1)); fi; }

mkdir -p "$T/bin"
printf '#!/bin/bash\necho "$*" >>"$STUB_LOG"\nexit 1\n' >"$T/bin/gh"
chmod +x "$T/bin/gh"
export PATH=$T/bin:$PATH STUB_LOG=$T/log
: >"$T/log"

# 1.
check "1. main is rc" [ "$("$W/ci/channel" main)" = rc ]
check "1. next/omarchy-4.5 is rc" [ "$("$W/ci/channel" next/omarchy-4.5)" = rc ]
check "1. a stacked PR's base is rc" [ "$("$W/ci/channel" fix/172-x)" = rc ]
check "1. no gh call" [ ! -s "$T/log" ]

# 2.
check "2. rc conf" [ "$("$W/ci/channel" --conf rc)" = build/pacman-rc.conf ]
check "2. quattro conf" [ "$("$W/ci/channel" --conf quattro)" = build/pacman.conf ]
check "2. rc tag" [ "$("$W/ci/channel" --tag rc)" = rc-x86_64 ]
check "2. quattro tag" [ "$("$W/ci/channel" --tag quattro)" = x86_64 ]
rc=0; out=$("$W/ci/channel" --conf nope 2>/dev/null) || rc=$?
check "2. an unknown channel exits 1, prints nothing" [ "$rc" = 1 ] && [ -z "$out" ]
rc=0; out=$("$W/ci/channel" --base main 2>/dev/null) || rc=$?
check "2. an unknown option (the old --base) exits 2, prints nothing" [ "$rc" = 2 ] && [ -z "$out" ]

((fails == 0)) || { echo "$fails failure(s)"; exit 1; }
echo "all ok"
