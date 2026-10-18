#!/usr/bin/env python3
"""Offline tests for bin/check-upstream's db freshness handling (no network,
no makepkg/vercmp).

  python3 -I tests/test_check_upstream.py
"""
import importlib.machinery
import importlib.util
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "check-upstream")


def load_check_upstream():
    sys.dont_write_bytecode = True
    os.environ.setdefault("OMARCHY_ASUS_WORKSPACE", os.path.join(HERE, ".."))
    loader = importlib.machinery.SourceFileLoader("check_upstream_mod", SCRIPT)
    spec = importlib.util.spec_from_loader("check_upstream_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


mod = load_check_upstream()

URL = "https://example.invalid/core.db"
DAY = 24 * 3600


class FakeResponse:
    def __init__(self, data):
        self.data = data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self.data


def unreachable(*args, **kwargs):
    raise OSError("unreachable")


class Fetch(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.dir.name, "core.db")
        self.real_urlopen = mod.urllib.request.urlopen
        self.real_stderr = sys.stderr
        sys.stderr = open(os.devnull, "w")

    def tearDown(self):
        mod.urllib.request.urlopen = self.real_urlopen
        sys.stderr.close()
        sys.stderr = self.real_stderr
        self.dir.cleanup()

    def write_cache(self, data, age):
        with open(self.cache, "wb") as f:
            f.write(data)
        t = time.time() - age
        os.utime(self.cache, (t, t))

    def test_stale_within_max_stale(self):
        self.write_cache(b"cached", 2 * 3600)
        mod.urllib.request.urlopen = unreachable
        data, info = mod.fetch(URL, self.cache, mod.DB_TTL, False, max_stale=DAY)
        self.assertEqual(data, b"cached")
        self.assertTrue(info["stale"])
        self.assertFalse(info["expired"])
        self.assertIn("unreachable", info["error"])
        self.assertGreaterEqual(info["age"], 2 * 3600 - 5)

    def test_stale_past_max_stale_is_expired(self):
        self.write_cache(b"cached", 3 * DAY)
        mod.urllib.request.urlopen = unreachable
        data, info = mod.fetch(URL, self.cache, mod.DB_TTL, False, max_stale=DAY)
        self.assertEqual(data, b"cached")
        self.assertTrue(info["stale"])
        self.assertTrue(info["expired"])
        self.assertGreater(info["age"], DAY)

    def test_stale_without_max_stale_never_expires(self):
        self.write_cache(b"cached", 3 * DAY)
        mod.urllib.request.urlopen = unreachable
        data, info = mod.fetch(URL, self.cache, mod.DB_TTL, False)
        self.assertEqual(data, b"cached")
        self.assertTrue(info["stale"])
        self.assertFalse(info["expired"])

    def test_no_cache_raises(self):
        mod.urllib.request.urlopen = unreachable
        with self.assertRaises(OSError):
            mod.fetch(URL, self.cache, mod.DB_TTL, False, max_stale=DAY)

    def test_fresh_cache_skips_download(self):
        self.write_cache(b"cached", 60)

        def must_not_download(*args, **kwargs):
            self.fail("urlopen called for a cache younger than the ttl")

        mod.urllib.request.urlopen = must_not_download
        data, info = mod.fetch(URL, self.cache, mod.DB_TTL, False, max_stale=DAY)
        self.assertEqual(data, b"cached")
        self.assertFalse(info["stale"])
        self.assertFalse(info["expired"])
        self.assertIsNone(info["error"])

    def test_download_writes_cache(self):
        self.write_cache(b"old", 2 * 3600)
        mod.urllib.request.urlopen = lambda *a, **k: FakeResponse(b"new")
        data, info = mod.fetch(URL, self.cache, mod.DB_TTL, False, max_stale=DAY)
        self.assertEqual(data, b"new")
        self.assertEqual(info["age"], 0)
        self.assertFalse(info["stale"])
        self.assertFalse(info["expired"])
        self.assertIsNone(info["error"])
        with open(self.cache, "rb") as f:
            self.assertEqual(f.read(), b"new")
        self.assertFalse(os.path.exists(self.cache + ".tmp"))


class FreshnessSummary(unittest.TestCase):
    def test_one_expired(self):
        dbs = [{"repo": "omarchy", "age": 10, "stale": False, "expired": False, "error": None},
               {"repo": "core", "age": 3 * DAY, "stale": True, "expired": True, "error": "unreachable"}]
        s = mod.freshness_summary(dbs, DAY)
        self.assertTrue(s["degraded"])
        self.assertEqual(s["expired"], ["core"])
        self.assertEqual(s["upstream_dbs"], dbs)
        self.assertEqual(s["db_max_stale"], DAY)

    def test_all_fresh(self):
        dbs = [{"repo": "core", "age": 0, "stale": False, "expired": False, "error": None}]
        s = mod.freshness_summary(dbs, DAY)
        self.assertFalse(s["degraded"])
        self.assertEqual(s["expired"], [])


class DbMaxStale(unittest.TestCase):
    KEY = "OMARCHY_ASUS_DB_MAX_STALE"

    def setUp(self):
        self.saved = os.environ.pop(self.KEY, None)

    def tearDown(self):
        os.environ.pop(self.KEY, None)
        if self.saved is not None:
            os.environ[self.KEY] = self.saved

    def test_unset_is_default(self):
        self.assertEqual(mod.db_max_stale(), 86400)

    def test_empty_is_default(self):
        os.environ[self.KEY] = ""
        self.assertEqual(mod.db_max_stale(), 86400)

    def test_seconds(self):
        os.environ[self.KEY] = "3600"
        self.assertEqual(mod.db_max_stale(), 3600)

    def test_invalid(self):
        for bad in ("abc", "0", "-5"):
            os.environ[self.KEY] = bad
            with self.assertRaises(SystemExit, msg=bad):
                mod.db_max_stale()


if __name__ == "__main__":
    unittest.main()
