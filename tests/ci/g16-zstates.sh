#!/bin/bash
# recipes/linux-omarchy/g16-test/zstates, AllowZstates in the bit-16 idle state (#249),
# offline. Every case runs the whole kit against its fake sysfs/debugfs tree and kernel
# emulator (--dry-run), so the real code paths read and write files, send the message, wait
# for its kernel line and undo the journal:
#   1. the verdicts: YES at 9 (8 skipped, 0 measured), YES at 8, PARTIAL (counter only, power
#      only), NO (0 sent without a phase), not answered (bit 16 never idle: no message sent)
#   2. the keyboard levels: K0 / K1 / K2 (services stopped, LEDs off) / K3 (deauthorized, no
#      key check), and a udev rule that did not apply
#   3. the key check: kept, lost, not pressed
#   4. a screen glitch makes a phase INVALID and it runs once more
#   5. everything back after every run (the restore check and the fake tree's own state:
#      the last AllowZstates sent 0, 3-4 on auto, DPMS on, the PSP on "on")
#   6. SIGTERM mid-run: the journal undo still sends AllowZstates(0) and puts everything back
#   7. the preflight refuses (nothing changed) on AC, without 9910's file, without 9907's
#   8. helpers: RAPL across a wrap, the per-IP counters, the verdict rules; bad usage exits 2
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
KIT=$W/recipes/linux-omarchy/g16-test/zstates
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
H='^## AllowZstates in the bit-16 idle state on the G16:'
dry() { TMPDIR=$T python3 -I "$KIT" --dry-run --phase-secs 2 "$@" 2>&1; }

echo "== 1-5. dry runs"
while IFS='|' read -r name args; do
    # shellcheck disable=SC2086 # the case's flags
    out=$(dry $args); rc=$?
    ((rc == 0)) && ok "$name: exits 0" || bad "$name: exit $rc: $out"
    printf '%s\n' "$out" >"$T/$name.out"
done <<'EOF'
z9|--sim-z z9
z8|--sim-z z8 --sim-kbd k0 --sim-key lost
counter|--sim-z counter --sim-kbd k2 --sim-udev no --sim-key none
drop|--sim-z drop --sim-state screen
none|--sim-z none --sim-kbd k3
nobit16|--sim-state nobit16
EOF
g() { grep -Eq "$2" "$T/$1.out"; }
g z9 "$H YES: AllowZstates\(9\) starts runtime S0i2 .*battery power [0-9.]+ W below base\) \(#249\)$" \
    && ok "z9: YES at 9" || bad "z9 heading: $(grep '^## ' "$T/z9.out")"
g z9 '^Notes: .*AllowZstates\(8\) skipped' && ! g z9 '^\| Z8 \|' && g z9 '^\| Z0 \| .* \| yes \|' \
    && ok "z9: 8 skipped, 0 measured" || bad "z9: phases $(grep -oE '^\| (base|Z[0-9]) ' "$T/z9.out" | tr -d '\n')"
g z8 "$H YES: AllowZstates\(8\) starts runtime S0i2" && g z8 '^\| Z9 \| .* \| 0 -> 0 \(0\) \|' \
    && ok "z8: YES at 8, nothing at 9" || bad "z8 heading: $(grep '^## ' "$T/z8.out")"
g counter "$H PARTIAL: timein_s0i2 grows after AllowZstates\(9\) .* but battery power doesn't drop 0.2 W" \
    && ok "counter: PARTIAL, counter only" || bad "counter heading: $(grep '^## ' "$T/counter.out")"
g drop "$H PARTIAL: battery power drops [0-9.]+ W after AllowZstates\(9\) but timein_s0i2 stays" \
    && ok "drop: PARTIAL, power only" || bad "drop heading: $(grep '^## ' "$T/drop.out")"
g none "$H NO: neither AllowZstates\(9\) nor \(8\) starts runtime S0i2" \
    && g none 'AllowZstates\(0\) sent without a measured phase' && ! g none '^\| Z0 \|' \
    && ok "none: NO, 0 sent without a phase" || bad "none heading: $(grep '^## ' "$T/none.out")"
g nobit16 "$H not answered: bit 16 idle in only 0% of base reads: not the idle state" \
    && g nobit16 'no AllowZstates message was sent' && ! g nobit16 'AllowZstates\(9\):' \
    && ok "nobit16: stops before any message" || bad "nobit16: $(grep -E '^(## |Notes)' "$T/nobit16.out")"
for c in z9:K1 z8:K0 counter:K2 none:K3; do
    g "${c%%:*}" "67:00.0 slept at \*\*${c#*:}\*\*" || bad "${c%%:*}: level ${c#*:}"
done
ok "keyboard levels K0 K1 K2 K3"
g z9 '67:00.0 slept at \*\*K1\*\* \(Bluetooth soft-blocked\)$' && g counter 'alone were not enough' \
    && ok "K0/K1 pass 9909 + udev; K2 says it wasn't enough" || bad "the 9909 + udev line"
g counter '^Notes: 3-4 power/control was on, not auto: the udev rule .* did not apply' \
    && ok "a udev rule that did not apply is named" || bad "udev note"
g counter '^K2 stopped: g16-winlockd@hidraw0.service, g16-winlock.service \(user\), asusd.service; LEDs: asus::kbd_backlight 1 -> 0' \
    && ok "K2 stops the services and the LEDs" || bad "K2 line: $(grep '^K2 stopped' "$T/counter.out")"
g z9 '^- key wake: \*\*kept\*\* \(Shift press delivered' && ok "key: kept" || bad "key kept"
g z8 '^- key wake: \*\*lost\*\* \(the first event was Shift.s release' && ok "key: lost" || bad "key lost"
g counter '^- key wake: \*\*not checked\*\* \(no key pressed in 6 s\)' && ok "key: not pressed" || bad "key none"
g none '^- key wake: \*\*not checked\*\* \(not reached\)' && ok "key: not with the keyboard deauthorized" || bad "key K3"
g drop '^Notes: Z9 INVALID on try 1 \(.*kernel DPMS Off in' && g drop '^\| Z9 \| .* \| yes \|' \
    && ok "a screen glitch: INVALID, run once more, valid" || bad "glitch: $(grep -E '^(Notes|\| Z9 )' "$T/drop.out")"
for f in z9 z8 counter drop none nobit16; do
    ctl=auto; [[ $f == counter ]] && ctl=on       # its udev rule did not apply: back to on
    g "$f" 'everything as before it \(.*\): yes$' || bad "$f: restore check"
    g "$f" "^Fake tree after the run: 3-4 power/control $ctl, dpms On, last AllowZstates (0|None), PSP control on\$" \
        || bad "$f: fake tree after: $(grep '^Fake tree' "$T/$f.out")"
done
ok "everything back after every run"
g z9 '^\| base \| the idle state, nothing sent \| 2 \| yes \| 100% / 100% / 100% \| 0xffdf9efd \| 8 \|' \
    && ok "a phase row: bits 5/16/20, the mask, gate bits busy" || bad "base row: $(grep '^| base ' "$T/z9.out")"
compgen -G "$T/omarchy-asus-g16-zstates-*.md" >/dev/null && ok "the report is written" || bad "no report in TMPDIR"

echo "== 6. SIGTERM mid-run"
TMPDIR=$T python3 -I "$KIT" --dry-run --phase-secs 4 --sim-z z9 >"$T/term.out" 2>&1 &
pid=$!
for _ in $(seq 1 200); do grep -q '^AllowZstates(9):' "$T/term.out" && break; sleep 0.1; done
sleep 1
kill -TERM "$pid"; wait "$pid"; rc=$?
((rc == 0)) && ok "SIGTERM: exits 0 with a report" || bad "SIGTERM: exit $rc"
grep -q '^Problems: interrupted' "$T/term.out" && grep -q 'last AllowZstates 0,' "$T/term.out" \
    && grep -q 'everything as before it (.*): yes$' "$T/term.out" \
    && ok "SIGTERM: AllowZstates(0) sent by the undo, everything back" || bad "SIGTERM: $(tail -8 "$T/term.out")"

echo "== 7. preflight"
for c in "--sim-ac:not on battery" "--sim-missing zstates:no amdgpu_smu_allow_zstates" \
         "--sim-missing metrics:no amd_pmc smu_metrics_runtime"; do
    # shellcheck disable=SC2086 # the case's flags
    out=$(dry ${c%%:*}); rc=$?
    ((rc == 1)) && grep -q "not started, nothing was changed: .*${c#*:}" <<<"$out" \
        && ok "refuses: ${c#*:}" || bad "${c%%:*}: rc $rc: $out"
done

echo "== 8. helpers"
out=$(python3 -I -B - "$KIT" <<'EOF' 2>&1
import importlib.machinery, importlib.util, sys
ld = importlib.machinery.SourceFileLoader("kit", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("kit", ld)); ld.exec_module(m)
assert abs(m.rapl_w((100, 1000, 0.0), (50, 1000, 1.0)) - 950e-6) < 1e-12      # across the wrap
assert m.rapl_w((100, 1000, 0.0), (600, 1000, 1.0)) == 500e-6
assert m.rapl_w(None, (1, 1, 1.0)) is None
t = ("Dump data (0x6): ok 0\ntimein_s0i2: 5\nidx name active timecondition_notmet_lastcapture timecondition_notmet_totaltime\n"
     " 0 DISPLAY  1 0 10\n 1 -        0 0 7\n")
p = m.parse_metrics(t)
assert p["timein_s0i2"] == 5 and p["dump"] == "ok 0" and p["ips"] == {0: ["DISPLAY", 10], 1: ["ip1", 7]}, p
q = m.parse_metrics(t.replace("0 10\n", "0 25\n").replace("timein_s0i2: 5", "timein_s0i2: 9"))
assert m.ip_growth(p, q) == [["DISPLAY", 15]] and m.s0i2_delta(p, q) == 4
assert m.s0i2_delta(p, dict(q, dump="rejected, table not refreshed: -5")) is None
assert m.busy_gate_bits(0xffffffff & ~(1 << 8) & ~(1 << 16)) == [8, 16]
assert m.ZLINE_RE.search("amdgpu 0000:65:00.0: EXPERIMENTAL: SMU AllowZstates(9) sent: -62, arg register 0x0000ffff").groups() \
    == ("9", "-62", "0x0000ffff")
base = {"phase": "base", "valid": True, "secs": 30, "s0i2": 0, "rapl_w": 4.6, "idle": {16: 1.0}}
z = lambda v, s, w, valid=True: {"phase": f"Z{v}", "valid": valid, "secs": 30, "s0i2": s, "rapl_w": w,
                                 "sent": {"v": v, "err": None, "ret": 0}}
assert m.clear_yes(z(9, 3_000_000, 4.3), base) and not m.clear_yes(z(9, 2_000_000, 4.3), base)   # 10% of 30 s
assert not m.clear_yes(z(9, 9_000_000, 4.45), base)                                             # 0.15 W only
assert not m.clear_yes(dict(z(9, 9_000_000, 4.0), bat_w=6.0), dict(base, bat_w=6.1))             # battery decides
assert m.clear_yes(dict(z(9, 9_000_000, 4.6), bat_w=5.8), dict(base, bat_w=6.1))
assert m.hold_bat_w([(0, 9.0), (7.9, 9.0), (8, 6.0), (20, 7.0)], 30) == 6.5                      # the gauge's lag left out
assert m.hold_bat_w([(0, 9.0), (1, 7.0)], 2) == 8.0 and m.hold_bat_w([(9, None)], 30) is None
assert m.verdict({"phases": [base, z(9, 0, 4.6), z(8, 0, 4.6)]})[1] == "NO"
assert m.verdict({"phases": [base, z(9, 0, 4.6), z(8, 0, 4.6, valid=False)]})[1] == "INCOMPLETE"
r = {"phases": [base, dict(z(9, 0, 4.6), sent={"v": 9, "err": "EIO Input/output error", "ret": None}, skipped="refused",
                           valid=False), z(8, 0, 4.6)]}
assert m.verdict(r)[1] == "INCOMPLETE" and "refused" in m.verdict(r)[0], m.verdict(r)
assert m.key_verdict({"events": [[0.5, 42, 1], [0.6, 42, 0]], "woke_s": 0.4})[0] == "kept"
assert m.key_verdict({"events": [[0.5, 42, 0]], "woke_s": 0.4})[0] == "lost"
assert m.key_verdict({"events": [], "woke_s": 0.4})[0] == "lost"
assert m.key_verdict({"events": [], "woke_s": None, "window": 45})[0] == "not checked"
print("helpers ok")
EOF
)
[[ $out == "helpers ok" ]] && ok "helpers" || bad "helpers: $out"
python3 -I "$KIT" --bogus >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "bad usage exits 2" || bad "bad usage exit $rc"
python3 -I "$KIT" --phase-secs 2 >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "--phase-secs without --dry-run exits 2" || bad "--phase-secs exit $rc"
exit $fail
