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
#   5. a connected Bluetooth device skips the Bluetooth phase;
#   6. the root helper refuses unknown tweaks and commands;
#   7. it never reads the nvidia_0 backlight or anything under the RTX but its
#      runtime_status (a read-only stand-in makes such a read fail loudly);
#   8. --boot keeps the numbers and --compare reports B against A.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
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
  mkdir -p "$S/bus/usb/devices/3-4/power"
  echo 0b05 >"$S/bus/usb/devices/3-4/idVendor"; echo 19b6 >"$S/bus/usb/devices/3-4/idProduct"
  echo on >"$S/bus/usb/devices/3-4/power/control"; echo active >"$S/bus/usb/devices/3-4/power/runtime_status"
  mkdir -p "$S/class/net/wlan0/wireless" "$S/class/leds/input12::numlock" "$S/class/rfkill/rfkill7"
  echo 1 >"$S/class/leds/input12::numlock/brightness"
  echo bluetooth >"$S/class/rfkill/rfkill7/type"; echo 0 >"$S/class/rfkill/rfkill7/soft"
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
    "$(cat "$S/class/rfkill/rfkill7/soft")" "$( [[ -e $ST/active/voxtype.service ]] && echo vox-on || echo vox-off)"
}
WANT="1 100 2000 100000 on auto on off 1 0 vox-on "

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
  rm -rf "${ST:?}" "${T:?}/home"
  mkdir -p "$ST/active" "$T/home"
  touch "$ST/active/voxtype.service" "$ST/log"
  echo off >"$ST/wifi"
}
run() {
  env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" G16_ROOT=none G16_AB_SYS="$S" G16_AB_PROC="$P" \
    G16_AB_ISSUE="$B/issue" G16_AB_STATE="$T/home/state" G16_AB_REPORT="$T/home/report.md" "$SCRIPT" "$@"
}
FAST=(--rounds 2 --measure 1 --settle 0 --interval 1 --seed 7)

# ---------------------------------------------------------------- 1. dry run
reset
out=$(run --dry-run "${FAST[@]}" 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
[[ $(orig_state) == "$WANT" ]] && ok "dry run changes nothing" || bad "dry run changed: $(orig_state)"
grep -qE '^(stop|iw|idle)' "$ST/log" && bad "dry run acted: $(cat "$ST/log")" || ok "dry run stops, sets and toggles nothing"
ls "$ST"/posted-* >/dev/null 2>&1 && bad "dry run posted" || ok "dry run posts nothing"
for t in nmi nvme-apst sd-off kbd-usb wifi-ps numlock bt-off voxtype; do
  grep -q "^| $t |" "$T/home/report.md" && ok "dry run reports $t" || bad "dry run report has no $t row"
done
grep -q '^Baseline over the run: battery 9.00 W' "$T/home/report.md" && ok "battery watts from current_now x voltage_now" || bad "battery: $(grep '^Baseline' "$T/home/report.md")"
grep -q 'SoC 4.50 W' "$T/home/report.md" && ok "SoC watts from gpu_metrics" || bad "SoC: $(grep '^Baseline' "$T/home/report.md")"
grep -q 'GFX 0.03 W, all CPU cores 0.18 W' "$T/home/report.md" && ok "GFX and core split from gpu_metrics" || bad "split: $(grep '^SoC split' "$T/home/report.md")"

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
((n == 18)) && ok "each round brackets every tweak with baselines (18 baselines)" || bad "$n baseline phases"
for t in nmi nvme-apst sd-off kbd-usb wifi-ps numlock bt-off voxtype; do
  grep -qE "^\| $t \| #[0-9]+ \| 2/2 \|" "$r" && ok "$t measured in both rounds" || bad "$t row: $(grep "^| $t |" "$r")"
done
grep -q 'nvme-apst ok 30/500 ms' "$r" && ok "APST timeouts 30/500 applied" || bad "APST apply: $(grep nvme-apst "$r")"
[[ -e $ST/posted-198 ]] && grep -q '^## G16 idle A/B' "$ST/posted-198" && ok "report posted to #198" || bad "not posted to #198"
grep -qF "$T/home" "$ST"/posted-* && bad "home path in a post" || ok "posts have no home path"
nposts=$(ls "$ST"/posted-* | wc -l)
# Each tweak with an issue number gets its own post, plus #198.
want_posts=$(( 1 + $("$SCRIPT" --list | awk '$2 != "#0"' | wc -l) ))
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
[[ $(cat "$S/class/rfkill/rfkill7/soft") == 0 ]] && ok "connected device: rfkill untouched" || bad "rfkill changed"

# ------------------------------------------------------- 6. the root helper
reset
reply=$(printf 'apply foo\napply nmi;rm\nfrob\napply nmi\napply nmi\nrevert nmi\n' | "$SCRIPT" --root-helper "$S" "$P" 0)
want=$'ready '"$(id -u)"$'\nerr unknown tweak\nerr bad tweak\nerr unknown\nok 0\nerr already applied\nok reverted'
[[ $reply == "$want" ]] && ok "root helper refuses unknown tweaks and commands" || bad "root helper replies: $reply"
printf 'apply nmi\napply bt-off\n' | "$SCRIPT" --root-helper "$S" "$P" 0 >/dev/null
[[ $(cat "$P/sys/kernel/nmi_watchdog") == 1 && $(cat "$S/class/rfkill/rfkill7/soft") == 0 ]] && ok "root helper reverts on EOF" || bad "root helper left nmi/bt changed"

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

((fails == 0)) && echo "PASS" || { echo "$fails failed"; exit 1; }
