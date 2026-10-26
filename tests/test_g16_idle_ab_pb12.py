#!/usr/bin/env python3
"""Offline tests for g16-idle-ab --design pb12 (#276): the Plackett-Burman matrix,
the run order, and the least-squares fit of the main effects on synthetic data; and the
early stop (the A/B, pb12 and --load light): it fires on settled data and not on
ambiguous data.

  python3 -I tests/test_g16_idle_ab_pb12.py
"""
import json
import os
import random
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "g16-idle-ab")
TWEAKS = ["nmi", "nvme-apst", "sd-off", "kbd-usb", "wifi-ps", "bt-off", "voxtype", "usb4", "cacp3"]


def pb12(*args):
    return subprocess.run([SCRIPT, "--pb12", *args], check=True, capture_output=True, text=True).stdout


def rows():
    return [[1 if c == "+" else -1 for c in line] for line in pb12("rows").split()]


def plan(rounds, seed):
    return [(int(r), int(i)) for r, i, _ in (line.split() for line in pb12("plan", str(rounds), str(seed)).splitlines())]


def fit(data):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(data, f)
    try:
        return json.loads(pb12("fit", f.name))
    finally:
        os.unlink(f.name)


def synthetic(effects, rounds=2, seed=1, noise=0.0, drift=0.0, block=0.0, base=9.0, drop=()):
    """Phases in the order g16-idle-ab runs them, with known effects (W, on minus off)."""
    m, rng = rows(), random.Random(seed)
    phases = []
    for seq, (r, i) in enumerate(plan(rounds, seed)):
        on = [t for j, t in enumerate(effects) if m[i][j] > 0]
        y = base + sum(effects[t] / 2 * (1 if t in on else -1) for t in effects)
        y += drift * seq + block * (r - 1) + rng.gauss(0, noise)
        phases.append({"on": on, "round": r, "seq": seq, "design": m[i], "bat": None if seq in drop else y})
    return {"tweaks": list(effects), "phases": phases, "dummies": list(range(len(effects), 11))}


class Matrix(unittest.TestCase):
    def test_shape(self):
        m = rows()
        self.assertEqual(len(m), 12)
        self.assertTrue(all(len(r) == 11 for r in m))
        self.assertEqual(m[-1], [-1] * 11, "the last row has every tweak off")
        self.assertEqual(len({tuple(r) for r in m}), 12, "rows are distinct")

    def test_balanced(self):
        for j, col in enumerate(zip(*rows())):
            self.assertEqual(sum(col), 0, f"column {j + 1}: 6 phases on, 6 off")

    def test_orthogonal(self):
        cols = list(zip(*rows()))
        for a in range(11):
            for b in range(a + 1, 11):
                self.assertEqual(sum(x * y for x, y in zip(cols[a], cols[b])), 0, f"columns {a + 1} and {b + 1}")

    def test_half_on_per_row(self):
        # every row but the all-off one switches on 6 of the 11 columns
        self.assertEqual(sorted(sum(v > 0 for v in r) for r in rows()), [0] + [6] * 11)


class Plan(unittest.TestCase):
    def test_every_row_once_a_round(self):
        p = plan(3, 42)
        self.assertEqual(len(p), 36)
        for r in (1, 2, 3):
            self.assertEqual(sorted(i for q, i in p if q == r), list(range(12)))
        self.assertEqual([q for q, _ in p], sorted(q for q, _ in p), "rounds run one after another")

    def test_seeded_and_shuffled(self):
        self.assertEqual(plan(2, 7), plan(2, 7))
        self.assertNotEqual(plan(2, 7), plan(2, 8))
        p = plan(2, 7)
        self.assertNotEqual([i for _, i in p[:12]], [i for _, i in p[12:]], "each round has its own order")


class Fit(unittest.TestCase):
    EFFECTS = dict(zip(TWEAKS, [-0.50, 0.0, -0.30, 0.20, 0.0, -0.15, 0.80, 0.0, -0.05]))

    def test_exact_without_noise(self):
        # Drift and a shift between rounds are absorbed; the effects come back exactly.
        r = fit(synthetic(self.EFFECTS, rounds=2, drift=0.004, block=0.3))["bat"]
        self.assertTrue(r["trend"])
        self.assertEqual(r["n"], 24)
        self.assertEqual(r["df"], 24 - (1 + 9 + 1 + 1))
        for t, e in self.EFFECTS.items():
            self.assertAlmostEqual(r["effects"][t][0], e, places=6, msg=t)
        for e, _ in r["dummies"]:
            self.assertAlmostEqual(e, 0.0, places=6)

    def test_one_round_dummies_are_the_noise(self):
        # One round of 9 tweaks: 2 dummy columns are all the noise estimate there is.
        r = fit(synthetic(self.EFFECTS, rounds=1, noise=0.05, seed=3))["bat"]
        self.assertFalse(r["trend"], "no room for a drift term")
        self.assertEqual(r["df"], 2)
        self.assertEqual(len(r["dummies"]), 2)
        for t, (e, se2) in r["effects"].items():
            self.assertIsNotNone(se2, t)
            self.assertLess(abs(e - self.EFFECTS[t]), 4 * se2, t)

    def test_one_round_eight_tweaks_keeps_the_dummies(self):
        # 8 tweaks, one round: no room for a drift term once the 3 dummies are fitted.
        eff = dict(list(self.EFFECTS.items())[:8])
        r = fit(synthetic(eff, rounds=1, noise=0.05, seed=4))["bat"]
        self.assertFalse(r["trend"])
        self.assertEqual(r["df"], 3)
        self.assertEqual(len(r["dummies"]), 3)

    def test_noise_coverage(self):
        # ±2 SE covers the true effect about 95% of the time.
        hit = n = 0
        for seed in range(40):
            r = fit(synthetic(self.EFFECTS, rounds=2, noise=0.08, drift=0.002, seed=seed))["bat"]
            for t, (e, se2) in r["effects"].items():
                n += 1
                hit += abs(e - self.EFFECTS[t]) <= se2
        self.assertGreater(hit / n, 0.85, f"{hit}/{n}")
        self.assertLess(hit / n, 0.995, f"{hit}/{n}: the SE is too wide")

    def test_dummies_read_as_noise(self):
        big = 0
        for seed in range(40):
            r = fit(synthetic(self.EFFECTS, rounds=2, noise=0.08, seed=seed))["bat"]
            big += sum(abs(e) > se2 for e, se2 in r["dummies"])
        self.assertLess(big, 0.15 * 80, f"{big} of 80 dummy effects beyond 2 SE")

    def test_phases_left_out(self):
        # Invalid phases (the RTX woke) are left out; the rest still fit.
        r = fit(synthetic(self.EFFECTS, rounds=2, drop={3, 17}))["bat"]
        self.assertEqual(r["n"], 22)
        for t, e in self.EFFECTS.items():
            self.assertAlmostEqual(r["effects"][t][0], e, places=6, msg=t)

    def test_a_tweak_that_never_applied(self):
        # sd-off refused every time: it reads as off in every phase, so it isn't
        # estimable; the others still are.
        d = synthetic({**self.EFFECTS, "sd-off": 0.0})
        for p in d["phases"]:
            p["on"] = [t for t in p["on"] if t != "sd-off"]
        r = fit(d)["bat"]
        self.assertIsNone(r["effects"]["sd-off"])
        self.assertAlmostEqual(r["effects"]["voxtype"][0], 0.80, places=6)

    def test_soc_and_battery_keys(self):
        d = synthetic(self.EFFECTS)
        for p in d["phases"]:
            p["sock"] = p["bat"] / 2
        d["keys"] = ["bat", "sock"]
        r = fit(d)
        self.assertAlmostEqual(r["sock"]["effects"]["nmi"][0], -0.25, places=6)


def phase(name, tweak, rnd, bat, design=""):
    return {"name": name, "tweak": tweak, "round": rnd, "design": design, "dt": 1.0,
            "samples": [{"bat": bat, "status": "Discharging"}], "states": [], "irq": {}}


def ab_phases(deltas, rounds, noise=(), base=9.0):
    """B T1 B T2 ... B a round; tweak t reads deltas[t] + noise[round - 1] above the baseline."""
    out = []
    for r in range(1, rounds + 1):
        out.append(phase("baseline", "-", r, base))
        for t, d in deltas.items():
            out += [phase(t, t, r, base + d + (noise[r - 1] if noise else 0.0)), phase("baseline", "-", r, base)]
    return out


def pb12_phases(data):
    signs = lambda r: "".join("+" if v > 0 else "-" for v in r)  # noqa: E731
    return [phase(f"row {n}", ",".join(p["on"]) or "-", p["round"], p["bat"], signs(p["design"]))
            for n, p in enumerate(data["phases"])]


def settled(phases, design="ab", load="idle", run=None):
    """g16-idle-ab --settled on these phases -> its answer ("settled", or "open" and the tweaks)."""
    with tempfile.TemporaryDirectory() as work:
        paths = []
        for i, p in enumerate(phases):
            paths.append(os.path.join(work, f"phase-{i}.json"))
            with open(paths[-1], "w") as f:
                json.dump(p, f)
        with open(os.path.join(work, "phases"), "w") as f:
            f.write("\n".join(paths) + "\n")
        if run is None:  # the tweaks the phases measured
            run = list(dict.fromkeys(p["tweak"] for p in phases if p["tweak"] != "-"))
        with open(os.path.join(work, "run"), "w") as f:
            f.write("\n".join(run) + "\n")
        rnd = str(max(p["round"] for p in phases))
        return subprocess.run([SCRIPT, "--settled", work, design, load, rnd], check=True, capture_output=True, text=True).stdout.strip()


class EarlyStop(unittest.TestCase):
    def test_ab_settled(self):
        # nmi saves well beyond noise; wifi-ps and voxtype clearly don't (the whole
        # interval above -0.10 W, a cost included): nothing a third round could change.
        d = {"nmi": -0.50, "wifi-ps": 0.0, "voxtype": 0.30}
        self.assertEqual(settled(ab_phases(d, 2, noise=(0.01, -0.01))), "settled")

    def test_ab_ambiguous(self):
        # wifi-ps reads -0.08 W, but its ±2 SE (0.20 W) reaches past -0.10 W both ways.
        d = {"nmi": -0.50, "wifi-ps": -0.08}
        self.assertEqual(settled(ab_phases(d, 2, noise=(0.10, -0.10))), "open wifi-ps")

    def test_ab_saving_near_the_line(self):
        # -0.12 W with ±2 SE 0.04: it saves (below -0.10 W and below -2 SE), settled.
        self.assertEqual(settled(ab_phases({"nmi": -0.12}, 2, noise=(0.02, -0.02))), "settled")

    def test_ab_one_round_has_no_noise_estimate(self):
        self.assertEqual(settled(ab_phases({"nmi": -0.50}, 1)), "open nmi")

    def test_ab_left_out_phase(self):
        # A round left out (the RTX woke) leaves one valid delta: no SE, so not settled.
        p = ab_phases({"nmi": -0.50}, 2, noise=(0.01, -0.01))
        p[4]["samples"][0]["status"] = "Charging"
        self.assertEqual(settled(p), "open nmi")

    def test_ab_a_tweak_not_applied_yet(self):
        # voxtype failed to apply in rounds 1 and 2: no phase, no verdict. nmi is
        # settled, but round 3 may still measure voxtype, so the run goes on.
        p = ab_phases({"nmi": -0.50}, 2, noise=(0.01, -0.01))
        self.assertEqual(settled(p, run=["nmi", "voxtype"]), "open voxtype")
        self.assertEqual(settled(p, run=["nmi"]), "settled")

    def test_light_load(self):
        d = {"boost-off": -0.40, "epp-power": 0.05}
        self.assertEqual(settled(ab_phases(d, 2, noise=(0.02, -0.02)), load="light"), "settled")
        self.assertEqual(settled(ab_phases({"boost-off": -0.10}, 2, noise=(0.15, -0.15)), load="light"), "open boost-off")

    def test_pb12_settled(self):
        eff = dict(zip(TWEAKS, [-0.50, 0.0, -0.30, 0.20, 0.0, -0.25, 0.80, 0.0, -0.05]))
        d = synthetic(eff, rounds=2, noise=0.005, seed=2)
        self.assertEqual(settled(pb12_phases(d), design="pb12", run=TWEAKS), "settled")

    def test_pb12_ambiguous(self):
        eff = dict(zip(TWEAKS, [-0.50, 0.0, -0.30, 0.20, 0.0, -0.12, 0.80, 0.0, -0.05]))
        d = synthetic(eff, rounds=2, noise=0.15, seed=2)
        out = settled(pb12_phases(d), design="pb12", run=TWEAKS)
        self.assertTrue(out.startswith("open "), out)
        self.assertIn("bt-off", out.split())


if __name__ == "__main__":
    unittest.main()
