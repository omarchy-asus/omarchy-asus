#!/bin/bash
# recipes/linux-omarchy/g16-test/dcn35-s0i2-ab, the patch 9901 A/B (#353), offline:
#   1. --dry-run: simulated readings, no root; ABBA order, a PASS report with every phase
#   2. the verdicts: a kernel-log error or a panel that stays off is FAIL, bit 5 never
#      idle is NO EFFECT, a run without both arms is INCOMPLETE; the bit keys survive
#      the root stage's JSON
#   3. bad usage exits 2
set -u
W=$(cd "$(dirname "$0")/../.." && pwd)
AB=$W/recipes/linux-omarchy/g16-test/dcn35-s0i2-ab
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

echo "== 1. dry run"
out=$(TMPDIR=$T python3 -I "$AB" --dry-run --rounds 1 2>&1); rc=$?
((rc == 0)) && ok "dry run exits 0" || bad "dry run exit $rc: $out"
grep -q '^## dcn35_s0i2 A/B on the G16: PASS (#353)' <<<"$out" && ok "simulated run is a PASS" || bad "no PASS heading: $out"
[[ $(grep -oE '^phase [0-9]/4 param=[01]' <<<"$out" | sed 's/.*=//' | tr -d '\n') == 0110 ]] &&
    ok "phases run in ABBA order" || bad "phase order: $out"
[[ $(grep -c '^| [0-9] | [01] |' <<<"$out") == 4 ]] && ok "one table row per phase" || bad "rows: $out"
compgen -G "$T/omarchy-asus-g16-dcn35-s0i2-*.md" >/dev/null && ok "the report is written" || bad "no report in TMPDIR"

echo "== 2. verdicts"
out=$(python3 -I -B - "$AB" <<'EOF' 2>&1
import argparse, copy, importlib.machinery, importlib.util, json, sys
ld = importlib.machinery.SourceFileLoader("ab", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("ab", ld)); ld.exec_module(m)
a = argparse.Namespace(rounds=1, measure=30, dry_run=True)
base = {"param_at_start": 0, "phases": m.run(m.SimHw(), a, lambda s: None), "errors": [], "problems": []}
def v(r):
    return m.verdict(m.normalize(json.loads(json.dumps(r))))[0]
r = copy.deepcopy(base); print("json", v(r))
r = copy.deepcopy(base); r["errors"] = ["amdgpu 0000:65:00.0: [drm] *ERROR* dmub timeout"]; print("klog", v(r))
r = copy.deepcopy(base); r["phases"][1]["panel_back"] = False; print("panel", v(r))
r = copy.deepcopy(base)
for p in r["phases"]:
    p["idle"] = {5: 0.0, 20: 0.0}
print("noeffect", v(r))
r = copy.deepcopy(base); r["phases"] = [p for p in r["phases"] if p["param"] == 0]; print("onearm", v(r))
EOF
)
for want in "json PASS" "klog FAIL" "panel FAIL" "noeffect NO EFFECT" "onearm INCOMPLETE"; do
    grep -qx "$want" <<<"$out" && ok "$want" || bad "want '$want': $out"
done

echo "== 3. usage"
python3 -I "$AB" --rounds 9 --dry-run >/dev/null 2>&1; rc=$?
((rc == 2)) && ok "--rounds 9 exits 2" || bad "--rounds 9 exit $rc"
exit $fail
