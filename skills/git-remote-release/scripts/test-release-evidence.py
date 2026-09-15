"""Offline regression checks. No GitHub or model calls."""

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("collector", Path(__file__).with_name("collect-release-evidence.py"))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


def commit(sha, login="service[bot]", message="Service update"):
    return {"sha": sha, "author": {"login": login} if login else None,
            "html_url": f"https://github.com/example/widget/commit/{sha}",
            "commit": {"message": message, "author": {"name": "Recorded Name"}}}


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.prefix = "repos/example/widget"
        self.pr = {"number": 22, "title": "Service update", "user": {"login": "service[bot]"},
                   "html_url": "https://github.com/example/widget/pull/22", "merged_at": "today",
                   "merge_commit_sha": "squash", "base": {"repo": {"full_name": "example/widget"}},
                   "commits": 3, "changed_files": 1, "body": "Only dependencies"}
        self.routes = {
            "/commits/v1": [{"sha": "base"}], "/commits/v2": [{"sha": "head"}],
            "/compare/base...head?per_page=100": [{"total_commits": 1, "commits": [commit("squash")],
                "files": [{"filename": "CONTRIBUTING.md", "patch": "+New workflow"}]}],
            "/commits/squash/pulls?per_page=100": [[{"number": 22}]],
            "/pulls/22": [self.pr],
            "/pulls/22/commits?per_page=100": [[commit("a")], [commit("b", "automation"), commit("c", "human")]],
            "/pulls/22/files?per_page=100": [[{"filename": "CONTRIBUTING.md", "patch": "+New workflow"}]],
        }
        self.calls = []

    def api(self, endpoint):
        self.calls.append(endpoint)
        value = self.routes[endpoint.removeprefix(self.prefix)]
        if isinstance(value, Exception):
            raise value
        return value

    def collect(self):
        return collector.collect("example/widget", "v1", "v2", self.api)

    def draft(self, evidence):
        return "## What's Changed\n\nUpdated contributor workflow.\n\nSources:\n\n" + "\n".join(evidence["sources"]) + "\n\n**Full Changelog**: https://github.com/example/widget/compare/v1...v2"

    def test_squash_expands_all_pages_and_preserves_changes(self):
        evidence = self.collect()
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(evidence["sources"], ["* Service update by @service[bot], @automation and @human in https://github.com/example/widget/pull/22"])
        self.assertEqual(len(evidence["pull_requests"][0]["commits"]), 3)
        self.assertIn("New workflow", evidence["files"][0]["patch"])
        self.assertEqual(collector.verify(evidence, self.draft(evidence)), [])

    def test_missing_contributor_and_duplicate_source_fail_verification(self):
        evidence = self.collect()
        draft = self.draft(evidence)
        self.assertTrue(collector.verify(evidence, draft.replace(", @automation and @human", "")))
        self.assertTrue(collector.verify(evidence, draft.replace("Sources:", "Sources:\n" + evidence["sources"][0])))
        self.assertTrue(collector.verify(evidence, draft.replace("Sources:", "Sources:\n- Extra source by @someone")))

    def test_failed_association_is_not_a_direct_commit(self):
        self.routes["/commits/squash/pulls?per_page=100"] = RuntimeError("HTTP 403")
        evidence = self.collect()
        self.assertFalse(evidence["complete"])
        self.assertEqual(evidence["sources"], [])
        self.assertTrue(collector.verify(evidence, self.draft(evidence)))

    def test_commit_and_file_caps_fail_closed(self):
        for field in ("commits", "changed_files"):
            with self.subTest(field=field):
                self.pr[field] += 1
                self.assertFalse(self.collect()["complete"])
                self.pr[field] -= 1
        self.routes["/compare/base...head?per_page=100"][0]["total_commits"] = 2
        self.assertFalse(self.collect()["complete"])

    def test_empty_association_allows_direct_commit(self):
        self.routes["/commits/squash/pulls?per_page=100"] = [[]]
        evidence = self.collect()
        self.assertTrue(evidence["complete"])
        self.assertIn("/commit/squash", evidence["sources"][0])

    def test_compare_pagination_deduplicates_pr_and_keeps_source_order(self):
        pages = self.routes["/compare/base...head?per_page=100"]
        pages[0]["commits"] = [commit("direct", "person")]
        pages[0]["total_commits"] = 3
        pages.append({"commits": [commit("squash"), commit("a")]})
        self.routes["/commits/direct/pulls?per_page=100"] = [[]]
        self.routes["/commits/a/pulls?per_page=100"] = [[{"number": 22}]]
        evidence = self.collect()
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(len(evidence["sources"]), 2)
        self.assertIn("/commit/direct", evidence["sources"][0])
        self.assertEqual(len(evidence["pull_requests"]), 1)
        self.assertEqual(self.calls.count(self.prefix + "/pulls/22/commits?per_page=100"), 1)

    def test_compare_file_cap_is_explicit(self):
        self.routes["/compare/base...head?per_page=100"][0]["files"] = [
            {"filename": str(index)} for index in range(300)]
        evidence = self.collect()
        self.assertFalse(evidence["complete"])
        self.assertIn("300", " ".join(evidence["issues"]))

    def test_open_pr_excluded_and_uncertain_integration_reported(self):
        self.pr["merged_at"] = None
        self.assertTrue(self.collect()["complete"])
        self.pr["merged_at"] = "today"
        self.pr["merge_commit_sha"] = "outside"
        evidence = self.collect()
        self.assertFalse(evidence["complete"])
        self.assertEqual(evidence["sources"], [])

    def test_author_fallback_coauthors_and_case_deduplication(self):
        values = [commit("a", "Human"), commit("b", "human"),
                  commit("c", None, "Fix\n\nCo-authored-by: Other Person <other@example.com>")]
        self.assertEqual(collector.contributors(values), ["@Human", "Recorded Name", "Other Person"])

    def test_gh_transport_uses_paginated_read_only_argument_array(self):
        with patch.object(collector.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = "[[1], [2]]"
            self.assertEqual(collector.github("repos/example/widget/pulls"), [[1], [2]])
            self.assertEqual(run.call_args.args[0][:7], ["gh", "api", "--method", "GET", "--paginate", "--slurp", "repos/example/widget/pulls"])
            run.return_value.returncode = 1
            run.return_value.stderr = "rate limited"
            with self.assertRaises(RuntimeError):
                collector.github("repos/example/widget/pulls")


if __name__ == "__main__":
    unittest.main()
