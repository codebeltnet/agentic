"""Offline regression checks. No GitHub or model calls."""

import importlib.util
import contextlib
import io
import json
import sys
import tempfile
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

    def draft(self, evidence, summary=None):
        summary = summary or (
            "This release improves contributor-complete verification for automated service updates.\n\n"
            "- **Contributor attribution** now keeps every verified PR contributor on the shared source line,\n"
            "- **Draft verification** rejects incomplete sources and malformed release-summary structure."
        )
        target = "commits/v2" if evidence["previous"] is None else "compare/v1...v2"
        return "## What's Changed\n\n" + summary + "\n\nSources:\n\n" + "\n".join(evidence["sources"]) + "\n\n**Full Changelog**: https://github.com/example/widget/" + target

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

    def generated_notes(self, entries=None, previous="v1", tag="v2"):
        if entries is None:
            entries = "* @service[bot] made their first contribution in https://github.com/example/widget/pull/22"
        request = {"repository": "example/widget", "tag_name": tag}
        if previous is not None:
            request["previous_tag_name"] = previous
        target = f"commits/{tag}" if previous is None else f"compare/{previous}...{tag}"
        section = "\n\n## New Contributors\n" + entries if entries else ""
        return {"request": request, "response": {"body": "## What's Changed\n\n* Service update" + section +
                "\n\n**Full Changelog**: https://github.com/example/widget/" + target}}

    def with_body(self, body):
        notes = self.generated_notes()
        notes["response"]["body"] = body
        return notes

    def with_newcomers(self, evidence):
        return self.draft(evidence).replace("\n\n**Full Changelog**:",
            "\n\n## New Contributors\n\n" + "\n".join(evidence["new_contributors"]) + "\n\n**Full Changelog**:")

    def test_new_contributors_render_before_changelog_and_preserve_sources(self):
        evidence = collector.collect("example/widget", "v1", "v2", self.api, self.generated_notes())
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(evidence["new_contributors"], [
            "* **@service[bot]** made their first contribution in [#22](https://github.com/example/widget/pull/22)."])
        self.assertEqual(collector.verify(evidence, self.with_newcomers(evidence)), [])
        self.assertTrue(collector.verify(evidence, self.draft(evidence)))

    def test_new_contributors_deduplicate_case_and_keep_rest_identity(self):
        notes = self.generated_notes()
        notes["response"]["body"] = notes["response"]["body"].replace("\n\n**Full Changelog**:",
            "\n* @SERVICE[bot] made their first contribution in https://github.com/example/widget/pull/22\n\n**Full Changelog**:")
        evidence = collector.collect("example/widget", "v1", "v2", self.api, notes)
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(len(evidence["new_contributors"]), 1)
        self.assertIn("@service[bot]", evidence["new_contributors"][0])

    def test_unknown_author_out_of_range_pr_and_malformed_notes_fail_closed(self):
        for notes in (self.generated_notes("* @unknown made their first contribution in https://github.com/example/widget/pull/22"),
                      self.generated_notes("* @service[bot] made their first contribution in https://github.com/other/widget/pull/22"),
                      self.generated_notes("* @service[bot] made their first contribution in https://github.com/example/widget/pull/99"),
                      self.generated_notes("* Unrecognized contributor format"), self.with_body(None),
                      {"response": {"body": "x"}}, {}, self.generated_notes()["response"]):
            with self.subTest(notes=notes):
                evidence = collector.collect("example/widget", "v1", "v2", self.api, notes)
                self.assertFalse(evidence["complete"])
                self.assertTrue(collector.verify(evidence, self.draft(evidence)))

    def test_no_newcomers_or_unavailable_metadata_omits_section(self):
        for notes in (None, self.generated_notes("")):
            evidence = collector.collect("example/widget", "v1", "v2", self.api, notes)
            self.assertTrue(evidence["complete"], evidence["issues"])
            self.assertFalse(evidence.get("new_contributors"))
            self.assertEqual(collector.verify(evidence, self.draft(evidence)), [])
            empty = self.draft(evidence).replace("\n\n**Full Changelog**:", "\n\n## New Contributors\n\n**Full Changelog**:")
            self.assertTrue(collector.verify(evidence, empty))

    def user_commit(self, sha, login, message="Improve runner"):
        value = commit(sha, login, message)
        value["author"]["type"] = "User"
        return value

    def prior_routes(self, commits=None):
        commits = commits if commits is not None else [commit("base", "maintainer")]
        self.routes["/commits/base"] = [{"sha": "base", "commit": {"tree": {"sha": "old-tree"}}}]
        self.routes["/commits?sha=base&per_page=100"] = [list(reversed(commits))]
        self.routes["/git/trees/old-tree?recursive=1"] = [{"truncated": False, "tree": []}]
        for value in commits:
            self.routes[f"/commits/{value['sha']}/pulls?per_page=100"] = [[]]

    def test_initial_release_includes_user_commit_author_despite_bot_in_name(self):
        self.initial_routes()
        self.pr["user"]["type"] = "User"
        self.routes["/pulls/22/commits?per_page=100"][0][0] = self.user_commit("a", "aicia-bot")
        self.routes["/pulls/22/commits?per_page=100"][1][1]["author"]["type"] = "Bot"
        evidence = collector.collect("example/widget", None, "v2", self.api,
                                     self.generated_notes(previous=None))
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(evidence["new_contributors"], [
            "* **@service[bot]** made their first contribution in [#22](https://github.com/example/widget/pull/22).",
            "* **@aicia-bot** made their first contribution in [#22](https://github.com/example/widget/pull/22)."])
        self.assertIn("@human", evidence["sources"][-1])  # Bot still retains Sources credit.
        self.assertEqual(collector.verify(evidence, self.with_newcomers(evidence)), [])

    def test_generated_newcomer_can_be_verified_original_commit_author(self):
        evidence = collector.collect("example/widget", "v1", "v2", self.api,
            self.generated_notes("* @HUMAN made their first contribution in https://github.com/example/widget/pull/22"))
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertIn("@human", evidence["new_contributors"][0])

    def test_empty_generated_section_does_not_hide_new_user(self):
        self.pr["user"]["type"] = "User"
        self.pr["user"]["login"] = "new-user"
        self.prior_routes()
        evidence = collector.collect("example/widget", "v1", "v2", self.api, self.generated_notes(""))
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(len(evidence["new_contributors"]), 1)
        self.assertIn("@new-user", evidence["new_contributors"][0])

    def test_returning_commit_author_is_not_new(self):
        self.prior_routes([self.user_commit("base", "AICIA-BOT")])
        self.routes["/pulls/22/commits?per_page=100"][0][0] = self.user_commit("a", "aicia-bot")
        evidence = self.collect()
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertFalse(evidence.get("new_contributors"))

    def test_returning_author_behind_prior_squash_is_not_new(self):
        self.prior_routes()
        self.routes["/commits/base/pulls?per_page=100"] = [[{"number": 9}]]
        self.routes["/pulls/9"] = [dict(self.pr, number=9, merge_commit_sha="base", commits=1,
            html_url="https://github.com/example/widget/pull/9")]
        self.routes["/pulls/9/commits?per_page=100"] = [[self.user_commit("old-original", "aicia-bot")]]
        self.routes["/pulls/9/files?per_page=100"] = [[{"filename": "old.py"}]]
        self.routes["/pulls/22/commits?per_page=100"][0][0] = self.user_commit("a", "aicia-bot")
        evidence = self.collect()
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertFalse(evidence.get("new_contributors"))
        self.assertIn(self.prefix + "/pulls/9/commits?per_page=100", self.calls)

    def test_failed_history_does_not_prove_newcomer_status(self):
        self.pr["user"]["type"] = "User"
        self.prior_routes()
        self.routes["/commits?sha=base&per_page=100"] = RuntimeError("HTTP 403")
        evidence = self.collect()
        self.assertFalse(evidence["complete"])
        self.assertFalse(evidence.get("new_contributors"))
        self.assertIn("Prior contributor history is incomplete", ";".join(evidence["issues"]))

    def test_direct_commit_newcomer_gets_commit_link(self):
        self.initial_routes()
        self.routes["/commits?sha=squash&per_page=100"][1][0] = self.user_commit("root", "founder")
        evidence = collector.collect("example/widget", None, "v2", self.api)
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(evidence["new_contributors"], [
            "* **@founder** made their first contribution in [root](https://github.com/example/widget/commit/root)."])
        self.assertEqual(collector.verify(evidence, self.with_newcomers(evidence)), [])

    def test_coauthors_use_github_mapping_and_unknown_names_stay_unlinked(self):
        self.initial_routes()
        self.routes["/pulls/22/commits?per_page=100"][0][0]["commit"]["message"] += (
            "\n\nCo-authored-by: Misleading Name <co@example.com>\nCo-authored-by: Unmapped <unknown@example.com>")
        actors = [{"name": "Misleading Name", "user": {"login": "coauthor-bot", "type": "User"}},
                  {"name": "Unmapped", "user": None}]
        calls = []
        def authors(repository, sha):
            calls.append((repository, sha))
            return actors
        evidence = collector.collect("example/widget", None, "v2", self.api, author_api=authors)
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(calls, [("example/widget", "a")])
        self.assertIn("@coauthor-bot", evidence["sources"][-1])
        self.assertIn("Unmapped", evidence["sources"][-1])
        self.assertEqual(len(evidence["new_contributors"]), 1)
        self.assertIn("@coauthor-bot", evidence["new_contributors"][0])

    def test_failed_coauthor_mapping_fails_closed(self):
        self.initial_routes()
        self.routes["/pulls/22/commits?per_page=100"][0][0]["commit"]["message"] += "\nCo-authored-by: X <x@example.com>"
        def authors(repository, sha):
            raise RuntimeError("HTTP 403")
        evidence = collector.collect("example/widget", None, "v2", self.api, author_api=authors)
        self.assertFalse(evidence["complete"])
        self.assertFalse(evidence.get("new_contributors"))

    def test_returning_coauthor_is_found_in_prior_direct_history(self):
        self.prior_routes([self.user_commit("base", "coauthor")])
        self.routes["/pulls/22/commits?per_page=100"][0][0]["commit"]["message"] += "\nCo-authored-by: Co Author <co@example.com>"
        actors = [{"name": "Co Author", "user": {"login": "coauthor", "type": "User"}}]
        evidence = collector.collect("example/widget", "v1", "v2", self.api,
                                     author_api=lambda repository, sha: actors)
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertFalse(evidence.get("new_contributors"))

    def test_generated_newcomer_conflicting_with_history_fails_closed(self):
        self.pr["user"]["type"] = "User"
        self.prior_routes([self.user_commit("base", self.pr["user"]["login"])])
        evidence = collector.collect("example/widget", "v1", "v2", self.api, self.generated_notes())
        self.assertFalse(evidence["complete"])
        self.assertIn("conflict", ";".join(evidence["issues"]))

    def test_generation_for_another_range_or_repository_fails_closed(self):
        # A narrower range can omit this release's newcomers; that must not read as "none".
        narrower = self.generated_notes("", previous="v1.5")
        narrower["request"]["previous_tag_name"] = "v1"
        other_repository = self.generated_notes("")
        other_repository["request"]["repository"] = "other/widget"
        mismatches = {
            "narrower response, matching request": narrower,
            "narrower request and response": self.generated_notes("", previous="v1.5"),
            "other current tag": self.generated_notes("", tag="v3"),
            "initial generation for compare range": self.generated_notes("", previous=None),
            "missing changelog link": self.with_body("## What's Changed\n* Update"),
            "other repository": other_repository,
            "bare response without request": self.generated_notes("")["response"],
        }
        for name, notes in mismatches.items():
            with self.subTest(name):
                evidence = collector.collect("example/widget", "v1", "v2", self.api, notes)
                self.assertFalse(evidence["complete"])
                self.assertFalse(evidence.get("new_contributors"))
                self.assertTrue(any("New contributor evidence" in issue for issue in evidence["issues"]))
                self.assertTrue(collector.verify(evidence, self.draft(evidence)))

    def test_generation_for_unreleased_tag_matches_target_commitish(self):
        self.routes["/commits/head"] = [{"sha": "head"}]
        notes = self.generated_notes()
        notes["request"]["target_commitish"] = "head"
        evidence = collector.collect("example/widget", "v1", "head", self.api, notes)
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual(len(evidence["new_contributors"]), 1)

    def test_new_contributor_section_rejects_duplicates_wrong_position_and_fabrication(self):
        evidence = collector.collect("example/widget", "v1", "v2", self.api, self.generated_notes())
        draft = self.with_newcomers(evidence)
        section = "## New Contributors\n\n" + "\n".join(evidence["new_contributors"])
        for invalid in (draft.replace(section, section + "\n" + section),
                        draft.replace(section + "\n\n", "").replace("Sources:", section + "\n\nSources:"),
                        draft.replace("@service[bot]**", "@invented**"),
                        draft.replace("[#22]", "[#99]"),
                        draft.replace("made their", "made — their"),
                        draft + "\n" + section):
            self.assertTrue(collector.verify(evidence, invalid), invalid)

    def initial_routes(self):
        self.routes["/commits/v2"] = [{"sha": "squash", "commit": {"tree": {"sha": "tree"}}}]
        self.routes["/commits?sha=squash&per_page=100"] = [[commit("squash")], [commit("root", "founder")]]
        self.routes["/git/trees/tree?recursive=1"] = [{"truncated": False, "tree": [
            {"path": "src", "type": "tree"}, {"path": "src/app.py", "type": "blob"},
            {"path": "vendor", "type": "commit"}]}]
        self.routes["/commits/root/pulls?per_page=100"] = [[]]

    def test_initial_release_collects_all_history_and_uses_commits_link(self):
        self.initial_routes()
        evidence = collector.collect("example/widget", None, "v2", self.api, self.generated_notes(previous=None))
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertEqual([c["sha"] for c in evidence["commits"]], ["root", "squash"])
        self.assertEqual(evidence["files_without_patch"], ["src/app.py", "vendor"])
        self.assertFalse(any("/compare/" in call for call in self.calls))
        self.assertIn("/commit/root", evidence["sources"][0])
        draft = self.with_newcomers(evidence)
        self.assertTrue(draft.endswith("**Full Changelog**: https://github.com/example/widget/commits/v2"))
        self.assertEqual(collector.verify(evidence, draft), [])
        self.assertTrue(collector.verify(evidence, draft.replace("commits/v2", "compare/v1...v2")))

    def test_initial_release_missing_or_truncated_tree_fails_closed(self):
        self.initial_routes()
        self.routes["/git/trees/tree?recursive=1"][0]["truncated"] = True
        self.assertFalse(collector.collect("example/widget", None, "v2", self.api)["complete"])
        self.routes["/git/trees/tree?recursive=1"] = RuntimeError("HTTP 403")
        self.assertFalse(collector.collect("example/widget", None, "v2", self.api)["complete"])

    def test_compare_release_rejects_initial_history_link(self):
        evidence = self.collect()
        self.assertTrue(collector.verify(evidence, self.draft(evidence).replace("compare/v1...v2", "commits/v2")))

    def test_initial_release_empty_history_cannot_pass(self):
        self.initial_routes()
        self.routes["/commits?sha=squash&per_page=100"] = [[]]
        evidence = collector.collect("example/widget", None, "v2", self.api)
        self.assertFalse(evidence["complete"])
        self.assertTrue(any("resolved current commit" in issue for issue in evidence["issues"]))

    def test_cli_initial_release_with_saved_generation_response(self):
        self.initial_routes()
        evidence = collector.collect("example/widget", None, "v2", self.api, self.generated_notes(previous=None))
        with tempfile.TemporaryDirectory(prefix="release-evidence-") as directory:
            notes = Path(directory) / "generated-notes.json"
            output = Path(directory) / "evidence.json"
            notes.write_text(json.dumps(self.generated_notes(previous=None)), encoding="utf-8-sig")
            args = ["collector", "collect", "example/widget", "v2", "--initial-release",
                    "--generated-notes", str(notes), "--output", str(output)]
            with patch.object(sys, "argv", args), patch.object(collector, "collect", return_value=evidence) as gather, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(collector.main(), 0)
            gather.assert_called_once_with("example/widget", None, "v2", generated_notes=self.generated_notes(previous=None))
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), evidence)

    def test_cli_rejects_missing_compare_ref_and_initial_release_with_two_refs(self):
        for args in (["collect", "example/widget", "v2", "--output", "unused"],
                     ["collect", "example/widget", "v1", "v2", "--initial-release", "--output", "unused"]):
            with self.subTest(args=args), patch.object(sys, "argv", ["collector"] + args), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    collector.main()
                self.assertEqual(error.exception.code, 2)

    def test_multiple_new_contributors_preserve_first_appearance_order(self):
        evidence = self.collect()
        other = dict(self.pr, number=23, user={"login": "Human"}, html_url="https://github.com/example/widget/pull/23")
        evidence["pull_requests"].append({"metadata": other})
        notes = self.generated_notes("* @Human made their first contribution in https://github.com/example/widget/pull/23\n"
                                     "* @service[bot] made their first contribution in https://github.com/example/widget/pull/22")
        collector.add_new_contributors(evidence, notes)
        self.assertTrue(evidence["new_contributors"][0].startswith("* **@Human**"))
        self.assertTrue(evidence["new_contributors"][1].startswith("* **@service[bot]**"))
        self.assertEqual(collector.verify(evidence, self.with_newcomers(evidence)), [])

    def test_source_titles_with_em_dash_still_verify(self):
        self.pr["title"] = "Service — update"
        evidence = self.collect()
        self.assertTrue(evidence["complete"], evidence["issues"])
        self.assertIn("—", evidence["sources"][0])
        self.assertEqual(collector.verify(evidence, self.draft(evidence)), [])

    def test_summary_structure_rejects_bold_paragraph_regression(self):
        evidence = self.collect()
        draft = self.draft(evidence, (
            "**Team catalog matching precision** — The API now matches exact team components.\n\n"
            "**Enhanced test coverage and infrastructure** — Comprehensive test fixtures exercise overlapping names.\n\n"
            "**Dependency and tooling updates** — Updated dependencies and repository tooling."
        ))
        errors = collector.verify(evidence, draft)
        self.assertTrue(any("This release " in error for error in errors), errors)
        self.assertTrue(any("Bold-leading prose paragraphs" in error for error in errors), errors)
        self.assertTrue(any("dash bullet" in error for error in errors), errors)
        self.assertTrue(any("Unicode em dash" in error for error in errors), errors)

    def test_summary_structure_requires_bullets_and_natural_bold_leads(self):
        evidence = self.collect()
        without_bullets = self.draft(evidence, "This release improves contributor-complete verification.")
        self.assertTrue(any("dash bullet" in error for error in collector.verify(evidence, without_bullets)))

        label_style = self.draft(evidence, (
            "This release improves contributor-complete verification.\n\n"
            "- **Contributor attribution**: now keeps every verified PR contributor on the shared source line."
        ))
        self.assertTrue(any("label punctuation" in error for error in collector.verify(evidence, label_style)))

    def test_summary_structure_rejects_plain_blockquotes_and_unsupported_alert_markers(self):
        evidence = self.collect()
        for summary, expected in (
            (
                "This release improves contributor-complete verification.\n\n"
                "- **Contributor attribution** now keeps every verified PR contributor on the shared source line.\n\n"
                "> Just a blockquote.",
                "Plain blockquotes are not allowed",
            ),
            (
                "This release improves contributor-complete verification.\n\n"
                "- **Contributor attribution** now keeps every verified PR contributor on the shared source line.\n\n"
                "> [!OTHER]\n"
                "> Unsupported marker.",
                "supported alert markers on standalone marker lines",
            ),
        ):
            with self.subTest(expected=expected):
                errors = collector.verify(evidence, self.draft(evidence, summary))
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_summary_structure_requires_explanatory_prose_after_bold_lead(self):
        evidence = self.collect()
        summary = (
            "This release improves contributor-complete verification.\n\n"
            "- **Contributor attribution** ."
        )
        errors = collector.verify(evidence, self.draft(evidence, summary))
        self.assertTrue(any("explanatory prose" in error for error in errors), errors)

    def test_summary_structure_requires_bullet_punctuation(self):
        evidence = self.collect()
        for summary, expected in (
            (
                "This release improves contributor-complete verification.\n\n"
                "- **Contributor attribution** now keeps every verified PR contributor on the shared source line.\n"
                "- **Draft verification** rejects incomplete sources and malformed release-summary structure.",
                "Each non-final release-highlight bullet must end with a comma",
            ),
            (
                "This release improves contributor-complete verification.\n\n"
                "- **Contributor attribution** now keeps every verified PR contributor on the shared source line,",
                "The final release-highlight bullet must end with a period",
            ),
        ):
            with self.subTest(expected=expected):
                errors = collector.verify(evidence, self.draft(evidence, summary))
                self.assertTrue(any(expected in error for error in errors), errors)

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

    def test_graphql_authors_transport_paginates_and_resolves_rest_account_types(self):
        def page(nodes, more):
            return {"data": {"repository": {"object": {"authors": {
                "nodes": nodes, "totalCount": 2, "pageInfo": {"hasNextPage": more, "endCursor": "next"}}}}}}
        pages = [page([{"name": "Author", "user": {"login": "author-bot"}}], True),
                 page([{"name": "Co Author", "user": {"login": "app[bot]"}}], False)]
        with patch.object(collector.subprocess, "run") as run, patch.object(collector, "github") as rest:
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps(pages)
            rest.side_effect = lambda endpoint: [{"login": "author-bot", "type": "User"} if endpoint == "users/author-bot"
                                                else {"login": "app[bot]", "type": "Bot"}]
            actors = collector.github_authors("example/widget", "abc")
            self.assertEqual([actor["user"]["type"] for actor in actors], ["User", "Bot"])
            command = run.call_args.args[0]
            self.assertEqual(command[:5], ["gh", "api", "graphql", "--paginate", "--slurp"])
            self.assertTrue(command[6].startswith("query=query("))
            self.assertNotIn("mutation", command[6])
            self.assertEqual(rest.call_count, 2)
            for invalid in (pages[:1], [{"errors": [{"message": "denied"}]}], []):
                run.return_value.stdout = json.dumps(invalid)
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    collector.github_authors("example/widget", "abc")


if __name__ == "__main__":
    unittest.main()
