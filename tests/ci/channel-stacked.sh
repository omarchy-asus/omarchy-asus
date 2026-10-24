#!/bin/bash
# ci/channel on a stacked PR's base, offline (gh stubbed):
#   1. main (the RC trunk, #309) and next/omarchy-4.5 are both rc, without gh;
#   2. --base names the channel branch a stacked branch sits on: next/omarchy-4.5 when it is
#      fewer commits ahead of it than of main, main the other way; either way it is rc
#      (Quattro is frozen: no branch builds it);
#   3. when the compare API fails or answers nonsense it exits 1 instead of guessing.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
check() { local what=$1; shift; if "$@"; then echo "ok: $what"; else echo "FAIL: $what"; fails=$((fails + 1)); fi; }

# gh api repos/<repo>/compare/<channel>...<branch> --jq .ahead_by: answers from $T/ahead.<channel>
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
[[ $1 == api && $2 =~ ^repos/[^/]+/[^/]+/compare/(main|next/omarchy-4.5)\.\.\. ]] || exit 1
f=$STUB_DIR/ahead.${BASH_REMATCH[1]//\//_}
[[ -f $f ]] || exit 1
cat "$f"
STUB
chmod +x "$T/bin/gh"
export PATH=$T/bin:$PATH STUB_DIR=$T STUB_LOG=$T/log GITHUB_REPOSITORY=o/r
: >"$T/log"

# 1.
check "1. next/omarchy-4.5 is rc" [ "$("$W/ci/channel" next/omarchy-4.5)" = rc ]
check "1. main is rc" [ "$("$W/ci/channel" main)" = rc ]
check "1. --base main is main" [ "$("$W/ci/channel" --base main)" = main ]
check "1. --base next/omarchy-4.5 is next/omarchy-4.5" [ "$("$W/ci/channel" --base next/omarchy-4.5)" = next/omarchy-4.5 ]
check "1. no gh call for a channel branch" [ ! -s "$T/log" ]

# 2.
echo 37 >"$T/ahead.main"; echo 1 >"$T/ahead.next_omarchy-4.5"
check "2. stacked on an RC fix is rc" [ "$("$W/ci/channel" fix/172-x 2>/dev/null)" = rc ]
check "2. compared in GITHUB_REPOSITORY" grep -q '^api repos/o/r/compare/next/omarchy-4.5\.\.\.fix/172-x ' "$T/log"
check "2. stacked on an RC branch fix sits on next/omarchy-4.5" [ "$("$W/ci/channel" --base fix/172-x 2>/dev/null)" = next/omarchy-4.5 ]
echo 2 >"$T/ahead.main"; echo 40 >"$T/ahead.next_omarchy-4.5"
check "2. stacked on a main fix is rc" [ "$("$W/ci/channel" fix/9-y 2>/dev/null)" = rc ]
check "2. stacked on a main fix sits on main" [ "$("$W/ci/channel" --base fix/9-y 2>/dev/null)" = main ]

# 3.
rm "$T/ahead.next_omarchy-4.5"
rc=0; out=$("$W/ci/channel" fix/172-x 2>/dev/null) || rc=$?
check "3. a failed compare exits 1, prints no channel" [ "$rc" = 1 ] && [ -z "$out" ]
echo null >"$T/ahead.next_omarchy-4.5"
rc=0; "$W/ci/channel" fix/172-x >/dev/null 2>&1 || rc=$?
check "3. a non-number from the API exits 1" [ "$rc" = 1 ]
rc=0; out=$("$W/ci/channel" --base fix/172-x 2>/dev/null) || rc=$?
check "3. --base on a failed compare exits 1, prints nothing" [ "$rc" = 1 ] && [ -z "$out" ]

((fails == 0)) || { echo "$fails failure(s)"; exit 1; }
echo "all ok"
