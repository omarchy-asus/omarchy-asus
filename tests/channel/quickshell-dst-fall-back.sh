#!/bin/bash
# Check for quickshell's clock-dst-fall-back.patch (quickshell-mirror/quickshell#1385):
#   1. the patch is in source=() with a sha256sum that matches the file, prepare()
#      applies it, and DELTA re-applies it;
#   2. a quickshell binary runs a SystemClock (seconds, minutes and hours precision)
#      with the wall clock moved into, and across, a DST fall-back, headless
#      (offscreen, its own HOME and runtime dir, nothing else changed: only this
#      process's wall clock moves, through an LD_PRELOAD shim; QTimer's monotonic
#      clock is untouched). Stock quickshell 0.3.2.r7.g2b4501a resolves the repeated
#      hour to its first occurrence, so the next tick is an hour in the past and
#      QTimer fires every 1 ms ("QTimer::start: negative intervals", ~1 kHz) for the
#      whole hour, and the clock shows the summer-time offset. Fixed: no warning,
#      about one tick a second, and the winter-time offset.
#
# Step 2 runs QS=<path to qs> (e.g. a build tree's build/src/quickshell), or the
# installed qs when it is our build; otherwise it says SKIP (CI's hosted runner has
# no quickshell). QS_EXPECT=storm turns step 2 around, to show the storm on stock:
#   QS=/usr/bin/qs QS_EXPECT=storm bash tests/channel/quickshell-dst-fall-back.sh
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
R=$W/recipes/quickshell
P=$R/clock-dst-fall-back.patch
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# ------------------------------------------------------------ 1. recipe
[[ -f $P ]] || { echo "FAIL $P missing"; exit 1; }
src=$(bash -c 'source "$1"; printf "%s\n" "${source[@]}"' _ "$R/PKGBUILD")
sha=$(bash -c 'source "$1"; printf "%s\n" "${sha256sums[@]}"' _ "$R/PKGBUILD")
i=$(grep -n -x "${P##*/}" <<<"$src" | cut -d: -f1)
[[ -n $i ]] && ok "the patch is in source=()" || bad "the patch is not in source=()"
[[ -n $i && $(sed -n "${i}p" <<<"$sha") == "$(sha256sum "$P" | cut -d' ' -f1)" ]] &&
  ok "sha256sum matches" || bad "sha256sum mismatch"
grep -q 'patch -Np1 -i "$srcdir/clock-dst-fall-back.patch"' "$R/PKGBUILD" &&
  ok "prepare() applies it" || bad "prepare() doesn't apply it"
grep -q '^patch clock-dst-fall-back.patch prepare$' "$R/DELTA" &&
  ok "DELTA re-applies it" || bad "DELTA has no line for it"

# ------------------------------------------------------------ 2. behaviour
qs=${QS:-}
if [[ -z $qs ]] && pacman -Qi quickshell 2>/dev/null | grep -q '^Description .*(omarchy-asus build)'; then
  qs=/usr/bin/qs
fi
expect=${QS_EXPECT:-none}
if [[ -z $qs ]]; then
  echo "SKIP behaviour: no quickshell of ours (set QS=<path to qs>)"
elif ! command -v gcc >/dev/null; then
  echo "SKIP behaviour: needs gcc for the wall-clock shim"
else
  H=$(mktemp -d)
  trap 'rm -r "${H:?}"' EXIT
  mkdir -m 700 "$H/home" "$H/run" "$H/cfg"
  # Only the wall clock moves: CLOCK_REALTIME(_COARSE), gettimeofday and time. No
  # malloc, so it is safe before jemalloc is up (libfaketime deadlocks qs there).
  cat >"$H/shim.c" <<'EOF'
#define _GNU_SOURCE
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
static long long off;
__attribute__((constructor)) static void init(void) {
	const char *v = getenv("WALL_OFFSET");
	if (v) off = atoll(v);
}
int clock_gettime(clockid_t id, struct timespec *ts) {
	int r = (int)syscall(SYS_clock_gettime, id, ts);
	if (r == 0 && (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE)) ts->tv_sec += off;
	return r;
}
int gettimeofday(struct timeval *tv, void *tz) {
	struct timespec ts;
	int r = clock_gettime(CLOCK_REALTIME, &ts);
	(void)tz;
	if (r == 0 && tv) { tv->tv_sec = ts.tv_sec; tv->tv_usec = ts.tv_nsec / 1000; }
	return r;
}
time_t time(time_t *t) {
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	if (t) *t = ts.tv_sec;
	return ts.tv_sec;
}
EOF
  gcc -shared -fPIC -O2 -o "$H/shim.so" "$H/shim.c" || { echo "FAIL shim build"; exit 1; }
  cat >"$H/cfg/shell.qml" <<'EOF'
import QtQuick
import Quickshell
ShellRoot {
  SystemClock { id: sec; precision: SystemClock.Seconds; onDateChanged: console.log("tick", sec.date) }
  SystemClock { id: min; precision: SystemClock.Minutes }
  SystemClock { precision: SystemClock.Hours }
  Component.onCompleted: console.log("start", min.date)
}
EOF
  # run NAME TZ UTC-START SECONDS: qs's output in $H/NAME.log
  run() {
    local off=$(($(date -ud "$3" +%s) - $(date +%s)))
    env -i PATH=/usr/bin HOME="$H/home" XDG_RUNTIME_DIR="$H/run" XDG_CONFIG_HOME="$H/home/.config" \
      XDG_CACHE_HOME="$H/home/.cache" XDG_STATE_HOME="$H/home/.local/state" \
      XDG_DATA_HOME="$H/home/.local/share" LANG=C.UTF-8 QT_QPA_PLATFORM=offscreen TZ="$2" \
      LD_PRELOAD="$H/shim.so" WALL_OFFSET="$off" \
      timeout -s INT -k 3 "$4" "$qs" -p "$H/cfg/shell.qml" >"$H/$1.log" 2>&1
  }
  # check NAME OFFSET: no storm, ~1 tick a second, the start shows OFFSET (e.g. GMT-0500)
  check() {
    local neg ticks
    neg=$(grep -c 'negative intervals' "$H/$1.log")
    ticks=$(grep -c ' tick ' "$H/$1.log")
    grep -q ' start ' "$H/$1.log" || { bad "$1: the shell didn't start: $(head -c 400 "$H/$1.log")"; return; }
    if [[ $expect == storm ]]; then
      ((neg > 100)) && ok "$1: stock storms ($neg negative-interval warnings, $ticks ticks)" ||
        bad "$1: expected a storm, got $neg warnings"
      return
    fi
    ((neg == 0)) && ok "$1: no negative-interval warning" || bad "$1: $neg negative-interval warnings"
    ((ticks >= 2 && ticks <= 8)) && ok "$1: $ticks ticks" || bad "$1: $ticks ticks (expected about one a second)"
    [[ -z $2 ]] && return
    grep ' start ' "$H/$1.log" | grep -q "$2" && ok "$1: shows $2" ||
      bad "$1: $(grep -o 'start .*' "$H/$1.log" | head -n1), expected $2"
  }
  echo "behaviour: $qs (expect $expect)"
  # New York, 2026-11-01: 02:00 EDT -> 01:00 EST at 06:00Z. 06:30Z is 01:30 EST, the
  # second 01:30; 05:59:58Z steps across the fold.
  run ny-repeated America/New_York '2026-11-01 06:30:00' 4
  check ny-repeated GMT-0500
  run ny-fold America/New_York '2026-11-01 05:59:58' 5
  check ny-fold ''
  # Berlin, 2026-10-25: 03:00 CEST -> 02:00 CET at 01:00Z.
  run berlin-repeated Europe/Berlin '2026-10-25 01:30:00' 4
  check berlin-repeated GMT+0100
fi

((fail == 0)) && echo "PASS" || echo "FAILED"
exit "$fail"
