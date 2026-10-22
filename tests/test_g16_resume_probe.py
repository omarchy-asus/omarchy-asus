#!/usr/bin/env python3
"""Offline tests for the g16-test kit's --resume-profile verdicts (#185).

  python3 -I tests/test_g16_resume_probe.py
"""
import csv
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
KIT = os.path.join(HERE, "..", "recipes", "linux-omarchy", "g16-test")
VERDICT = os.path.join(KIT, "probe-verdict.py")
HEADER = ["step", "t_s", "phase", "tctl_c", "apu_edge_c", "dgpu", "fan1_rpm", "fan2_rpm", "fan3_rpm",
          "apu_w", "batt_w", "mhz_avg", "mhz_max", "platform_profile", "asus_wmi", "amd_pmf"]


def step_rows(step, idle_tctl=45.0, idle_fans=(0, 0, 0), load_w=33.0, load_tctl=86.0):
    rows = []
    for t in range(180):
        idle = t < 120
        fans = idle_fans if idle else (2500, 2000, 4200)
        rows.append({
            "step": step, "t_s": t, "phase": "idle" if idle else "load",
            "tctl_c": idle_tctl if idle else load_tctl, "apu_edge_c": 45, "dgpu": "suspended",
            "fan1_rpm": fans[0], "fan2_rpm": fans[1], "fan3_rpm": fans[2],
            "apu_w": 5.0 if idle else load_w, "batt_w": "", "mhz_avg": 3150, "mhz_max": 3600,
            "platform_profile": "custom", "asus_wmi": "quiet", "amd_pmf": "balanced",
        })
    return rows


class Verdict(unittest.TestCase):
    def run_verdict(self, rows, step):
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="") as fh:
            w = csv.DictWriter(fh, HEADER, quoting=csv.QUOTE_MINIMAL)
            w.writeheader()
            w.writerows(rows)
        try:
            out = subprocess.run([sys.executable, "-I", VERDICT, fh.name, step],
                                 capture_output=True, text=True, check=True).stdout
        finally:
            os.unlink(fh.name)
        return out.split(" ", 1)[0]

    def test_quiet(self):
        self.assertEqual(self.run_verdict(step_rows("baseline"), "baseline"), "quiet")

    def test_lost_on_power(self):
        rows = step_rows("after hibernate 1", load_w=41.0, load_tctl=95.0)
        self.assertEqual(self.run_verdict(rows, "after hibernate 1"), "lost")

    def test_lost_on_cool_idle_spin(self):
        rows = step_rows("after hibernate 1", idle_tctl=45.0, idle_fans=(2100, 1900, 3800))
        self.assertEqual(self.run_verdict(rows, "after hibernate 1"), "lost")

    def test_hot_idle_spin_is_quiet(self):
        # The quiet curve spins the fans above ~54 C; a hot idle is not the table lost.
        rows = step_rows("after hibernate 2", idle_tctl=72.8, idle_fans=(2100, 1800, 3800))
        self.assertEqual(self.run_verdict(rows, "after hibernate 2"), "quiet")

    def test_missing_fans_is_unclear(self):
        rows = step_rows("after s2idle", idle_fans=("", "", ""))
        self.assertEqual(self.run_verdict(rows, "after s2idle"), "unclear")

    def test_power_capped_is_unclear(self):
        rows = step_rows("after s2idle", load_w=25.0, load_tctl=84.5)
        self.assertEqual(self.run_verdict(rows, "after s2idle"), "unclear")

    def test_label_with_comma_and_colon(self):
        step = "hibernate 2: quiet written again, then idle"
        self.assertEqual(self.run_verdict(step_rows(step), step), "quiet")

    def test_no_rows_is_unclear(self):
        self.assertEqual(self.run_verdict(step_rows("baseline"), "missing step"), "unclear")


class DownSeconds(unittest.TestCase):
    def down(self, *args):
        cmd = 'source "$1/lib.sh"; shift; down_seconds "$@"'
        return int(subprocess.run(["bash", "-c", cmd, "_", KIT, *map(str, args)],
                                  capture_output=True, text=True, check=True).stdout)

    def test_real_hibernate(self):
        # 66 s of wall time, 10 s of CLOCK_MONOTONIC: 56 s powered down
        self.assertEqual(self.down(1000, 500, 1066, 510), 56)

    def test_failed_hibernate(self):
        # clocks moved together: nothing slept
        self.assertEqual(self.down(1000, 500, 1012, 512), 0)

    def test_never_negative(self):
        self.assertEqual(self.down(1000, 500, 1001, 503), 0)


if __name__ == "__main__":
    unittest.main()
