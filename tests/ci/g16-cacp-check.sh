#!/bin/bash
# bin/g16-cacp-check, offline: a fake GA605 sysfs, hyprctl, omarchy-toggle-idle and
# g16-testd stubbed (the stand-in logs its calls):
#   1. --dry-run walks the steps and writes nothing;
#   2. inside an open g16-testd session every level is the helper's knob-set
#      panel-power-savings with the kit's reason, the exit is its knob-restore, step 1
#      runs through the helper's dmub-cacp-set-level trace (the handed-over trace files
#      are removed), step 2's table is written, and nothing asks for root; with a
#      helper whose allowlist lacks that kprobe, step 1 is reported as skipped; a
#      failed trace-stop or restart gives no verdict (CAPTURE FAILED), and the exit
#      retries a stop that failed;
#   3. a panel-power-savings another test changed in the session is refused, untouched;
#   4. with no session it falls back to pkexec, and G16_ROOT=testd refuses.
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
SCRIPT=$W/bin/g16-cacp-check
S=$T/sys B=$T/bin ST=$T/state
mkdir -p "$S/class/dmi/id" "$S/class/power_supply/BAT1" "$S/class/drm/card1-eDP-1/amdgpu" "$S/bus/pci/devices" "$B"
echo "ROG Zephyrus G16 GA605KM_GA605KM" >"$S/class/dmi/id/product_name"
echo Battery >"$S/class/power_supply/BAT1/type"
echo Discharging >"$S/class/power_supply/BAT1/status"
echo 600000 >"$S/class/power_supply/BAT1/current_now"
echo 15000000 >"$S/class/power_supply/BAT1/voltage_now"
echo connected >"$S/class/drm/card1-eDP-1/status"
echo 0 >"$S/class/drm/card1-eDP-1/amdgpu/panel_power_savings"

cat >"$B/g16-testd" <<'STUB'
#!/bin/bash
case $1 in
  available) [[ -e $STUB/td-open ]] ;;
  session) [[ -e $STUB/td-pre ]] && echo '{"knobs": {"panel-power-savings": "0"}}' || echo '{"knobs": {}}' ;;
  list) [[ -e $STUB/td-old ]] || printf 'kprobes (trace-start):\n  dmub-cacp-set-level    dmub_cacp_set_level level=%%si:u32\n' ;;
  call)
    shift; m=$1 r=''; shift; a=()
    while (($#)); do if [[ $1 == --reason ]]; then r=$2; shift 2; else a+=("$1"); shift; fi; done
    [[ -n $r && -e $STUB/td-open ]] || exit 3
    echo "$m ${a[*]} | $r" >>"$STUB/td.log"
    if [[ $m == trace-stop && -e $STUB/td-stop-fail ]]; then echo "g16-testd: stop failed"; exit 1
    elif [[ $m == trace-start && -e $STUB/td-restart-fail && $(grep -c '^trace-start ' "$STUB/td.log") -gt 1 ]]; then
      echo "g16-testd: start failed"; exit 1
    elif [[ $m == trace-stop ]]; then
      # the levels written since the trace started reach the firmware at once
      f=$STUB/trace-$(wc -l <"$STUB/td.log")
      tac "$STUB/td.log" | awk '/^trace-start / {exit} /^knob-set panel-power-savings/ {print "  <idle>-0 [000] g16testd/dmub_cacp_set_level: (dmub_cacp_set_level+0x0/0x80) level=" $3}' >"$f"
      echo "$f"
    else echo ok; fi ;;
esac
STUB
cat >"$B/hyprctl" <<'STUB'
#!/bin/bash
echo "hyprctl $*" >>"$STUB/log"
STUB
cat >"$B/omarchy-toggle-idle" <<'STUB'
#!/bin/bash
echo "idle $1" >>"$STUB/log"
STUB
cat >"$B/systemd-run" <<'STUB'
#!/bin/bash
echo "systemd-run $*" >>"$STUB/root.log"; exit 1
STUB
cat >"$B/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >>"$STUB/root.log"; exit 1
STUB
cat >"$B/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$B"/*
reset() { rm -rf "${ST:?}" "${T:?}/home"; mkdir -p "$ST" "$T/home"; }
run() {
  env HOME="$T/home" PATH="$B:$PATH" STUB="$ST" CACP_SYS="$S" G16_TESTD="$B/g16-testd" HYPRLAND_INSTANCE_SIGNATURE=test \
    "$SCRIPT" "$@"
}

# 1. dry run
reset
out=$(run --dry-run --rounds 1 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
[[ ! -e $ST/td.log && ! -e $ST/root.log ]] && ok "dry run asks nothing" || bad "dry run called: $(cat "$ST"/td.log "$ST"/root.log 2>&1)"

# 2. through g16-testd
reset
touch "$ST/td-open"
out=$(run --rounds 1 --measure 1 --settle 1 2>&1); rc=$?
((rc == 0)) && ok "testd run exits 0" || bad "testd run exit $rc: $out"
grep -q 'through the open g16-testd session (no dialog)' <<<"$out" && ok "testd run says it uses the session" || bad "testd run: $out"
[[ ! -e $ST/root.log ]] && ok "testd run asks for no root" || bad "testd run asked for root: $(cat "$ST/root.log")"
L=$ST/td.log
for v in 3 4 0; do grep -q "^knob-set panel-power-savings $v | g16-cacp-check: " "$L" && ok "testd: level $v through knob-set" || bad "testd: no level $v: $(cat "$L")"; done
[[ $(tail -n1 "$L") == "knob-restore panel-power-savings | g16-cacp-check: "* ]] && ok "testd: knob-restore at the exit" || bad "testd: last call $(tail -n1 "$L")"
R=$(ls "$T"/home/omarchy-asus-cacp-check-*.md 2>/dev/null | head -1)
grep -q "^trace-start cacp-[0-9]* - dmub-cacp-set-level 1024 | g16-cacp-check: " "$L" && ok "testd: step 1 through the dmub-cacp-set-level kprobe" || bad "testd: no kprobe trace: $(cat "$L")"
grep -q "PASS: the write alone reached the firmware" "${R:-/dev/null}" && grep -q 'after write: level=3 x1;' "$R" &&
  ok "testd: step 1 verdict from the helper's trace" || bad "testd step 1: $(grep -A4 'Step 1' "${R:-/dev/null}")"
[[ $(grep -c '^trace-start ' "$L") == "$(grep -c '^trace-stop ' "$L")" ]] && ok "testd: every trace stopped" || bad "testd: traces left: $(grep '^trace-' "$L")"
compgen -G "$ST/trace-*" >/dev/null && bad "testd: trace files left: $(ls "$ST"/trace-*)" || ok "testd: handed-over traces removed"
grep -qE '^\| L3 \| 1 \|' "${R:-/dev/null}" && grep -qE '^\| L4 \| 1 \|' "$R" && ok "testd: step 2 measured L3 and L4" || bad "testd step 2: $(cat "${R:-/dev/null}")"

# 2b. a helper without the kprobe: step 1 skipped, step 2 still runs
reset
touch "$ST/td-open" "$ST/td-old"
out=$(run --rounds 1 --measure 1 --settle 1 2>&1); rc=$?
R=$(ls -t "$T"/home/omarchy-asus-cacp-check-*.md 2>/dev/null | head -1)
((rc == 0)) && grep -q "SKIP: err the dmub_cacp_set_level kprobe is not on this g16-testd's allowlist" "${R:-/dev/null}" &&
  ! grep -q '^trace-' "$ST/td.log" && ok "old helper: step 1 reported as skipped" || bad "old helper: rc=$rc $(grep -A2 'Step 1' "${R:-/dev/null}")"

# 2c. capture failures: no firmware verdict, and the exit still stops the trace
for want in "stop|g16-testd trace-stop: g16-testd: stop failed" "restart|g16-testd trace-start: g16-testd: start failed"; do
  mode=${want%%|*}
  reset
  touch "$ST/td-open" "$ST/td-$mode-fail"
  out=$(run --verify-only 2>&1); rc=$?
  R=$(ls -t "$T"/home/omarchy-asus-cacp-check-*.md 2>/dev/null | head -1)
  grep -qF "CAPTURE FAILED, no verdict: ${want#*|}" "${R:-/dev/null}" && ! grep -qE 'NO CACP COMMAND|PASS:|BUG CONFIRMED' "$R" &&
    ok "$mode failure: no verdict" || bad "$mode failure: rc=$rc $(grep -A3 'Step 1' "${R:-/dev/null}") $out"
done
reset
touch "$ST/td-open" "$ST/td-stop-fail"
run --verify-only >/dev/null 2>&1
(($(grep -c '^trace-stop ' "$ST/td.log") >= 3)) && ok "stop failure: probe-off and the exit retry the stop" || bad "stop failure: $(grep '^trace-' "$ST/td.log")"

# 3. another test's setting
reset
touch "$ST/td-open" "$ST/td-pre"
out=$(run --rounds 1 --measure 1 --settle 1 2>&1); rc=$?
((rc == 1)) && grep -q 'already changed in this g16-testd session' <<<"$out" && [[ ! -e $ST/td.log ]] &&
  ok "testd: refuses a panel-power-savings another test changed, touching nothing" || bad "taken: rc=$rc $out $(cat "$ST/td.log" 2>&1)"

# 4. no session
reset
out=$(run --rounds 1 --measure 1 --settle 1 2>&1); rc=$?
((rc == 1)) && grep -q 'pkexec' "$ST/root.log" && [[ ! -e $ST/td.log ]] && ok "no session: falls back to pkexec" || bad "no session: rc=$rc $(cat "$ST/root.log" 2>&1) $out"
reset
out=$(G16_ROOT=testd run --rounds 1 2>&1); rc=$?
((rc == 1)) && grep -q 'no g16-testd session is open' <<<"$out" && [[ ! -e $ST/root.log ]] && ok "G16_ROOT=testd with no session refuses" || bad "G16_ROOT=testd: rc=$rc $out"

((fails == 0)) && echo "all g16-cacp-check checks passed" || { echo "$fails check(s) failed"; exit 1; }
