#!/bin/bash
# bin/g16-idle-ab: on a fake GA605 sysfs/procfs, with systemctl, iw, bluetoothctl,
# omarchy-toggle-idle and bin/issue stubbed and the root helper run as this user
# (G16_ROOT=none):
#   1. --dry-run changes nothing and posts nothing, and still reports every tweak;
#   2. a real run applies each tweak between baselines and puts every setting back
#      (nmi_watchdog, APST timeouts, the SD reader, keyboard power/control, Wi-Fi
#      power save, Num Lock LED, Bluetooth rfkill, voxtype), posts each tweak's
#      row to its own issue and the report to #198, without the home path;
#   3. it refuses to start on the charger or with the RTX awake, changing nothing;
#   4. a run killed mid-phase puts everything back;
#   5. a connected Bluetooth device skips the Bluetooth phases (bt-off, usb-idle);
#      the report's Bluetooth line counts connected devices, 0 included (#307);
#   6. the root helper refuses unknown tweaks and commands;
#   7. it never reads the nvidia_0 backlight or anything under the RTX but its
#      runtime_status (a read-only stand-in makes such a read fail loudly);
#   8. --boot keeps the numbers and --compare reports B against A;
#   9. inside an open g16-testd session (a stand-in that logs its calls) every tweak
#      is that helper's knob-set and knob-restore, the trace its trace-start and
#      trace-stop, each call with a reason, and nothing asks for root; with no
#      session it falls back to pkexec, and G16_ROOT=testd then refuses to start.
#  10. usb4 and the CACP levels (cacp3, cacp4) apply, cycle DPMS and go back;
#  11. --design pb12 (#276): the dry run prints the matrix and changes nothing; a
#      run sets each phase to its row's tweaks, fits every tweak and the dummy
#      columns, posts each tweak's row and puts everything back; tweaks that switch
#      the same setting, or more than 11, are refused;
#  12. pb12 through an open g16-testd session: the CACP level is its knob,
#      usb4 is skipped, every knob-set has its knob-restore;
#  13. pb12 verdicts come from the fit alone; a failed DPMS cycle fails the CACP
#      apply; a run killed with a CACP level on puts it back and cycles the panel
#      on; a testd dry run doesn't trace, and a killed testd helper stops its trace.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
SCRIPT=$W/bin/g16-idle-ab

S=$T/sys P=$T/proc B=$T/bin ST=$T/state
build_fake() {
  rm -rf "$S" "$P"
  mkdir -p "$S/class/dmi/id" "$S/class/power_supply/BAT1" "$S/class/power_supply/ACAD" "$S/bus/pci/devices" \
    "$S/bus/usb/devices" "$S/class/net" "$S/class/leds" "$S/class/rfkill" "$S/class/backlight" "$S/class/drm" \
    "$S/module/nvme_core/parameters" "$S/class/nvme/nvme0/power" "$P/sys/kernel"
  echo "ROG Zephyrus G16 GA605KM_GA605KM" >"$S/class/dmi/id/product_name"
  echo GA605KM >"$S/class/dmi/id/board_name"
  echo Battery >"$S/class/power_supply/BAT1/type"
  echo Discharging >"$S/class/power_supply/BAT1/status"
  echo 600000 >"$S/class/power_supply/BAT1/current_now"
  echo 15000000 >"$S/class/power_supply/BAT1/voltage_now"
  echo Mains >"$S/class/power_supply/ACAD/type"
  echo 0 >"$S/class/power_supply/ACAD/online"
  pci() { # bdf parent vendor device class
    local d=$S/devices/pci0000:00/$2/$1
    mkdir -p "$d/power"
    echo "$3" >"$d/vendor"; echo "$4" >"$d/device"; echo "$5" >"$d/class"
    echo on >"$d/power/control"; echo active >"$d/power/runtime_status"
    ln -s "$d" "$S/bus/pci/devices/$1"
  }
  # The RTX, its HDMI codec and nvidia_0: everything but runtime_status unreadable.
  pci 0000:64:00.0 0000:00:01.1 0x10de 0x2d59 0x030000
  echo suspended >"$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/power/runtime_status"
  mkdir -p "$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/hwmon/hwmon9" "$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/backlight/nvidia_0"
  for f in hwmon/hwmon9/temp1_input backlight/nvidia_0/brightness backlight/nvidia_0/actual_brightness backlight/nvidia_0/max_brightness; do
    echo 1 >"$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/$f"; chmod 000 "$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/$f"
  done
  ln -s ../../devices/pci0000:00/0000:00:01.1/0000:64:00.0/backlight/nvidia_0 "$S/class/backlight/nvidia_0"
  # amdgpu with gpu_metrics v3.0: socket 4500 mW, GFX 30 mW, cores 180 mW.
  pci 0000:65:00.0 0000:00:08.1 0x1002 0x1114 0x038000
  local a=$S/devices/pci0000:00/0000:00:08.1/0000:65:00.0
  mkdir -p "$S/drivers/amdgpu" "$S/class/drm/card1"
  ln -s "$S/drivers/amdgpu" "$a/driver"
  ln -s "$a" "$S/class/drm/card1/device"
  python3 -I -c 'import struct,sys; b=bytearray(264); struct.pack_into("<HBB",b,0,264,3,0); struct.pack_into("<I",b,112,4500); struct.pack_into("<I",b,124,30); struct.pack_into("<I",b,132,180); open(sys.argv[1],"wb").write(b)' "$a/gpu_metrics"
  mkdir -p "$S/class/backlight/amdgpu_bl1"
  echo 100000 >"$S/class/backlight/amdgpu_bl1/actual_brightness"; echo 400000 >"$S/class/backlight/amdgpu_bl1/max_brightness"
  # GL9767 behind its port, NVMe, keyboard, Wi-Fi, LED, rfkill.
  mkdir -p "$S/devices/pci0000:00/0000:00:02.2/power"
  echo auto >"$S/devices/pci0000:00/0000:00:02.2/power/control"; : >"$S/devices/pci0000:00/0000:00:02.2/rescan"
  pci 0000:62:00.0 0000:00:02.2 0x17a0 0x9767 0x080501
  : >"$S/devices/pci0000:00/0000:00:02.2/0000:62:00.0/remove"
  echo 100 >"$S/module/nvme_core/parameters/apst_primary_timeout_ms"
  echo 2000 >"$S/module/nvme_core/parameters/apst_secondary_timeout_ms"
  echo 100000 >"$S/class/nvme/nvme0/power/pm_qos_latency_tolerance_us"
  # The keyboard and the Bluetooth radio (btusb) on one xHCI controller.
  pci 0000:67:00.0 0000:00:08.3 0x1022 0x151e 0x0c0330
  echo D0 >"$S/devices/pci0000:00/0000:00:08.3/0000:67:00.0/power_state"
  local x=$S/devices/pci0000:00/0000:00:08.3/0000:67:00.0/usb3
  mkdir -p "$x/3-4/power" "$x/3-3/power" "$x/3-3/3-3:1.0" "$S/bus/usb/drivers/btusb"
  ln -s "$x/3-4" "$S/bus/usb/devices/3-4"; ln -s "$x/3-3" "$S/bus/usb/devices/3-3"
  ln -s "$S/bus/usb/drivers/btusb" "$x/3-3/3-3:1.0/driver"
  echo 0489 >"$x/3-3/idVendor"; echo e11e >"$x/3-3/idProduct"; echo auto >"$x/3-3/power/control"; echo active >"$x/3-3/power/runtime_status"
  echo 0b05 >"$S/bus/usb/devices/3-4/idVendor"; echo 19b6 >"$S/bus/usb/devices/3-4/idProduct"
  echo on >"$S/bus/usb/devices/3-4/power/control"; echo active >"$S/bus/usb/devices/3-4/power/runtime_status"
  mkdir -p "$S/class/net/wlan0/wireless" "$S/class/leds/input12::numlock" "$S/class/rfkill/rfkill7"
  echo 1 >"$S/class/leds/input12::numlock/brightness"
  echo bluetooth >"$S/class/rfkill/rfkill7/type"; echo 0 >"$S/class/rfkill/rfkill7/soft"
  # A USB4 NHI left awake (power/control on) and the eDP panel's CACP level.
  pci 0000:67:00.5 0000:00:08.3 0x1022 0x1668 0x0c0340
  mkdir -p "$S/bus/pci/drivers/thunderbolt"
  ln -s "$S/bus/pci/drivers/thunderbolt" "$S/devices/pci0000:00/0000:00:08.3/0000:67:00.5/driver"
  mkdir -p "$S/class/drm/card1-eDP-1/amdgpu"
  echo 0 >"$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings"
  echo 1 >"$P/sys/kernel/nmi_watchdog"
  echo "BOOT_IMAGE=/vmlinuz quiet" >"$P/cmdline"
  printf 'cpu  1 2 3 4\nintr 1000 0\nctxt 5000\n' >"$P/stat"
  printf '            CPU0       CPU1\n  68:        100        0  IR-PCI-MSIX-0000:65:00.0    0-edge      amdgpu\n CAL:       2000       2000   Function call interrupts\n LOC:       5000       5000   Local timer interrupts\n' >"$P/interrupts"
}
orig_state() {
  printf '%s ' "$(cat "$P/sys/kernel/nmi_watchdog")" "$(cat "$S/module/nvme_core/parameters/apst_primary_timeout_ms")" \
    "$(cat "$S/module/nvme_core/parameters/apst_secondary_timeout_ms")" "$(cat "$S/class/nvme/nvme0/power/pm_qos_latency_tolerance_us")" \
    "$(cat "$S/bus/pci/devices/0000:62:00.0/power/control")" "$(cat "$S/devices/pci0000:00/0000:00:02.2/power/control")" \
    "$(cat "$S/bus/usb/devices/3-4/power/control")" "$(cat "$ST/wifi")" "$(cat "$S/class/leds/input12::numlock/brightness")" \
    "$(cat "$S/class/rfkill/rfkill7/soft")" "$( [[ -e $ST/active/voxtype.service ]] && echo vox-on || echo vox-off)" \
    "$(cat "$S/bus/pci/devices/0000:67:00.5/power/control")" "$(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings")"
}
WANT="1 100 2000 100000 on auto on off 1 0 vox-on on 0 "
ALL=(nmi nvme-apst sd-off kbd-usb wifi-ps numlock bt-off voxtype usb-idle usb4 cacp3 cacp4)
PB_DEFAULT=(nmi nvme-apst sd-off kbd-usb wifi-ps bt-off voxtype usb4 cacp3)

mkdir -p "$B"
cat >"$B/systemctl" <<'EOF'
#!/bin/bash
[[ $1 == --user ]] && shift
case $1 in
  is-active) [[ $2 == -q ]] && shift; [[ -e $STUB/active/$2 ]] ;;
  stop) echo "stop $2" >>"$STUB/log"; [[ -e $STUB/fail-stop ]] && exit 1; rm -f "$STUB/active/$2" ;;
  start) echo "start $2" >>"$STUB/log"; touch "$STUB/active/$2" ;;
  *) exit 1 ;;
esac
EOF
cat >"$B/iw" <<'EOF'
#!/bin/bash
case "$3 $4" in
  "get power_save") echo "Power save: $(cat "$STUB/wifi")" ;;
  "set power_save") echo "$5" >"$STUB/wifi"; echo "iw $5" >>"$STUB/log" ;;
  *) exit 1 ;;
esac
EOF
cat >"$B/bluetoothctl" <<'EOF'
#!/bin/bash
case $1 in
  show) [[ -e $STUB/bt-off ]] && echo "	Powered: no" || echo "	Powered: yes" ;;
  devices) [[ -e $STUB/bt-connected ]] && echo "Device 00:11:22:33:44:55 Some Buds" ; exit 0 ;;
  power) echo "bt power $2" >>"$STUB/log" ;;
esac
EOF
cat >"$B/hyprctl" <<'EOF'
#!/bin/bash
[[ $1 == dispatch && $2 == dpms ]] || exit 0
[[ -e $STUB/dpms-fail ]] && { echo "dpms failed" >>"$STUB/log"; echo "error"; exit 0; }
echo "dpms $3 $4" >>"$STUB/log"; echo ok
EOF
cat >"$B/omarchy-toggle-idle" <<'EOF'
#!/bin/bash
f=$HOME/.local/state/omarchy/indicators/stay-awake
case $1 in stay-awake) mkdir -p "${f%/*}"; touch "$f" ;; allow-idle) rm -f "$f" ;; esac
echo "idle $1" >>"$STUB/log"
EOF
cat >"$B/issue" <<'EOF'
#!/bin/bash
# bin/issue comment N --agent A --body-file F
[[ $1 == comment ]] || exit 1
f=''; while (($#)); do [[ $1 == --body-file ]] && f=$2; shift; done
cp "$f" "$STUB/posted-$N_OF"; exit 0
EOF
# The real issue helper is replaced by one that records the issue number.
cat >"$B/issue" <<'EOF'
#!/bin/bash
[[ $1 == comment ]] || exit 1
n=$2; f=''
while (($#)); do [[ $1 == --body-file ]] && f=$2; shift; done
cp "$f" "$STUB/posted-$n"; echo "post $n" >>"$STUB/log"
EOF
chmod +x "$B"/*

reset() {
  build_fake
  [[ -d $ST/td-out ]] && chmod 755 "$ST/td-out"
  rm -rf "${ST:?}" "${T:?}/home"
  mkdir -p "$ST/active" "$T/home"
  touch "$ST/active/voxtype.service" "$ST/log"
  echo off >"$ST/wifi"
}
run() {
  env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_AB_SYS="$S" G16_AB_PROC="$P" G16_AB_DPMS_WAIT=0 \
    HYPRLAND_INSTANCE_SIGNATURE=test G16_AB_ISSUE="$B/issue" G16_AB_STATE="$T/home/state" G16_AB_REPORT="$T/home/report.md" "$SCRIPT" "$@"
}
FAST=(--rounds 2 --measure 1 --settle 0 --interval 1 --seed 7)

# ---------------------------------------------------------------- 1. dry run
reset
out=$(run --dry-run "${FAST[@]}" 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
[[ $(orig_state) == "$WANT" ]] && ok "dry run changes nothing" || bad "dry run changed: $(orig_state)"
grep -qE '^(stop|iw|idle)' "$ST/log" && bad "dry run acted: $(cat "$ST/log")" || ok "dry run stops, sets and toggles nothing"
ls "$ST"/posted-* >/dev/null 2>&1 && bad "dry run posted" || ok "dry run posts nothing"
for t in "${ALL[@]}"; do
  grep -q "^| $t |" "$T/home/report.md" && ok "dry run reports $t" || bad "dry run report has no $t row"
done
grep -q '^Baseline over the run: battery 9.00 W' "$T/home/report.md" && ok "battery watts from current_now x voltage_now" || bad "battery: $(grep '^Baseline' "$T/home/report.md")"
grep -q 'SoC 4.50 W' "$T/home/report.md" && ok "SoC watts from gpu_metrics" || bad "SoC: $(grep '^Baseline' "$T/home/report.md")"
grep -q 'GFX 0.03 W, all CPU cores 0.18 W' "$T/home/report.md" && ok "GFX and core split from gpu_metrics" || bad "split: $(grep '^SoC split' "$T/home/report.md")"
grep -qx -- '- Bluetooth: powered, 0 connected' "$T/home/report.md" && ok "no device connected: one Bluetooth line, 0 connected (#307)" || bad "bluetooth line: $(grep -A1 -- '- Bluetooth' "$T/home/report.md")"

# ------------------------------------------------------------- 2. real run
reset
out=$(run "${FAST[@]}" 2>&1); rc=$?
((rc == 0)) && ok "run exits 0" || bad "run exit $rc: $out"
[[ $(orig_state) == "$WANT" ]] && ok "every setting back at the end" || bad "left changed: $(orig_state) (want $WANT)"
[[ -e $T/home/.local/state/omarchy/indicators/stay-awake ]] && bad "stay-awake left on" || ok "stay-awake cleared"
[[ $(grep -c '^stop voxtype' "$ST/log") == 2 && $(grep -c '^start voxtype' "$ST/log") == 2 ]] && ok "voxtype stopped and started once per round" || bad "voxtype: $(grep voxtype "$ST/log")"
[[ $(grep -c '^iw on' "$ST/log") == 2 ]] && ok "Wi-Fi power save set once per round" || bad "iw: $(grep '^iw' "$ST/log")"
r=$T/home/report.md
n=$(grep -cE '^\| [0-9]+ \| [12] \| baseline \|' "$r")
((n == 2 * (${#ALL[@]} + 1))) && ok "each round brackets every tweak with baselines ($n baselines)" || bad "$n baseline phases"
for t in "${ALL[@]}"; do
  grep -qE "^\| $t \| #[0-9]+ \| 2/2 \|" "$r" && ok "$t measured in both rounds" || bad "$t row: $(grep "^| $t |" "$r")"
done
grep -q 'nvme-apst ok 30/500 ms' "$r" && ok "APST timeouts 30/500 applied" || bad "APST apply: $(grep nvme-apst "$r")"
reply=$( { printf 'apply kbd-usb\n'; sleep 0.5; cat "$S/class/leds/input12::numlock/brightness" "$S/bus/usb/devices/3-4/power/control" >"$T/kbd-mid"; } | "$SCRIPT" --root-helper "$S" "$P" 0 | tail -n1)
[[ $reply == "ok auto" && $(paste -sd' ' "$T/kbd-mid") == "0 auto" ]] && ok "kbd-usb sets autosuspend and the Num Lock LED off" || bad "kbd-usb: $reply / $(paste -sd' ' "$T/kbd-mid")"
[[ $(cat "$S/class/leds/input12::numlock/brightness") == 1 && $(cat "$S/bus/usb/devices/3-4/power/control") == on ]] && ok "kbd-usb reverted on EOF" || bad "kbd-usb left changed"
grep -q 'usb4 ok auto on 1' "$r" && ok "usb4 sets the awake NHI to auto" || bad "usb4 apply: $(grep usb4 "$r")"
grep -q 'cacp3 ok 3' "$r" && grep -q 'cacp4 ok 4' "$r" && ok "cacp3 and cacp4 write their levels" || bad "cacp apply: $(grep cacp "$r")"
# Two rounds, two levels, a DPMS off/on after each write and each revert.
[[ $(grep -c '^dpms off eDP-1' "$ST/log") == 8 && $(grep -c '^dpms on eDP-1' "$ST/log") == 8 ]] && ok "CACP: one DPMS cycle per level change" || bad "dpms: $(grep -c '^dpms' "$ST/log") lines"
grep -q 'usb-idle ok auto, blocked' "$r" && ok "usb-idle sets the keyboard to auto and blocks Bluetooth" || bad "usb-idle apply: $(grep usb-idle "$r")"
grep -qE '\| bt active; codec|bt active;.*kbd active;.*xhci D0' "$r" && ok "phases log the Bluetooth radio and the xHCI controller" || bad "states: $(grep -m1 '| baseline |' "$r")"
[[ -e $ST/posted-198 ]] && grep -q '^## G16 idle A/B' "$ST/posted-198" && ok "report posted to #198" || bad "not posted to #198"
grep -qF "$T/home" "$ST"/posted-* && bad "home path in a post" || ok "posts have no home path"
nposts=$(ls "$ST"/posted-* | wc -l)
# Each tweak with an issue number gets its own post, plus #198.
want_posts=$(( 1 + $("$SCRIPT" --list | awk '$2 != "#0" {print $2}' | sort -u | wc -l) ))
((nposts == want_posts)) && ok "one post per tweak issue plus #198 ($nposts)" || bad "$nposts posts, want $want_posts"
for f in "$ST"/posted-*; do
  [[ $f == */posted-198 ]] && continue
  grep -q '^## A/B on the G16: ' "$f" && grep -q '^Verdict: ' "$f" && ok "${f##*/} has its row and verdict" || bad "${f##*/}: $(head -3 "$f")"
done

# ---------------------------------------------------------- 3. the guards
reset
echo Charging >"$S/class/power_supply/BAT1/status"
out=$(run "${FAST[@]}" 2>&1); rc=$?
((rc == 1)) && grep -q 'not discharging' <<<"$out" && ok "refuses on the charger" || bad "charger: exit $rc: $out"
[[ $(orig_state) == "$WANT" && ! -s $ST/log ]] && ok "charger: nothing changed" || bad "charger changed: $(orig_state) $(cat "$ST/log")"
reset
echo active >"$S/devices/pci0000:00/0000:00:01.1/0000:64:00.0/power/runtime_status"
out=$(run "${FAST[@]}" 2>&1); rc=$?
((rc == 1)) && grep -q 'RTX is awake' <<<"$out" && ok "refuses with the RTX awake" || bad "RTX: exit $rc: $out"
[[ $(orig_state) == "$WANT" && ! -s $ST/log ]] && ok "RTX awake: nothing changed" || bad "RTX awake changed: $(orig_state)"

# --------------------------------------------- 3b. charger back mid-run
reset
( for _ in $(seq 1 100); do grep -q '^stop voxtype\|^iw on' "$ST/log" 2>/dev/null && break; sleep 0.1; done
  echo Charging >"$S/class/power_supply/BAT1/status" ) &
out=$(run --rounds 3 --measure 1 --settle 1 --interval 1 --seed 3 --no-post 2>&1); rc=$?
wait
((rc == 1)) && grep -q 'charger is back' <<<"$out" && ok "stops when the charger comes back" || bad "charger mid-run: exit $rc"
echo Discharging >"$S/class/power_supply/BAT1/status"
[[ $(orig_state) == "$WANT" ]] && ok "charger mid-run: everything back" || bad "charger mid-run left: $(orig_state)"

# ------------------------------------------------------- 4. killed mid-phase
reset
env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_AB_SYS="$S" G16_AB_PROC="$P" G16_AB_ISSUE="$B/issue" \
  G16_AB_REPORT="$T/home/report.md" "$SCRIPT" --only voxtype,wifi-ps,nmi --rounds 1 --measure 20 --settle 0 --interval 1 --no-post >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 300); do
  [[ $(cat "$P/sys/kernel/nmi_watchdog") == 0 || $(cat "$ST/wifi") == on || ! -e $ST/active/voxtype.service ]] && break
  sleep 0.1
done
sleep 0.5
mid=$(orig_state)
kill -TERM "$pid"; wait "$pid" 2>/dev/null
sleep 0.5
[[ $mid != "$WANT" ]] && ok "killed: a tweak was applied when killed" || bad "killed: nothing was applied yet"
[[ $(orig_state) == "$WANT" ]] && ok "killed: everything back" || bad "killed: left $(orig_state)"

# --------------------------------------- 5. a connected Bluetooth device
reset
touch "$ST/bt-connected"
out=$(run --only bt-off,nmi "${FAST[@]}" --no-post 2>&1)
grep -q 'skipped: bt-off: a Bluetooth device is connected' <<<"$out" && ok "connected device: Bluetooth phase skipped" || bad "bt: $out"
out=$(run --only usb-idle,nmi "${FAST[@]}" --no-post 2>&1)
grep -q 'skipped: usb-idle: a Bluetooth device is connected' <<<"$out" && ok "connected device: usb-idle phase skipped" || bad "usb-idle: $out"
[[ $(cat "$S/class/rfkill/rfkill7/soft") == 0 ]] && ok "connected device: rfkill untouched" || bad "rfkill changed"
grep -qx -- '- Bluetooth: powered, 1 connected' "$T/home/report.md" && ok "connected device: report counts 1 connected" || bad "bluetooth line: $(grep -A1 -- '- Bluetooth' "$T/home/report.md")"

# ------------------------------------------------------- 6. the root helper
reset
reply=$(printf 'apply foo\napply nmi;rm\nfrob\napply nmi\napply nmi\nrevert nmi\n' | "$SCRIPT" --root-helper "$S" "$P" 0)
want=$'ready '"$(id -u)"$'\nerr unknown tweak\nerr bad tweak\nerr unknown\nok 0\nerr already applied\nok reverted'
[[ $reply == "$want" ]] && ok "root helper refuses unknown tweaks and commands" || bad "root helper replies: $reply"
printf 'apply nmi\napply bt-off\n' | "$SCRIPT" --root-helper "$S" "$P" 0 >/dev/null
[[ $(cat "$P/sys/kernel/nmi_watchdog") == 1 && $(cat "$S/class/rfkill/rfkill7/soft") == 0 ]] && ok "root helper reverts on EOF" || bad "root helper left nmi/bt changed"
printf 'apply usb-idle\n' | "$SCRIPT" --root-helper "$S" "$P" 0 >/dev/null
[[ $(cat "$S/bus/usb/devices/3-4/power/control") == on && $(cat "$S/class/rfkill/rfkill7/soft") == 0 && $(cat "$S/class/leds/input12::numlock/brightness") == 1 ]] && ok "root helper reverts usb-idle on EOF" || bad "usb-idle left kbd/bt changed"

# A restore write that fails is an error, stays applied, and EOF retries it.
if ((EUID != 0)); then
  reset
  reply=$( { printf 'apply nmi\n'; sleep 0.3; chmod 444 "$P/sys/kernel/nmi_watchdog"; printf 'revert nmi\n'; sleep 0.3; chmod 644 "$P/sys/kernel/nmi_watchdog"; } | "$SCRIPT" --root-helper "$S" "$P" 0)
  grep -q '^err restore write refused' <<<"$reply" && ok "root helper reports a failed restore" || bad "failed restore: $reply"
  [[ $(cat "$P/sys/kernel/nmi_watchdog") == 1 ]] && ok "root helper retries a failed restore on EOF" || bad "nmi left at $(cat "$P/sys/kernel/nmi_watchdog")"
fi

# A reader that doesn't come back stays applied (EOF rescans again); once it is
# back, the revert succeeds.
reset
reply=$( { printf 'apply sd-off\n'; sleep 0.5; rm "$S/bus/pci/devices/0000:62:00.0"; printf 'revert sd-off\nrevert sd-off\n'; sleep 12; ln -s "$S/devices/pci0000:00/0000:00:02.2/0000:62:00.0" "$S/bus/pci/devices/0000:62:00.0"; printf 'revert sd-off\n'; } | "$SCRIPT" --root-helper "$S" "$P" 0 2>&1)
[[ $(grep -c '^err the SD reader did not come back' <<<"$reply") == 2 && $(tail -n1 <<<"$reply") == "ok reverted" ]] &&
  ok "SD reader restore stays pending until it is back" || bad "SD restore replies: $reply"
[[ $(cat "$S/devices/pci0000:00/0000:00:02.2/rescan") == 1 && $(cat "$S/devices/pci0000:00/0000:00:02.2/power/control") == auto ]] &&
  ok "SD rescan below its port, port control put back" || bad "SD port: rescan=$(cat "$S/devices/pci0000:00/0000:00:02.2/rescan") control=$(cat "$S/devices/pci0000:00/0000:00:02.2/power/control")"
if ((EUID != 0)); then
  # The port can't be set back: an error, still applied, and fixed on retry.
  reset
  pc=$S/devices/pci0000:00/0000:00:02.2/power/control
  reply=$( { printf 'apply sd-off\n'; sleep 0.5; rm "$S/bus/pci/devices/0000:62:00.0"
    ( sleep 1; chmod 444 "$pc"; ln -s "$S/devices/pci0000:00/0000:00:02.2/0000:62:00.0" "$S/bus/pci/devices/0000:62:00.0" ) &
    printf 'revert sd-off\n'; sleep 7; chmod 644 "$pc"; printf 'revert sd-off\n'; } | "$SCRIPT" --root-helper "$S" "$P" 0 2>&1)
  grep -q "^err the SD reader's port could not be set back" <<<"$reply" && [[ $(tail -n1 <<<"$reply") == "ok reverted" && $(cat "$pc") == auto ]] &&
    ok "SD port left forced on is an error and is fixed on retry" || bad "SD port restore: $reply / $(cat "$pc")"
  reset
  chmod 444 "$S/class/leds/input12::numlock/brightness"
  reply=$(printf 'apply numlock\n' | "$SCRIPT" --root-helper "$S" "$P" 0 2>&1)
  chmod 644 "$S/class/leds/input12::numlock/brightness"
  grep -q '^err write refused' <<<"$reply" && ok "a refused Num Lock write is an error" || bad "numlock replies: $reply"
fi

# --------------------------- 6b. voxtype that won't stop is not measured
reset
touch "$ST/fail-stop"
out=$(run --only voxtype,nmi "${FAST[@]}" --no-post 2>&1)
grep -q 'voxtype did not stop' <<<"$out" && ok "voxtype stop failure noticed" || bad "voxtype stop failure: $out"
grep -qE '^\| [0-9]+ \| [12] \| voxtype \|' "$T/home/report.md" && bad "voxtype phase measured though it never stopped" || ok "no voxtype phase when it didn't stop"

# ------------ 6c. Bluetooth powered off at the start stays off (boot, dry)
for mode in "--boot btoff" "--dry-run"; do
  reset
  touch "$ST/bt-off"
  # shellcheck disable=SC2086 # mode is two words on purpose
  run $mode --rounds 1 --measure 1 --settle 0 --interval 1 --no-post >/dev/null 2>&1
  grep -q '^bt power' "$ST/log" && bad "$mode powered Bluetooth on" || ok "$mode leaves Bluetooth off"
done
reset
touch "$ST/bt-off"
run --only bt-off --rounds 1 --measure 1 --settle 0 --interval 1 --no-post >/dev/null 2>&1
grep -q '^bt power' "$ST/log" && bad "bt-off powered an adapter that was off" || ok "bt-off doesn't power on an adapter that was off"

# --------------------------------------- 7. nothing under the RTX was read
# The unreadable stand-ins (mode 000) would make a read print an error; root
# would read them, so this check only means something as a normal user.
if ((EUID != 0)); then
  reset
  out=$(run --dry-run "${FAST[@]}" 2>&1)
  grep -qE 'nvidia_0|hwmon9|Permission denied' <<<"$out" && bad "read something under the RTX: $(grep -E 'nvidia_0|hwmon9|Permission' <<<"$out" | head -2)" || ok "never reads nvidia_0 or the RTX's hwmon"
fi
grep -qE 'nvidia_0|nvidia-smi|sensors( |$)' <(grep -v '^#' "$SCRIPT") && bad "the script names nvidia_0, nvidia-smi or sensors outside comments" || ok "no nvidia_0, nvidia-smi or sensors in the code"

# ----------------------------------------------------- 8. boot runs
reset
run --boot stock --rounds 2 --measure 1 --settle 0 --interval 1 >/dev/null 2>&1
echo 500000 >"$S/class/power_supply/BAT1/current_now"
run --boot nocb --rounds 2 --measure 1 --settle 0 --interval 1 >/dev/null 2>&1
[[ -s $T/home/state/stock.json && -s $T/home/state/nocb.json ]] && ok "--boot keeps both runs" || bad "--boot kept nothing"
grep -qE '^(stop|iw)' "$ST/log" && bad "--boot changed a setting" || ok "--boot changes no setting"
out=$(run --compare stock nocb --issue 0 --no-post 2>&1)
grep -q '| 9.00 | 7.50 | -1.50 |' <<<"$out" && ok "--compare reports B − A" || bad "compare: $out"

# ---------------------------------------------------- 9. through g16-testd
# A stand-in for g16-testd: a session is open while $STUB/td-open exists; each call
# is logged, a knob stays marked from knob-set until knob-restore.
cat >"$B/g16-testd" <<'EOF'
#!/bin/bash
case $1 in
  available) [[ -e $STUB/td-open ]] ;;
  session) # status: the knobs changed in the session (td-pre-*: by another test)
    k=(); for f in "$STUB"/td-set-* "$STUB"/td-pre-*; do [[ -e $f ]] && k+=("\"${f##*/td-???-}\": \"1\""); done
    (IFS=,; echo "{\"knobs\": {${k[*]}}}") ;;
  call)
    shift; m=$1 r=''; shift; a=()
    while (($#)); do if [[ $1 == --reason ]]; then r=$2; shift 2; else a+=("$1"); shift; fi; done
    [[ -n $r ]] || { echo "g16-testd: --reason needed" >&2; exit 2; }
    [[ -e $STUB/td-open ]] || { echo "g16-testd: no session open" >&2; exit 3; }
    echo "$m ${a[*]} | $r" >>"$STUB/td.log"
    case $m in
      knob-set) [[ -e $STUB/td-fail-${a[0]} ]] && { echo "g16-testd: ${a[0]} absent" >&2; exit 1; }
        touch "$STUB/td-set-${a[0]}"; echo "${a[1]}" ;;
      knob-restore) rm -f "$STUB/td-set-${a[0]}"; echo "${a[0]} back" ;;
      trace-start) touch "$STUB/td-trace-${a[0]}"; printf '{\n "missing": [],\n "on": []\n}\n' ;;
      trace-stop) rm -f "$STUB/td-trace-${a[0]}"
        # as the helper does: the file is the caller's, the directory root's (read-only here)
        mkdir -p "$STUB/td-out"; chmod 755 "$STUB/td-out"
        printf '  kworker/1:0-55  [001] d.h1. 10.0: csd_queue_cpu: cpu=2 callsite=x func=do_sync_core csd=0\n' >"$STUB/td-out/${a[0]}.trace"
        chmod 555 "$STUB/td-out"; echo "$STUB/td-out/${a[0]}.trace" ;;
    esac ;;
esac
EOF
cat >"$B/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >>"$STUB/log"; exit 1
EOF
chmod +x "$B/g16-testd" "$B/systemd-run"
run_td() { # like run, with G16_ROOT left to the script
  env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_TESTD="$B/g16-testd" G16_AB_SYS="$S" G16_AB_PROC="$P" \
    G16_AB_DPMS_WAIT=0 HYPRLAND_INSTANCE_SIGNATURE=test G16_AB_ISSUE="$B/issue" G16_AB_STATE="$T/home/state" G16_AB_REPORT="$T/home/report.md" "$SCRIPT" "$@"
}
reset
touch "$ST/td-open"
out=$(run_td "${FAST[@]}" --no-post 2>&1); rc=$?
((rc == 0)) && ok "testd run exits 0" || bad "testd run exit $rc: $out"
grep -q 'through the open g16-testd session' <<<"$out" && ok "testd run says it uses the session" || bad "testd run: $out"
grep -q '^systemd-run' "$ST/log" && bad "testd run asked for root: $(grep systemd-run "$ST/log")" || ok "testd run asks for no root"
[[ $(orig_state) == "$WANT" ]] && ok "testd run writes no setting itself" || bad "testd run changed: $(orig_state)"
L=$ST/td.log
for kv in "nmi-watchdog 0" "nvme-apst 30/500" "sd-reader removed" "kbd-usb-pm auto" "numlock-led 0" "wifi-ps on" "bt-rfkill 1"; do
  grep -q "^knob-set $kv |" "$L" && ok "testd: knob-set $kv" || bad "testd: no knob-set $kv"
done
nset=$(grep -c '^knob-set' "$L") nres=$(grep -c '^knob-restore' "$L")
((nset > 0 && nset == nres)) && ok "testd: every knob-set has its knob-restore ($nset)" || bad "testd: $nset sets, $nres restores"
ls "$ST"/td-set-* >/dev/null 2>&1 && bad "testd: left set: $(ls "$ST"/td-set-*)" || ok "testd: nothing left set"
[[ $(grep -c '^knob-set kbd-usb-pm' "$L") == 4 ]] && ok "testd: kbd-usb and usb-idle each set the keyboard once per round" || bad "testd: kbd-usb-pm $(grep -c '^knob-set kbd-usb-pm' "$L")"
grep -vq '| g16-idle-ab: ' "$L" && bad "testd: a call without the kit's reason: $(grep -v '| g16-idle-ab: ' "$L" | head -1)" || ok "testd: every call gives the kit's reason"
grep -q '^trace-start idle-ab-[0-9]* csd/csd_queue_cpu,timer/hrtimer_expire_entry - 8192 |' "$L" && grep -q '^trace-stop idle-ab-' "$L" &&
  ok "testd: the trace through trace-start and trace-stop" || bad "testd trace: $(grep trace "$L")"
grep -q 'ipi kworker/1:0 do_sync_core' "$T/home/report.md" && ok "testd: the trace is in the report" || bad "testd: trace not reported"
if ((EUID != 0)); then
  for f in "$ST"/td-out/*.trace; do [[ -s $f ]] && bad "testd: trace data left in the helper's directory" || ok "testd: the helper's trace file is emptied"; done
fi
grep -q 'g16-testd has no call for it' "$T/home/report.md" && ok "testd: diag says it was not read" || bad "testd: diag: $(grep -i debugfs "$T/home/report.md")"

reset
touch "$ST/td-open" "$ST/td-pre-nmi-watchdog"
out=$(run_td --only nmi,wifi-ps "${FAST[@]}" --no-post 2>&1); rc=$?
grep -q 'nmi not applied: err already changed in this g16-testd session: nmi-watchdog' <<<"$out" && ok "testd: a knob another test changed is refused" || bad "testd taken knob: $out"
grep -qE '^knob-(set|restore) nmi-watchdog' "$ST/td.log" && bad "testd: touched the other test's knob: $(grep nmi "$ST/td.log")" || ok "testd: the other test's knob is left alone"
grep -q '^knob-set wifi-ps on' "$ST/td.log" && ((rc == 0)) && ok "testd: the other tweaks still run" || bad "testd: rc=$rc, $(cat "$ST/td.log")"

reset
touch "$ST/td-open" "$ST/td-fail-wifi-ps"
out=$(run_td --only wifi-ps,nmi "${FAST[@]}" --no-post 2>&1); rc=$?
grep -q 'wifi-ps not applied: err wifi-ps: g16-testd: wifi-ps absent' <<<"$out" && ok "testd: a refused knob-set skips the phase" || bad "testd refusal: $out"
grep -qE '^\| [0-9]+ \| [12] \| wifi-ps \|' "$T/home/report.md" && bad "testd: wifi-ps measured though refused" || ok "testd: no phase for a refused tweak"
((rc == 0)) && ok "testd: the run carries on after a refusal" || bad "testd refusal exit $rc"

reset
touch "$ST/td-open"
run_td --only nmi --rounds 50 --measure 2 --settle 0 --interval 1 --no-post >/dev/null 2>&1 &
pid=$!
for _ in $(seq 50); do [[ -e $ST/td-set-nmi-watchdog ]] && break; sleep 0.2; done
kill -TERM "$pid"; wait "$pid" 2>/dev/null
[[ -e $ST/td-set-nmi-watchdog ]] && bad "testd: killed run left nmi-watchdog set" || ok "testd: a killed run restores through the helper"

reset
out=$(run_td --dry-run "${FAST[@]}" 2>&1)
grep -q '^systemd-run .*pkexec' "$ST/log" && ok "no session: falls back to pkexec" || bad "no session: $(cat "$ST/log") $out"
[[ -e $ST/td.log ]] && bad "no session: g16-testd was called" || ok "no session: g16-testd not called"
reset
out=$(G16_ROOT=testd run_td --dry-run "${FAST[@]}" 2>&1); rc=$?
((rc == 1)) && grep -q 'no g16-testd session is open' <<<"$out" && ! grep -q '^systemd-run' "$ST/log" &&
  ok "G16_ROOT=testd with no session refuses, asks nothing" || bad "G16_ROOT=testd: rc=$rc $out"
# ------------------------------------------------ 10. usb4 and CACP
reset
reply=$(printf 'apply cacp3\napply cacp4\nrevert cacp3\napply usb4\n' | "$SCRIPT" --root-helper "$S" "$P" 0 | tail -n +2)
[[ $reply == $'ok 3\nerr the other CACP level is applied\nok reverted\nok auto on 1' ]] && ok "root helper: one CACP level at a time; usb4 applies" || bad "cacp/usb4 replies: $reply"
[[ $(cat "$S/bus/pci/devices/0000:67:00.5/power/control") == on && $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 0 ]] && ok "usb4 and CACP back on EOF" || bad "usb4/cacp left: $(orig_state)"
echo auto >"$S/bus/pci/devices/0000:67:00.5/power/control"
out=$(run --only usb4,nmi "${FAST[@]}" --no-post 2>&1)
grep -q 'skipped: usb4: no USB4/Thunderbolt NHI or router is awake' <<<"$out" && ok "usb4 skipped when nothing is awake" || bad "usb4 skip: $out"
reset
echo 2 >"$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings"
out=$(run --only cacp3,nmi "${FAST[@]}" --no-post 2>&1)
grep -q 'skipped: cacp3: panel_power_savings is 2, not 0' <<<"$out" && ok "CACP skipped unless the level is 0" || bad "cacp skip: $out"
reset
run --only cacp4 "${FAST[@]}" --no-post --no-dpms >/dev/null 2>&1
grep -q '^dpms' "$ST/log" && bad "--no-dpms still cycled DPMS" || ok "--no-dpms: the write alone"
[[ $(orig_state) == "$WANT" ]] && ok "cacp4 put back" || bad "cacp4 left: $(orig_state)"

# ------------------------------------------------------ 11. pb12
# phase rows of a pb12 report -> "row on-set" lines
pb_phases() { grep -oE '^\| [0-9]+ \| [0-9]+ \| row [0-9]+ \([^)]*\)' "$1" | sed -E 's/.*row ([0-9]+) \(([^)]*)\)/\1 \2/'; }
# the tweaks a pb12 row switches on, for these columns
pb_row() { # row tweaks...
  local signs i on=''; signs=$("$SCRIPT" --pb12 rows | sed -n "${1}p"); shift
  for ((i = 0; i < $#; i++)); do [[ ${signs:i:1} == + ]] && { j=$((i + 1)); on+=${on:+,}${!j}; }; done
  echo "${on:--}"
}
reset
out=$(run --dry-run --design pb12 --rounds 1 --measure 1 --settle 0 --interval 1 --seed 5 2>&1); rc=$?
((rc == 0)) && ok "pb12 dry run exits 0" || bad "pb12 dry run exit $rc: $out"
grep -q 'Plackett-Burman design, 12 phases a round, 9 tweaks, 2 dummy columns' <<<"$out" && ok "pb12 dry run prints the design" || bad "pb12 header: $out"
for ((j = 0; j < 11; j++)); do
  w=${PB_DEFAULT[j]:-dummy}
  grep -q "column $((j + 1)): $w\$" <<<"$out" || bad "pb12 column $((j + 1)) is not $w"
done
ok "pb12 columns: the default set in order, then the dummies"
[[ $(grep -cE '^ +[0-9]+ +([+-]  ){10}[+-]' <<<"$out") == 12 ]] && ok "pb12 dry run prints the 12 rows" || bad "pb12 matrix rows: $(grep -cE '^ +[0-9]+ ' <<<"$out")"
[[ $(orig_state) == "$WANT" ]] && ok "pb12 dry run changes nothing" || bad "pb12 dry run changed: $(orig_state)"
grep -qE '^(stop|iw|dpms)' "$ST/log" && bad "pb12 dry run acted: $(cat "$ST/log")" || ok "pb12 dry run stops, sets and cycles nothing"
[[ $(pb_phases "$T/home/report.md" | wc -l) == 12 ]] && ok "pb12 dry run walks 12 phases" || bad "pb12 dry phases: $(pb_phases "$T/home/report.md" | wc -l)"

reset
out=$(run --design pb12 --rounds 2 --measure 1 --settle 0 --interval 1 --seed 5 2>&1); rc=$?
r=$T/home/report.md
((rc == 0)) && ok "pb12 run exits 0" || bad "pb12 run exit $rc: $out"
[[ $(orig_state) == "$WANT" ]] && ok "pb12: every setting back at the end" || bad "pb12 left: $(orig_state) (want $WANT)"
n=0 wrong=0 seen=''
while read -r row on; do
  n=$((n + 1)); seen+=" $row"
  [[ $on == "$(pb_row "$row" "${PB_DEFAULT[@]}")" ]] || { wrong=$((wrong + 1)); echo "  row $row on '$on', want '$(pb_row "$row" "${PB_DEFAULT[@]}")'"; }
done < <(pb_phases "$r")
((n == 24 && wrong == 0)) && ok "pb12: 24 phases, each with exactly its row's tweaks on" || bad "pb12 phases: $n, $wrong wrong"
[[ $(tr ' ' '\n' <<<"$seen" | grep -c .) == 24 && $(tr ' ' '\n' <<<"$seen" | sort -u | grep -c .) == 12 ]] && ok "pb12: every row in each round" || bad "pb12 rows seen: $seen"
# A tweak changes only when its level differs from the row before: voxtype stops
# once per run of rows with it on, never twice in a row.
stops=$(grep -c '^stop voxtype' "$ST/log"); starts=$(grep -c '^start voxtype' "$ST/log")
((stops == starts && stops >= 2 && stops <= 12)) && ok "pb12: voxtype stopped and started in pairs ($stops)" || bad "pb12 voxtype: $stops stops, $starts starts"
[[ -z $(grep voxtype "$ST/log" | uniq -d) ]] && ok "pb12: no tweak applied twice without a revert" || bad "pb12: voxtype stopped twice in a row"
for t in "${PB_DEFAULT[@]}"; do
  grep -qE "^\| $t \| #[0-9]+ \| 12 / 12 \| [+-][0-9.]+ \| [0-9.]+ \|" "$r" && ok "pb12 fits $t (12 phases on, 12 off)" || bad "pb12 $t row: $(grep "^| $t |" "$r")"
done
[[ $(grep -c '^| (dummy, column 1[01]) |' "$r") == 2 ]] && ok "pb12 reports the two dummy columns" || bad "pb12 dummies: $(grep dummy "$r")"
grep -q '^Fit: 24 valid phases' "$r" && grep -q 'assumes the effects add up' "$r" && ok "pb12 report: the fit and the additivity assumption" || bad "pb12 fit line: $(grep '^Fit' "$r")"
want_posts=$(( 1 + $(for t in "${PB_DEFAULT[@]}"; do "$SCRIPT" --list | awk -v t="$t" '$1 == t {print $2}'; done | sort -u | wc -l) ))
nposts=$(ls "$ST"/posted-* | wc -l)
((nposts == want_posts)) && ok "pb12: one post per tweak issue plus #198 ($nposts)" || bad "pb12: $nposts posts, want $want_posts"
grep -q '^Verdict: ' "$ST/posted-225" && grep -q 'assumes the effects add up' "$ST/posted-225" && ok "pb12 post carries the verdict and the assumption" || bad "pb12 post #225: $(cat "$ST/posted-225")"

out=$(run --design pb12 --only kbd-usb,numlock --dry-run 2>&1); rc=$?
((rc == 2)) && grep -q "kbd-usb and numlock switch the same setting" <<<"$out" && ok "pb12 refuses tweaks that switch the same setting" || bad "pb12 conflict: exit $rc: $out"
out=$(run --design pb12 --only cacp3,cacp4 --dry-run 2>&1); rc=$?
((rc == 2)) && ok "pb12 refuses cacp3 with cacp4" || bad "pb12 cacp conflict: exit $rc"
out=$(run --design pb12 --only "$(IFS=,; echo "${ALL[*]}")" --dry-run 2>&1); rc=$?
((rc == 2)) && grep -q 'at most 11 tweaks' <<<"$out" && ok "pb12 refuses more than 11 tweaks" || bad "pb12 12 tweaks: exit $rc: $out"
out=$(run --design xyz --dry-run 2>&1); rc=$?
((rc == 2)) && ok "an unknown --design is refused" || bad "--design xyz: exit $rc"

# ------------------------------- 12. pb12 through a G16 test session
reset
touch "$ST/td-open"
out=$(run_td --design pb12 --rounds 1 --measure 1 --settle 0 --interval 1 --seed 5 --no-post 2>&1); rc=$?
((rc == 0)) && ok "testd pb12 run exits 0" || bad "testd pb12 run exit $rc: $out"
grep -q "skipped: usb4: not on g16-testd's allowlist" <<<"$out" && ok "testd: usb4 skipped" || bad "testd usb4: $out"
grep -q '^knob-set panel-power-savings 3 |' "$ST/td.log" && ok "testd: cacp3 is the panel-power-savings knob" || bad "testd cacp3: $(grep panel "$ST/td.log")"
nset=$(grep -c '^knob-set' "$ST/td.log") nres=$(grep -c '^knob-restore' "$ST/td.log")
((nset > 0 && nset == nres)) && ok "testd pb12: every knob-set has its knob-restore ($nset)" || bad "testd pb12: $nset sets, $nres restores"
[[ $(grep -c '^| (dummy, column' "$T/home/report.md") == 3 ]] && ok "testd pb12: 8 tweaks, 3 dummy columns" || bad "testd pb12 dummies: $(grep dummy "$T/home/report.md")"
[[ $(orig_state) == "$WANT" ]] && ok "testd pb12: nothing changed behind g16-testd's back" || bad "testd pb12 changed: $(orig_state)"

# --------------------------------------------- 13. review fixes (#276)
# pb12 verdicts come from the fit only, even with a small selection
reset
run --design pb12 --only nmi,wifi-ps --rounds 1 --measure 1 --settle 0 --interval 1 --seed 5 >/dev/null 2>&1
r=$T/home/report.md
[[ $(grep -c '^| tweak |' "$r") == 1 ]] && ok "pb12: one tweak table (no one-at-a-time table)" || bad "pb12 tables: $(grep '^| tweak |' "$r")"
row=$(grep '^| nmi |' "$r")
[[ $row == *"| 6 / 6 |"* ]] && grep -qF "$row" "$ST/posted-225" && ok "pb12: the posted row is the fitted one" || bad "pb12 nmi row: $row / $(grep '^| nmi' "$ST/posted-225")"
# a DPMS cycle that fails: the CACP phase isn't measured and the run stops with the level back
reset
touch "$ST/dpms-fail"
out=$(run --only cacp3,nmi "${FAST[@]}" --no-post 2>&1); rc=$?
((rc == 1)) && grep -q 'cacp3: the DPMS cycle failed' <<<"$out" && ok "a failed DPMS cycle is a failed CACP apply" || bad "dpms fail: exit $rc: $out"
grep -qE '^\| [0-9]+ \| [12] \| cacp3 \|' "$T/home/report.md" 2>/dev/null && bad "cacp3 measured without its DPMS cycle" || ok "no cacp3 phase without the DPMS cycle"
[[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 0 ]] && ok "dpms fail: the level is back" || bad "dpms fail: level $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings")"
rm -f "$ST/dpms-fail"
reset
# No Hyprland session: an empty runtime dir, so none is found (the hyprctl stub stays first).
mkdir -p "$T/xdg"
env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_AB_SYS="$S" G16_AB_PROC="$P" G16_AB_DPMS_WAIT=0 \
  HYPRLAND_INSTANCE_SIGNATURE= XDG_RUNTIME_DIR="$T/xdg" G16_AB_REPORT="$T/home/report.md" "$SCRIPT" --only cacp3,nmi "${FAST[@]}" --no-post >"$T/out" 2>&1
grep -q 'skipped: cacp3: no Hyprland session for the DPMS cycle' "$T/out" && ok "CACP skipped without a Hyprland session" || bad "no hyprland: $(cat "$T/out")"
grep -q '^dpms' "$ST/log" && bad "no Hyprland session, yet DPMS was cycled" || ok "no Hyprland session: no DPMS"
# killed while a CACP level is on: the level goes back and the panel is cycled back on
reset
env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_AB_SYS="$S" G16_AB_PROC="$P" G16_AB_DPMS_WAIT=0 HYPRLAND_INSTANCE_SIGNATURE=test \
  G16_AB_REPORT="$T/home/report.md" "$SCRIPT" --only cacp3 --rounds 1 --measure 20 --settle 0 --interval 1 --no-post >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 300); do [[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 3 ]] && grep -q '^dpms on' "$ST/log" && break; sleep 0.1; done
sleep 0.5
kill -TERM "$pid"; wait "$pid" 2>/dev/null
[[ $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings") == 0 ]] && ok "killed with CACP on: the level is back" || bad "killed: level $(cat "$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings")"
[[ $(grep -c '^dpms off' "$ST/log") == 2 && $(grep '^dpms' "$ST/log" | tail -n1) == "dpms on eDP-1" ]] && ok "killed with CACP on: one more DPMS cycle, panel on" || bad "killed dpms: $(grep '^dpms' "$ST/log" | paste -sd' ')"
# testd: no trace in a dry run; a trace in progress is stopped when the helper is killed
reset
touch "$ST/td-open"
run_td --dry-run --only nmi --rounds 1 --measure 1 --settle 0 --interval 1 >/dev/null 2>&1
grep -q '^trace-' "$ST/td.log" 2>/dev/null && bad "testd dry run traced: $(grep '^trace-' "$ST/td.log")" || ok "testd dry run: no trace"
reset
touch "$ST/td-open"
{ printf 'trace 10\n'; sleep 1; } | G16_TESTD="$B/g16-testd" STUB="$ST" "$SCRIPT" --testd-helper 0 30/500 test >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 50); do grep -q '^trace-start' "$ST/td.log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$pid"; wait "$pid" 2>/dev/null
grep -q '^trace-stop idle-ab-' "$ST/td.log" && ok "testd helper killed mid-trace stops the trace" || bad "testd trace left on: $(cat "$ST/td.log")"

((fails == 0)) && echo "PASS" || { echo "$fails failed"; exit 1; }
