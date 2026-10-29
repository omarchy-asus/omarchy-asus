#!/bin/bash
# recipes/linux-omarchy/g16-test/dm-idle-all-off, the patch 9902/9903 test (#353), offline:
#   1. --dry-run: simulated readings, no root; phases a-d, a CONFIRMED report with the
#      per-phase table and the suspend stage table
#   2. the verdicts: a kernel-log error or a panel that stays off (after a phase, the
#      suspend or the restore) is FAIL; bits 5/20 not idle is NO EFFECT; bit 16 still not
#      idle is PASS (not CONFIRMED); a missing phase, the charger or a failed suspend is
#      INCOMPLETE; the bit keys survive the root stage's JSON
#   3. the stage lines parse out of a kernel log, and the first stage with bit 16 idle
#   4. the watchdog: with the kit gone it turns both parameters to 0, pm_debug_messages
#      back and the screen on; after a clean finish it changes nothing
#   5. bad usage exits 2
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
KIT=$W/recipes/linux-omarchy/g16-test/dm-idle-all-off
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

echo "== 1. dry run"
out=$(TMPDIR=$T python3 -I "$KIT" --dry-run --measure 10 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -q '^## dm_idle_all_off on the G16: PASS, root cause confirmed' <<<"$out" && ok "simulated run is CONFIRMED" || bad "no CONFIRMED heading: $out"
[[ $(grep -oE '^phase [a-d]' <<<"$out" | sort -u | tr -d '\n') == "phase aphase bphase cphase d" ]] &&
    ok "phases a-d run" || bad "phases: $out"
[[ $(grep -c '^| [abc] |' <<<"$out") == 3 ]] && ok "one table row per measured phase" || bad "rows: $out"
[[ $(grep -cE '^\| (amdgpu-display|amdgpu-ip|prepare|os-hint|s0i3) \| 0x' <<<"$out") == 5 ]] &&
    ok "one row per suspend stage" || bad "stage rows: $out"
grep -q 'first suspend stage with bit 16 idle: os-hint' <<<"$out" && ok "first stage with bit 16 idle" || bad "stage16: $out"
compgen -G "$T/omarchy-asus-g16-dm-idle-all-off-*.md" >/dev/null && ok "the report is written" || bad "no report in TMPDIR"

echo "== 2-4. verdicts, stage parsing, watchdog"
out=$(python3 -I -B - "$KIT" "$T" <<'EOF' 2>&1
import argparse, copy, importlib.machinery, importlib.util, json, os, sys
ld = importlib.machinery.SourceFileLoader("kit", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("kit", ld)); ld.exec_module(m)
a = argparse.Namespace(measure=10, dry_run=True)
ph, sus = m.run(m.SimHw(), a, lambda s: None, lambda v: True)
sus["stages"] = [[st, f"0x{x:08x}"] for st, x in m.parse_stages(sus.pop("lines"))]
base = {"phases": ph, "suspend": sus, "errors": [], "problems": []}
def v(r):
    return m.verdict(m.normalize(json.loads(json.dumps(r))))[0]
def ph_(r, n):
    return next(p for p in r["phases"] if p["phase"] == n)
r = copy.deepcopy(base); print("json", v(r))
r = copy.deepcopy(base); r["errors"] = ["amdgpu 0000:65:00.0: [drm] *ERROR* dmub timeout"]; print("klog", v(r))
r = copy.deepcopy(base); ph_(r, "b")["panel_back"] = False; print("panel", v(r))
r = copy.deepcopy(base); r["suspend"]["panel_back"] = False; print("resume-panel", v(r))
r = copy.deepcopy(base); r["panel_restore"] = False; r["problems"] = ["screen"]; print("restore", v(r))
r = copy.deepcopy(base); ph_(r, "b")["idle"] = {5: 0.0, 16: 0.0, 20: 0.0}; print("noeffect", v(r))
r = copy.deepcopy(base); ph_(r, "b")["idle"][16] = 0.0; print("pass", v(r))
r = copy.deepcopy(base); ph_(r, "b")["sock"] = ph_(r, "c")["sock"] + 0.1; print("nodrop", v(r))
r = copy.deepcopy(base); r["phases"] = [p for p in r["phases"] if p["phase"] != "c"]; print("nocontrol", v(r))
r = copy.deepcopy(base); ph_(r, "c")["status"] = ["Charging"]; print("charger", v(r))
r = copy.deepcopy(base); r["suspend"]["ok"] = False; print("nosuspend", v(r))
r = copy.deepcopy(base); r["suspend"] = None; print("nosleep", v(r))
log = ["[  12.3] amd_pmc: SMU idlemask amdgpu-display: 0xffce9add", "noise",
       "amd_pmc: SMU idlemask prepare: 0xffce9edd", "amd_pmc: SMU idlemask s0i3: 0xffff9efd"]
st = m.parse_stages(log)
print("stages", ",".join(s for s, _ in st), m.first_idle(st, 16))
print("notidle", m.not_idle(0xffff9efd))
# 4. watchdog, with sysfs writes and the screen faked
writes, screen = [], []
m.wr = lambda p, x: writes.append((os.path.basename(p), str(x))) or True
class D:
    def __init__(self, *x): pass
    def back_on(self): screen.append("on"); return True
m.Display = D
dead = os.fork()
if dead == 0:
    os._exit(0)
os.waitpid(dead, 0)
wa = argparse.Namespace(deadline=5, user="u", uid=1000, hypr="x", parent=dead, done=os.path.join(sys.argv[2], "done"), pm_debug="0")
m.watchdog(wa)
print("wd-dead", sorted(writes), screen)
writes.clear(); screen.clear()
open(wa.done, "w").close()
m.watchdog(wa)
print("wd-clean", writes, screen)
EOF
)
for want in "json CONFIRMED" "klog FAIL" "panel FAIL" "resume-panel FAIL" "restore FAIL" "noeffect NO EFFECT" \
    "pass PASS" "nodrop PASS" "nocontrol INCOMPLETE" "charger INCOMPLETE" "nosuspend INCOMPLETE" "nosleep INCOMPLETE" \
    "stages amdgpu-display,prepare,s0i3 s0i3" "notidle [1, 8, 13, 14]" \
    "wd-dead [('dcn35_s0i2', '0'), ('dm_idle_all_off', '0'), ('pm_debug_messages', '0')] ['on']" \
    "wd-clean [] []"; do
    grep -qxF "$want" <<<"$out" && ok "$want" || bad "want '$want': $out"
done

echo "== 5. usage"
python3 -I "$KIT" --measure 5 --dry-run >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "--measure 5 exits 2" || bad "--measure 5 exit $rc"
python3 -I "$KIT" --stage watchdog >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "a bare watchdog exits 2" || bad "bare watchdog exit $rc"
exit $fail
