#!/bin/bash
# g16-winlockd under the [Service] sandbox of g16-winlockd@.service, as root, called
# by this (non-root) user: a fake node and private bus as in winlockd.test.sh. By hand
# on a systemd host (sudo; not in check(), which has neither):
#   ./sandbox.test.sh
# Catches what the same-user offline test can't: a syscall, path or device the
# sandbox denies, and sd-bus refusing another user's call.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here
# /dev/shm: the unit's PrivateTmp and ProtectHome hide /tmp and the home dirs.
R=$(mktemp -d /dev/shm/g16-winlockd-test.XXXXXX)
chmod 755 "$R"
unit=g16-winlockd-test-$$
cleanup() {
    sudo systemctl stop "$unit" 2>/dev/null || true
    sudo systemctl reset-failed "$unit" 2>/dev/null || true
    kill "${PK:-}" "${BUS:-}" 2>/dev/null || true
    exec 7>&- || true
    wait 2>/dev/null || true
    rm -rf "$R"
}
trap cleanup EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

sd=$(pkg-config --cflags --libs libsystemd)
# shellcheck disable=SC2086
cc -O2 -Wall -o "$R/g16-winlockd" "$src/g16-winlockd.c" $sd
cc -O2 -shared -fPIC -o "$R/fake_hid.so" "$here/fake_hid.c" -ldl
# shellcheck disable=SC2086
cc -O2 -Wall -o "$R/fake_polkit" "$here/fake_polkit.c" $sd
mkdir -p "$R/sys/hidraw1/device" "$R/dev"
echo 'HID_ID=0003:00000B05:000019B6' >"$R/sys/hidraw1/device/uevent"
printf '\x06\x31\xff\x09\x76\xa1\x01\x85\x5d\x75\x08\x95\x3f\xc0' >"$R/sys/hidraw1/device/report_descriptor"

# A private bus any user may connect to (root's daemon, this user's calls).
sed "s|<listen>unix:tmpdir=/tmp</listen>|<listen>unix:path=$R/bus</listen>|; s|<allow own=\"\\*\"/>|&<allow user=\"*\"/>|" \
    /usr/share/dbus-1/session.conf >"$R/bus.conf"
dbus-daemon --config-file="$R/bus.conf" --nofork 2>"$R/bus.err" & BUS=$!
export DBUS_SYSTEM_BUS_ADDRESS=unix:path=$R/bus
for ((i = 0; i < 50; i++)); do [[ -S $R/bus ]] && break; sleep 0.1; done
touch "$R/hid.log" "$R/polkit.log" "$R/written.log"
chmod 666 "$R/hid.log"
FAKE_POLKIT_LOG=$R/polkit.log FAKE_POLKIT_ALLOW=1 "$R/fake_polkit" & PK=$!
exec 7> >(exec python3 -I "$here/fake_node.py" "$R/dev/hidraw1" "$R/written.log" >/dev/null)
for ((i = 0; i < 50; i++)); do [[ -L $R/dev/hidraw1 ]] && break; sleep 0.1; done
chmod 666 "$(readlink "$R/dev/hidraw1")"

# The unit's [Service] sandbox; a pty stands in for the hidraw node.
props=()
while IFS= read -r l; do props+=(-p "$l"); done < <(sed -n '/^\[Service\]/,$p' "$src/g16-winlockd@.service" |
    grep -E '^[A-Z][A-Za-z]+=' | grep -vE '^(ExecStart|Restart|RestartSec)=')
sudo systemd-run --quiet --unit="$unit" "${props[@]}" -p 'DeviceAllow=char-pts rw' \
    -E DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS" -E G16_WINLOCKD_SYSFS="$R/sys" \
    -E G16_WINLOCKD_DEV="$R/dev" -E LD_PRELOAD="$R/fake_hid.so" -E FAKE_HID_LOG="$R/hid.log" \
    "$R/g16-winlockd" hidraw1

N=io.github.omarchy_asus.WinLock1 P=/io/github/omarchy_asus/WinLock1
call() { gdbus call --system --dest $N --object-path $P --method "$N.$1" "${@:2}" 2>&1 || true; }
for ((i = 0; i < 50; i++)); do sudo journalctl -u "$unit" -q -o cat | grep -q '^watching' && break; sleep 0.1; done
gdbus monitor --system --dest $N >"$R/mon.log" 2>&1 & MON=$!
for ((i = 0; i < 50; i++)); do grep -q 'owned by' "$R/mon.log" && break; sleep 0.1; done
echo '5d bf 01 01' >&7
for ((i = 0; i < 50; i++)); do grep -q LockChanged "$R/mon.log" && break; sleep 0.1; done
kill "$MON"
grep -q 'LockChanged (true,)' "$R/mon.log" && pass "sandboxed: report -> LockChanged(true)" || fail "no signal: $(cat "$R/mon.log")"
out=$(call Status)
[[ $out == '(true,)' ]] && pass "sandboxed: Status from uid $(id -u): $out" || fail "Status: $out"
out=$(call SetLocked false)
for ((i = 0; i < 50; i++)); do grep -q '01 01' "$R/written.log" && break; sleep 0.1; done
[[ $out == '()' ]] && grep -qx 'SetFeature 5d bf 00 00' "$R/hid.log" && grep -qx '01 01' "$R/written.log" &&
    grep -q set-locked "$R/polkit.log" &&
    pass "sandboxed: SetLocked(false) asks polkit, writes the feature and 01 01" ||
    fail "SetLocked: $out / $(cat "$R/hid.log") / $(cat "$R/written.log") / $(cat "$R/polkit.log")"
sudo systemctl is-active -q "$unit" && pass "sandboxed: still running" ||
    fail "the daemon died: $(sudo journalctl -u "$unit" -q -o cat)"
sudo systemd-analyze security "$unit" --no-pager 2>/dev/null | tail -1

((fails == 0)) && echo "all passed" || { echo "$fails failed"; sudo journalctl -u "$unit" -q -o cat; exit 1; }
