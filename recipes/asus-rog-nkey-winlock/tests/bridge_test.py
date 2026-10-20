#!/usr/bin/python3 -I
"""bridge/g16_bridge.py end to end, headless: two private dbus-daemons (one
standing in for the system bus) with fake asusd, UPower and systemd
(tests/fake_services.py), a fake Hyprland on its two IPC sockets, a fake
sysfs tree and a temp HOME. The real bridge runs as the shell would start it.

Run: tests/bridge_test.py   (needs dbus-daemon and python-gobject)
"""
import json
import os
import queue
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "g16_bridge.py")
FAKES = os.path.join(HERE, "fake_services.py")
AURA = "/xyz/ljones/aura/19b6_3_4"
OVERDRIVE = "/xyz/ljones/asus_armoury/panel_overdrive"

CONF = """# test
INTERNAL_OUTPUT=eDP-1
HZ_AC=240
HZ_BATTERY=60
HZ_GAMING=165
KBD_AC=med
KBD_BATTERY=off
PANEL_OVERDRIVE_AC=1
PANEL_OVERDRIVE_BATTERY=0
"""


class FakeHyprland:
    """.socket.sock answers j/monitors and records /eval modesets (which
    change the rate); .socket2.sock pushes events to every listener."""

    def __init__(self, d):
        self.dir = d
        os.makedirs(d)
        self.hz = 60
        self.evals = []
        self.listeners = []
        self.lock = threading.Lock()
        self.req = self._server(".socket.sock", self._request)
        self.ev = self._server(".socket2.sock", self._listener)

    def _server(self, name, handler):
        s = socket.socket(socket.AF_UNIX)
        s.bind(os.path.join(self.dir, name))
        s.listen(8)

        def loop():
            while True:
                try:
                    c, _ = s.accept()
                except OSError:
                    return
                handler(c)
        threading.Thread(target=loop, daemon=True).start()
        return s

    def _request(self, c):
        data = c.recv(65536).decode()
        with self.lock:
            if data == "j/monitors":
                out = json.dumps([
                    {"name": "eDP-1", "description": "Samsung Display Corp. ATNA60DL04-0",
                     "width": 2560, "height": 1600, "x": 0, "y": 0, "scale": 1.6,
                     "refreshRate": float(self.hz), "currentFormat": "XRGB2101010"},
                    {"name": "HDMI-A-1", "description": "Monitor", "width": 2560, "height": 1440,
                     "x": 1600, "y": 0, "scale": 1.0, "refreshRate": 144.0, "currentFormat": "XRGB8888"}])
            elif data.startswith("/eval "):
                self.evals.append(data[6:])
                m = re.search(r'output = "eDP-1", mode = "2560x1600@(\d+)"', data)
                if m:
                    self.hz = int(m.group(1))
                out = "ok"
            else:
                out = "unknown request"
        c.sendall(out.encode())
        c.close()

    def _listener(self, c):
        with self.lock:
            self.listeners.append(c)

    def event(self, line, hz=None):
        with self.lock:
            if hz is not None:
                self.hz = hz
            for c in self.listeners:
                c.sendall((line + "\n").encode())

    def close(self):
        self.req.close()
        self.ev.close()


class Harness:
    def __init__(self, conf=CONF, asusd=True, on_battery=False):
        self.tmp = tempfile.mkdtemp(prefix="g16b-")
        t = self.tmp
        self.home = os.path.join(t, "home")
        self.run_dir = os.path.join(t, "run")
        self.sys = os.path.join(t, "sys")
        for d in (self.home, self.run_dir, os.path.join(self.sys, "class", "power_supply", "BAT0"),
                  os.path.join(self.sys, "class", "leds", "asus::kbd_backlight")):
            os.makedirs(d)
        with open(os.path.join(self.sys, "class", "power_supply", "BAT0", "charge_control_end_threshold"), "w") as f:
            f.write("80\n")
        self.led = os.path.join(self.sys, "class", "leds", "asus::kbd_backlight", "brightness_hw_changed")
        with open(self.led, "w") as f:
            f.write("1\n")
        self.conf = os.path.join(self.home, ".config", "omarchy", "power-tune.conf")
        self.state_dir = os.path.join(self.home, ".local", "state", "omarchy")
        if conf is not None:
            os.makedirs(os.path.dirname(self.conf))
            with open(self.conf, "w") as f:
                f.write(conf)
        self.winlock = os.path.join(t, "g16-winlock")
        with open(self.winlock, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(self.winlock, 0o755)
        self.log = os.path.join(t, "fake.log")
        open(self.log, "w").close()
        self.daemons = []
        self.sysbus = self._bus("system.bus")
        self.sesbus = self._bus("session.bus")
        self.hypr = FakeHyprland(os.path.join(self.run_dir, "hypr", "SIG"))
        base = {"PATH": "/usr/bin:/bin", "HOME": self.home, "LANG": "C.UTF-8",
                "DBUS_SYSTEM_BUS_ADDRESS": self.sysbus, "DBUS_SESSION_BUS_ADDRESS": self.sesbus}
        fenv = dict(base, FAKE_LOG=self.log, FAKE_NO_ASUSD="0" if asusd else "1")
        self.fakes = subprocess.Popen([sys.executable, "-I", FAKES], env=fenv, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, text=True)
        assert self.fakes.stdout.readline().strip() == "ready"
        if on_battery:
            self.fake({"set": ["/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", "b", True]})
        self.env = dict(base, XDG_RUNTIME_DIR=self.run_dir, HYPRLAND_INSTANCE_SIGNATURE="SIG",
                        G16_BRIDGE_SYSROOT=self.sys, G16_BRIDGE_WINLOCK=self.winlock)
        self.out = queue.Queue()
        self.states = []
        self.replies = {}
        self.next_id = 1
        self.err = open(os.path.join(t, "bridge.err"), "w")
        self.bridge = subprocess.Popen([sys.executable, "-I", "-B", BRIDGE], env=self.env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=self.err, text=True)
        threading.Thread(target=self._read, daemon=True).start()

    def _bus(self, name):
        addr = "unix:path=" + os.path.join(self.tmp, name)
        p = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--address=" + addr,
                              "--print-address=1"], stdout=subprocess.PIPE, text=True)
        p.stdout.readline()
        self.daemons.append(p)
        return addr

    def _read(self):
        for line in self.bridge.stdout:
            self.out.put(json.loads(line))
        self.out.put(None)

    def pump(self, timeout):
        try:
            msg = self.out.get(timeout=timeout)
        except queue.Empty:
            return False
        if msg is None:
            return False
        if msg["type"] == "state":
            self.states.append(msg)
        elif msg["type"] == "reply":
            self.replies[msg["id"]] = msg
        return True

    def wait(self, pred, timeout=8.0, what="condition"):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return
            self.pump(min(0.2, max(0.01, end - time.time())))
        if pred():
            return
        raise AssertionError(f"timed out waiting for {what}; last state: {self.states[-1] if self.states else None}\n"
                             f"log: {self.calls()}\nstderr: {open(os.path.join(self.tmp, 'bridge.err')).read()[-2000:]}")

    @property
    def state(self):
        return self.states[-1] if self.states else {}

    def send(self, cmd, *args):
        cid = self.next_id
        self.next_id += 1
        self.bridge.stdin.write(json.dumps({"id": cid, "cmd": cmd, "args": list(args)}) + "\n")
        self.bridge.stdin.flush()
        self.wait(lambda: cid in self.replies, what=f"reply to {cmd}")
        self.wait(lambda: self.state.get("ack", 0) >= cid, what=f"state with ack {cid}")
        return self.replies[cid]

    def fake(self, msg):
        self.fakes.stdin.write(json.dumps(msg) + "\n")
        self.fakes.stdin.flush()
        assert self.fakes.stdout.readline().strip() == "done"

    def calls(self):
        with open(self.log) as f:
            return [json.loads(x) for x in f if x.strip()]

    def sets(self, prop):
        return [c["set"] for c in self.calls() if "set" in c and c["set"][2] == prop]

    def close(self):
        for p in (self.bridge, self.fakes):
            if p.poll() is None:
                p.stdin.close()
                try:
                    p.wait(5)
                except subprocess.TimeoutExpired:
                    p.kill()
        for p in self.daemons:
            p.terminate()
            p.wait()
            p.stdout.close()
        for p in (self.bridge, self.fakes):
            p.stdout.close()
        self.err.close()
        self.hypr.close()
        shutil.rmtree(self.tmp, ignore_errors=True)


class BridgeTest(unittest.TestCase):
    def harness(self, **kw):
        h = Harness(**kw)
        self.addCleanup(h.close)
        return h

    def test_start_on_ac_applies_the_ac_settings_once(self):
        h = self.harness()
        h.wait(lambda: h.state.get("hasAura") and h.state.get("refreshHz") == 240, what="AC applied")
        self.assertEqual([s[4] for s in h.sets("Brightness") if s[1] == "xyz.ljones.Aura"], [2])
        self.assertEqual([s[4] for s in h.sets("CurrentValue")], [1])
        self.assertEqual(len(h.hypr.evals), 1)
        self.assertIn('mode = "2560x1600@240", position = "0x0", scale = 1.6, bitdepth = 10', h.hypr.evals[0])
        s = h.state
        self.assertEqual((s["kbdAC"], s["kbdBattery"], s["chargeLimit"], s["slashPattern"]), ("med", "off", 80, 2))
        self.assertEqual((s["kbdColor"], s["kbdSleep"], s["showOnBoot"], s["hasOverdrive"]), ("00FF88", False, True, True))
        self.assertEqual((s["winlockService"], s["hasWinlock"], s["refreshOverride"]), ("active", True, "auto"))

    def test_unplug_applies_battery_settings_and_replug_ac(self):
        h = self.harness()
        h.wait(lambda: h.state.get("refreshHz") == 240, what="AC applied")
        h.fake({"set": ["/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", "b", True]})
        h.wait(lambda: h.state.get("onBattery") and h.state.get("refreshHz") == 60, what="battery applied")
        h.wait(lambda: h.state.get("kbdBrightness") == 0, what="keyboard off")
        self.assertEqual([s[4] for s in h.sets("CurrentValue")], [1, 0])
        h.fake({"set": ["/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", "b", False]})
        h.wait(lambda: h.state.get("refreshHz") == 240 and h.state.get("kbdBrightness") == 2, what="AC again")
        self.assertEqual(len(h.hypr.evals), 3)

    def test_hyprland_reload_reapplies_the_refresh_rate(self):
        h = self.harness(on_battery=True)
        h.wait(lambda: h.state.get("refreshHz") == 60 and h.state.get("hasAura"), what="battery applied")
        n = len(h.hypr.evals)
        brightness_sets = len(h.sets("Brightness"))
        h.hypr.event("configreloaded>>", hz=240)   # monitors.lua put the native rate back
        h.wait(lambda: len(h.hypr.evals) == n + 1 and h.hypr.hz == 60, what="re-applied after reload")
        h.hypr.event("monitoraddedv2>>2,HDMI-A-1,Monitor", hz=240)
        h.wait(lambda: len(h.hypr.evals) == n + 2 and h.hypr.hz == 60, what="re-applied after hotplug")
        self.assertEqual(len(h.sets("Brightness")), brightness_sets, "a Hyprland event only touches the refresh rate")

    def test_pin_beats_gaming_beats_power_source(self):
        h = self.harness()
        h.wait(lambda: h.state.get("refreshHz") == 240, what="AC applied")
        r = subprocess.run([sys.executable, "-I", "-B", BRIDGE, "gaming", "on"], env=h.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        h.wait(lambda: h.hypr.hz == 165 and h.state.get("gaming"), what="gaming rate")
        self.assertTrue(h.send("refresh", "120")["ok"])
        h.wait(lambda: h.hypr.hz == 120 and h.state.get("refreshOverride") == "120", what="pinned rate")
        with open(os.path.join(h.state_dir, "power-tune-hz")) as f:
            self.assertEqual(f.read().strip(), "120")
        self.assertTrue(h.send("refresh", "auto")["ok"])
        h.wait(lambda: h.hypr.hz == 165, what="back to gaming")
        self.assertTrue(h.send("gaming", "off")["ok"])
        h.wait(lambda: h.hypr.hz == 240 and not h.state.get("gaming"), what="back to AC")

    def test_kbd_level_for_the_other_source_is_saved_not_applied(self):
        h = self.harness(on_battery=True)
        h.wait(lambda: h.state.get("hasAura") and h.state.get("refreshHz") == 60, what="battery applied")
        before = len(h.sets("Brightness"))
        self.assertTrue(h.send("kbd-level", "ac", "high")["ok"])
        self.assertEqual(len(h.sets("Brightness")), before)
        self.assertIn("KBD_AC=high\n", open(h.conf).read())
        self.assertIn("# test\n", open(h.conf).read(), "other lines are kept")
        self.assertEqual(h.state["kbdAC"], "high")
        h.fake({"set": ["/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", "b", False]})
        h.wait(lambda: h.state.get("kbdBrightness") == 3, what="AC level applied on plug")
        self.assertTrue(h.send("kbd-level", "both", "low")["ok"])
        h.wait(lambda: h.state.get("kbdBrightness") == 1, what="both applied now")
        self.assertFalse(h.send("kbd-level", "ac", "blinding")["ok"])

    def test_writes_keep_the_dbus_types(self):
        h = self.harness()
        h.wait(lambda: h.state.get("hasAura"), what="asusd")
        for args in (("kbd-color", "#1A2B3C"), ("kbd-power", "sleep", "true"), ("slash-flag", "ShowOnSleep", "true"),
                     ("slash-brightness", "300"), ("slash-pattern", "5"), ("slash-enabled", "false"),
                     ("battery-limit", "60")):
            self.assertTrue(h.send(*args)["ok"], args)
        sets = {s[2] if s[2] != "Brightness" else s[1] + ".Brightness": s for s in h.sets("") or
                [c["set"] for c in h.calls() if "set" in c]}
        self.assertEqual(sets["LedModeData"][3:], ["(uu(yyy)(yyy)ss)", [0, 0, [26, 43, 60], [0, 0, 0], "Med", "Right"]])
        self.assertEqual(sets["LedPower"][3:], ["(a(ubbbb))", [[[1, True, True, True, True]]]])
        self.assertEqual(sets["ShowOnSleep"][3:], ["b", True])
        self.assertEqual(sets["xyz.ljones.Slash.Brightness"][3:], ["y", 255])
        self.assertEqual(sets["Interval"][3:], ["y", 5])
        self.assertEqual(sets["Enabled"][3:], ["b", False])
        self.assertEqual(sets["ChargeControlEndThreshold"][3:], ["y", 60])
        h.wait(lambda: h.state.get("kbdColor") == "1A2B3C" and h.state.get("chargeLimit") == 60
               and h.state.get("kbdSleep") and not h.state.get("slashOn"), what="signals reflected")
        for bad in (("kbd-color", "red"), ("slash-flag", "Bogus", "true"), ("battery-limit", "5"), ("nope",)):
            self.assertFalse(h.send(*bad)["ok"], bad)

    def test_no_settings_file_enforces_nothing(self):
        h = self.harness(conf=None)
        h.wait(lambda: h.state.get("hasAura") and h.state.get("refreshHz") == 60, what="started")
        h.fake({"set": ["/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery", "b", True]})
        h.wait(lambda: h.state.get("onBattery"), what="battery")
        h.send("get")
        self.assertEqual(h.hypr.evals, [])
        self.assertEqual([c for c in h.calls() if "set" in c], [])
        self.assertEqual((h.state["kbdAC"], h.state["kbdBattery"]), ("", ""))

    def test_fn_keys_reach_the_state(self):
        h = self.harness()
        h.wait(lambda: h.state.get("kbdBrightness") == 2, what="AC level")
        with open(h.led, "w") as f:
            f.write("3\n")
        h.wait(lambda: h.state.get("kbdBrightness") == 3, what="brightness_hw_changed")

    def test_asusd_absent_then_appearing(self):
        h = self.harness(asusd=False)
        h.wait(lambda: h.state.get("refreshHz") == 240, what="started")
        self.assertFalse(h.state["hasAura"])
        self.assertFalse(h.send("kbd-color", "112233")["ok"])
        h.fake({"asusd": True})
        h.wait(lambda: h.state.get("hasAura") and h.state.get("hasSlash"), what="asusd found")
        h.wait(lambda: [s[4] for s in h.sets("Brightness") if s[1] == "xyz.ljones.Aura"] == [2], what="AC level applied")
        h.fake({"asusd": False})
        h.wait(lambda: not h.state.get("hasAura"), what="asusd gone")

    def test_winlock_mode_writes_the_dropin_and_restarts_the_unit(self):
        h = self.harness()
        h.wait(lambda: h.state.get("hasWinlock"), what="started")
        self.assertTrue(h.send("winlock-mode", "unlock")["ok"])
        dropin = os.path.join(h.home, ".config", "systemd", "user", "g16-winlock.service.d", "mode.conf")
        self.assertEqual(open(dropin).read(), "[Service]\nEnvironment=G16_WINLOCK_MODE=unlock\n")
        methods = [c["call"][2] for c in h.calls() if "call" in c]
        self.assertEqual([m for m in methods if m != "GetUnit"], ["Reload", "EnableUnitFiles", "RestartUnit"])
        self.assertEqual(h.state["winlockMode"], "unlock")
        self.assertFalse(h.send("winlock-mode", "off")["ok"])

    def test_idle_bridge_never_wakes(self):
        # No timers: with nothing happening, no thread of the bridge runs.
        h = self.harness()
        h.wait(lambda: h.state.get("hasAura") and h.state.get("refreshHz") == 240, what="settled")
        time.sleep(1.5)

        def switches():
            n = 0
            for task in os.listdir(f"/proc/{h.bridge.pid}/task"):
                with open(f"/proc/{h.bridge.pid}/task/{task}/status") as f:
                    n += sum(int(x.split()[1]) for x in f if "ctxt_switches" in x)
            return n
        before = switches()
        time.sleep(6)
        self.assertEqual(switches() - before, 0, "the idle bridge woke up")

    def test_closing_stdin_stops_the_bridge(self):
        h = self.harness()
        h.wait(lambda: h.state.get("hasAura"), what="started")
        h.bridge.stdin.close()
        self.assertEqual(h.bridge.wait(5), 0)


if __name__ == "__main__":
    if not shutil.which("dbus-daemon"):
        print("bridge tests skipped: no dbus-daemon")
        sys.exit(0)
    unittest.main(verbosity=2)
