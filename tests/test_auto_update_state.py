#!/usr/bin/env python3
"""bin/auto-update-state: plans on upstream db freshness (#81), revdep-withdraw (an
unreadable conf fails, #89), forget and counterpart-key. Offline: hand-made check-upstream JSON, no vercmp needed (one row per
recipe and no HOLD never reaches a version comparison).

Run: python3 -I tests/test_auto_update_state.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "bin", "auto-update-state")


def row(name, status, repo, local_only=False, ours="1.0-1.1", upstream="1.0-1", recipe=None):
    return {"name": name, "ours": ours, "base": None, "repo": repo, "local_only": local_only,
            "hold": None, "upstream": upstream, "upstream_repo": None if local_only else "omarchy",
            "recipe": name if recipe is None else recipe, "status": status, "dep_mismatch": []}


def run(*args, cwd=None):
    env = dict(os.environ, BUILD_NOT_BUILT="yes")
    env.pop("SKIP_RECIPES", None)
    return subprocess.run([sys.executable, "-I", BIN, *args], capture_output=True, text=True,
                          env=env, cwd=cwd)


EXTRA_EXPIRED = {
    "upstream_dbs": [{"repo": "extra", "age": 73 * 3600 + 120, "stale": True, "expired": True,
                      "error": "download failed"},
                     {"repo": "omarchy", "age": 60, "stale": False, "expired": False, "error": None}],
    "degraded": True, "expired": ["extra"], "db_max_stale": 24 * 3600,
}
EXTRA_STALE = {
    "upstream_dbs": [{"repo": "extra", "age": 5 * 3600, "stale": True, "expired": False,
                      "error": "download failed"}],
    "degraded": True, "expired": [], "db_max_stale": 24 * 3600,
}


class PlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def plan(self, rows, **freshness):
        check = os.path.join(self.tmp.name, "check.json")
        with open(check, "w") as f:
            json.dump({"packages": rows, "prs": [], **freshness}, f)
        p = run("plan", check, os.path.join(self.tmp.name, "status.json"))
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = [ln.split("\t") for ln in p.stdout.splitlines() if ln]
        return {f[0]: f for f in lines}

    def test_expired_db_keeps_current_package(self):
        # never stock over our patch (#201): stale data builds nothing, and withdraws nothing
        line = self.plan([row("a", "current", "1.0-1.1")], **EXTRA_EXPIRED)["a"]
        self.assertEqual(line[1], "attention")
        self.assertIn("stays published", line[5])
        self.assertIn("extra", line[5])
        self.assertIn("24h", line[5])
        self.assertIn("73h", line[5])

    def test_expired_db_not_built_is_attention(self):
        line = self.plan([row("a", "not-built", None)], **EXTRA_EXPIRED)["a"]
        self.assertEqual(line[1], "attention")
        self.assertIn("extra", line[5])

    def test_expired_db_db_row_without_recipe_unpublishes(self):
        # a removed recipe (upstream replaced our patch) is withdrawn whatever the dbs say
        line = self.plan([row("b", "current", "1.0-1.1", recipe="")], inventory_errors=[],
                         **EXTRA_EXPIRED)["(db) b"]
        self.assertEqual(line[1], "unpublish")

    def test_dep_mismatch_keeps_our_build(self):
        # never stock over our patch (#201): a moved exact-version dependency needs a recipe fix
        r = dict(row("a", "dep-mismatch", "1.0-1.1"),
                 dep_mismatch=[{"dep": "nvidia-utils", "want": "1.0", "upstream": "1.1"}])
        line = self.plan([r], inventory_errors=[])["a"]
        self.assertEqual(line[1], "attention")
        self.assertIn("stays published", line[5])
        self.assertIn("nvidia-utils=1.0", line[5])

    def test_held_recipe_behind_upstream_keeps_our_build(self):
        r = dict(row("a", "rebuild-needed", "1.0-1.1", upstream="1.1-1"), hold="waiting for a G16 boot")
        line = self.plan([r], inventory_errors=[])["a"]
        self.assertEqual(line[1], "attention")
        self.assertIn("held", line[5])
        self.assertIn("stays published", line[5])

    def test_no_recipe_with_incomplete_inventory_is_kept_even_when_stale(self):
        # the recipe may only be unreadable: withdraw nothing until the inventory is complete
        line = self.plan([row("b", "rebuild-needed", "1.0-1.1", upstream="1.1-1", recipe="")],
                         inventory_errors=["recipes/b: makepkg --printsrcinfo failed"])["(db) b"]
        self.assertEqual(line[1], "attention")

    def test_no_recipe_with_complete_inventory_unpublishes(self):
        line = self.plan([row("b", "current", "1.0-1.1", recipe="")], inventory_errors=[])["(db) b"]
        self.assertEqual(line[1], "unpublish")

    def test_expired_db_respects_keep_published(self):
        os.environ["KEEP_PUBLISHED"] = "b"
        self.addCleanup(os.environ.pop, "KEEP_PUBLISHED", None)
        line = self.plan([row("b", "current", "1.0-1.1", recipe="")], **EXTRA_EXPIRED)["(db) b"]
        self.assertEqual(line[1], "attention")
        self.assertIn("KEEP_PUBLISHED", line[5])

    def test_expired_db_keeps_package_without_upstream(self):
        line = self.plan([row("d", "current", "1.0-1.1", upstream=None)], **EXTRA_EXPIRED)["d"]
        self.assertNotEqual(line[1], "unpublish")

    def test_expired_db_leaves_local_only_recipe(self):
        line = self.plan([row("c", "local", "1.0-1.1", local_only=True, upstream=None)],
                         **EXTRA_EXPIRED)["c"]
        self.assertEqual(line[1], "current")
        self.assertEqual(line[5], "-")

    def test_degraded_db_keeps_action_and_notes_stale(self):
        plan = self.plan([row("a", "rebuild-needed", "1.0-1.1", upstream="1.1-1"),
                          row("d", "current", "1.0-1.1")], **EXTRA_STALE)
        self.assertEqual(plan["a"][1], "rebase")
        self.assertIn("stale", plan["a"][5])
        self.assertIn("extra", plan["a"][5])
        self.assertEqual(plan["d"][1], "current")
        self.assertEqual(plan["d"][5], "-")

    def test_no_freshness_keys_plans_as_before(self):
        line = self.plan([row("a", "rebuild-needed", "1.0-1.1", upstream="1.1-1")])["a"]
        self.assertEqual(line[1], "rebase")
        self.assertEqual(line[5], "-")


class RevdepWithdrawTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conf = os.path.join(self.tmp.name, "revdeps.conf")
        self.write("# kernel recipe  dkms:<recipe>  [headers=<pkgname>]\n"
                   "\n"
                   "linux-omarchy  dkms:nvidia-open-dkms  headers=linux-omarchy-headers\n")

    def write(self, text):
        with open(self.conf, "w") as f:
            f.write(text)

    def withdraw(self, withdrawn, repo, conf=None):
        p = run("revdep-withdraw", conf or self.conf, withdrawn, repo)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_headers_withdrawn_dkms_published(self):
        out = self.withdraw("linux-omarchy,linux-omarchy-headers",
                            "linux-omarchy,linux-omarchy-headers,nvidia-open-dkms")
        self.assertEqual(out, "linux-omarchy-headers\tnvidia-open-dkms\n")

    def test_dkms_not_in_repo(self):
        self.assertEqual(self.withdraw("linux-omarchy,linux-omarchy-headers",
                                       "linux-omarchy,linux-omarchy-headers"), "")

    def test_dkms_withdrawn_too(self):
        self.assertEqual(self.withdraw("linux-omarchy-headers,nvidia-open-dkms",
                                       "linux-omarchy-headers,nvidia-open-dkms"), "")

    def test_empty_csvs(self):
        self.assertEqual(self.withdraw("-", ""), "")

    def test_missing_conf(self):
        missing = os.path.join(self.tmp.name, "nope.conf")
        self.assertEqual(self.withdraw("linux-omarchy-headers", "nvidia-open-dkms", conf=missing), "")

    def test_default_headers_name(self):
        self.write("linux-g16 dkms:nvidia-open-dkms\n")
        self.assertEqual(self.withdraw("linux-g16-headers", "nvidia-open-dkms"),
                         "linux-g16-headers\tnvidia-open-dkms\n")

    def test_unreadable_conf(self):
        # Present but unreadable: exit 1, so nothing is withdrawn (#89)
        os.remove(self.conf)
        os.mkdir(self.conf)
        p = run("revdep-withdraw", self.conf, "linux-omarchy-headers", "nvidia-open-dkms")
        self.assertEqual(p.returncode, 1, p.stdout)
        self.assertIn("cannot read", p.stderr)
        self.assertEqual(p.stdout, "")


class ForgetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.status = os.path.join(self.tmp.name, "status.json")

    def recipes(self):
        with open(self.status) as f:
            return json.load(f)["recipes"]

    def test_forget_drops_entry(self):
        p = run("record", self.status, "r1", "(upstream dbs)", "attention", "none", "message=x")
        self.assertEqual(p.returncode, 0, p.stderr)
        p = run("record", self.status, "r1", "other", "ok", "build", "message=y")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("(upstream dbs)", self.recipes())
        p = run("forget", self.status, "(upstream dbs)")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn("(upstream dbs)", self.recipes())
        self.assertIn("other", self.recipes())
        p = run("summary", self.status, "r2", os.path.join(self.tmp.name, "status.md"))
        self.assertNotIn("(upstream dbs)", p.stdout)
        self.assertIn("other", p.stdout)

    def test_forget_missing_recipe(self):
        p = run("record", self.status, "r1", "other", "ok", "build")
        self.assertEqual(p.returncode, 0, p.stderr)
        p = run("forget", self.status, "(dkms check)")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(list(self.recipes()), ["other"])


class CounterpartKeyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pkg = os.path.join(self.tmp.name, "nvidia-open-dkms-1.0-1.1-x86_64.pkg.tar.zst")
        with open(self.pkg, "wb") as f:
            f.write(b"one")

    def key(self, *items):
        p = run("counterpart-key", *items)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def test_same_file_same_key(self):
        k = self.key(self.pkg)
        self.assertRegex(k, r"^[0-9a-f]{64}$")
        self.assertEqual(k, self.key(self.pkg))

    def test_file_bytes_change_key(self):
        before = self.key(self.pkg)
        with open(self.pkg, "wb") as f:
            f.write(b"two")
        self.assertNotEqual(before, self.key(self.pkg))

    def test_stock_versions_differ(self):
        self.assertNotEqual(self.key("stock:h=1-1"), self.key("stock:h=1-2"))

    def test_no_items(self):
        self.assertEqual(self.key(), "none")

    def test_missing_file(self):
        p = run("counterpart-key", os.path.join(self.tmp.name, "missing.pkg.tar.zst"))
        self.assertEqual(p.returncode, 1)
        self.assertTrue(p.stderr.strip())


if __name__ == "__main__":
    unittest.main()
