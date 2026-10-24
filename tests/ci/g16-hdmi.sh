#!/bin/bash
# bin/g16-hdmi, offline: a fake sysfs/procfs shaped like the G16's (card0 nvidia with
# HDMI-A-1 and DP-9, card1 amdgpu), journalctl, udevadm, logger and g16-testd stubbed:
#   1. snapshot finds the RTX's card, reads its connectors (the EDID's monitor name,
#      never its serial), runtime PM, the GPIO 16/5 interrupt counts and the
#      nvidia display warnings, scrubs the host name, and flags an HDMI connector
#      that is connected without an EDID;
#   2. watch logs a line when the state changes (poll), on a resume (suspend_stats)
#      and on a drm uevent, to its file and the journal, and stops cleanly;
#   3. log keeps only the watch lines and the kernel's display and suspend lines;
#   4. trace refuses without a g16-testd session (exit 3), starts the allowlisted
#      events through it, and stop keeps only the RTX's and the suspend lines;
#   5. bad usage exits 2.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; [[ -n ${KEEP:-} ]] || rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
has() { grep -qE -- "$2" "$1" && ok "$3" || { bad "$3"; sed 's/^/    /' "$1"; }; }
hasnt() { grep -qE -- "$2" "$1" && { bad "$3"; sed 's/^/    /' "$1"; } || ok "$3"; }
SCRIPT=$W/bin/g16-hdmi
S=$T/sys P=$T/proc B=$T/bin H=$T/home
RTX=$S/devices/pci0000:00/0000:00:03.1/0000:64:00.0
IGPU=$S/devices/pci0000:00/0000:00:08.1/0000:65:00.0
mkdir -p "$B" "$H" "$S/class/drm" "$S/bus/pci/drivers/nvidia" "$S/bus/pci/drivers/amdgpu" "$RTX/power" "$IGPU" \
  "$S/module/nvidia" "$S/power/suspend_stats" "$P/sys/kernel" "$P/driver/nvidia/gpus/0000:64:00.0"
ln -s "$S/bus/pci/drivers/nvidia" "$RTX/driver"
ln -s "$S/bus/pci/drivers/amdgpu" "$IGPU/driver"
echo active >"$RTX/power/runtime_status"; echo auto >"$RTX/power/control"
mkdir "$S/class/drm/card0" "$S/class/drm/card1"
ln -s "$RTX" "$S/class/drm/card0/device"; ln -s "$IGPU" "$S/class/drm/card1/device"
conn() {  # card-name status enabled edid-file
  mkdir -p "$S/class/drm/$1"; echo "$2" >"$S/class/drm/$1/status"; echo "$3" >"$S/class/drm/$1/enabled"
  echo On >"$S/class/drm/$1/dpms"; if [[ -n ${4:-} ]]; then cp "$4" "$S/class/drm/$1/edid"; else : >"$S/class/drm/$1/edid"; fi
}
# A 128-byte EDID: monitor name "TEST MONITOR" at descriptor 54, serial "SECRET123" at 72.
python3 -I - "$T/edid" <<'EOF'
import sys
b = bytearray(128); b[0:8] = b'\x00\xff\xff\xff\xff\xff\xff\x00'
b[54:59] = b'\x00\x00\x00\xfc\x00'; b[59:72] = b'TEST MONITOR\n'
b[72:77] = b'\x00\x00\x00\xff\x00'; b[77:90] = b'SECRET123\n   '
open(sys.argv[1], 'wb').write(b)
EOF
conn card0-HDMI-A-1 connected enabled "$T/edid"
conn card0-DP-9 disconnected disabled
conn card1-eDP-1 connected enabled "$T/edid"
echo 615.78.08 >"$S/module/nvidia/version"
echo 1 >"$S/power/suspend_stats/success"
echo 7.2.8-9.104-omarchy >"$P/sys/kernel/osrelease"
echo testhost >"$P/sys/kernel/hostname"
echo "root=/dev/x quiet gpiolib_acpi.ignore_wake=AMDI0030:00@16 splash" >"$P/cmdline"
printf 'Runtime D3 status:          Enabled (fine-grained)\nVideo Memory:               Active\n' \
  >"$P/driver/nvidia/gpus/0000:64:00.0/power"
interrupts() {  # GPIO 16 count, GPIO 5 count
  cat >"$P/interrupts" <<EOF
            CPU0       CPU1
  28:          0          2  amd_gpio    0  ACPI:Event
  29:          0          $2  amd_gpio    5  ACPI:Event
  30:          1          $(($1 - 1))  amd_gpio   16  ACPI:Event
  91:     658211          0  amd_gpio    8  ASUF1209:00
  94:          0     158658  IR-PCI-MSIX-0000:64:00.0 0-edge nvidia
EOF
}
interrupts 3 0
cat >"$T/journal" <<'EOF'
2026-10-20T00:16:51.405490-04:00 testhost kernel: PM: suspend entry (s2idle)
2026-10-20T00:16:54.571423-04:00 testhost kernel: [drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00006400] Flip event timeout on head 0
2026-10-20T00:17:34.940930-04:00 testhost kernel: PM: suspend exit
2026-10-20T00:20:00.000000-04:00 testhost kernel: wlp99s0: associated
2026-10-20T03:30:44.517590-04:00 testhost kernel: nvidia 0000:64:00.0: Enabling HDA controller
2026-10-20T03:30:46.805383-04:00 testhost kernel: nvidia-modeset: WARNING: GPU:0: Unable to read EDID for display device TEST MONITOR (HDMI-0)
2026-10-20T03:31:00.000000-04:00 testhost kernel: nvidia-modeset: WARNING: GPU:0: Unable to read EDID for display device DP-0
2026-10-20T03:32:00.000000-04:00 testhost g16-hdmi[42]: poll: HDMI-A-1=disconnected,disabled,edid0 rtx=suspended
EOF
cat >"$B/journalctl" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB/journalctl.args"; cat "$STUB/journal"
EOF
cat >"$B/logger" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB/logger"
EOF
# udevadm monitor: a header, then whatever the test appends to $STUB/uevents.
: >"$T/uevents"
cat >"$B/udevadm" <<'EOF'
#!/bin/bash
[[ -e $STUB/udev-exits ]] && exit 0
echo "monitor will print the received events for:"; echo "KERNEL - the kernel uevent"; echo
exec tail -n0 -f "$STUB/uevents"
EOF
cat >"$B/g16-testd" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB/testd.args"
case $1 in
  available) [[ -e $STUB/session ]] ;;
  call) if [[ $2 == trace-stop ]]; then
          [[ -e $STUB/watchdog-stopped ]] && { echo "g16-testd: no trace hdmi running" >&2; exit 1; }
          echo "$STUB/hdmi.trace"
        fi; exit 0 ;;
esac
EOF
chmod +x "$B"/*
run() { env PATH="$B:$PATH" HOME="$H" USER=tester STUB="$T" G16_HDMI_SYS="$S" G16_HDMI_PROC="$P" \
  G16_HDMI_STATE="$H/state" G16_HDMI_TESTD="$B/g16-testd" G16_HDMI_TESTD_OUT="$T/testd-out" "$SCRIPT" "$@"; }
# A watch in the background, its pid the script's own (so a TERM reaches it).
watch_bg() { local out=$1; shift; (run_exec "$@" >"$out" 2>&1) & wp=$!; }
run_exec() { exec env PATH="$B:$PATH" HOME="$H" USER=tester STUB="$T" G16_HDMI_SYS="$S" G16_HDMI_PROC="$P" \
  G16_HDMI_STATE="$H/state" G16_HDMI_TESTD="$B/g16-testd" G16_HDMI_TESTD_OUT="$T/testd-out" "$SCRIPT" "$@"; }

# ------------------------------------------------------------------ 1. snapshot
run snapshot >"$T/snap" 2>&1; rc=$?
((rc == 0)) && ok "snapshot exits 0" || bad "snapshot exits $rc"
has "$T/snap" 'RTX 0000:64:00.0: runtime active \(control auto\), runtime D3 Enabled \(fine-grained\), video memory Active' "snapshot reads the RTX's runtime PM"
has "$T/snap" 'connectors \(card0, nvidia\)' "snapshot picks the nvidia card"
has "$T/snap" 'HDMI-A-1 +connected +enabled +dpms On +EDID 128 bytes \(TEST MONITOR\)' "snapshot reads HDMI status and the monitor name"
has "$T/snap" 'DP-9 +disconnected +disabled .*EDID 0 bytes$' "snapshot lists the other connector"
hasnt "$T/snap" 'eDP-1' "snapshot leaves the amdgpu card out"
hasnt "$T/snap" 'SECRET123' "snapshot never prints the EDID serial"
has "$T/snap" 'pin 16 \(HDMI\) 3, pin 5 0' "snapshot sums the GPIO interrupts over CPUs"
has "$T/snap" 'gpiolib_acpi on the command line: gpiolib_acpi.ignore_wake=AMDI0030:00@16' "snapshot shows a gpiolib_acpi option"
has "$T/snap" 'flip event timeouts \(#1361\) +1$' "snapshot counts flip event timeouts"
has "$T/snap" 'HDMI EDID read failures +1$' "snapshot counts HDMI EDID failures, not DP-0's"
hasnt "$T/snap" 'testhost' "snapshot scrubs the host name"
hasnt "$T/snap" 'stale connect state' "no stale-state note while the EDID is there"
: >"$S/class/drm/card0-HDMI-A-1/edid"
run snapshot >"$T/snap2" 2>&1
has "$T/snap2" 'connected without an EDID: a stale connect state \(#213\)' "snapshot flags HDMI connected without an EDID"
cp "$T/edid" "$S/class/drm/card0-HDMI-A-1/edid"

# ------------------------------------------------------------------ 2. watch
until_has() {  # file regex seconds
  local i
  for ((i = 0; i < $3 * 10; i++)); do grep -qE -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  return 1
}
watch_bg "$T/watch" watch --interval 1 --hours 1
until_has "$T/watch" 'watch started' 5 && ok "watch starts" || bad "watch starts"
has "$T/watch" 'watch started \(1 h, every 1 s, file ~/state/watch-[0-9-]+\.log\): DP-9=disconnected,disabled,edid0 HDMI-A-1=connected,enabled,edid128 rtx=active gpio16=3 gpio5=0 suspends=1' "watch logs the starting state"
sleep 1.5
lines=$(wc -l <"$T/watch")
((lines == 1)) && ok "watch logs nothing while nothing changes" || bad "watch logged $lines lines with no change"
echo disconnected >"$S/class/drm/card0-HDMI-A-1/status"; : >"$S/class/drm/card0-HDMI-A-1/edid"; interrupts 4 0
until_has "$T/watch" 'poll: .*HDMI-A-1=disconnected,enabled,edid0 .*gpio16=4' 5 && ok "watch logs an unplug with the GPIO 16 edge" ||
  { bad "watch logs an unplug"; cat "$T/watch"; }
echo 2 >"$S/power/suspend_stats/success"
until_has "$T/watch" 'resume: .*suspends=2' 5 && ok "watch logs a resume even with no other change" || bad "watch logs a resume"
kill -TERM $wp; wait $wp 2>/dev/null
has "$T/watch" 'watch stopped$' "watch says it stopped"
f=$(ls "$H"/state/watch-*.log 2>/dev/null | head -1)
[[ -n $f ]] && cmp -s <(cut -d' ' -f2- "$f") <(cut -d' ' -f2- "$T/watch") && ok "watch writes the same lines to its file" || bad "watch file"
has "$T/logger" '^-t g16-hdmi -- poll: .*HDMI-A-1=disconnected' "watch logs to the journal (tag g16-hdmi)"
# A drm uevent ends the wait at once (a 60 s poll would not).
rm -f "$H"/state/watch-*.log
watch_bg "$T/watch2" watch --interval 60
until_has "$T/watch2" 'watch started' 5
echo connected >"$S/class/drm/card0-HDMI-A-1/status"; cp "$T/edid" "$S/class/drm/card0-HDMI-A-1/edid"; interrupts 5 0
echo "KERNEL[123.4] change   /devices/pci0000:00/0000:00:03.1/0000:64:00.0/drm/card0 (drm)" >>"$T/uevents"
until_has "$T/watch2" 'uevent: .*HDMI-A-1=connected,enabled,edid128 .*gpio16=5' 5 && ok "watch reacts to a drm uevent" ||
  { bad "watch reacts to a drm uevent"; cat "$T/watch2"; }
kill -TERM $wp; wait $wp 2>/dev/null
# udevadm exiting at once (the coprocess gone before the first read) falls back to polling.
touch "$T/udev-exits"
watch_bg "$T/watch3" watch --interval 1
until_has "$T/watch3" 'watch started' 5
sleep 1.5
kill -0 $wp 2>/dev/null && ok "watch survives udevadm exiting" || { bad "watch survives udevadm exiting"; cat "$T/watch3"; }
interrupts 6 0
until_has "$T/watch3" 'poll: .*gpio16=6' 5 && ok "watch polls once udevadm is gone" || { bad "watch polls once udevadm is gone"; cat "$T/watch3"; }
kill -TERM $wp; wait $wp 2>/dev/null
rm -f "$T/udev-exits"

# ------------------------------------------------------------------ 3. log
run log --boot -1 >"$T/log" 2>&1
has "$T/journalctl.args" '-b -1 .*-t g16-hdmi -t kernel' "log asks the journal for that boot's watch and kernel lines"
has "$T/log" 'Flip event timeout' "log keeps the flip timeout"
has "$T/log" 'PM: suspend entry' "log keeps the suspend lines"
has "$T/log" 'g16-hdmi\[42\]: poll' "log keeps the watch lines"
has "$T/log" 'Enabling HDA' "log keeps the RTX's wakes"
hasnt "$T/log" 'wlp99s0' "log drops unrelated kernel lines"
hasnt "$T/log" 'testhost' "log scrubs the host name"

# ------------------------------------------------------------------ 4. trace
run trace start >"$T/tr0" 2>&1; rc=$?
((rc == 3)) && ok "trace without a session exits 3" || bad "trace without a session exits $rc"
has "$T/tr0" 'g16-testd session start' "trace says how to open a session"
touch "$T/session"
run trace start >"$T/tr1" 2>&1; rc=$?
((rc == 0)) && ok "trace start exits 0" || bad "trace start exits $rc"
has "$T/testd.args" '^call trace-start hdmi rpm/rpm_suspend,rpm/rpm_resume,rpm/rpm_return_int,power/suspend_resume - 32768 --reason #158' "trace start asks testd for the allowlisted events"
# every event asked for is on testd's allowlist (the recipe lives on the RC branch only)
TD=$W/recipes/omarchy-asus-g16-testd/g16-testd
if [[ -f $TD ]]; then
  for e in rpm/rpm_suspend rpm/rpm_resume rpm/rpm_return_int power/suspend_resume; do
    grep -q "$e" "$TD" || bad "$e is not on g16-testd's allowlist"
  done
else
  echo "skip: g16-testd's allowlist (its recipe isn't on this branch)"
fi
cat >"$T/hdmi.trace" <<'EOF'
# tracer: nop
     kworker/6:1-120     [006] d..1.   100.000100: rpm_resume: 0000:64:00.0 flags-4 cnt-1 dep-0 auto-1 p-0 irq-0 child-0
     kworker/6:1-120     [006] d..1.   100.000200: rpm_return_int: rpm_resume+0x1a0/0x5e0:0000:64:00.0 ret=0
     kworker/2:0-30      [002] d..1.   100.100000: rpm_suspend: 0000:65:00.0 flags-c cnt-0 dep-0 auto-1 p-0 irq-0 child-0
     kworker/6:1-120     [006] d..1.   101.000000: rpm_suspend: 0000:64:00.1 flags-c cnt-0 dep-0 auto-1 p-0 irq-0 child-0
     kworker/6:1-120     [006] d..1.   102.000000: rpm_suspend: 0000:64:00.0 flags-c cnt-0 dep-0 auto-1 p-0 irq-0 child-0
         systemd-1       [000] .....   200.000000: suspend_resume: suspend_enter[3] begin
EOF
run trace stop >"$T/tr2" 2>&1; rc=$?
((rc == 0)) && ok "trace stop exits 0" || { bad "trace stop exits $rc"; cat "$T/tr2"; }
has "$T/tr2" 'RTX runtime resumes 1, suspends 1, system suspend entries 1' "trace stop counts the RTX's transitions"
tl=$(ls "$H"/state/trace-*.txt 2>/dev/null | head -1)
[[ -n $tl ]] && ok "trace stop writes a timeline" || bad "trace stop writes a timeline"
[[ -n $tl ]] && has "$tl" '^100\.000100 kworker/6:1-120 rpm_resume: 0000:64:00\.0' "timeline lines start with the timestamp"
[[ -n $tl ]] && has "$tl" 'rpm_suspend: 0000:64:00\.1' "timeline keeps the RTX's HDA function"
[[ -n $tl ]] && hasnt "$tl" '0000:65:00' "timeline drops other devices"
# testd's 30-minute watchdog stopped the trace and kept it: stop still collects it,
# with the session open or already closed.
rm -f "$H"/state/trace-*.txt; touch "$T/watchdog-stopped"; mkdir -p "$T/testd-out"; cp "$T/hdmi.trace" "$T/testd-out/hdmi.trace"
run trace stop >"$T/tr3" 2>&1; rc=$?
((rc == 0)) && ok "trace stop after the watchdog exits 0" || { bad "trace stop after the watchdog exits $rc"; cat "$T/tr3"; }
has "$T/tr3" 'already been stopped' "trace stop says the watchdog had stopped it"
has "$T/tr3" 'RTX runtime resumes 1, suspends 1' "trace stop collects the watchdog's file"
rm -f "$T/session"
run trace stop >"$T/tr4" 2>&1; rc=$?
((rc == 0)) && ok "trace stop with the session closed collects the kept file" || bad "trace stop with the session closed exits $rc"
rm -f "$T/testd-out/hdmi.trace"
run trace stop >"$T/tr5" 2>&1; rc=$?
((rc == 3)) && ok "trace stop with nothing to collect exits 3" || bad "trace stop with nothing to collect exits $rc"

# ------------------------------------------------------------------ 5. usage
for a in "bogus" "snapshot --x" "watch --hours 0" "watch --interval 99" "log --boot x" "trace"; do
  # shellcheck disable=SC2086
  run $a >/dev/null 2>&1; rc=$?
  ((rc == 2)) && ok "'$a' exits 2" || bad "'$a' exits $rc"
done

echo
((fails == 0)) && echo "g16-hdmi: all passed" || echo "g16-hdmi: $fails failed"
((fails == 0))
