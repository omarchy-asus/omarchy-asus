#!/bin/bash
# bin/g16-idle-power (#198): on a fake GA605 sysfs, with systemctl, quickshell,
# omarchy-restart-shell, omarchy-toggle-idle and gh stubbed and the root helper
# run as this user (G16_ROOT=none):
#   1. --dry-run stops nothing, writes no panel_power_savings, posts nothing, and
#      still reports every phase with the battery watts from current x voltage;
#   2. a real run stops each unit (and the shell) in turn, starts each again,
#      sets and clears stay-awake, measures the CACP levels and puts the original
#      level back, and posts to #198 and the CACP table to #172;
#   3. a run killed mid-phase puts everything back too.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

# ------------------------------------------------------------- fake sysfs
S=$T/sys
mkdir -p "$S/class/dmi/id" "$S/class/power_supply/BAT1" "$S/class/power_supply/ACAD" \
  "$S/devices/card1/hwmon/hwmon5" "$S/class/powercap/intel-rapl:0" "$S/class/powercap/intel-rapl:0:0" \
  "$S/class/drm/card1-eDP-1/amdgpu" "$S/class/drm/card1" "$S/class/backlight/amdgpu_bl1"
echo "ROG Zephyrus G16 GA605KM_GA605KM" >"$S/class/dmi/id/product_name"
echo GA605KM >"$S/class/dmi/id/board_name"
echo Battery >"$S/class/power_supply/BAT1/type"
echo 636000 >"$S/class/power_supply/BAT1/current_now"
echo 16300000 >"$S/class/power_supply/BAT1/voltage_now"
echo Mains >"$S/class/power_supply/ACAD/type"
echo 0 >"$S/class/power_supply/ACAD/online"
ln -s ../../../devices/card1 "$S/class/drm/card1/device"
echo amdgpu >"$S/devices/card1/hwmon/hwmon5/name"
echo 4877000 >"$S/devices/card1/hwmon/hwmon5/power1_input"
echo 3 >"$S/devices/card1/gpu_busy_percent"
echo package-0 >"$S/class/powercap/intel-rapl:0/name"
echo core >"$S/class/powercap/intel-rapl:0:0/name"
for d in intel-rapl:0 intel-rapl:0:0; do
  echo 1000000 >"$S/class/powercap/$d/energy_uj"
  echo 65532610987 >"$S/class/powercap/$d/max_energy_range_uj"
done
echo connected >"$S/class/drm/card1-eDP-1/status"
echo 2 >"$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings"
echo 200000 >"$S/class/backlight/amdgpu_bl1/actual_brightness"
echo 400000 >"$S/class/backlight/amdgpu_bl1/max_brightness"

# ------------------------------------------------------------------ stubs
B=$T/bin ST=$T/state
mkdir -p "$B"
cat >"$B/systemctl" <<'EOF'
#!/bin/bash
[[ $1 == --user ]] && shift
case $1 in
  show-environment) echo "OMARCHY_PATH=$STUB/omarchy" ;;
  is-active) [[ $2 == -q ]] && shift; [[ -e $STUB/active/$2 ]] ;;
  stop) echo "stop $2" >>"$STUB/log"; rm -f "$STUB/active/$2" ;;
  start) echo "start $2" >>"$STUB/log"; touch "$STUB/active/$2" ;;
  *) exit 1 ;;
esac
EOF
cat >"$B/pgrep" <<'EOF'
#!/bin/bash
[[ -e $STUB/shell ]]
EOF
cat >"$B/quickshell" <<'EOF'
#!/bin/bash
[[ $1 == kill && -e $STUB/shell ]] || exit 1
rm -f "$STUB/shell"; echo "kill shell" >>"$STUB/log"
EOF
cat >"$B/omarchy-restart-shell" <<'EOF'
#!/bin/bash
touch "$STUB/shell"; echo "restart shell" >>"$STUB/log"
EOF
cat >"$B/omarchy-toggle-idle" <<'EOF'
#!/bin/bash
f=$HOME/.local/state/omarchy/indicators/stay-awake
case $1 in
  stay-awake) mkdir -p "${f%/*}"; touch "$f" ;;
  allow-idle) rm -f "$f" ;;
esac
echo "idle $1" >>"$STUB/log"
EOF
cat >"$B/gh" <<'EOF'
#!/bin/bash
[[ $1 == issue && $2 == comment ]] || exit 1
n=$3; shift 3
while (($#)); do [[ $1 == --body-file ]] && cp "$2" "$STUB/posted-$n"; shift; done
echo "post $n" >>"$STUB/log"
EOF
chmod +x "$B"/*

reset() {
  rm -rf "${ST:?}" "${T:?}/home"
  mkdir -p "$ST/active" "$T/home"
  touch "$ST/active/omarchy-fcitx5.service" "$ST/active/owed.service" "$ST/shell" "$ST/log"
  echo 2 >"$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings"
}
run() { # args...
  env -u OMARCHY_PATH HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_IDLE_SYS="$S" \
    G16_IDLE_REPORT="$T/home/report.md" "$W/bin/g16-idle-power" "$@"
}
FAST=(--measure 2 --settle 0 --interval 1)

# ---------------------------------------------------------------- 1. dry run
reset
out=$(run --dry-run "${FAST[@]}" 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -qE '^(stop|start|kill|restart|idle)' "$ST/log" && bad "dry run changed something: $(cat "$ST/log")" || ok "dry run stops and restarts nothing"
[[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 2 ]] && ok "dry run leaves panel_power_savings" || bad "dry run wrote panel_power_savings"
[[ -e $ST/posted-198 ]] && bad "dry run posted" || ok "dry run posts nothing"
r=$T/home/report.md
for ph in baseline no-omarchy-fcitx5 no-owed no-shell all-stopped baseline-again cacp-4; do
  grep -q "^| $ph |" "$r" && ok "dry run reports $ph" || bad "dry run report has no $ph row"
done
grep -q '^| baseline | 10.37 ' "$r" && ok "battery watts from current_now x voltage_now" || bad "battery watts wrong: $(grep '^| baseline' "$r")"
grep -q '^| baseline | [^|]*|[^|]*| 4.88 |' "$r" && ok "SoC watts from amdgpu PPT" || bad "PPT wrong: $(grep '^| baseline' "$r")"

# ------------------------------------------------------------- 2. real run
reset
out=$(run "${FAST[@]}" 2>&1); rc=$?
((rc == 0)) && ok "run exits 0" || bad "run exit $rc: $out"
want=$'idle stay-awake\nstop omarchy-fcitx5.service\nstart omarchy-fcitx5.service\nstop owed.service\nstart owed.service\nkill shell\nrestart shell'
[[ $(head -n7 "$ST/log") == "$want" ]] && ok "each unit and the shell stopped and started in turn" || bad "unexpected order: $(cat "$ST/log")"
for u in omarchy-fcitx5.service owed.service; do [[ -e $ST/active/$u ]] && ok "$u running at the end" || bad "$u left stopped"; done
[[ -e $ST/shell ]] && ok "shell running at the end" || bad "shell left stopped"
[[ -e $T/home/.local/state/omarchy/indicators/stay-awake ]] && bad "stay-awake left on" || ok "stay-awake cleared"
[[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 2 ]] && ok "panel_power_savings back to 2" || bad "panel_power_savings not restored"
grep -q '^| no-owed |' "$T/home/report.md" && ok "report written" || bad "no report"
[[ -e $ST/posted-198 ]] && grep -q 'G16 idle power by phase' "$ST/posted-198" && ok "posted to #198" || bad "not posted to #198"
[[ -e $ST/posted-172 ]] && grep -q '^### CACP' "$ST/posted-172" && ok "CACP table posted to #172" || bad "CACP table not posted to #172"
grep -qF "$T/home" "$ST/posted-198" && bad "home path in the post" || ok "post has no home path"

# ------------------------------------------------- 3. killed mid-measurement
reset
# Not through run(): $! must be the script itself, not a subshell.
env -u OMARCHY_PATH HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_IDLE_SYS="$S" \
  G16_IDLE_REPORT="$T/home/report.md" "$W/bin/g16-idle-power" --measure 30 --settle 0 --interval 1 --no-post >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 300); do grep -q '^stop omarchy-fcitx5' "$ST/log" && break; sleep 0.2; done
kill -TERM "$pid"; wait "$pid" 2>/dev/null
sleep 0.5
for u in omarchy-fcitx5.service owed.service; do [[ -e $ST/active/$u ]] && ok "killed: $u running" || bad "killed: $u left stopped"; done
[[ -e $T/home/.local/state/omarchy/indicators/stay-awake ]] && bad "killed: stay-awake left on" || ok "killed: stay-awake cleared"
[[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 2 ]] && ok "killed: panel_power_savings untouched" || bad "killed: panel_power_savings changed"

# Root helper: only its commands, only levels 0-4.
reply=$(printf 'cacp 9\nfoo\nrapl\n' | "$W/bin/g16-idle-power" --root-helper "$S" 1)
[[ $reply == $'ready '"$(id -u)"$' 2\nerr bad level\nerr unknown\nrapl 1000000 65532610987 1000000 65532610987' ]] &&
  ok "root helper refuses bad levels and unknown commands" || bad "root helper replies: $reply"

((fails == 0)) && echo "PASS" || { echo "$fails failed"; exit 1; }
