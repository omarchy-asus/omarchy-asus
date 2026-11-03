#!/bin/bash
# bin/g16-flood-logger, offline: a fake sysfs/procfs shaped like the G16's (the RTX at
# 64:00.0 with a root port above it, amdgpu and k10temp hwmon, ACAD and BAT1, eDP and
# HDMI connectors) and a stubbed journalctl:
#   1. watch writes one line per interval to <boot id>.log with the RTX's runtime and
#      PCI power state, the video memory state, the summed AER counters, the connected
#      outputs, AC, battery mW, Tctl, iGPU temperature and power, load, memory and the
#      sleep count, and stops at --hours;
#   2. it never opens the RTX's hwmon or backlight (they wake it): both are planted as
#      unreadable files and must stay untouched;
#   3. report prints the next boot's reset reason, the change lines and the last lines;
#   4. bad usage exits 2.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
SCRIPT=$W/bin/g16-flood-logger
S=$T/sys P=$T/proc B=$T/bin ST=$T/state
RTX=$S/bus/pci/devices/0000:64:00.0 RP=$S/bus/pci/devices/0000:00:03.1
mkdir -p "$B" "$RTX/power" "$RP" "$S/class/drm/card0-HDMI-A-1" "$S/class/drm/card1-eDP-2" "$S/class/drm/card0-DP-9" \
  "$S/class/hwmon/hwmon4" "$S/class/hwmon/hwmon6" "$S/class/hwmon/hwmon9" "$S/class/power_supply/ACAD" \
  "$S/class/power_supply/BAT1" "$S/power/suspend_stats" "$S/class/backlight/nvidia_0" \
  "$P/sys/kernel/random" "$P/driver/nvidia/gpus/0000:64:00.0"
echo 0x10de >"$RTX/vendor"; echo 0x030000 >"$RTX/class"; echo active >"$RTX/power/runtime_status"; echo D0 >"$RTX/power_state"
echo 0x1022 >"$RP/vendor"; echo 0x060400 >"$RP/class"
printf 'RxErr 2\nBadTLP 1\nTOTAL_ERR_COR 3\n' >"$RP/aer_dev_correctable"
printf 'Undefined 0\nTOTAL_ERR_NONFATAL 0\n' >"$RP/aer_dev_nonfatal"
printf 'Undefined 0\nTOTAL_ERR_FATAL 0\n' >"$RP/aer_dev_fatal"
printf 'TOTAL_ERR_COR 1\n' >"$RTX/aer_dev_correctable"
printf 'Runtime D3 status:          Enabled (fine-grained)\nVideo Memory:               Active\n\nGPU Hardware Support:\n Video Memory Off:          Supported\n' \
  >"$P/driver/nvidia/gpus/0000:64:00.0/power"
echo connected >"$S/class/drm/card0-HDMI-A-1/status"; echo connected >"$S/class/drm/card1-eDP-2/status"
echo disconnected >"$S/class/drm/card0-DP-9/status"
echo amdgpu >"$S/class/hwmon/hwmon4/name"; echo 45000 >"$S/class/hwmon/hwmon4/temp1_input"; echo 4600000 >"$S/class/hwmon/hwmon4/power1_average"
echo k10temp >"$S/class/hwmon/hwmon6/name"; echo 67125 >"$S/class/hwmon/hwmon6/temp1_input"
echo nvidia >"$S/class/hwmon/hwmon9/name"; echo 50000 >"$S/class/hwmon/hwmon9/temp1_input"; chmod 000 "$S/class/hwmon/hwmon9/temp1_input"
echo 128 >"$S/class/backlight/nvidia_0/brightness"; chmod 000 "$S/class/backlight/nvidia_0/brightness"
echo Mains >"$S/class/power_supply/ACAD/type"; echo 1 >"$S/class/power_supply/ACAD/online"
echo Battery >"$S/class/power_supply/BAT1/type"; echo 600000 >"$S/class/power_supply/BAT1/current_now"; echo 16000000 >"$S/class/power_supply/BAT1/voltage_now"
echo 41 >"$S/power/suspend_stats/success"
echo 2c1d5f60-1111-2222-3333-444455556666 >"$P/sys/kernel/random/boot_id"
echo '0.42 0.30 0.20 1/500 999' >"$P/loadavg"
printf 'MemTotal: 32000000 kB\nMemAvailable: 20480000 kB\n' >"$P/meminfo"
cat >"$B/journalctl" <<'EOF'
#!/bin/sh
case "$*" in
  *--list-boots*) echo '[{"index":-1,"boot_id":"2c1d5f601111222233334444555566 66"},{"index":0,"boot_id":"ffff"}]' | sed 's/66 66/6666/' ;;
  *"-b 0 -k"*) echo 'x86/amd: Previous system reset reason [0x08000800]: an uncorrected error caused a data fabric sync flood event' ;;
esac
EOF
chmod +x "$B/journalctl"
run() { G16_FLOOD_SYS=$S G16_FLOOD_PROC=$P G16_FLOOD_STATE=$ST G16_FLOOD_JOURNALCTL=$B/journalctl "$SCRIPT" "$@"; }

# 1. watch: --hours is at least 1, so stop it after two lines
(G16_FLOOD_SYS=$S G16_FLOOD_PROC=$P G16_FLOOD_STATE=$ST exec "$SCRIPT" watch --interval 1) & pid=$!
for _ in $(seq 50); do [[ $(grep -vc '^#' "$ST"/*.log 2>/dev/null) -ge 2 ]] && break; sleep 0.1; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
LOG=$ST/2c1d5f60111122223333444455556666.log
[[ -f $LOG ]] && ok "log named after the boot id" || bad "no log: $(ls "$ST" 2>&1)"
l=$(grep -v '^#' "$LOG" | head -1)
for want in 'rtx=active/D0' 'vram=Active' 'aer=4/0/0' 'out=HDMI-A-1,eDP-2' 'ac=1' 'bat_mw=9600' 'tctl=67125' \
  'igpu_t=45000' 'igpu_uw=4600000' 'load=0.42' 'mem_mb=20000' 'sleeps=41'; do
  [[ " $l " == *" $want "* ]] && ok "line has $want" || bad "line lacks $want: $l"
done
[[ $(grep -vc '^#' "$LOG") -ge 2 ]] && ok "one line per interval" || bad "lines: $(cat "$LOG")"

# 2. the RTX's hwmon and backlight stay untouched (unreadable, and never asked for)
[[ $l != *50000* ]] && ok "the RTX's hwmon isn't read" || bad "read the RTX hwmon: $l"
out=$(run watch --hours 0 2>&1); rc=$?
[[ $rc == 2 ]] && ok "--hours 0 refused" || bad "--hours 0: rc=$rc $out"

# 3. report
out=$(run report)
[[ $out == *"sync flood"* ]] && ok "report shows the next boot's reset reason" || bad "report: $out"
[[ $out == *"rtx=active/D0"* && $out == *"last 12 lines"* ]] && ok "report shows the change and last lines" || bad "report: $out"

# 4. bad usage
run bogus >/dev/null 2>&1; [[ $? == 2 ]] && ok "unknown command exits 2" || bad "unknown command"
run watch --interval 0 >/dev/null 2>&1; [[ $? == 2 ]] && ok "--interval 0 exits 2" || bad "--interval 0"
run report --boot 1 >/dev/null 2>&1; [[ $? == 2 ]] && ok "--boot 1 exits 2" || bad "--boot 1"

((fails == 0)) && echo "all g16-flood-logger checks passed" || { echo "$fails check(s) failed"; exit 1; }
