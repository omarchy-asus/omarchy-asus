#!/usr/bin/env python3
"""Offline tests for bin/issue (no gh calls, no real denylist).

  python3 -I tests/test_issue.py
"""
import importlib.machinery
import importlib.util
import json
import multiprocessing
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
ISSUE = os.path.join(HERE, "..", "bin", "issue")


def load_issue():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("issue_mod", ISSUE)
    spec = importlib.util.spec_from_loader("issue_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


issue = load_issue()

DENYLIST = """# throwaway test denylist
secretword
alpha|beta
/home/someuser
"""


class PiiScan(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.deny = os.path.join(self.dir.name, "denylist")
        with open(self.deny, "w") as f:
            f.write(DENYLIST)

    def tearDown(self):
        self.dir.cleanup()

    def scan(self, text):
        return issue.pii_scan(text, self.deny)

    def test_clean(self):
        self.assertEqual(self.scan("nothing to see\nhere\n"), [])

    def test_word_hit(self):
        self.assertEqual(self.scan("ok\nhas secretword in it\n"), [(2, 2)])

    def test_alternative_case_insensitive(self):
        self.assertEqual(self.scan("ok\nBETA build\n"), [(3, 2)])

    def test_embedded_is_not_a_hit(self):
        self.assertEqual(self.scan("alphabet soup\n"), [])

    def test_path(self):
        self.assertEqual(self.scan("/home/someuser/build\n"), [(4, 1)])

    def test_tab_is_allowed(self):
        self.assertEqual(self.scan("col1\tcol2\n"), [])

    def test_nul_fixture_is_refused(self):
        # A NUL makes GNU grep say "binary file matches" on stderr and print no
        # lines, which used to hide the hit on line 2 entirely.
        text = "harmless\x00\nhas secretword in it\n"
        self.assertEqual(self.scan(text), [(0, 1)])

    def test_other_control_chars_are_refused(self):
        self.assertEqual(self.scan("a\nb\x1b[31m\nc\x7f\n"), [(0, 2), (0, 3)])
        self.assertEqual(self.scan("windows\r\n"), [(0, 1)])

    def test_guard_aborts_on_nul(self):
        with self.assertRaises(SystemExit) as cm:
            issue.pii_guard("title\nbody\x00\n", self.deny)
        self.assertEqual(cm.exception.code, 1)

    def test_grep_match_without_line_output_counts(self):
        # Simulate grep exit 0 with no parsable line (e.g. binary-file mode).
        real = issue.subprocess.run

        class R:
            returncode, stdout, stderr = 0, "", "grep: x: binary file matches\n"

        issue.subprocess.run = lambda *a, **k: R()
        try:
            hits = self.scan("clean text\n")
        finally:
            issue.subprocess.run = real
        self.assertTrue(hits)
        self.assertTrue(all(t is None for _, t in hits))

    def test_missing_denylist(self):
        with self.assertRaises(OSError):
            issue.pii_scan("x", os.path.join(self.dir.name, "nope"))


def _writer(cache_dir, n, barrier, q):
    try:
        issue.CACHE_DIR = cache_dir
        payload = [{"writer": n, "pad": "x" * 2000, "i": i} for i in range(300)]

        def fetch():
            barrier.wait()   # both runs write at the same moment
            return payload

        issue.cached("o/r", "issues", fetch, refresh=True)
        q.put(None)
    except BaseException as e:   # report, don't hang the parent
        q.put(repr(e))


class ConcurrentCache(unittest.TestCase):
    def test_two_concurrent_writes(self):
        ctx = multiprocessing.get_context("fork")
        for _ in range(20):
            with tempfile.TemporaryDirectory() as d:
                cache_dir = os.path.join(d, "cache")
                barrier, q = ctx.Barrier(2), ctx.Queue()
                procs = [ctx.Process(target=_writer, args=(cache_dir, n, barrier, q))
                         for n in (1, 2)]
                for p in procs:
                    p.start()
                errors = [q.get(timeout=30) for _ in procs]
                for p in procs:
                    p.join(30)
                self.assertEqual(errors, [None, None])
                path = os.path.join(cache_dir, "o__r.issues.json")
                with open(path) as f:
                    data = json.load(f)          # valid JSON, not interleaved
                self.assertEqual(len(data), 300)
                self.assertEqual({e["writer"] for e in data} in ({1}, {2}), True)
                self.assertEqual(sorted(os.listdir(cache_dir)), ["o__r.issues.json"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
