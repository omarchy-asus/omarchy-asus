#!/bin/bash
# recipes/linux-omarchy/g16-test/idlemask-trace, the patch 9903/9904 suspend trace (#353), offline:
#   1. --dry-run: a simulated kernel log, no root; a TRACED report with one row per stage,
#      the _DSM calls not run, and the first stage where each display bit reads idle
#   2. parsing a kernel log: stage lines (hex and "not run"), the LPS0 _DSM transitions,
#      kernel-log errors; the verdicts: an error or a panel that stays off is FAIL; a failed
#      suspend, a problem or a kernel without 9904's stages is INCOMPLETE
#   3. bad usage exits 2
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
KIT=$W/recipes/linux-omarchy/g16-test/idlemask-trace
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

echo "== 1. dry run"
out=$(TMPDIR=$T python3 -I "$KIT" --dry-run 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -q '^## Idlemask through one s2idle on the G16: TRACED' <<<"$out" && ok "simulated run is TRACED" || bad "heading: $out"
[[ $(grep -cE '^\| [a-z0-9-]+ \| 0x[0-9a-f]{8} \|' <<<"$out") == 12 ]] && ok "one row per logged stage" || bad "rows: $out"
[[ $(grep -c '| not run (func ' <<<"$out") == 2 ]] && ok "the AMD-GUID calls show as not run" || bad "not run: $out"
grep -qx -- '- bit 16: dsm-screen-off' <<<"$out" && ok "first stage with bit 16 idle" || bad "bit 16: $out"
grep -q 'Stages not logged' <<<"$out" && bad "dry run misses a stage: $out" || ok "every stage logged"
grep -q '^LPS0 _DSM calls: screen off ok; lps0 ms entry ok; lps0 entry ok$' <<<"$out" && ok "_DSM transitions" || bad "dsm: $out"
compgen -G "$T/omarchy-asus-g16-idlemask-trace-*.md" >/dev/null && ok "the report is written" || bad "no report in TMPDIR"

echo "== 2. parsing and verdicts"
out=$(python3 -I -B - "$KIT" <<'EOF' 2>&1
import copy, importlib.machinery, importlib.util, json, sys
ld = importlib.machinery.SourceFileLoader("kit", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("kit", ld)); ld.exec_module(m)
log = "\n".join(["[  12.3] amd_pmc: SMU idlemask amdgpu-ip: 0xfdc09add", "noise",
                 "amd_pmc: SMU idlemask noirq: 0xfdc09add",
                 "SMU idlemask dsm-screen-off-amd: not run (func 4, mask -22)",
                 "ACPI: \\_SB_.PEP_: Failed to transitioned to state screen off",
                 "amd_pmc: SMU idlemask dsm-screen-off: 0xffdf9afd",
                 "amdgpu 0000:65:00.0: [drm] *ERROR* dmub timeout"])
c = m.collect(log)
print("stages", ";".join(f"{s}={x}" for s, x, _ in c["stages"]))
print("note", c["stages"][2][2])
print("dsm", c["dsm"])
print("errors", len(c["errors"]))
st = [(s, None if x is None else int(x, 16), n) for s, x, n in c["stages"]]
print("first16", m.first_idle(st, 16), m.first_idle(st, 21))
base = {"ok": True, "hw_sleep_us": 1, "panel_back": True, "problems": [], **m.collect(m.SIM_LOG)}
def v(r):
    return m.verdict(json.loads(json.dumps(r)))[0]
r = copy.deepcopy(base); print("json", v(r))
r = copy.deepcopy(base); r["errors"] = ["x"]; print("klog", v(r))
r = copy.deepcopy(base); r["panel_back"] = False; print("panel", v(r))
r = copy.deepcopy(base); r["panel_back"] = None; print("nopanel", v(r))
r = copy.deepcopy(base); r["ok"] = False; print("nosuspend", v(r))
r = copy.deepcopy(base); r["problems"] = ["interrupted"]; print("problem", v(r))
r = copy.deepcopy(base); r["stages"] = [x for x in r["stages"] if x[0] not in m.NEW]; print("no9904", v(r))
text, _ = m.report(r, "k", False)
print("lacks", "this kernel lacks patch 9904" in text)
r = copy.deepcopy(base); r["stages"] = []; text, vv = m.report(r, "k", False); print("empty", vv, "no `SMU idlemask" in text)
EOF
)
for want in "stages amdgpu-ip=0xfdc09add;noirq=0xfdc09add;dsm-screen-off-amd=None;dsm-screen-off=0xffdf9afd" \
    "note not run (func 4, mask -22)" "dsm [['screen off', False]]" "errors 1" "first16 dsm-screen-off None" \
    "json TRACED" "klog FAIL" "panel FAIL" "nopanel TRACED" "nosuspend INCOMPLETE" "problem INCOMPLETE" \
    "no9904 INCOMPLETE" "lacks True" "empty INCOMPLETE True"; do
    grep -qxF "$want" <<<"$out" && ok "$want" || bad "want '$want': $out"
done

echo "== 3. usage"
python3 -I "$KIT" --bogus >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "an unknown option exits 2" || bad "unknown option exit $rc"
python3 -I "$KIT" --stage root >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "a bare root stage exits 2" || bad "bare root stage exit $rc"
exit $fail
