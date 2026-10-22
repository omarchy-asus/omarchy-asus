#!/bin/bash
# g16-winlockd and g16-winlock against a fake hidraw node (a raw pty, with the
# feature ioctls shimmed by fake_hid.c) on a private D-Bus with a fake polkit.
# Run by the PKGBUILD's check(), or by hand:
#   ./winlockd.test.sh [path/to/g16-winlockd]   (default: compiles g16-winlockd.c)
# Needs cc, libsystemd, dbus-daemon, gdbus (glib2), python3.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here
T=$(mktemp -d)
pids=()
cleanup() {
    local p
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    [[ -n ${BUS_PID:-} ]] && kill "$BUS_PID" 2>/dev/null
    wait 2>/dev/null || true
    rm -rf "$T"
}
trap cleanup EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

CFLAGS_SD=$(pkg-config --cflags --libs libsystemd)
if [[ -n ${1:-} ]]; then
    DAEMON=$1
else
    DAEMON=$T/g16-winlockd
    # shellcheck disable=SC2086
    cc -O2 -Wall -o "$DAEMON" "$src/g16-winlockd.c" $CFLAGS_SD
fi
cc -O2 -shared -fPIC -o "$T/fake_hid.so" "$here/fake_hid.c" -ldl
# shellcheck disable=SC2086
cc -O2 -Wall -o "$T/fake_polkit" "$here/fake_polkit.c" $CFLAGS_SD

# A private bus stands in for the system bus (the session config lets anyone own a name).
read -r DBUS_SYSTEM_BUS_ADDRESS BUS_PID < <(dbus-daemon --session --fork --nopidfile \
    --print-address=1 --print-pid=1 | paste -sd' ')
export DBUS_SYSTEM_BUS_ADDRESS
export FAKE_POLKIT_LOG=$T/polkit.log FAKE_HID_LOG=$T/hid.log
touch "$FAKE_POLKIT_LOG" "$FAKE_HID_LOG" "$T/written.log"

# Fake sysfs: hidraw0 is another interface of the keyboard (no report 0x5D),
# hidraw1 the Win-lock one. Descriptor: Usage Page FF31, Collection, Report ID 0x5D.
export G16_WINLOCKD_SYSFS=$T/sys G16_WINLOCKD_DEV=$T/dev G16_WINLOCK_SYSFS=$T/sys
mkdir -p "$T/sys/hidraw0/device" "$T/sys/hidraw1/device" "$T/dev" "$T/bin"
for n in 0 1; do echo 'HID_ID=0003:00000B05:000019B6' >"$T/sys/hidraw$n/device/uevent"; done
printf '\x05\x01\x09\x06\xa1\x01\x85\x01\x75\x08\x95\x08\xc0' >"$T/sys/hidraw0/device/report_descriptor"
printf '\x06\x31\xff\x09\x76\xa1\x01\x85\x5d\x75\x08\x95\x3f\xc0' >"$T/sys/hidraw1/device/report_descriptor"

coproc NODE { exec python3 -I "$here/fake_node.py" "$T/dev/hidraw1" "$T/written.log"; }
pids+=("$NODE_PID")
read -r _ <&"${NODE[0]}"
report() { echo "$1" >&"${NODE[1]}"; }

# OSD: a fake omarchy-osd records each message.
cat >"$T/bin/omarchy-osd" <<EOF
#!/bin/bash
while getopts i:m:d: o; do [[ \$o == m ]] && echo "\$OPTARG" >>"$T/osd.log"; done
EOF
chmod +x "$T/bin/omarchy-osd"
touch "$T/osd.log"

NAME=io.github.omarchy_asus.WinLock1 OPATH=/io/github/omarchy_asus/WinLock1
call() { gdbus call --system --dest $NAME --object-path $OPATH --method "$NAME.$1" "${@:2}" 2>&1; }
# wait_for <file> <regex>: up to 5 s
wait_for() {
    local i
    for ((i = 0; i < 50; i++)); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
    return 1
}
owned() { gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true; }

# 1. An interface without report 0x5D: exit 0 at once, without the name.
if out=$(timeout 5 "$DAEMON" hidraw0) && [[ $out == *"nothing to do"* ]] && ! owned $NAME; then
    pass "hidraw0 (no report 0x5D): exits 0 without taking the bus name"
else
    fail "hidraw0: expected a clean exit, got: $out"
fi

start_polkit() {
    FAKE_POLKIT_ALLOW=$1 "$T/fake_polkit" & POLKIT_PID=$!; pids+=($!)
    for ((i = 0; i < 50; i++)); do owned org.freedesktop.PolicyKit1 && break; sleep 0.1; done
}
start_polkit 1
LD_PRELOAD=$T/fake_hid.so "$DAEMON" hidraw1 >"$T/daemon.log" 2>&1 & DAEMON_PID=$!; pids+=($!)
for ((i = 0; i < 50; i++)); do owned $NAME && break; sleep 0.1; done
owned $NAME && pass "hidraw1: owns $NAME" || fail "hidraw1: $NAME not owned: $(cat "$T/daemon.log")"

# 2. Reports become LockChanged signals; other 0x5D reports (Aura) don't.
gdbus monitor --system --dest $NAME --object-path $OPATH >"$T/monitor.log" 2>&1 & pids+=($!)
wait_for "$T/monitor.log" "owned by" || true
report '5d bf 01 01'
wait_for "$T/monitor.log" 'LockChanged \(true,\)' &&
    pass "5D BF 01 01 -> LockChanged(true)" || fail "no LockChanged(true): $(cat "$T/monitor.log")"
report '5d 01 02 03'
report '5d bf 01 00'
wait_for "$T/monitor.log" 'LockChanged \(false,\)' &&
    pass "5D BF 01 00 -> LockChanged(false)" || fail "no LockChanged(false)"
n=$(grep -c LockChanged "$T/monitor.log" || true)
[[ $n == 2 ]] && pass "an Aura 5D report sends no signal" || fail "expected 2 signals, saw $n"

# 3. Status: the GetFeature reply, or the last report when GetFeature fails.
out=$(call Status)
[[ $out == '(false,)' ]] && pass "Status without a feature reply: last report (false)" ||
    fail "Status: $out"

# 4. SetLocked, authorized: SetFeature 5D BF 00 xx, then the 01 01 write; polkit asked.
out=$(call SetLocked false)
if [[ $out == '()' ]] && grep -qx 'SetFeature 5d bf 00 00' "$FAKE_HID_LOG" &&
    wait_for "$T/written.log" '^01 01$'; then
    pass "SetLocked(false): SetFeature 5d bf 00 00 and output report 01 01"
else
    fail "SetLocked(false): $out / $(cat "$FAKE_HID_LOG") / $(cat "$T/written.log")"
fi
grep -qx 'io.github.omarchy-asus.winlock.set-locked system-bus-name' "$FAKE_POLKIT_LOG" &&
    pass "SetLocked checks polkit io.github.omarchy-asus.winlock.set-locked for the caller" ||
    fail "polkit not asked: $(cat "$FAKE_POLKIT_LOG")"

# 5. SetLocked, refused: AccessDenied, nothing written.
kill "$POLKIT_PID"; wait "$POLKIT_PID" 2>/dev/null || true
start_polkit 0
: >"$FAKE_HID_LOG"
out=$(call SetLocked true || true)
[[ $out == *AccessDenied* && ! -s $FAKE_HID_LOG ]] &&
    pass "SetLocked refused by polkit: AccessDenied, no SetFeature" || fail "refused SetLocked: $out / $(cat "$FAKE_HID_LOG")"
kill "$POLKIT_PID"; wait "$POLKIT_PID" 2>/dev/null || true
start_polkit 1

# 6. The client: one-shot commands are D-Bus calls.
export PATH=$T/bin:$PATH
: >"$FAKE_HID_LOG"
out=$(python3 -I "$src/g16-winlock" lock 2>&1) && grep -qx 'SetFeature 5d bf 00 01' "$FAKE_HID_LOG" &&
    pass "g16-winlock lock -> SetLocked(true)" || fail "g16-winlock lock: $out / $(cat "$FAKE_HID_LOG")"
out=$(python3 -I "$src/g16-winlock" status 2>&1 || true)
[[ $out == *locked=* ]] && pass "g16-winlock status: $out" || fail "g16-winlock status: $out"

# 7. watch --mode=unlock: OSD, SetLocked(false), and its echo suppressed.
: >"$FAKE_HID_LOG"
python3 -I "$src/g16-winlock" watch --mode=unlock >"$T/watch.log" 2>&1 & WATCH_PID=$!; pids+=($!)
wait_for "$T/watch.log" "owned by" || true
report '5d bf 01 01'
if wait_for "$FAKE_HID_LOG" 'SetFeature 5d bf 00 00' && wait_for "$T/osd.log" 'Super auto-unlocked'; then
    pass "watch --mode=unlock: Fn+Super lock is cleared, OSD 'Super auto-unlocked'"
else
    fail "watch unlock: $(cat "$T/watch.log") / $(cat "$FAKE_HID_LOG") / $(cat "$T/osd.log")"
fi
report '5d bf 01 00'
wait_for "$T/watch.log" 'suppressed echo' && ! grep -q 'Super unlocked' "$T/osd.log" &&
    pass "watch --mode=unlock: the unlock echo shows no second OSD" || fail "echo not suppressed: $(cat "$T/watch.log")"
kill "$WATCH_PID" 2>/dev/null || true

# 8. watch --mode=toast: OSD only, nothing written.
: >"$FAKE_HID_LOG"; : >"$T/osd.log"
python3 -I "$src/g16-winlock" watch --mode=toast >"$T/watch.log" 2>&1 & WATCH_PID=$!; pids+=($!)
wait_for "$T/watch.log" "owned by" || true
report '5d bf 01 01'
wait_for "$T/osd.log" '^Super locked$' && sleep 0.3 && [[ ! -s $FAKE_HID_LOG ]] &&
    pass "watch --mode=toast: OSD 'Super locked', lock left alone" || fail "watch toast: $(cat "$T/watch.log")"
kill "$WATCH_PID" 2>/dev/null || true

# 9. The client never opens a device node: no /dev path and no os.open in it.
if grep -nE '/dev/|os\.open|O_RDWR|ioctl' "$src/g16-winlock"; then
    fail "g16-winlock still touches a device node (lines above)"
else
    pass "g16-winlock opens no /dev node"
fi

# 10. Unplug: the daemon exits when the node goes away (pty closed = EOF/EIO).
kill "$NODE_PID" 2>/dev/null || true
for ((i = 0; i < 50; i++)); do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.1; done
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    wait "$DAEMON_PID" && rc=0 || rc=$?
    [[ $rc == 0 ]] && pass "node gone: the daemon exits 0" || fail "node gone: exit $rc"
else
    fail "node gone: the daemon is still running"
fi

((fails == 0)) && echo "all passed" || { echo "$fails failed"; cat "$T/daemon.log"; exit 1; }
