#!/usr/bin/env python3
"""Offline tests for bin/g16-idlemask-bisect (#249): the gpu_metrics v3.0 layout and
parse, the idlemask bits, the bisect on simulated device-to-bit maps, the watts fit,
discovery and the preflight on a fake G16 sysfs, the bus changes against a stand-in
kernel, and the dry run from the command line (nothing changed, nothing started).

  python3 -I tests/test_g16_idlemask_bisect.py
"""
import importlib.machinery
import importlib.util
import itertools
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "g16-idlemask-bisect")


def load():
    loader = importlib.machinery.SourceFileLoader("g16_idlemask_bisect", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


B = load()
B.log = lambda *a: None  # the runner logs every phase

# The G16's PCI devices: bdf, parent port, vendor, device, class, driver.
G16 = [
    ("0000:00:00.0", "", "0x1022", "0x1122", "0x060000", ""),
    ("0000:00:01.1", "", "0x1022", "0x1125", "0x060400", "pcieport"),
    ("0000:00:02.1", "", "0x1022", "0x1126", "0x060400", "pcieport"),
    ("0000:00:02.2", "", "0x1022", "0x1126", "0x060400", "pcieport"),
    ("0000:00:02.3", "", "0x1022", "0x1126", "0x060400", "pcieport"),
    ("0000:00:03.1", "", "0x1022", "0x1126", "0x060400", "pcieport"),
    ("0000:00:08.1", "", "0x1022", "0x1110", "0x060400", "pcieport"),
    ("0000:00:08.2", "", "0x1022", "0x1111", "0x060400", "pcieport"),
    ("0000:00:08.3", "", "0x1022", "0x1112", "0x060400", "pcieport"),
    ("0000:00:14.0", "", "0x1022", "0x790b", "0x0c0500", "piix4_smbus"),
    ("0000:00:14.3", "", "0x1022", "0x790e", "0x060100", ""),
    ("0000:00:18.3", "", "0x1022", "0x124b", "0x060000", "k10temp"),
    ("0000:61:00.0", "0000:00:02.1", "0x144d", "0xa80d", "0x010802", "nvme"),
    ("0000:62:00.0", "0000:00:02.2", "0x17a0", "0x9767", "0x080501", "sdhci-pci"),
    ("0000:63:00.0", "0000:00:02.3", "0x14c3", "0x7925", "0x028000", "mt7925e"),
    ("0000:64:00.0", "0000:00:03.1", "0x10de", "0x2d59", "0x030000", "nvidia"),
    ("0000:64:00.1", "0000:00:03.1", "0x10de", "0x22eb", "0x040300", "snd_hda_intel"),
    ("0000:65:00.0", "0000:00:08.1", "0x1002", "0x1114", "0x038000", "amdgpu"),
    ("0000:65:00.1", "0000:00:08.1", "0x1002", "0x1640", "0x040300", "snd_hda_intel"),
    ("0000:65:00.2", "0000:00:08.1", "0x1022", "0x17e0", "0x108000", "ccp"),
    ("0000:65:00.4", "0000:00:08.1", "0x1022", "0x1128", "0x0c0330", "xhci_hcd"),
    ("0000:65:00.5", "0000:00:08.1", "0x1022", "0x15e2", "0x048000", "snd_acp_pci"),
    ("0000:65:00.6", "0000:00:08.1", "0x1022", "0x15e3", "0x040300", "snd_hda_intel"),
    ("0000:66:00.0", "0000:00:08.2", "0x1022", "0x1116", "0x130000", ""),
    ("0000:66:00.1", "0000:00:08.2", "0x1022", "0x17f0", "0x118000", "amdxdna"),
    ("0000:67:00.0", "0000:00:08.3", "0x1022", "0x1118", "0x0c0330", "xhci_hcd"),
    ("0000:67:00.3", "0000:00:08.3", "0x1022", "0x111c", "0x0c0330", "xhci_hcd"),
    ("0000:67:00.4", "0000:00:08.3", "0x1022", "0x111e", "0x0c0330", "xhci_hcd"),
    ("0000:67:00.5", "0000:00:08.3", "0x1022", "0x1120", "0x0c0340", "thunderbolt"),
]
# USB: name, host BDF, vid:pid, interface classes
USB = [("1-1", "0000:65:00.4", "13d3:52ba", ["0e", "0e"]), ("3-3", "0000:67:00.0", "0489:e11e", ["e0"]),
       ("3-4", "0000:67:00.0", "0b05:19b6", ["03", "03"])]
GROUPS = ["rtx", "smbus", "sd", "wifi", "hdmi-audio", "psp", "xhci-cam", "acp", "audio", "npu",
          "xhci-kbd", "xhci-67:00.3", "xhci-67:00.4", "usb4"]


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text + "\n")


def fake_g16(root):
    """A fake /sys and /proc of the G16 on battery, idle, RTX asleep."""
    sysd, proc = os.path.join(root, "sys"), os.path.join(root, "proc")
    paths = {}
    for bdf, parent, v, d, c, drv in G16:
        base = paths[parent] if parent else os.path.join(sysd, "devices", "pci0000:00")
        p = os.path.join(base, bdf)
        paths[bdf] = p
        for k, val in (("vendor", v), ("device", d), ("class", c)):
            put(os.path.join(p, k), val)
        put(os.path.join(p, "power", "runtime_status"), "suspended" if v == "0x10de" else "active")
        put(os.path.join(p, "power", "control"), "auto")
        os.makedirs(os.path.join(sysd, "bus", "pci", "devices"), exist_ok=True)
        os.symlink(p, os.path.join(sysd, "bus", "pci", "devices", bdf))
        if drv:
            dd = os.path.join(sysd, "bus", "pci", "drivers", drv)
            os.makedirs(dd, exist_ok=True)
            os.symlink(dd, os.path.join(p, "driver"))
    for bus in sorted({bdf.rsplit(":", 1)[0] for bdf, *_ in G16}):
        put(os.path.join(sysd, "class", "pci_bus", bus, "rescan"), "")
    for name, host, vp, ifcs in USB:
        bus = name.split("-")[0]
        p = os.path.join(paths[host], f"usb{bus}", name)
        put(os.path.join(p, "idVendor"), vp.split(":")[0])
        put(os.path.join(p, "idProduct"), vp.split(":")[1])
        for i, c in enumerate(ifcs):
            put(os.path.join(p, f"{name}:1.{i}", "bInterfaceClass"), c)
        os.makedirs(os.path.join(sysd, "bus", "usb", "devices"), exist_ok=True)
        os.symlink(p, os.path.join(sysd, "bus", "usb", "devices", name))
    # DRM: card0 the RTX (HDMI, its eDP), card1 the AMD GPU with the panel
    for card, bdf in (("card0", "0000:64:00.0"), ("card1", "0000:65:00.0")):
        put(os.path.join(paths[bdf], "drm", card, "dev"), "226:%d" % int(card[-1]))
        os.makedirs(os.path.join(sysd, "class", "drm"), exist_ok=True)
        os.symlink(os.path.join(paths[bdf], "drm", card), os.path.join(sysd, "class", "drm", card))
        os.symlink(paths[bdf], os.path.join(paths[bdf], "drm", card, "device"))
    for conn, st in (("card0-HDMI-A-1", "disconnected"), ("card0-eDP-2", "disconnected"),
                     ("card1-eDP-1", "connected"), ("card1-DP-1", "disconnected")):
        put(os.path.join(sysd, "class", "drm", conn, "status"), st)
    put(os.path.join(paths["0000:65:00.0"], "gpu_metrics"), "")
    put(os.path.join(sysd, "class", "dmi", "id", "product_name"), "ROG Zephyrus G16 GA605KM_GA605KM")
    ps = os.path.join(sysd, "class", "power_supply")
    for k, v in (("type", "Battery"), ("status", "Discharging"), ("capacity", "80"),
                 ("current_now", "400000"), ("voltage_now", "16000000")):
        put(os.path.join(ps, "BAT1", k), v)
    put(os.path.join(ps, "ACAD", "type"), "Mains")
    put(os.path.join(ps, "ACAD", "online"), "0")
    put(os.path.join(sysd, "class", "firmware-attributes", "asus-armoury", "attributes", "gpu_mux_mode",
                     "current_value"), "1")
    put(os.path.join(sysd, "class", "leds", "asus::kbd_backlight", "brightness"), "2")
    put(os.path.join(sysd, "kernel", "debug", "amd_pmc", "amd_pmc_idlemask"), "SMU idlemask s0i3: 0xffce9add")
    # the root disk: / on nvme0n1 below 61:00.0
    blk = os.path.join(paths["0000:61:00.0"], "nvme", "nvme0", "nvme0n1")
    os.makedirs(blk)
    os.makedirs(os.path.join(sysd, "dev", "block"))
    os.symlink(blk, os.path.join(sysd, "dev", "block", "259:2"))
    put(os.path.join(proc, "self", "mountinfo"), "25 1 259:2 / / rw,relatime - btrfs /dev/nvme0n1p2 rw")
    put(os.path.join(proc, "driver", "nvidia", "gpus", "0000:64:00.0", "power"),
        "Runtime D3 status:          Enabled (fine-grained)\nVideo Memory:               Off\n")
    put(os.path.join(proc, "sys", "kernel", "osrelease"), "7.2.8-9.104-omarchy")
    return sysd, proc, paths


class Fake(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.sys, self.proc, self.paths = fake_g16(self.tmp)
        self.old = (B.SYS, B.PROC)
        B.SYS, B.PROC = self.sys, self.proc

    def tearDown(self):
        B.SYS, B.PROC = self.old
        shutil.rmtree(self.tmp)


# ------------------------------------------------------------------ gpu_metrics
class GpuMetrics(unittest.TestCase):
    def test_layout_matches_the_kernel_struct(self):
        # struct gpu_metrics_v3_0, natural alignment (kgd_pp_interface.h)
        self.assertEqual(B.GM_SIZE, 264)
        want = {"system_clock_counter": 104, "average_socket_power": 112, "average_ipu_power": 116,
                "average_apu_power": 120, "average_gfx_power": 124, "average_dgpu_power": 128,
                "average_all_core_power": 132, "average_core_power": 136, "average_sys_power": 168}
        for k, off in want.items():
            self.assertEqual(B.GM_LAYOUT[k][0], off, k)

    def table(self, **vals):
        b = bytearray(264)
        struct.pack_into("<HBB", b, 0, 264, 3, 0)
        for k, (off, code, v) in vals.items():
            struct.pack_into("<" + code, b, off, v)
        return bytes(b)

    def test_parse_reads_the_struct_offsets(self):
        b = self.table(c=(104, "Q", 53724143548302), s=(112, "I", 4410), i=(116, "H", 0xFFFF), a=(120, "I", 4410),
                       g=(124, "I", 205), d=(128, "I", 0), k=(132, "I", 202))
        m = B.parse_gpu_metrics(b)
        self.assertEqual(m["clock_counter"], 53724143548302)
        self.assertEqual((m["socket_mw"], m["apu_mw"], m["gfx_mw"], m["dgpu_mw"], m["core_mw"]), (4410, 4410, 205, 0, 202))
        self.assertIsNone(m["ipu_mw"])  # 0xffff: not reported

    def test_the_old_2_byte_shift_is_not_what_it_reads(self):
        # the kit's earlier layout read every field 2 bytes late: socket came out 0
        b = self.table(s=(112, "I", 4410))
        self.assertEqual(B.parse_gpu_metrics(b)["socket_mw"], 4410)
        self.assertEqual(struct.unpack_from("<I", b, 114)[0] & 0xFFFF, 0)

    def test_other_formats_are_refused(self):
        b = bytearray(self.table())
        b[2] = 2
        self.assertIsNone(B.parse_gpu_metrics(bytes(b)))
        self.assertIsNone(B.parse_gpu_metrics(b"\x00\x01"))


# ------------------------------------------------------------------ idlemask
class Mask(unittest.TestCase):
    def test_not_idle_bits_of_the_g16_baseline(self):
        self.assertEqual(B.not_idle_bits(0xffce9add), [1, 5, 8, 10, 13, 14, 16, 20, 21])
        self.assertEqual(B.not_idle_bits(0xffce9a5d), [1, 5, 7, 8, 10, 13, 14, 16, 20, 21])

    def test_parse_mask(self):
        self.assertEqual(B.parse_mask("SMU idlemask s0i3: 0xffce9add\n"), 0xffce9add)
        self.assertIsNone(B.parse_mask(""))

    def test_shares_and_flicker(self):
        masks = [0xffce9add] * 6 + [0xffce9a5d] * 4 + [None]
        sh = B.bit_shares(masks)
        self.assertEqual(sh[1], 1.0)
        self.assertAlmostEqual(sh[7], 0.4)
        self.assertEqual(sh[0], 0.0)


# ------------------------------------------------------------------ the bisect
def oracle(model, calls):
    """model: bit -> holders; a bit goes idle once all its holders are removed."""
    def released(removed):
        calls.append(removed)
        return {b for b, hs in model.items() if hs and set(hs) <= removed}
    return released


class Bisecting(unittest.TestCase):
    def run_model(self, model, names=GROUPS):
        calls = []
        bis = B.Bisect(names, oracle(model, calls), budget=10 ** 6)
        s_all = {b for b, hs in model.items() if hs}
        got = bis.run(s_all)
        return got, calls

    def test_single_holders(self):
        model = {1: ["wifi"], 5: ["xhci-kbd"], 10: ["sd"], 13: [], 14: []}
        got, calls = self.run_model(model)
        self.assertEqual(got, {1: ["wifi"], 5: ["xhci-kbd"], 10: ["sd"]})
        self.assertLessEqual(len(calls), 3 * 2 * 4)  # at most two reads a level, depth 4, per bit

    def test_one_bit_held_by_one_device_in_each_half(self):
        model = {21: ["smbus", "usb4"], 8: ["audio", "acp"]}
        got, _ = self.run_model(model)
        self.assertEqual(got, {21: ["smbus", "usb4"], 8: ["acp", "audio"]})

    def test_three_holders_and_internal_bits(self):
        model = {20: ["wifi", "npu", "usb4"], 13: [], 16: []}
        got, _ = self.run_model(model)
        self.assertEqual(got, {20: ["wifi", "npu", "usb4"]})

    def test_nothing_to_find(self):
        got, calls = self.run_model({13: [], 14: []})
        self.assertEqual((got, calls), ({}, []))

    def test_random_maps_are_recovered_exactly(self):
        rng = random.Random(249)
        for _ in range(300):
            model = {}
            for b in rng.sample(range(22), rng.randint(1, 9)):
                k = rng.choice([0, 1, 1, 1, 2, 3])
                model[b] = rng.sample(GROUPS, k)
            got, calls = self.run_model(model)
            want = {b: sorted(hs, key=GROUPS.index) for b, hs in model.items() if hs}
            self.assertEqual(got, want, model)
            self.assertLess(len(calls), 120)

    def test_single_holder_maps_are_cheap(self):
        # one holder each, up to 9 bits: never more phases than a linear sweep of 14
        for k in range(1, 10):
            worst = 0
            for hs in itertools.islice(itertools.permutations(GROUPS, k), 200):
                calls = []
                bis = B.Bisect(GROUPS, oracle({i: [h] for i, h in enumerate(hs)}, calls), budget=10 ** 6)
                bis.run(set(range(k)))
                worst = max(worst, len(set(calls)))
            self.assertLessEqual(worst, 2 * len(GROUPS), k)

    def test_budget(self):
        bis = B.Bisect(GROUPS, oracle({1: ["wifi"]}, []), budget=2)
        with self.assertRaises(B.Budget):
            bis.run({1})


# ------------------------------------------------------------------ the two passes
def sim_groups(names=GROUPS):
    return [{"name": n, "label": n, "top": f"0000:{i + 0x60:02x}:00.0", "members": [f"0000:{i + 0x60:02x}:00.0"],
             "drivers": {}, "port": "", "bus": f"0000:{i + 0x60:02x}", "method": "remove"} for i, n in enumerate(names)]


class Passes(unittest.TestCase):
    def run_sim(self, holders, watts=None, *args):
        model = {"base": "0xffce9add", "holders": {str(b): h for b, h in holders.items()}, "watts": watts or {}}
        groups = sim_groups()
        hw = B.SimHw(groups, model)
        r = B.Runner(hw, groups, B.parse(list(args)))
        res = r.run()
        return res, r.phases

    def test_a_pairwise_only_bit_needs_both(self):
        # 5 needs two devices of the same half; 21 one device in each half
        res, phases = self.run_sim({5: ["xhci-kbd", "usb4"], 21: ["smbus", "audio"], 1: ["wifi"],
                                    13: ["soc"], 14: ["soc"], 8: ["soc"], 10: ["soc"], 16: ["soc"], 20: ["soc"]})
        self.assertEqual(res["holders"], {"1": ["wifi"], "5": ["xhci-kbd", "usb4"], "21": ["smbus", "audio"]})
        # neither device alone let it go: each was off on its own in some phase with the bit stuck
        for b, pair in ((5, ["xhci-kbd", "usb4"]), (21, ["smbus", "audio"])):
            for d in pair:
                alone = [p for p in phases if d in p["removed"] and not set(pair) <= set(p["removed"])]
                self.assertTrue(alone, d)
                self.assertTrue(all(b not in p["released"] for p in alone))
        self.assertEqual(res["verified"], {"1": True, "5": True, "21": True})
        md = B.report(res, phases, sim_groups(), {}, {}, {}, B.parse([]))
        self.assertIn("| 5 | needs xhci-kbd, 6a:00.0 + usb4, 6d:00.0 together", md)

    def test_nothing_clears_with_everything_off_skips_the_bisect(self):
        res, phases = self.run_sim({b: ["soc"] for b in (1, 5, 8, 10, 13, 14, 16, 20, 21)})
        self.assertTrue(res["pass1"].startswith("skipped"))
        self.assertEqual([p["why"] for p in phases],
                         ["baseline", "all-off", "screen-off", "watts", "watts", "watts", "rtx", "all+screen", "quiet"])
        self.assertEqual([w["label"] for w in res["watts"]], ["baseline", "all-off", "baseline", "rtx"])
        self.assertEqual(res["internal"], [1, 5, 8, 10, 13, 14, 16, 20, 21])

    def test_pass_2_is_long_phases_for_each_holder_set(self):
        res, phases = self.run_sim({1: ["wifi"], 5: ["xhci-kbd", "usb4"], 13: ["soc"]},
                                   {"base": 7.0, "socket": 4.4, "wifi": 0.2, "xhci-kbd": 0.1, "usb4": 0.3})
        p2 = [p for p in phases if p["why"] == "watts"]
        self.assertEqual([p["removed"] for p in p2], [[], GROUPS[1:], ["wifi"], ["xhci-kbd", "usb4"], []])
        self.assertTrue(all(p["settle"] == 10 and p["reads"] == 300 for p in p2))
        w = {x["label"]: x for x in res["watts"]}
        self.assertAlmostEqual(w["wifi"]["d_bat"], -0.2, delta=0.05)
        self.assertAlmostEqual(w["xhci-kbd+usb4"]["d_bat"], -0.4, delta=0.05)
        self.assertEqual(w["xhci-kbd+usb4"]["bits"], [5])
        # pass 1 is short
        self.assertTrue(all(p["reads"] == 30 for p in phases if p["why"] in ("bisect", "all-off")))

    def test_the_quiet_phase_says_quiet_or_firmware(self):
        res, phases = self.run_sim({1: ["wifi"], 14: ["quiet"], 13: ["soc"], 16: ["display"]})
        q = [p for p in phases if p["why"] == "quiet"]
        self.assertEqual(len(q), 1)
        q = q[0]
        self.assertEqual((q["removed"], q["screen_off"], q["frozen"], q["reads"]), (GROUPS, True, True, 600))
        self.assertEqual(res["quiet_only"], [14])
        self.assertEqual(res["display"], [16])
        self.assertIn(13, res["internal"])
        self.assertNotIn(14, res["internal"])
        md = B.report(res, phases, sim_groups(), {}, {}, {}, B.parse([]))
        self.assertIn("**Quiet:** bits 14 go idle only when everything is quiet", md)
        self.assertIn("**Firmware:** bits 5, 8, 10, 13, 20, 21 stay not idle", md)
        self.assertIn("| wakeups/s | 150 | 850 |", md)

    def test_the_rtx_comes_off_once_at_the_end_and_stays_off(self):
        # 3 is the RTX's alone, 4 needs the RTX and the Wi-Fi: neither goes idle with the RTX on
        res, phases = self.run_sim({1: ["wifi"], 3: ["rtx"], 4: ["rtx", "wifi"], 13: ["soc"]},
                                   {"base": 7.0, "socket": 4.4, "rtx": 0.5})
        off = [i for i, p in enumerate(phases) if "rtx" in p["removed"]]
        self.assertEqual([phases[i]["why"] for i in off], ["rtx", "all+screen", "quiet"])
        self.assertEqual(off, list(range(len(phases) - 3, len(phases))))  # one stretch, the last, no rescan in it
        self.assertEqual(res["rtx"], {"phase": phases[off[0]]["n"], "bits": [3, 4]})
        self.assertEqual(res["holders"], {"1": ["wifi"]})
        self.assertNotIn(3, res["internal"])
        self.assertEqual(res["quiet_only"], [])
        w = {x["label"]: x for x in res["watts"]}
        self.assertAlmostEqual(w["rtx"]["d_bat"] - w["all-off"]["d_bat"], -0.5, delta=0.05)
        md = B.report(res, phases, sim_groups(), {}, {}, {}, B.parse([]))
        self.assertIn("| 3 | the RTX's port (rtx, 60:00.0): idle only once it came off too", md)
        self.assertIn("The RTX's port on its own (the last two rows apart): battery -0.", md)

    def test_a_second_rtx_removal_is_refused(self):
        groups = sim_groups()
        hw = B.SimHw(groups, {"holders": {}})
        hw.set_state({"rtx"}, False)
        hw.set_state(set(), False)
        with self.assertRaises(B.Skip):
            hw.set_state({"rtx", "wifi"}, False)
        self.assertEqual(hw.removed, frozenset())
        # the runner carries on without it
        r = B.Runner(hw, groups, B.parse([]))
        p = r.measure({"rtx", "wifi"}, why="bisect")
        self.assertEqual(p["removed"], ["wifi"])
        self.assertIn("#352", r.rtx_skipped)

    def test_no_screen_still_runs_a_quiet_phase(self):
        res, phases = self.run_sim({1: ["wifi"]}, None, "--no-screen")
        self.assertEqual([p["screen_off"] for p in phases if p["why"] == "quiet"], [False])
        self.assertNotIn("screen-off", [p["why"] for p in phases])


class QuietReadings(Fake):
    def test_rates(self):
        put(os.path.join(self.proc, "interrupts"), "  CPU0 CPU1\nLOC: 100 100 Local\nCAL: 10 10 Func\n 91: 5 5 x ASUF1209:00")
        for c in (0, 1):
            for i, name in enumerate(("POLL", "C1", "C3")):
                put(os.path.join(self.sys, f"devices/system/cpu/cpu{c}/cpuidle/state{i}/name"), name)
                put(os.path.join(self.sys, f"devices/system/cpu/cpu{c}/cpuidle/state{i}/time"), "0")
                put(os.path.join(self.sys, f"devices/system/cpu/cpu{c}/cpuidle/state{i}/usage"), "0")
        c0 = B.counters()
        put(os.path.join(self.proc, "interrupts"), "  CPU0 CPU1\nLOC: 200 200 Local\nCAL: 20 20 Func\n 91: 15 15 x ASUF1209:00")
        for c in (0, 1):
            put(os.path.join(self.sys, f"devices/system/cpu/cpu{c}/cpuidle/state2/time"), "1900000")
        c1 = B.counters()
        c1["mono"] = c0["mono"] + 2.0
        r = B.rates(c0, c1)
        self.assertEqual(r["wakeups"], (200 + 20 + 20) // 2)
        self.assertEqual(r["deepest"], "C3")
        self.assertAlmostEqual(r["deepest_pct"], 95.0)

    def test_the_freezer_takes_app_scopes_only_and_the_watchdog_thaws(self):
        app = os.path.join(self.sys, "fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice")
        cases = {"app-firefox-1.scope": "firefox", "app-Hyprland.scope": "Hyprland", "voxtype.service": "voxtype",
                 "app-keyring-2.scope": "gnome-keyring", "run-u5.scope": "bash"}
        for i, (unit, comm) in enumerate(cases.items()):
            put(os.path.join(app, unit, "cgroup.procs"), str(500 + i))
            put(os.path.join(app, unit, "cgroup.freeze"), "0")
            put(os.path.join(self.proc, str(500 + i), "comm"), comm)
        state = os.path.join(self.tmp, "frozen.txt")
        f = B.Freezer(1000, state)
        self.assertEqual(f.apply(), 1)
        self.assertEqual(B.rd(os.path.join(app, "app-firefox-1.scope/cgroup.freeze")), "1")
        for u in ("app-Hyprland.scope", "voxtype.service", "app-keyring-2.scope", "run-u5.scope"):
            self.assertEqual(B.rd(os.path.join(app, u, "cgroup.freeze")), "0", u)
        B.thaw_from_file(state)
        self.assertEqual(B.rd(os.path.join(app, "app-firefox-1.scope/cgroup.freeze")), "0")
        self.assertFalse(os.path.exists(state))

    def test_trace_summary(self):
        txt = ("kworker-1 [003] 1.0: idle: (dc_allow_idle_optimizations_internal+0x0/0x10) allow=1 zs=3 nstr=1 "
               "st=0x407b000000000000\n"
               "kworker-1 [003] 1.1: smumsg: (dcn35_smu_send_msg_with_param+0x0/0x10) msg=0x15 param=0x1\n")
        lines, data = B.summarize_trace(txt, 60)
        self.assertIn("0x15/0x1 x1", lines[0])
        self.assertIn("zstate=Z8_Z10_ONLY", lines[2])
        self.assertIn("StutterPeriod (us): min 432", lines[3])


# ------------------------------------------------------------------ discovery
class Discovery(Fake):
    def test_the_g16_groups(self):
        groups, left = B.discover()
        self.assertEqual([g["name"] for g in groups], GROUPS)
        by = {g["name"]: g for g in groups}
        self.assertEqual(by["rtx"]["top"], "0000:00:03.1")
        self.assertEqual(by["rtx"]["members"], ["0000:00:03.1", "0000:64:00.0", "0000:64:00.1"])
        self.assertEqual(by["xhci-kbd"]["top"], "0000:67:00.0")
        self.assertIn("Bluetooth (0489:e11e)", by["xhci-kbd"]["label"])
        self.assertEqual(by["xhci-cam"]["top"], "0000:65:00.4")
        self.assertEqual(by["wifi"]["port"], "0000:00:02.3")
        self.assertEqual(by["wifi"]["bus"], "0000:63")
        self.assertEqual(by["rtx"]["bus"], "0000:00")

    def test_never_the_nvme_the_amd_gpu_or_bridges(self):
        groups, left = B.discover()
        members = {m for g in groups for m in g["members"]}
        for bdf in ("0000:61:00.0", "0000:65:00.0", "0000:00:00.0", "0000:00:02.1", "0000:00:08.1",
                    "0000:00:14.3", "0000:00:18.3", "0000:66:00.0"):
            self.assertNotIn(bdf, members, bdf)
        self.assertIn("NVMe", left["0000:61:00.0"])
        self.assertEqual(left["0000:65:00.0"], "the AMD GPU")

    def test_a_group_on_the_root_disks_path_is_left_alone(self):
        # / on a disk behind the SD reader: the reader is not removed
        blk = os.path.join(self.paths["0000:62:00.0"], "mmc0", "mmcblk0")
        os.makedirs(blk)
        os.symlink(blk, os.path.join(self.sys, "dev", "block", "179:0"))
        put(os.path.join(self.proc, "self", "mountinfo"), "25 1 179:0 / / rw - ext4 /dev/mmcblk0 rw")
        groups, left = B.discover()
        self.assertNotIn("sd", [g["name"] for g in groups])
        self.assertEqual(left["0000:62:00.0"], "on the root disk's path")

    def test_an_open_drm_node_keeps_the_rtx(self):
        groups, _ = B.discover()
        self.assertEqual(B.busy_groups(groups, B.pci_devices()), {})
        # a process with the RTX's card0 open (a stand-in node: /dev/null is 1:3)
        put(os.path.join(self.paths["0000:64:00.0"], "drm", "card0", "dev"), "1:3")
        fd = os.path.join(self.proc, "4242", "fd")
        os.makedirs(fd)
        put(os.path.join(self.proc, "4242", "comm"), "Hyprland")
        os.symlink("/dev/null", os.path.join(fd, "7"))
        busy = B.busy_groups(groups, B.pci_devices())
        self.assertEqual(list(busy), ["rtx"])
        self.assertIn("Hyprland[4242] has card0 open", busy["rtx"])


class Preflight(Fake):
    def refusals(self):
        return B.preflight(B.pci_devices(), as_root=True)[0]

    def test_ok(self):
        self.assertEqual(self.refusals(), [])

    def test_each_refusal(self):
        cases = [
            (("class/power_supply/ACAD/online", "1"), "on AC"),
            (("class/power_supply/BAT1/status", "Not charging"), "not discharging"),
            (("class/firmware-attributes/asus-armoury/attributes/gpu_mux_mode/current_value", "0"), "not in hybrid"),
            (("class/drm/card0-HDMI-A-1/status", "connected"), "HDMI-A-1"),
            (("class/drm/card1-DP-1/status", "connected"), "DP-1"),
            (("bus/pci/devices/0000:64:00.0/power/runtime_status", "active"), "not runtime-suspended"),
            (("kernel/debug/amd_pmc/amd_pmc_idlemask", ""), "amd_pmc_idlemask"),
            (("class/dmi/id/product_name", "Something Else"), "not a ROG"),
        ]
        for (rel, val), want in cases:
            p = os.path.join(self.sys, rel)
            with open(p) as f:
                old = f.read()
            put(p, val)
            got = self.refusals()
            self.assertTrue(any(want in r for r in got), (rel, got))
            with open(p, "w") as f:
                f.write(old)
        self.assertEqual(self.refusals(), [])

    def test_the_panel_on_the_rtx(self):
        put(os.path.join(self.sys, "class/drm/card1-eDP-1/status"), "disconnected")
        put(os.path.join(self.sys, "class/drm/card0-eDP-2/status"), "connected")
        self.assertTrue(any("driven by nvidia" in r for r in self.refusals()))

    def test_rtx_video_memory_awake(self):
        put(os.path.join(self.proc, "driver/nvidia/gpus/0000:64:00.0/power"), "Video Memory:               Active\n")
        self.assertTrue(any("video memory is Active" in r for r in self.refusals()))


# ------------------------------------------------------------------ the bus
class Kernel(B.Hw):
    """A stand-in kernel: remove takes a device and what's below it off, a bus rescan
    brings back what's missing on that bus (only with its port awake), drivers bind
    unless told not to."""

    def __init__(self, groups, state, devs, no_bind=(), block=()):
        self.present = set(devs)
        self.devs, self.no_bind, self.writes, self.bound, self.block = devs, set(no_bind), [], {}, set(block)
        super().__init__(groups, state)

    def _exists(self, bdf):
        return bdf in self.present

    def _driver(self, bdf):
        if bdf in self.bound:
            return self.bound[bdf]
        return "" if bdf in self.no_bind else self.devs[bdf]["driver"]

    def sleep(self, s):
        pass

    def _timed_write(self, path, value, timeout):
        rel = path[len(B.SYS) + 1:]
        self.writes.append((rel, str(value)))
        if rel in self.block:
            return None
        parts = rel.split("/")
        if rel.endswith("/remove"):
            top = parts[-2]
            self.present -= {top, *B.below(self.devs, top)}
        elif rel.startswith("class/pci_bus/") and rel.endswith("/rescan"):
            bus, before = parts[2], set(self.present)
            for b in self.devs:
                if b in before:
                    continue
                chain = [b] + [a for a in self.devs if b in B.below(self.devs, a)]
                top = next((x for x in chain if x.rsplit(":", 1)[0] == bus), None)
                if top is None:
                    continue
                port = self.devs[top]["parent"]  # a port that was there must be awake to be read
                if port and port in before and B.rd(f"{B.SYS}/bus/pci/devices/{port}/power/control") != "on":
                    continue
                self.present.add(b)
        elif rel == "bus/pci/rescan":
            self.present = set(self.devs)
        elif rel.endswith("/bind"):
            self.bound[str(value)] = parts[-2]
        elif rel.endswith("/unbind"):
            self.bound[str(value)] = ""
        elif rel.endswith("/power/control") or "leds" in rel:
            B.wr(path, value)
        return True


class Bus(Fake):
    def hw(self, **kw):
        groups, _ = B.discover()
        devs = B.pci_devices()
        return Kernel(groups, os.path.join(self.tmp, "state.json"), devs, **kw), devs

    def test_remove_then_back_with_the_port_awake(self):
        hw, _ = self.hw()
        hw.set_state({"wifi"}, False)
        self.assertNotIn("0000:63:00.0", hw.present)
        self.assertIn(("bus/pci/devices/0000:63:00.0/remove", "1"), hw.writes)
        hw.writes.clear()
        info = hw.set_state(set(), False)
        self.assertEqual(info["rescanned"], ["wifi"])
        self.assertIn("0000:63:00.0", hw.present)
        self.assertEqual(hw.writes[:3], [("bus/pci/devices/0000:00:02.3/power/control", "on"),
                                         ("class/pci_bus/0000:63/rescan", "1"),
                                         ("bus/pci/devices/0000:00:02.3/power/control", "auto")])
        self.assertEqual(B.rd(f"{B.SYS}/bus/pci/devices/0000:00:02.3/power/control"), "auto")

    def test_siblings_on_a_rescanned_bus_go_again(self):
        hw, _ = self.hw()
        hw.set_state({"audio", "acp"}, False)
        hw.set_state({"acp"}, False)
        self.assertIn("0000:65:00.6", hw.present)
        self.assertNotIn("0000:65:00.5", hw.present)
        self.assertEqual(sum(1 for w in hw.writes if w[0] == "bus/pci/devices/0000:65:00.5/remove"), 2)

    def test_the_rtx_port_takes_what_is_behind_it(self):
        hw, _ = self.hw()
        hw.set_state({"rtx"}, False)
        self.assertFalse({"0000:00:03.1", "0000:64:00.0", "0000:64:00.1"} & hw.present)
        hw.set_state(set(), False)
        self.assertTrue({"0000:00:03.1", "0000:64:00.0", "0000:64:00.1"} <= hw.present)

    def test_the_rtx_port_comes_off_at_most_once(self):
        hw, _ = self.hw()
        hw.set_state({"rtx"}, False)
        hw.set_state(set(), False)
        self.assertTrue(hw.rtx_reprobed)  # nvidia bound again after the rescan
        hw.writes.clear()
        with self.assertRaises(B.Skip) as e:
            hw.set_state({"rtx", "wifi"}, False)
        self.assertIn("nvidia re-probed it", str(e.exception))
        self.assertEqual(hw.writes, [])  # refused before anything changed
        self.assertIn("0000:00:03.1", hw.present)

    def test_the_rtx_stays_on_unless_suspended_and_unheld(self):
        hw, _ = self.hw()
        put(os.path.join(self.paths["0000:64:00.0"], "power", "runtime_status"), "active")
        with self.assertRaises(B.Skip) as e:
            hw.set_state({"rtx"}, False)
        self.assertIn("the RTX is active, not runtime-suspended", str(e.exception))
        put(os.path.join(self.paths["0000:64:00.0"], "power", "runtime_status"), "suspended")
        # something opened /dev/nvidia0 since the run started
        fd = os.path.join(self.proc, "4243", "fd")
        os.makedirs(fd)
        put(os.path.join(self.proc, "4243", "comm"), "steam")
        nv = os.path.join(self.tmp, "dev", "nvidia0")
        os.makedirs(os.path.dirname(nv))
        os.symlink("/dev/null", nv)
        os.symlink("/dev/null", os.path.join(fd, "3"))
        B.os.readlink, real = (lambda f, _r=os.readlink: "/dev/nvidia0" if f.endswith("4243/fd/3") else _r(f)), os.readlink
        try:
            with self.assertRaises(B.Skip) as e:
                hw.set_state({"rtx"}, False)
        finally:
            B.os.readlink = real
        self.assertIn("steam /dev/nvidia0 open", str(e.exception))
        self.assertEqual(hw.writes, [])
        self.assertEqual(hw.rtx_removals, 0)

    def test_a_driver_that_does_not_come_back_is_bound(self):
        hw, _ = self.hw(no_bind={"0000:62:00.0"})
        hw.set_state({"sd"}, False)
        hw.set_state(set(), False)
        self.assertIn(("bus/pci/drivers/sdhci-pci/bind", "0000:62:00.0"), hw.writes)

    def test_the_smbus_is_unbound_and_the_root_bus_never_rescanned(self):
        hw, _ = self.hw()
        self.assertEqual(hw.groups["smbus"]["method"], "unbind")
        hw.set_state({"smbus", "wifi"}, False)
        self.assertIn(("bus/pci/drivers/piix4_smbus/unbind", "0000:00:14.0"), hw.writes)
        self.assertIn("0000:00:14.0", hw.present)
        self.assertEqual(hw._driver("0000:00:14.0"), "")
        hw.set_state(set(), False)
        self.assertEqual(hw._driver("0000:00:14.0"), "piix4_smbus")
        self.assertEqual(hw.restore(), [])
        rescans = [w for w, _ in hw.writes if w.endswith("rescan")]
        self.assertTrue(rescans)
        self.assertNotIn("class/pci_bus/0000:00/rescan", rescans)
        self.assertNotIn("bus/pci/rescan", rescans)

    def test_restore_puts_everything_back(self):
        hw, devs = self.hw()
        hw.set_state({"wifi", "usb4", "xhci-kbd", "smbus"}, False)
        put(os.path.join(self.sys, "class/leds/asus::kbd_backlight/brightness"), "0")
        self.assertEqual(hw.restore(), [])
        self.assertEqual(hw.present, set(devs))
        self.assertEqual(B.rd(os.path.join(self.sys, "class/leds/asus::kbd_backlight/brightness")), "2")
        with open(os.path.join(self.tmp, "state.json")) as f:
            st = json.load(f)
        self.assertTrue(st["done"])
        self.assertEqual(sorted(st["touched"]), ["smbus", "usb4", "wifi", "xhci-kbd"])

    def test_runner_on_the_stand_in(self):
        hw, _ = self.hw()
        model = {1: {"wifi"}, 5: {"xhci-kbd"}, 21: {"usb4", "xhci-67:00.3"}}
        base = 0xffce9add

        def sample(secs, probes=False):
            m = base
            for b, hs in model.items():
                gone = all(hw.groups[h]["top"] not in hw.present for h in hs)
                m = m | (1 << b) if gone else m
            return {"masks": [m] * 10, "gm": [], "bat": [7.0], "status": ["Discharging"], "rtx": ["suspended"]}
        hw.sample = sample
        hw.clock = lambda: 0.0
        a = B.parse(["--no-screen"])
        r = B.Runner(hw, list(hw.groups.values()), a)
        res = r.run()
        self.assertEqual(res["holders"], {"1": ["wifi"], "5": ["xhci-kbd"], "21": ["xhci-67:00.3", "usb4"]})
        self.assertEqual(res["internal"], [8, 10, 13, 14, 16, 20])
        self.assertEqual([w["label"] for w in res["watts"]], ["baseline", "all-off", "wifi", "xhci-kbd", "xhci-67:00.3+usb4",
                                                              "baseline", "rtx"])
        self.assertTrue(all(res["verified"].values()))
        self.assertEqual(hw.removed, frozenset(GROUPS))  # everything off together at the end, until the restore
        self.assertEqual(sum(1 for w, _ in hw.writes if w == "bus/pci/devices/0000:00:03.1/remove"), 1)
        self.assertEqual(sum(1 for w, _ in hw.writes if w == "class/pci_bus/0000:00/rescan"), 0)  # not until the restore
        self.assertEqual(hw.restore(), [])
        self.assertEqual(hw.removed, frozenset())
        self.assertEqual(sum(1 for w, _ in hw.writes if w == "class/pci_bus/0000:00/rescan"), 1)

    def runner(self, hw):
        hw.sample = lambda secs, probes=False: {"masks": [0xffce9add] * 10, "gm": [], "bat": [7.0],
                                                "status": ["Discharging"], "rtx": ["suspended"]}
        hw.clock = lambda: 0.0
        return B.Runner(hw, list(hw.groups.values()), B.parse(["--no-screen"]))

    def test_an_awake_rtx_at_the_end_is_skipped_and_said(self):
        hw, _ = self.hw()
        r = self.runner(hw)
        real = hw.set_state

        def set_state(removed, screen_off, frozen=False):  # the RTX wakes during pass 2
            if any(p["why"] == "watts" for p in r.phases):
                put(os.path.join(self.paths["0000:64:00.0"], "power", "runtime_status"), "active")
            return real(removed, screen_off, frozen)
        hw.set_state = set_state
        res = r.run()
        self.assertEqual(res["rtx"], {"skipped": "the RTX is active, not runtime-suspended"})
        q = next(p for p in r.phases if p["why"] == "quiet")
        self.assertEqual(q["removed"], [g for g in GROUPS if g != "rtx"])
        self.assertNotIn("bus/pci/devices/0000:00:03.1/remove", [w for w, _ in hw.writes])
        md = B.report(res, r.phases, list(hw.groups.values()), {}, {}, {}, B.parse([]))
        self.assertIn("Not removed: rtx (the RTX is active, not runtime-suspended).", md)

    def test_a_stuck_remove_stops_the_run_without_a_rescan(self):
        hw, _ = self.hw(block={"bus/pci/devices/0000:00:03.1/remove"})
        r = self.runner(hw)
        with self.assertRaises(B.Stuck):
            r.run()
        n = len(hw.writes)
        errs = hw.restore()
        self.assertEqual(len(errs), 1)
        self.assertIn("the write to", errs[0])
        self.assertIn("is stuck in the kernel", errs[0])
        after = [w for w, _ in hw.writes[n:]]
        self.assertFalse([w for w in after if "pci" in w], after)  # no rescan, not of the root bus, not global
        self.assertIn("class/leds/asus::kbd_backlight/brightness", after)
        with open(os.path.join(self.tmp, "state.json")) as f:
            st = json.load(f)
        self.assertTrue(st["stuck"].endswith("bus/pci/devices/0000:00:03.1/remove"))
        self.assertFalse(st["done"])
        with self.assertRaises(B.Stuck):  # and nothing else gets written to the bus
            hw._write(f"{B.SYS}/class/pci_bus/0000:63/rescan", 1)

    def test_a_write_that_blocks_times_out(self):
        hw, _ = self.hw()
        fifo = os.path.join(self.tmp, "fifo")
        os.mkfifo(fifo)  # opening it to write blocks until a reader comes: a stand-in for a stuck write
        self.assertIsNone(B.Hw._timed_write(hw, fifo, 1, 0.3))
        r = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)  # let the child go
        os.close(r)
        f = os.path.join(self.tmp, "plain")
        self.assertTrue(B.Hw._timed_write(hw, f, 1, 5))
        self.assertEqual(B.rd(f), "1")
        self.assertFalse(B.Hw._timed_write(hw, os.path.join(self.tmp, "no", "such"), 1, 5))


# ------------------------------------------------------------------ the command
class Command(Fake):
    def run_cli(self, *args, stub=True):
        env = dict(os.environ, G16_BISECT_SYS=self.sys, G16_BISECT_PROC=self.proc, HOME=self.tmp)
        if stub:  # systemd-run / pkexec stand-ins that only log
            sb = os.path.join(self.tmp, "stub")
            os.makedirs(sb, exist_ok=True)
            for n in ("systemd-run", "pkexec", "systemctl"):
                put(os.path.join(sb, n), "#!/bin/sh\necho \"$0 $*\" >>\"%s/calls\"\nexit 3" % self.tmp)
                os.chmod(os.path.join(sb, n), 0o755)
            env["PATH"] = sb + ":" + env["PATH"]
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, env=env)

    def calls(self):
        p = os.path.join(self.tmp, "calls")
        if not os.path.exists(p):
            return ""
        with open(p) as f:
            return f.read()

    def test_dry_run_changes_nothing_and_writes_the_report(self):
        before = sorted(os.path.relpath(os.path.join(d, f), self.sys) for d, _, fs in os.walk(self.sys) for f in fs)
        out = os.path.join(self.tmp, "out")
        r = self.run_cli("--dry-run", "--out", out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("nothing was changed", r.stdout)
        self.assertNotIn("would refuse", r.stdout)
        after = sorted(os.path.relpath(os.path.join(d, f), self.sys) for d, _, fs in os.walk(self.sys) for f in fs)
        self.assertEqual(before, after)
        self.assertEqual(self.calls(), "")
        with open(os.path.join(out, "report.md")) as f:
            md = f.read()
        self.assertIn("DRY RUN", md)
        self.assertIn("| 1 | Wi-Fi (mt7925e), 63:00.0 | yes |", md)
        self.assertIn("For AMD (drm/amd#5863)", md)
        self.assertNotIn(self.tmp, md)
        with open(os.path.join(out, "bisect.json")) as f:
            data = json.load(f)
        self.assertTrue(data["simulated"])
        self.assertLess(data["minutes"], 16)  # the made-up map is a hard one: 7 bits, 2 of them pairs

    def test_on_ac_it_refuses_before_starting_anything(self):
        put(os.path.join(self.sys, "class/power_supply/ACAD/online"), "1")
        r = self.run_cli()
        self.assertEqual(r.returncode, 1)
        self.assertIn("nothing was changed", r.stderr)
        self.assertIn("on AC", r.stderr)
        self.assertEqual(self.calls(), "")

    def test_list(self):
        r = self.run_cli("--list")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("xhci-kbd", r.stdout)
        self.assertIn("Preflight: ok", r.stdout)
        self.assertEqual(self.calls(), "")

    def test_bad_usage(self):
        self.assertEqual(self.run_cli("--measure", "0").returncode, 2)
        r = self.run_cli("--dry-run", "--skip", "nope", "--out", os.path.join(self.tmp, "o"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no such group", r.stderr)

    def test_the_watchdog_restores_when_the_run_is_gone(self):
        out = os.path.join(self.tmp, "out")
        os.makedirs(out)
        cg = os.path.join(self.tmp, "cg-app-firefox.scope")
        put(os.path.join(cg, "cgroup.freeze"), "1")
        put(os.path.join(out, "frozen.txt"), cg)
        st = {"done": False, "screen_off": False, "ports": {"0000:00:02.3": "auto"}, "leds": {"asus::kbd_backlight": "2"},
              "touched": {"smbus": {"top": "0000:00:14.0", "members": ["0000:00:14.0"], "method": "unbind", "bus": "0000:00",
                                    "drivers": {"0000:00:14.0": "piix4_smbus"}},
                          "wifi": {"top": "0000:63:00.0", "members": ["0000:63:00.0"], "method": "remove", "bus": "0000:63",
                                   "drivers": {"0000:63:00.0": "mt7925e"}}}}
        with open(os.path.join(out, "state.json"), "w") as f:
            json.dump(st, f)
        os.unlink(os.path.join(self.paths["0000:00:14.0"], "driver"))
        put(os.path.join(self.sys, "class/leds/asus::kbd_backlight/brightness"), "0")
        dead = subprocess.Popen(["true"])
        dead.wait()
        B.time.sleep, real = (lambda s: None), B.time.sleep
        try:
            B.stage_watchdog(B.parse(["--stage", "watchdog", "--pid", str(dead.pid), "--out", out]))
        finally:
            B.time.sleep = real
        self.assertEqual(B.rd(os.path.join(cg, "cgroup.freeze")), "0")
        self.assertFalse(os.path.exists(os.path.join(out, "frozen.txt")))
        self.assertEqual(B.rd(os.path.join(self.sys, "bus/pci/drivers/piix4_smbus/bind")), "0000:00:14.0")
        self.assertEqual(B.rd(os.path.join(self.sys, "class/pci_bus/0000:63/rescan")), "1")
        self.assertIsNone(B.rd(os.path.join(self.sys, "class/pci_bus/0000:00/rescan")) or None)
        self.assertEqual(B.rd(os.path.join(self.sys, "bus/pci/devices/0000:00:02.3/power/control")), "auto")
        self.assertEqual(B.rd(os.path.join(self.sys, "class/leds/asus::kbd_backlight/brightness")), "2")

    def test_the_watchdog_writes_nothing_to_the_bus_after_a_stuck_write(self):
        out = os.path.join(self.tmp, "out")
        os.makedirs(out)
        st = {"done": False, "screen_off": False, "stuck": f"{self.sys}/bus/pci/devices/0000:00:03.1/remove",
              "ports": {"0000:00:03.1": "auto"}, "leds": {"asus::kbd_backlight": "2"},
              "touched": {"rtx": {"top": "0000:00:03.1", "members": ["0000:00:03.1"], "method": "remove",
                                  "bus": "0000:00", "drivers": {}}}}
        put(os.path.join(self.sys, "class/leds/asus::kbd_backlight/brightness"), "0")
        B.time.sleep, real = (lambda s: None), B.time.sleep
        written = []
        B.wr, real_wr = (lambda p, v: written.append(p[len(self.sys) + 1:]) or real_wr(p, v)), B.wr
        try:
            B.restore_from_state(st, out)
        finally:
            B.time.sleep, B.wr = real, real_wr
        self.assertEqual(written, ["class/leds/asus::kbd_backlight/brightness"])

    def test_the_root_stage_refuses_without_root(self):
        if os.geteuid() == 0:
            self.skipTest("runs as root")
        r = self.run_cli("--stage", "root", "--out", self.tmp)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.calls(), "")


if __name__ == "__main__":
    unittest.main(verbosity=1)
