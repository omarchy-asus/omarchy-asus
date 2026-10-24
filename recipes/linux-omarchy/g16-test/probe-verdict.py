#!/usr/bin/env python3
"""Verdict for one `test --resume-profile` step, from its CSV samples.

  probe-verdict.py CSV STEP  ->  "<verdict> <cells for the report table>"

Load decides (medians of the last 30 s of load): the quiet table holds Tctl
near 86 C at about 31-34 W; the balanced-like table #185 reported runs 94-95 C
at 39-50 W. Idle fans (medians of the last 30 s idle) count only when idle Tctl
is below the quiet curve's first real point (about 54 C): above it the quiet
table spins the fans too, e.g. after background work on resume.

quiet:   at most 35 W and peak below 90 C, with readable fans that are not
         spinning on a cool idle, and not power-capped (below);
lost:    at least 37 W, or peak at least 90 C, or fans spinning on a cool idle;
unclear: anything else: missing fan or power readings, 35-37 W, or a load held
         under 30 W (a low battery caps the APU at 25 W, where the quiet and
         balanced tables can't be told apart).
"""
import csv
import math
import statistics as st
import sys

FANS = ("fan1_rpm", "fan2_rpm", "fan3_rpm")
MIN_SAMPLES = 10  # of the last 30 s, per column
COOL_IDLE_C = 50  # below the quiet curve's first real point (54 C), fans should be off


def num(r, k):
    try:
        return float(r[k])
    except (KeyError, TypeError, ValueError):
        return None


def col(rs, k):
    return [v for v in (num(r, k) for r in rs) if v is not None]


def med(xs):
    return st.median(xs) if len(xs) >= MIN_SAMPLES else math.nan


def verdict(rows):
    idle = [r for r in rows if r["phase"] == "idle"][-30:]
    load = [r for r in rows if r["phase"] == "load"]
    tail = load[-30:]
    fans = [med(col(idle, k)) for k in FANS]
    w = med(col(tail, "apu_w"))
    peak = max(col(load, "tctl_c") or [math.nan])
    tctl = med(col(idle, "tctl_c"))
    mhz = st.median(col(tail, "mhz_avg") or [math.nan])
    # NaN compares false everywhere, so a missing reading never makes "quiet".
    cool_spin = tctl < COOL_IDLE_C and any(x > 0 for x in fans)
    fans_ok = all(x == 0 for x in fans) or (tctl >= COOL_IDLE_C and all(x >= 0 for x in fans))
    capped = w < 30
    if w >= 37 or peak >= 90 or cool_spin:
        v = "lost"
    elif w <= 35 and peak < 90 and fans_ok and not capped:
        v = "quiet"
    else:
        v = "unclear"
    prof = (rows[-1]["asus_wmi"] + "/" + rows[-1]["amd_pmf"]) if rows else "?"
    cells = [prof, "/".join(f"{x:.0f}" for x in fans), f"{tctl:.1f}", f"{peak:.1f}", f"{w:.1f}", f"{mhz:.0f}"]
    return v, cells


def main(path, step):
    with open(path, newline="") as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("step") == step]
    v, cells = verdict(rows)
    print(v, " | ".join(cells))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
