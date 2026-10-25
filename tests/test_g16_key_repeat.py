#!/usr/bin/env python3
"""Offline tests for bin/g16-key-repeat (#350): the WAYLAND_DEBUG parse (libwayland 1.26's
clock stamps and the older millisecond ones), and the analysis on synthetic captures:
plain typing, a late release, fcitx5's repeat running away and stopping normally, fcitx5
repeating past the release, a key stuck without fcitx5, wtype's time-0 keys, the side
events listed with an anomaly, the report's scrub, and the command line's exit codes.

  python3 -I tests/test_g16_key_repeat.py
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "g16-key-repeat")


def load():
    loader = importlib.machinery.SourceFileLoader("g16_key_repeat", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


K = load()
T0 = 1792961500.0
A, B, C = 30, 48, 46


class Wire:
    """Builds wire.log lines: our stamp, then libwayland's line for wl_keyboard#40."""

    def __init__(self, old=False):
        self.lines, self.serial, self.old = [], 10, old
        self.ev(0.0, "repeat_info(40, 250)")
        self.ev(0.0, "enter(11, wl_surface#3, array[0])")

    def ev(self, t, what):
        self.serial += 1
        stamp = f"[{int((T0 + t) * 1000) % 10000000:7d}.000]" if self.old else "[20:52:11.560110] {Default Queue}"
        obj = "wl_keyboard@40" if self.old else "wl_keyboard#40"
        self.lines.append(f"{T0 + t:.6f} {stamp} {obj}.{what}")
        return self

    def key(self, t, wt, code, state):
        return self.ev(t, f"key({self.serial}, {wt}, {code}, {state})")

    def tap(self, t, code, hold=0.08, wt=None):
        wt = int(t * 1000) + 5000 if wt is None else wt
        return self.key(t, wt, code, 1).key(t + hold, wt + int(hold * 1000), code, 0)

    def fcitx_repeats(self, code, wt, start, stop, every=0.025):
        t = start
        while t < stop:
            self.key(t, wt, code, 0).key(t + 0.0005, wt, code, 1)
            t += every
        return self

    def run(self, side=()):
        return K.analyze(K.parse_wire(self.lines), K.parse_side([f"{T0 + t:.6f} {x}" for t, x in side]))


def kinds(r):
    return [a["kind"] for a in r["anomalies"]]


class Parse(unittest.TestCase):
    def test_both_stamp_formats(self):
        for old in (False, True):
            w = Wire(old).tap(1.0, A)
            ev = K.parse_wire(w.lines)
            self.assertEqual([e[3] for e in ev], ["repeat_info", "enter", "key", "key"], old)
            self.assertEqual(ev[2][4], ["12", "6000", "30", "1"])

    def test_requests_dropped(self):
        ev = K.parse_wire([f"{T0} [20:52:11.559934] {{Default Queue}}  -> wl_seat#19.get_keyboard(new id wl_keyboard#40)"])
        self.assertEqual(ev, [])

    def test_keep_filter(self):
        self.assertTrue(K.KEEP.search("[1.0] {Default Queue} wl_keyboard#40.key(1, 2, 3, 1)"))
        self.assertTrue(K.KEEP.search("[1.0] wl_registry@2.global_remove(31)"))
        self.assertFalse(K.KEEP.search("[1.0] {Default Queue} wl_surface#3.frame(new id wl_callback#9)"))


class Analyze(unittest.TestCase):
    def test_plain_typing(self):
        w = Wire()
        for i in range(30):
            w.tap(1 + i * 0.12, (A, B, C)[i % 3])
        r = w.run()
        self.assertEqual(r["anomalies"], [])
        self.assertTrue(r["verdict"].startswith("nothing seen"))
        self.assertEqual(r["keys"], 3)

    def test_late_release(self):
        # held 100 ms by the hardware's clock, the release reached the window 800 ms after the press
        w = Wire().key(1.0, 6000, A, 1).key(1.8, 6100, A, 0)
        r = w.run(side=[(1.05, "hyprland monitorremoved>>HDMI-A-1")])
        self.assertEqual(kinds(r), ["late release"])
        an = r["anomalies"][0]
        self.assertEqual(an["late_ms"], 700)
        self.assertEqual(an["extra_repeats"], 22)
        self.assertIn("monitorremoved", an["near"][0])
        self.assertTrue(r["verdict"].startswith("late release"))

    def test_held_key_is_not_late(self):
        r = Wire().key(1.0, 6000, A, 1).key(2.0, 7000, A, 0).run()
        self.assertEqual(r["anomalies"], [])

    def test_fcitx_runaway_until_another_key(self):
        # A is tapped, fcitx5 never sees its release and repeats it until B is typed
        w = Wire().key(1.0, 6000, A, 1).fcitx_repeats(A, 6000, 1.247, 4.0)
        w.tap(4.0, B).tap(4.3, C)
        r = w.run(side=[(1.1, "udev UDEV  [1.1] change   /devices/LNXSYSTM:00/ACPI0003:00/power_supply/ACAD (power_supply)")])
        self.assertEqual(kinds(r), ["ime repeat"])
        an = r["anomalies"][0]
        self.assertEqual(an["ended"], "never released")
        self.assertGreater(an["repeats"], 100)
        self.assertEqual(an["others_typed"], 2)
        self.assertIn("power_supply", an["near"][0])
        self.assertTrue(r["verdict"].startswith("lost release at fcitx5"))
        self.assertGreater(r["stats"]["ime_repeats"], 100)

    def test_fcitx_repeat_with_its_release(self):
        # held for a second: fcitx5 repeats, then the real release (a later time) stops it
        w = Wire().key(1.0, 6000, A, 1).fcitx_repeats(A, 6000, 1.247, 2.0).key(2.0, 7000, A, 0)
        r = w.run()
        self.assertEqual(r["anomalies"], [])
        self.assertEqual(r["stats"]["ime_repeats"], 31)

    def test_fcitx_repeat_past_release(self):
        # released after 300 ms (hardware), but the release arrived at 1.0 s: fcitx5 kept repeating
        w = Wire().key(1.0, 6000, A, 1).fcitx_repeats(A, 6000, 1.247, 2.0).key(2.0, 6300, A, 0)
        r = w.run()
        self.assertEqual(kinds(r), ["ime repeat past release"])
        self.assertGreater(r["anomalies"][0]["repeats_after_release"], 15)
        self.assertTrue(r["verdict"].startswith("late release"))

    def test_fcitx_repeat_cut_by_leave(self):
        w = Wire().key(1.0, 6000, A, 1).fcitx_repeats(A, 6000, 1.247, 1.5).ev(1.5, "leave(90, wl_surface#3)")
        r = w.run()
        self.assertEqual(kinds(r), ["ime repeat"])
        self.assertEqual(r["anomalies"][0]["ended"], "keyboard leave")

    def test_stuck_without_fcitx(self):
        # A's release is lost; the next A (pressed 5 s later) only delivers a release
        w = Wire().key(1.0, 6000, A, 1)
        for i in range(10):
            w.tap(1.5 + i * 0.3, B if i % 2 else C)
        w.key(6.0, 11000, A, 0)
        r = w.run()
        self.assertEqual(kinds(r), ["stuck"])
        self.assertEqual(r["anomalies"][0]["others_typed"], 10)
        self.assertTrue(r["verdict"].startswith("lost release on the way"))

    def test_stuck_never_released(self):
        w = Wire().key(1.0, 6000, A, 1)
        for i in range(10):
            w.tap(1.5 + i * 0.3, B)
        r = w.run()
        self.assertEqual(kinds(r), ["stuck"])
        self.assertEqual(r["anomalies"][0]["ended"], "never released")

    def test_wtype_time_zero(self):
        w = Wire()
        for i in range(6):
            w.tap(1 + i * 0.01, (A, B, C)[i % 3], hold=0.002, wt=0)
        r = w.run()
        self.assertEqual(r["anomalies"], [])
        self.assertEqual(r["stats"]["ime_repeats"], 0)
        self.assertEqual(r["stats"]["releases"], 6)


class Report(unittest.TestCase):
    def test_render_scrubs_and_numbers_keys(self):
        w = Wire().key(1.0, 6000, A, 1).key(1.8, 6100, A, 0)
        r = w.run(side=[(1.1, f"note {os.path.expanduser('~')}/x")])
        r["versions"] = "hyprland 0.56.2-4.103"
        text = K.render(r)
        self.assertIn("| late release |", text)
        self.assertIn("key=k1", text)
        self.assertNotIn(os.path.expanduser("~") + "/", text)
        self.assertNotIn("key=30", text)

    def test_analyze_dir_and_cli(self):
        with tempfile.TemporaryDirectory() as d:
            w = Wire().key(1.0, 6000, A, 1).key(1.8, 6100, A, 0)
            with open(os.path.join(d, "wire.log"), "w") as f:
                f.write("\n".join(w.lines) + "\n")
            with open(os.path.join(d, "side.log"), "w") as f:
                f.write(f"{T0 + 1.05:.6f} hyprland configreloaded>>\n")
            with open(os.path.join(d, "devices-before.json"), "w") as f:
                f.write('["asustek-n-key-device", "video-bus"]')
            with open(os.path.join(d, "devices-after.json"), "w") as f:
                f.write('["asustek-n-key-device"]')
            out = subprocess.run([sys.executable, "-I", SCRIPT, "analyze", d], capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("Keyboards: 2 before, 1 after; gone: video-bus", out.stdout)
            self.assertIn("configreloaded", out.stdout)
            js = subprocess.run([sys.executable, "-I", SCRIPT, "analyze", d, "--json"], capture_output=True, text=True)
            self.assertIn('"late release"', js.stdout)
            self.assertEqual(subprocess.run([sys.executable, "-I", SCRIPT, "analyze", os.path.join(d, "none")],
                                            capture_output=True).returncode, 1)
        self.assertEqual(subprocess.run([sys.executable, "-I", SCRIPT, "bogus"], capture_output=True).returncode, 2)
        self.assertEqual(subprocess.run([sys.executable, "-I", SCRIPT, "capture", "--minutes", "0"],
                                        capture_output=True).returncode, 2)


if __name__ == "__main__":
    unittest.main()
