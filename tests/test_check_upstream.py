#!/usr/bin/env python3
"""Offline tests for bin/check-upstream's db freshness handling, release-cohort
dependency resolution and release channels (no network, no makepkg/vercmp).

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


COHORT = [["omarchy", "omarchy-settings"]]


class LoadCohorts(unittest.TestCase):
    def test_comments_and_blank_lines(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cohorts.conf")
            with open(path, "w", encoding="utf-8") as f:
                f.write("# release cohorts\n\n   \nomarchy  omarchy-settings  # published together\n# trailing\n")
            self.assertEqual(mod.load_cohorts(path), [["omarchy", "omarchy-settings"]])

    def test_missing_file(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(mod.load_cohorts(os.path.join(d, "cohorts.conf")), [])


class ResolveDep(unittest.TestCase):
    def test_cohort_partner_resolves_to_own_version(self):
        # On main upstream's 4.0.5-1 was compared, so omarchy (pinned to
        # omarchy-settings=4.0.5-1.2) was reported dep-mismatch forever.
        have = mod.resolve_dep("omarchy", "4.0.5-1.2", "omarchy-settings", COHORT,
                              [("omarchy", {"omarchy-settings": "4.0.5-1"})], {})
        self.assertEqual(have, "4.0.5-1.2")

    def test_rebased_cohort_member_resolves_to_its_new_version(self):
        # A rebased omarchy (--recipe-path) pins omarchy-settings=4.0.6-1.1 while the
        # base branch's omarchy-settings is still 4.0.5-1.2 (rebased in its own PR):
        # that must not flag the rebase PR, or it could never auto-merge.
        have = mod.resolve_dep("omarchy", "4.0.6-1.1", "omarchy-settings", COHORT,
                              [("omarchy", {"omarchy-settings": "4.0.6-1"})], {"omarchy-settings": "4.0.5-1.2"})
        self.assertEqual(have, "4.0.6-1.1")

    def test_dep_outside_cohort_uses_upstream(self):
        upstream = [("omarchy", {}), ("extra", {"nvidia-utils": "580.95.05-1"})]
        have = mod.resolve_dep("nvidia-open-dkms", "580.82.09-1.1", "nvidia-utils", COHORT,
                              upstream, {"nvidia-utils": "580.82.09-1.1"})
        self.assertEqual(have, "580.95.05-1")

    def test_first_upstream_repo_wins(self):
        upstream = [("omarchy", {"x": "2-1"}), ("extra", {"x": "3-1"})]
        self.assertEqual(mod.resolve_dep("y", "1-1", "x", [], upstream, {}), "2-1")

    def test_dep_missing_upstream_uses_ours_repo(self):
        have = mod.resolve_dep("foo", "1-1", "bar", COHORT,
                              [("omarchy", {}), ("extra", {})], {"bar": "1.0-1.1"})
        self.assertEqual(have, "1.0-1.1")

    def test_dep_missing_everywhere_is_none(self):
        self.assertIsNone(mod.resolve_dep("foo", "1-1", "bar", [], [("extra", {})], {}))


def conf_servers(path):
    """[(repo, server)] of [omarchy]/[core]/[extra]/[multilib] in a pacman.conf, with $repo
    and $arch filled in (the db URL is <server>/<repo>.db)."""
    out, section = [], None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("["):
                section = line.strip("[]")
            elif section in ("omarchy", "core", "extra", "multilib") and line.startswith("Server"):
                server = line.split("=", 1)[1].strip().replace("$repo", section).replace("$arch", "x86_64")
                out.append((section, f"{server}/{section}.db"))
    return out


class Channels(unittest.TestCase):
    """The upstream dbs of each release channel are its chroot's package sources, and
    env.sh's channel picks them, with that channel's local repo."""

    def test_dbs_match_the_channel_pacman_conf(self):
        for channel, conf in (("quattro", "pacman.conf"), ("rc", "pacman-rc.conf")):
            with self.subTest(channel=channel):
                dbs, _ = mod.CHANNEL_DBS[channel]
                self.assertEqual(dbs, conf_servers(os.path.join(HERE, "..", "build", conf)))

    def test_quattro_cache_is_unprefixed(self):
        # the quattro channel keeps reading and writing the cache files it always had
        self.assertEqual(mod.CHANNEL_DBS["quattro"], (mod.UPSTREAM_DBS, ""))
        self.assertNotEqual(mod.CHANNEL_DBS["rc"][1], "")

    def test_env_picks_the_channel(self):
        old = os.environ.get("OMARCHY_ASUS_CHANNEL"), os.environ.get("OMARCHY_ASUS_DATA")
        with tempfile.TemporaryDirectory() as d:
            os.environ["OMARCHY_ASUS_DATA"] = d
            try:
                for channel, repo in (("quattro", "x86_64"), ("rc", "rc-x86_64"), (None, "x86_64")):
                    with self.subTest(channel=channel):
                        if channel:
                            os.environ["OMARCHY_ASUS_CHANNEL"] = channel
                        else:
                            os.environ.pop("OMARCHY_ASUS_CHANNEL", None)
                        data, repo_dir, name, got = mod.env_from_sh()
                        self.assertEqual((data, repo_dir, name, got),
                                         (d, os.path.join(d, "repo", repo), "omarchy-asus", channel or "quattro"))
            finally:
                for k, v in zip(("OMARCHY_ASUS_CHANNEL", "OMARCHY_ASUS_DATA"), old):
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
