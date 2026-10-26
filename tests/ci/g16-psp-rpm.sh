#!/bin/bash
# recipes/linux-omarchy/g16-test/psp-rpm, the patch 9906 PSP runtime D3hot test (#249), offline:
#   1. --dry-run: simulated readings, no root; a BIT 16 IDLE report (screen off only) with the
#      three phases, the suspend wait, the version and TPM checks, and the waker list
#   2. parsing 9906's psp_rpm_debug lines (suspends, resumes, wakers with and without a
#      module tag, resumes not for a ccp command); the verdicts: kernel-log errors, a panel
#      left off, a wrong version read or a failed TPM read are FAIL; a problem, the charger
#      or a screen that did not really go off (bit 10) is INCOMPLETE; a PSP that never
#      suspended is NOT SUSPENDED; bit 16 busy throughout is NO EFFECT
#   3. bad usage exits 2
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
KIT=$W/recipes/linux-omarchy/g16-test/psp-rpm
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

echo "== 1. dry run"
out=$(TMPDIR=$T python3 -I "$KIT" --dry-run 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -q '^## PSP runtime D3hot on the G16: BIT 16 IDLE with the PSP in runtime D3hot, with the screen off only (#249)$' <<<"$out" \
    && ok "simulated run is BIT 16 IDLE, screen off only" || bad "heading: $out"
[[ $(grep -cE '^\| [abc] \| ' <<<"$out") == 3 ]] && ok "one row per phase" || bad "rows: $out"
grep -qx -- '- runtime_status=suspended: after 2.1 s, power_state D3hot' <<<"$out" && ok "suspend wait" || bad "wait: $out"
grep -qx -- '- screen really off in (c) (bit 10 idle in most reads): yes' <<<"$out" && ok "bit 10 check" || bad "bit 10: $out"
grep -q '^- `bootloader_version` read with the PSP suspended: 00.2d.00.6a (same as in D0)' <<<"$out" \
    && ok "version read" || bad "version: $out"
grep -q '^- fTPM PCR read with the PSP suspended: ok, ' <<<"$out" && ok "TPM read" || bad "tpm: $out"
grep -qx 'Who woke the PSP (psp_rpm_debug): bootloader_version_show (python3) x1' <<<"$out" && ok "waker list" || bad "wakers: $out"
grep -q '^Before: power/control on, psp_rpm_delay_ms 0, psp_rpm_debug N, active. After: on, 0, N, active.$' <<<"$out" \
    && ok "before and after" || bad "restore line: $out"
compgen -G "$T/omarchy-asus-g16-psp-rpm-*.md" >/dev/null && ok "the report is written" || bad "no report in TMPDIR"

echo "== 2. parsing and verdicts"
out=$(python3 -I -B - "$KIT" <<'EOF' 2>&1
import copy, importlib.machinery, importlib.util, json, sys
ld = importlib.machinery.SourceFileLoader("kit", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("kit", ld)); ld.exec_module(m)
ev = m.rpm_events(["ccp 0000:65:00.2: psp rpm: runtime suspend #4", "noise",
                   "ccp 0000:65:00.2: psp rpm: runtime resume #4 for handle_invoke_cmd+0x5a/0x120 [amdtee] (pmf)",
                   "ccp 0000:65:00.2: psp rpm: runtime resume #5 for tee_version_show+0x2c/0x90 (cat)",
                   "ccp 0000:65:00.2: psp rpm: runtime resume #6, not for a ccp command (kworker/3:1)",
                   "ccp 0000:65:00.2: psp rpm: runtime resume #7 for handle_invoke_cmd+0x5a/0x120 [amdtee] (pmf)"])
print("events", ev["suspends"], ev["resumes"], json.dumps(ev["wakers"], sort_keys=True))
hw = m.SimHw()
base = {"phases": [], "problems": [], "errors": [], "address": "0000:65:00.2"}
base.update(m.run(hw, lambda s: None, True))
base = m.normalize(json.loads(json.dumps(base)))
def v(r):
    return m.verdict(m.normalize(json.loads(json.dumps(r))))[0]
print("base", v(base))
r = copy.deepcopy(base); r["errors"] = ["tee: command 0x5 timed out, disabling PSP"]; print("klog", v(r))
r = copy.deepcopy(base); r["phases"][1]["panel_back"] = False; print("panel", v(r))
r = copy.deepcopy(base); r["checks"]["version"]["value"] = "ff.ff.ff.ff"; print("version", v(r))
r = copy.deepcopy(base); r["checks"]["tpm"]["ok"] = False; print("tpm", v(r))
r = copy.deepcopy(base); r["checks"]["tpm"]["ok"] = None; print("notpm", v(r))
r = copy.deepcopy(base); r["problems"] = ["interrupted"]; print("problem", v(r))
r = copy.deepcopy(base); r["phases"][2]["status"] = ["Charging"]; print("charger", v(r))
r = copy.deepcopy(base); r["phases"][2]["idle"][10] = 0.1; print("screen", v(r))
r = copy.deepcopy(base); r["reached"]["ok"] = False; r["phases"] = r["phases"][:1]; r["checks"] = {}; print("nosus", v(r))
text, _ = m.report(r, "k", False); print("nosustext", "**not reached**" in text)
r = copy.deepcopy(base); r["phases"][2]["idle"][16] = 0.2; print("noeffect", v(r))
r = copy.deepcopy(base); r["phases"][1]["idle"][16] = 0.9; f = m.verdict(r)[1]; print("both", m.where16(f))
r = copy.deepcopy(base); r["phases"] = []; print("empty", v(r))
EOF
)
for want in 'events 1 4 {"handle_invoke_cmd (pmf)": 2, "not a ccp command (kworker/3:1)": 1, "tee_version_show (cat)": 1}' \
    "base BIT 16 IDLE" "klog FAIL" "panel FAIL" "version FAIL" "tpm FAIL" "notpm BIT 16 IDLE" \
    "problem INCOMPLETE" "charger INCOMPLETE" "screen INCOMPLETE" "nosus NOT SUSPENDED" "nosustext True" \
    "noeffect NO EFFECT" "both with the screen on and off" "empty INCOMPLETE"; do
    grep -qxF "$want" <<<"$out" && ok "$want" || bad "want '$want': $out"
done

echo "== 3. usage"
python3 -I "$KIT" --bogus >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "an unknown option exits 2" || bad "unknown option exit $rc"
python3 -I "$KIT" --stage root >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "a bare root stage exits 2" || bad "bare root stage exit $rc"
python3 -I "$KIT" --stage watchdog >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "a bare watchdog exits 2" || bad "bare watchdog exit $rc"
exit $fail
