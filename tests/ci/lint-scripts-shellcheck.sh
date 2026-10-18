#!/bin/bash
# ci/lint-scripts with a shellcheck that can't run, offline (#89, #80): it stops up front
# with one "shellcheck not runnable" error instead of a "shellcheck findings" error per script.
#   a. a broken shellcheck (a stub that fails like a wrong-arch binary): exits non-zero,
#      one "shellcheck not runnable" line, no "shellcheck findings", no script was checked
#   b. no shellcheck on PATH at all: the same
# The real shellcheck is never run (slow, and depends on the host's version).
# Usage: tests/ci/lint-scripts-shellcheck.sh [keep]   (keep: leave the temp dir for inspection)
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
S=$(realpath "$(mktemp -d)")
[[ ${1:-} == keep ]] && echo "state: $S" || trap 'rm -rf "$S"' EXIT
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }

# check <label> <output file> <exit status>
check() {
    expect "$([[ $3 -ne 0 ]] && echo nonzero || echo zero)" nonzero "$1: exits non-zero (got $3)"
    expect "$(grep -c 'shellcheck not runnable' "$2")" 1 "$1: one 'shellcheck not runnable' error"
    expect "$(grep -c 'shellcheck findings' "$2")" 0 "$1: no 'shellcheck findings' errors"
    expect "$(grep -cE '^  (shell|sourced|install|python):' "$2")" 0 "$1: no script was checked"
}

echo "== a. broken shellcheck"
mkdir -p "$S/bin"
printf '#!/bin/bash\necho '\''shellcheck: cannot execute binary file'\'' >&2\nexit 126\n' >"$S/bin/shellcheck"
chmod +x "$S/bin/shellcheck"
PATH=$S/bin:$PATH "$W/ci/lint-scripts" >"$S/out-a" 2>&1
check "broken" "$S/out-a" $?
grep -q 'cannot execute binary file' "$S/out-a"; expect $? 0 "broken: the error quotes shellcheck's own message"

echo "== b. no shellcheck on PATH"
# A PATH with only what ci/lint-scripts needs before the check (and to clean up).
mkdir -p "$S/bin-b"
missing=
for c in dirname mktemp rm git head python3; do
    p=$(command -v "$c") || { missing+=" $c"; continue; }
    ln -s "$p" "$S/bin-b/$c"
done
if [[ -n $missing ]]; then
    echo "SKIP: b. no$missing on this host"
else
    PATH=$S/bin-b "$W/ci/lint-scripts" >"$S/out-b" 2>&1
    check "missing" "$S/out-b" $?
fi

((fail)) && { echo "FAILED"; cat "$S"/out-*; exit 1; }
echo "all passed"
