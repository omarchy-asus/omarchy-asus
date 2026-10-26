#!/bin/bash
# recipes/linux-omarchy/g16-test/psp-rpm, the patch 9906-9908 PSP runtime D3hot and display
# idle test (#249), offline:
#   1. --dry-run: simulated readings, no root; a BIT 16 IDLE report (in d, not in e) with the
#      five phases, the suspend wait, the screen-off checks, Idle optimization, the version
#      and TPM checks, the wakers and 9908's idle trace
#   2. parsing 9906's psp_rpm_debug lines (suspends, resumes, wakers with and without a
#      module tag, resumes not for a ccp command), 9908's dm_idle_trace and re-allow lines,
#      9907's smu_metrics_runtime; the verdicts: kernel-log errors, a panel left off, a wrong
#      version read or a failed TPM read are FAIL; a problem, the charger or a screen-off
#      phase not verified off is INCOMPLETE; a PSP that never suspended is NOT SUSPENDED, one
#      kept awake is PSP KEPT AWAKE; bit 16 busy with display idle held is NO EFFECT, without
#      it NO DISPLAY IDLE
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
grep -qF '## PSP runtime D3hot on the G16: BIT 16 IDLE with the PSP in runtime D3hot, in d; with the PSP back in D0 (e): not idle, so it needs the PSP in D3hot (#249)' <<<"$out" \
    && ok "simulated run is BIT 16 IDLE in d, not e" || bad "heading: $out"
[[ $(grep -cE '^\| [a-e] \| ' <<<"$out") == 5 ]] && ok "one row per phase" || bad "rows: $out"
grep -qx -- '- runtime_status=suspended: after 2.1 s, power_state D3hot' <<<"$out" && ok "suspend wait" || bad "wait: $out"
grep -qx -- '- screen-off cells verified off: all' <<<"$out" && ok "screen-off verification" || bad "screen: $out"
grep -qx -- '- display idle kept in d (Idle optimization 1 in most reads): yes' <<<"$out" && ok "display idle in d" || bad "idle opt: $out"
grep -qE '^\| d \| .* \| yes \| 100% \| .* \| 1 -> 1 \(100%\) \|' <<<"$out" && ok "d row: verified, suspended, Idle optimization" || bad "d row: $out"
grep -q '^- `bootloader_version` read with the PSP suspended: 00.2d.00.6a (same as in D0)' <<<"$out" \
    && ok "version read" || bad "version: $out"
grep -q '^- fTPM PCR read with the PSP suspended: ok, ' <<<"$out" && ok "TPM read" || bad "tpm: $out"
grep -qx 'Who woke the PSP (psp_rpm_debug): bootloader_version_show (python3) x1' <<<"$out" && ok "waker list" || bad "wakers: $out"
grep -qF 'Display idle trace, d (dm_idle_trace): 1 allows, 0 disallows, 1 re-allows' <<<"$out" && ok "trace summary" || bad "trace: $out"
grep -q '^dm_idle_trace: disallow by amdgpu_dm_commit_streams -> allowed=0; ' <<<"$out" && ok "trace lines in the report" || bad "trace lines: $out"
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
tr = m.trace_summary(["amdgpu 0000:65:00.0: [drm] dm_idle_trace: disallow by dm_read_reg_func -> allowed=0; x",
                      "amdgpu 0000:65:00.0: [drm] dm_idle_trace: allow by dm_idle_all_off_worker -> allowed=1; y",
                      "amdgpu 0000:65:00.0: [drm] dm_idle_trace: disallow by dm_read_reg_func -> allowed=0; z",
                      "amdgpu 0000:65:00.0: [drm] dm_idle_all_off: idle re-allowed #3 (allowed=1)"])
print("trace", tr["allow"], tr["disallow"], tr["reallows"], json.dumps(tr["by"], sort_keys=True), tr["lines"][0][:30])
hw = m.SimHw()
base = {"phases": [], "problems": [], "errors": [], "address": "0000:65:00.2"}
base.update(m.run(hw, lambda s: None, True))
base = m.normalize(json.loads(json.dumps(base)))
def v(r):
    return m.verdict(m.normalize(json.loads(json.dumps(r))))[0]
def ph(r, n):
    return next(p for p in r["phases"] if p["phase"] == n)
print("base", v(base))
r = copy.deepcopy(base); r["errors"] = ["tee: command 0x5 timed out, disabling PSP"]; print("klog", v(r))
r = copy.deepcopy(base); r["panel_restore"] = False; print("panel", v(r))
r = copy.deepcopy(base); r["checks"]["version"]["value"] = "ff.ff.ff.ff"; print("version", v(r))
r = copy.deepcopy(base); r["checks"]["tpm"]["ok"] = False; print("tpm", v(r))
r = copy.deepcopy(base); r["checks"]["tpm"]["ok"] = None; print("notpm", v(r))
r = copy.deepcopy(base); r["problems"] = ["interrupted"]; print("problem", v(r))
r = copy.deepcopy(base); ph(r, "c")["status"] = ["Charging"]; print("charger", v(r))
r = copy.deepcopy(base); ph(r, "d")["screen_ok"] = False; print("screen", v(r))
text, _ = m.report(r, "k", False); print("screentext", "**INVALID: d**" in text)
r = copy.deepcopy(base); r["screen"]["off2"] = False; print("off2", v(r))
r = copy.deepcopy(base); r["reached"]["ok"] = False; r["phases"] = r["phases"][:1]; r["checks"] = {}; print("nosus", v(r))
text, _ = m.report(r, "k", False); print("nosustext", "**not reached**" in text)
r = copy.deepcopy(base); ph(r, "c")["suspended_share"] = 0.3; print("awake", v(r))
r = copy.deepcopy(base); ph(r, "e")["suspended_share"] = 0.0; print("e-in-d0", v(r))
r = copy.deepcopy(base); ph(r, "d")["idle"][16] = 0.2; print("noeffect", v(r))
r = copy.deepcopy(base); ph(r, "d")["idle"][16] = 0.2; ph(r, "d")["idleopt_share"] = 0.1; print("nodisplay", v(r))
r = copy.deepcopy(base); ph(r, "e")["idle"][16] = 0.9; f = m.verdict(r)[1]; print("both", m.where16(f))
r = copy.deepcopy(base); r["phases"] = []; print("empty", v(r))
met = m.parse_metrics("Dump data (0x8): ok 0\ntable_version: 3\ntimein_s0i2: 4500\nactive_ips: 0x1ff\n"
                     "idx name active timecondition_notmet_lastcapture timecondition_notmet_totaltime\n 0 DISPLAY  1 5 9\n")
print("metrics", met["dump"], met["timein_s0i2"], met["active_ips"], m.smu_cell(met))
print("rejected", m.smu_cell(m.parse_metrics("Dump data (0x8): rejected, table not refreshed: -5\ntimein_s0i2: 0\n")))
print("nometrics", m.parse_metrics(""), m.smu_cell(None))
EOF
)
for want in 'events 1 4 {"handle_invoke_cmd (pmf)": 2, "not a ccp command (kworker/3:1)": 1, "tee_version_show (cat)": 1}' \
    'trace 1 2 1 {"allow by dm_idle_all_off_worker": 1, "disallow by dm_read_reg_func": 2} dm_idle_trace: disallow by dm_' \
    "base BIT 16 IDLE" "klog FAIL" "panel FAIL" "version FAIL" "tpm FAIL" "notpm BIT 16 IDLE" \
    "problem INCOMPLETE" "charger INCOMPLETE" "screen INCOMPLETE" "screentext True" "off2 INCOMPLETE" \
    "nosus NOT SUSPENDED" "nosustext True" "awake PSP KEPT AWAKE" "e-in-d0 BIT 16 IDLE" \
    "noeffect NO EFFECT" "nodisplay NO DISPLAY IDLE" "both in d; with the PSP back in D0 (e): idle too, so display idle alone does it" \
    "empty INCOMPLETE" "metrics ok 0 4500 511 4500" "rejected dump rejected, table not refreshed: -5" "nometrics None -"; do
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
