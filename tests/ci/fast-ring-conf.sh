#!/bin/bash
# bin/env.sh's promotion-ring helpers (#309, not in use yet), offline:
#   a. RINGS and ring_next: rc -> quattro -> nothing; an unknown channel fails
#   b. channel_pins_ref: rc -> main, quattro -> pins/stable; an unknown channel fails
#   c. fast_ring_packages reads build/fast-ring.conf (omarchy-asus-keyring only, to start)
#   d. a conf with comments, blank lines and extra spacing prints just the names
#   e. a malformed conf (no reason, bad name, duplicate, missing file) fails, naming the line
# Usage: tests/ci/fast-ring-conf.sh
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export OMARCHY_ASUS_DATA=$T/data OMARCHY_ASUS_CHANNEL=quattro
fail=0
expect() { if [[ $1 == "$2" ]]; then echo "ok: $3"; else printf 'FAIL: %s\n  got:  %s\n  want: %s\n' "$3" "$1" "$2"; fail=1; fi; }
# run <shell code>: its output (stdout and stderr) and exit code, with bin/env.sh sourced
run() { (source "$W/bin/env.sh" && eval "$1") 2>&1; echo "rc=$?"; }
# has <text> <pattern>: y when the text matches the glob pattern, else n
# shellcheck disable=SC2053  # the pattern is meant to glob
has() { [[ $1 == $2 ]] && echo y || echo n; }

echo "== a. rings"
expect "$(run 'echo "${RINGS[*]}"')" $'rc quattro\nrc=0' "order: rc, then quattro"
expect "$(run 'ring_next rc')" $'quattro\nrc=0' "rc -> quattro"
expect "$(run 'ring_next quattro')" "rc=0" "quattro -> nothing"
expect "$(run 'ring_next edge')" "rc=1" "unknown channel fails"

echo "== b. pins refs"
expect "$(run 'channel_pins_ref rc')" $'main\nrc=0' "rc -> main"
expect "$(run 'channel_pins_ref quattro')" $'pins/stable\nrc=0' "quattro -> pins/stable"
expect "$(run 'channel_pins_ref edge')" "rc=1" "unknown channel fails"

echo "== c. the tracked conf"
expect "$(run 'fast_ring_packages')" $'omarchy-asus-keyring\nrc=0' "keyring only"

echo "== d. comments, blank lines, spacing"
printf '# head\n\n  pkg-a\treason one\n   # indented comment\npkg.b+c  reason two  \n\t\n' >"$T/ok.conf"
expect "$(run "fast_ring_packages '$T/ok.conf'")" $'pkg-a\npkg.b+c\nrc=0' "names in order"

echo "== e. malformed"
printf 'pkg-a  ok\npkg-b\n' >"$T/noreason.conf"
out=$(run "fast_ring_packages '$T/noreason.conf'")
expect "${out##*$'\n'}" "rc=1" "no reason: fails"
expect "$(has "$out" '*noreason.conf:2: no reason*')" y "no reason: names line 2"
expect "$(has "$out" "*pkg-a"$'\n'"*")" n "no reason: prints no names"
printf 'Pkg-A  upper case\n' >"$T/badname.conf"
out=$(run "fast_ring_packages '$T/badname.conf'")
expect "${out##*$'\n'}" "rc=1" "bad name: fails"
expect "$(has "$out" '*badname.conf:1: invalid package name*')" y "bad name: names line 1"
printf -- '-pkg  leading dash\n' >"$T/dash.conf"
expect "$(run "fast_ring_packages '$T/dash.conf'" | tail -1)" "rc=1" "leading dash: fails"
printf 'pkg-a  one\npkg-a  two\n' >"$T/dup.conf"
out=$(run "fast_ring_packages '$T/dup.conf'")
expect "${out##*$'\n'}" "rc=1" "duplicate: fails"
expect "$(has "$out" '*dup.conf:2: listed twice*')" y "duplicate: names line 2"
expect "$(run "fast_ring_packages '$T/missing.conf'" | tail -1)" "rc=2" "missing file: fails"

echo "== the channels are untouched"
expect "$(run 'echo "$CHANNEL $GH_BRANCH $GH_TAG"')" $'quattro main x86_64\nrc=0' "quattro as before"
expect "$(OMARCHY_ASUS_CHANNEL=rc run 'echo "$CHANNEL $GH_BRANCH $GH_TAG"')" $'rc next/omarchy-4.5 rc-x86_64\nrc=0' "rc as before"

exit $fail
