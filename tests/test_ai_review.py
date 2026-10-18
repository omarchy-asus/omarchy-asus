#!/usr/bin/env python3
"""Offline tests for bin/ai-review (gh, git and the reviewers are mocked).

  python3 -I tests/test_ai_review.py
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.join(HERE, "..", "bin", "ai-review")
TMP = tempfile.mkdtemp(prefix="ai-review-test-")
os.environ["OMARCHY_ASUS_DATA"] = TMP


def load():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("ai_review_mod", TOOL)
    spec = importlib.util.spec_from_loader("ai_review_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


ar = load()
REPO, NUM, HEAD, MB = "omarchy-asus/omarchy-asus", 7, "a" * 40, "b" * 40


def finding(priority, verdict, title="t", path="bin/x", line=3):
    return {"priority": priority, "verdict": verdict, "title": title, "path": path,
            "start": line, "end": line, "body": "why", "reason": "checked"}


def result(findings, **kw):
    res = {"repo": REPO, "pr": NUM, "head": HEAD, "base": MB, "merge_base": MB, "reviewer": "codex m",
           "findings": findings, "verifier": "codex m", "_commentable": {}, "reviewed": True,
           "seconds": 1, "default_base": True, "blocking": ar.count_blocking(findings)}
    res.update(kw)
    return res


class Patch:
    """Replace module attributes for one test."""

    def __init__(self, **attrs):
        self.attrs, self.saved = attrs, {}

    def __enter__(self):
        for k, v in self.attrs.items():
            self.saved[k] = getattr(ar, k)
            setattr(ar, k, v)
        return self

    def __exit__(self, *exc):
        for k, v in self.saved.items():
            setattr(ar, k, v)


class P:  # a subprocess result
    def __init__(self, rc=0, out=""):
        self.returncode, self.stdout, self.stderr = rc, out, ""


class Authors(unittest.TestCase):
    def test_owner_account_is_ours(self):
        self.assertTrue(ar.is_ours({"author": {"login": "Maintainer"}, "body": ""}, {"maintainer"}))

    def test_agent_signature_is_ours(self):
        for body in ("Fixes #3\n\nFiled by laptop-claude", "x\n_Filed by auto-update_\n", "- Filed by codex"):
            self.assertTrue(ar.is_ours({"author": {"login": "someone"}, "body": body}, {"maintainer"}), body)

    def test_external_is_not_ours(self):
        for body in ("", None, "this was not filed by anyone", "Filed by"):
            self.assertFalse(ar.is_ours({"author": {"login": "someone"}, "body": body}, {"maintainer"}), body)
        self.assertFalse(ar.is_ours({"author": None, "body": ""}, {"maintainer"}))

    def test_ours_logins(self):
        os.environ["AI_REVIEW_OURS"] = "Alice, bot ,"
        try:
            self.assertEqual(ar.ours_logins(), {"alice", "bot"})
        finally:
            del os.environ["AI_REVIEW_OURS"]
        with Patch(gh_json=lambda *a: {"login": "Me"}):
            self.assertEqual(ar.ours_logins(), {"me"})


class Cache(unittest.TestCase):
    def setUp(self):
        self.cache = os.path.join(tempfile.mkdtemp(dir=TMP), "c.json")

    def write(self, path, obj, t):
        with open(path, "w") as fh:
            json.dump({**obj, "saved_at": t}, fh)

    def test_missing(self):
        self.assertIsNone(ar.load_cache(self.cache))

    def test_unposted_alone_is_restored(self):
        self.write(self.cache + ".unposted", {"v": "new"}, 2)
        self.assertEqual(ar.load_cache(self.cache)["v"], "new")
        self.assertTrue(os.path.exists(self.cache))
        self.assertFalse(os.path.exists(self.cache + ".unposted"))

    def test_newer_unposted_beats_older_posted_cache(self):  # issue #60
        self.write(self.cache, {"v": "old", "posted": True}, 1)
        self.write(self.cache + ".unposted", {"v": "new"}, 2)
        res = ar.load_cache(self.cache)
        self.assertEqual(res["v"], "new")
        self.assertFalse(res.get("posted"))
        self.assertEqual(json.load(open(self.cache))["v"], "new")
        self.assertFalse(os.path.exists(self.cache + ".unposted"))

    def test_older_unposted_is_dropped(self):
        self.write(self.cache, {"v": "cur"}, 5)
        self.write(self.cache + ".unposted", {"v": "stale"}, 2)
        self.assertEqual(ar.load_cache(self.cache)["v"], "cur")
        self.assertFalse(os.path.exists(self.cache + ".unposted"))

    def test_save_json_stamps_time(self):
        res = {"v": 1}
        ar.save_json(self.cache, res)
        self.assertGreater(json.load(open(self.cache))["saved_at"], 0)


class FakeGH:
    """gh_json for review_pr: the PR, the repo, statuses; records POSTs."""

    def __init__(self, status=None):
        self.status, self.calls = status, []

    def __call__(self, *args):
        self.calls.append(args)
        if args[:2] == ("pr", "view"):
            return {"headRefOid": HEAD, "baseRefOid": MB, "baseRefName": "main", "title": "t",
                    "isCrossRepository": False}
        if args[:2] == ("api", f"repos/{REPO}"):
            return {"default_branch": "main"}
        if args[0] == "api" and args[1].endswith("/status"):
            return {"statuses": [self.status] if self.status else []}
        if args[:3] == ("api", "-X", "POST"):
            return {"id": 99, "html_url": "u"}
        if args[:2] == ("api", "graphql"):
            return {"data": {"repository": {"pullRequest": {"reviews": {"nodes": []}, "comments": {"nodes": []}}}}}
        raise AssertionError(f"unexpected gh call {args}")


class ReviewPR(unittest.TestCase):
    def setUp(self):
        ar.DATA = tempfile.mkdtemp(dir=TMP)
        self.reviews = []
        self.posted = []
        self.statuses = []

    def fake_review(self, findings):
        def review_tree(root, base, title, diff):
            self.reviews.append(findings)
            return {k: v for k, v in result(findings).items()
                    if k not in ("repo", "pr", "head", "base", "merge_base", "default_base")}
        return review_tree

    def patches(self, gh, findings=(), post_fails=False, extra=None):
        @contextlib.contextmanager
        def checkout(*a, **k):
            class C:
                root, diff = "/nonexistent", ""
            yield C()

        def post(repo, num, res, roots):
            self.posted.append(("post", res["findings"]))
            if post_fails:
                raise RuntimeError("network down")

        attrs = dict(gh_json=gh, merge_base=lambda *a: MB, Checkout=checkout,
                     review_tree=self.fake_review(list(findings)), post=post,
                     set_status=lambda repo, head, state, desc, url=None: self.statuses.append((state, desc)))
        attrs.update(extra or {})
        return Patch(**attrs)

    def test_forced_repost_failure_is_retried_not_stale(self):  # issue #60
        gh = FakeGH(status={"context": "ai-review", "state": "success",
                            "description": f"0 blocking | mb {MB[:12]} by codex"})
        with self.patches(gh, findings=[finding(1, "confirmed", "new")], post_fails=True):
            cache = os.path.join(ar.DATA, f"{ar.slug(REPO)}-{NUM}-{HEAD}-{MB[:12]}-main-codex.json")
            ar.save_json(cache, result([], posted=True))  # an older, posted review of this head
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(RuntimeError):
                    ar.review_pr(REPO, NUM, do_post=True, force=True)
            self.assertEqual(len(self.reviews), 1, "--force reviews again even with --post")
            self.assertEqual(self.statuses[-1][0], "error")
        with self.patches(gh, findings=[]):
            with contextlib.redirect_stderr(io.StringIO()):
                res = ar.review_pr(REPO, NUM, do_post=True)
        self.assertEqual(res["findings"][0]["title"], "new", "the newer unposted result wins")
        self.assertTrue(res["posted"])
        self.assertEqual(len(self.posted), 2, "posting is retried")
        self.assertEqual(len(self.reviews), 1, "and not reviewed again")

    def test_forced_review_failure_never_falls_back_to_old_status(self):  # issue #60
        gh = FakeGH(status={"context": "ai-review", "state": "success",
                            "description": f"0 blocking | mb {MB[:12]} by codex"})

        def boom(*a):
            raise RuntimeError("codex down")
        with self.patches(gh, extra={"review_tree": boom}):
            with self.assertRaises(RuntimeError):
                ar.review_pr(REPO, NUM, do_post=True, force=True)
        with self.patches(gh):
            with self.assertRaisesRegex(RuntimeError, "no local review"):
                ar.review_pr(REPO, NUM, do_post=True)

    def test_stamp_reuses_local_review(self):
        gh = FakeGH()
        stamped = []
        local = ar.local_cache_path(REPO, HEAD, MB)
        ar.save_json(local, {**result([finding(3, "confirmed")]), "local": True})
        with self.patches(gh, extra={"stamp": lambda repo, num, res, roots: stamped.append(res)}):
            with contextlib.redirect_stderr(io.StringIO()):
                res = ar.review_pr(REPO, NUM, do_stamp=True)
        self.assertEqual(self.reviews, [], "no second review of the same head and merge-base")
        self.assertEqual(len(stamped), 1)
        self.assertTrue(res["posted"])
        self.assertNotIn("local", res)

    def test_local_review_of_other_merge_base_is_not_reused(self):
        gh = FakeGH()
        ar.save_json(ar.local_cache_path(REPO, HEAD, "c" * 40), {**result([]), "merge_base": "c" * 40})
        with self.patches(gh, extra={"stamp": lambda *a: None}):
            with contextlib.redirect_stderr(io.StringIO()):
                ar.review_pr(REPO, NUM, do_stamp=True)
        self.assertEqual(len(self.reviews), 1)

    def test_post_still_needs_a_local_review(self):
        with self.patches(FakeGH()):
            with self.assertRaisesRegex(RuntimeError, "no local review"):
                ar.review_pr(REPO, NUM, do_post=True)


class Stamp(unittest.TestCase):
    def run_stamp(self, res, post=None):
        gh = FakeGH()
        statuses, minimized = [], []
        with Patch(gh_json=gh, pii_check=lambda text: None,
                   set_status=lambda repo, head, state, desc, url=None: statuses.append((state, desc, url)),
                   minimize_previous=lambda repo, num, keep=(): minimized.append(set(keep)),
                   post=post or (lambda *a: (_ for _ in ()).throw(AssertionError("no full review")))):
            with contextlib.redirect_stderr(io.StringIO()):
                ar.stamp(REPO, NUM, res, [None])
        return gh, statuses, minimized

    def test_clean_posts_status_only(self):
        res = result([finding(2, "refuted")])
        gh, statuses, minimized = self.run_stamp(res)
        self.assertEqual([c for c in gh.calls if c[:3] == ("api", "-X", "POST")], [], "no comment, no review")
        self.assertEqual(statuses[0][0], "success")
        self.assertIn(f"mb {MB[:12]} by codex", statuses[0][1])  # final_status must recognise it
        self.assertEqual(res["mode"], "stamp")
        self.assertEqual(minimized, [{None}])

    def test_nonblocking_findings_get_one_comment_line(self):
        res = result([finding(2, "confirmed", "a"), finding(3, "uncertain", "b"), finding(1, "refuted", "c")])
        gh, statuses, minimized = self.run_stamp(res)
        posts = [c for c in gh.calls if c[:3] == ("api", "-X", "POST")]
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0][3], f"repos/{REPO}/issues/{NUM}/comments")
        body = posts[0][5][len("body="):]
        self.assertNotIn("\n", body)
        self.assertTrue(body.startswith(ar.MARK.format(head=HEAD)))
        self.assertIn("2 non-blocking", body)
        self.assertEqual(res["comment_id"], 99)
        self.assertEqual(minimized, [{99}], "the new comment is kept, older summaries minimized")
        self.assertEqual(statuses[0][0], "success")

    def test_blocking_falls_back_to_full_review(self):
        called = []
        res = result([finding(1, "confirmed")])
        gh, statuses, _ = self.run_stamp(res, post=lambda *a: called.append(a))
        self.assertEqual(len(called), 1)
        self.assertEqual(statuses, [])

    def test_non_default_base_gets_no_status(self):
        gh, statuses, _ = self.run_stamp(result([], default_base=False))
        self.assertEqual(statuses, [])


class Minimize(unittest.TestCase):
    def test_minimizes_only_earlier_ai_review_summaries(self):
        nodes = {"reviews": {"nodes": [
            {"id": "R_old", "databaseId": 1, "body": "<!-- ai-review:abc -->\nold", "isMinimized": False, "viewerCanMinimize": True},
            {"id": "R_new", "databaseId": 2, "body": "<!-- ai-review:def -->\nnew", "isMinimized": False, "viewerCanMinimize": True},
            {"id": "R_done", "databaseId": 3, "body": "<!-- ai-review:x -->", "isMinimized": True, "viewerCanMinimize": True},
            {"id": "R_human", "databaseId": 4, "body": "LGTM", "isMinimized": False, "viewerCanMinimize": True}]},
            "comments": {"nodes": [
                {"id": "C_old", "databaseId": 5, "body": "<!-- ai-review:abc --> ai-review of x", "isMinimized": False, "viewerCanMinimize": True},
                {"id": "C_noperm", "databaseId": 6, "body": "<!-- ai-review:abc -->", "isMinimized": False, "viewerCanMinimize": False}]}}
        queries, runs = [], []
        with Patch(gh_json=lambda *a: queries.append(a) or {"data": {"repository": {"pullRequest": nodes}}},
                   run=lambda cmd, **k: runs.append(cmd) or P()):
            done = ar.minimize_previous(REPO, 12, keep={2})
        self.assertEqual(done, ["R_old", "C_old"])
        q = queries[0]
        self.assertIn("owner=omarchy-asus", q)
        self.assertIn("number=12", q)
        for cmd in runs:
            self.assertEqual(cmd[:3], ["gh", "api", "graphql"])
            query = next(x for x in cmd if x.startswith("query="))
            self.assertIn("minimizeComment", query)
            self.assertIn("classifier:OUTDATED", query)
        self.assertEqual([next(x for x in c if x.startswith("id=")) for c in runs], ["id=R_old", "id=C_old"])

    def test_failure_is_logged_not_raised(self):
        def bad(*a):
            raise RuntimeError("graphql down")
        with Patch(gh_json=bad):
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(ar.minimize_previous(REPO, 1), [])
        self.assertIn("could not list", err.getvalue())

    def test_post_minimizes_after_submitting(self):
        order = []
        with Patch(pii_check=lambda t: None,
                   submit_review=lambda *a: order.append("review") or {"id": 42, "html_url": "u"},
                   minimize_previous=lambda repo, num, keep=(): order.append(("minimize", set(keep))),
                   set_status=lambda *a, **k: order.append("status")):
            ar.post(REPO, NUM, result([finding(2, "confirmed")]), [None])
        self.assertEqual(order, ["review", ("minimize", {42}), "status"])


class Local(unittest.TestCase):
    def test_print_local(self):
        out = io.StringIO()
        ar.print_local({**result([finding(1, "confirmed", "bad"), finding(2, "refuted", "meh")]),
                        "base_ref": "main", "title": "subject"}, out)
        text = out.getvalue()
        self.assertIn(f"ai-review of {HEAD[:12]}", text)
        self.assertIn("BLOCKING [P1] confirmed", text)
        self.assertIn("BLOCKING: 1", text)
        out = io.StringIO()
        ar.print_local({**result([finding(3, "confirmed")]), "base_ref": "main"}, out)
        self.assertIn("CLEAN", out.getvalue())


def tearDownModule():
    import shutil
    shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
