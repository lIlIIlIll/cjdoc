"""Offline contract tests for the managed Codex review completion gate."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import codex_review_gate as gate


HEAD = "13520cbff8287e88b43d488990ff09c105cf5023"
OLD_HEAD = "305c4d4a7588f09d1d4f180fd3062ad204f23377"
URL = "https://github.com/lIlIIlIll/cjdoc/pull/133"


def summary(
    sha=HEAD,
    status="completed",
    unresolved=False,
    updated="2026-10-19T02:32:22Z",
    user=None,
    body=None,
):
    if user is None:
        user = {"login": gate.CODEX_BOT_LOGIN, "id": gate.CODEX_BOT_ID, "type": "Bot"}
    if body is None:
        state = {
            "code_review": {
                "commit_sha": sha,
                "status": status,
                "has_any_findings": unresolved,
                "has_unresolved_findings": unresolved,
            },
            "security_review": {"commit_sha": OLD_HEAD, "status": "completed"},
        }
        body = gate.SUMMARY_PREFIX + (
            "<!-- codex-review-state:v1 " + json.dumps(state) + " -->\n"
        )
    return {
        "id": 123,
        "user": user,
        "body": body,
        "updated_at": updated,
        "html_url": URL + "#issuecomment-123",
        "performed_via_github_app": {"slug": "chatgpt-codex-connector"},
    }


class DecisionTests(unittest.TestCase):
    def decide(self, *comments):
        return gate.classify_codex_review(HEAD, list(comments), URL)

    def test_clean_review_with_full_sha_succeeds(self):
        result = self.decide(summary())
        self.assertEqual(result.state, "success")
        self.assertIn("completed", result.description)

    def test_review_with_unresolved_findings_means_completed_not_clean(self):
        result = self.decide(summary(unresolved=True))
        self.assertEqual(result.state, "success")
        self.assertIn("need triage", result.description)

    def test_missing_summary_is_pending(self):
        self.assertEqual(self.decide().state, "pending")

    def test_stale_review_is_pending(self):
        self.assertEqual(self.decide(summary(sha=OLD_HEAD)).state, "pending")

    def test_same_short_prefix_but_different_full_sha_is_pending(self):
        close = HEAD[:-1] + ("0" if HEAD[-1] != "0" else "1")
        self.assertEqual(self.decide(summary(sha=close)).state, "pending")

    def test_running_or_queued_review_is_pending(self):
        for status in ("queued", "in_progress", "running"):
            with self.subTest(status=status):
                self.assertEqual(self.decide(summary(status=status)).state, "pending")

    def test_running_review_has_null_finding_flags(self):
        # Observed on live PR #134 while the Codex review was still running.
        result = self.decide(summary(status="running", unresolved=None))
        self.assertEqual(result.state, "pending")

    def test_queued_review_without_commit_or_findings_is_pending(self):
        result = self.decide(summary(sha=None, status="queued", unresolved=None))
        self.assertEqual(result.state, "pending")

    def test_completed_review_with_null_finding_flag_fails_closed(self):
        result = self.decide(summary(status="completed", unresolved=None))
        self.assertEqual(result.state, "error")

    def test_failed_and_cancelled_review_fail_closed(self):
        for status in ("failed", "error", "cancelled", "timed_out"):
            with self.subTest(status=status):
                self.assertEqual(self.decide(summary(status=status)).state, "failure")

    def test_invalid_or_unknown_schema_fails_closed(self):
        bad = summary(body=gate.SUMMARY_PREFIX + "<!-- codex-review-state:v2 {} -->\n")
        self.assertEqual(self.decide(bad).state, "error")

    def test_duplicate_json_keys_rejected(self):
        body = gate.SUMMARY_PREFIX + (
            '<!-- codex-review-state:v1 {"code_review":{},"code_review":{}} -->\n'
        )
        self.assertEqual(self.decide(summary(body=body)).state, "error")

    def test_security_only_completion_cannot_satisfy_code_review(self):
        body = gate.SUMMARY_PREFIX + (
            '<!-- codex-review-state:v1 {"security_review":{"commit_sha":"'
            + HEAD
            + '","status":"completed"}} -->\n'
        )
        self.assertEqual(self.decide(summary(body=body)).state, "error")

    def test_untrusted_user_cannot_spoof_summary(self):
        for user in (
            {"login": "attacker", "id": 12, "type": "User"},
            {"login": gate.CODEX_BOT_LOGIN, "id": 42, "type": "Bot"},
            {"login": gate.CODEX_BOT_LOGIN, "id": gate.CODEX_BOT_ID, "type": "User"},
        ):
            with self.subTest(user=user):
                self.assertEqual(self.decide(summary(user=user)).state, "pending")

    def test_untrusted_app_identity_is_rejected(self):
        forged = summary()
        forged["performed_via_github_app"]["slug"] = "another-app"
        self.assertEqual(self.decide(forged).state, "pending")

    def test_newest_summary_takes_precedence_over_prior_completion(self):
        old = summary(status="completed", updated="2026-10-19T02:30:00Z")
        new = summary(status="in_progress", updated="2026-10-19T02:40:00Z")
        new["id"] = 124
        self.assertEqual(self.decide(old, new).state, "pending")

    def test_cannot_use_review_receipt_without_canonical_summary(self):
        fake_review = {
            **summary(),
            "body": "<!-- codex-review-receipt:v1 -->\nReviewed commit: `13520cbff8`",
        }
        self.assertEqual(self.decide(fake_review).state, "pending")

    def test_missing_boolean_flag_fails_closed(self):
        body = gate.SUMMARY_PREFIX + (
            '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"'
            + HEAD
            + '","status":"completed"}} -->\n'
        )
        self.assertEqual(self.decide(summary(body=body)).state, "error")

    def test_description_stays_under_github_limit(self):
        self.assertLessEqual(len(self.decide(summary()).description), 140)


class EventTests(unittest.TestCase):
    def test_pull_request_target_number(self):
        self.assertEqual(
            gate.pr_number_from_event("pull_request_target", {"pull_request": {"number": 130}}),
            130,
        )

    def test_edited_codex_pr_comment(self):
        self.assertEqual(
            gate.pr_number_from_event(
                "issue_comment", {"issue": {"number": 133, "pull_request": {"url": "x"}}}
            ),
            133,
        )

    def test_deleted_codex_pr_comment(self):
        # GitHub issue_comment.deleted retains the PR issue number and bot comment.
        event = {
            "action": "deleted",
            "issue": {"number": 133, "pull_request": {"url": "x"}},
            "comment": {"user": {"login": gate.CODEX_BOT_LOGIN}},
        }
        self.assertEqual(gate.pr_number_from_event("issue_comment", event), 133)

    def test_deleted_summary_event_forces_revocation(self):
        event = {
            "action": "deleted",
            "comment": {
                "user": {"login": gate.CODEX_BOT_LOGIN, "id": gate.CODEX_BOT_ID},
                "body": summary()["body"],
            },
        }
        self.assertTrue(gate.deleted_codex_summary("issue_comment", event))
        event["comment"]["body"] = None
        self.assertTrue(gate.deleted_codex_summary("issue_comment", event))

    def test_non_summary_deletion_does_not_revoke(self):
        event = {
            "action": "deleted",
            "comment": {
                "user": {"login": gate.CODEX_BOT_LOGIN, "id": gate.CODEX_BOT_ID},
                "body": "Ordinary bot status update",
            },
        }
        self.assertFalse(gate.deleted_codex_summary("issue_comment", event))
        event["comment"]["user"]["id"] = 123
        event["comment"]["body"] = summary()["body"]
        self.assertFalse(gate.deleted_codex_summary("issue_comment", event))

    def test_ordinary_issue_comment_is_ignored(self):
        self.assertIsNone(gate.pr_number_from_event("issue_comment", {"issue": {"number": 1}}))

    def test_workflow_subscribes_to_summary_deletion(self):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/codex-review-gate.yml"
        self.assertIn("types: [created, edited, deleted]", workflow.read_text(encoding="utf-8"))

    def test_dispatch_manual_refresh(self):
        self.assertEqual(
            gate.pr_number_from_event("workflow_dispatch", {"inputs": {"pr_number": "130"}}),
            130,
        )

    def test_reject_invalid_pr_number(self):
        with self.assertRaises(ValueError):
            gate.pr_number_from_event("workflow_dispatch", {"inputs": {"pr_number": "13a"}})



class FakeAPI:
    def __init__(
        self, sha=HEAD, comments=None, state="open", merge_sha="b" * 40,
        number=133, base_sha=OLD_HEAD, other_open_prs=None,
    ):
        self.sha = sha
        self.base_sha = base_sha
        self.number = number
        self.comments = [summary()] if comments is None else comments
        self.state = state
        self.merge_sha = merge_sha
        self.other_open_prs = [] if other_open_prs is None else other_open_prs
        self.statuses = []
        self.get_merge_parents = lambda: [self.base_sha, self.sha]

    def get_pull_request(self, number):
        return {
            "state": self.state,
            "number": self.number,
            "head": {"sha": self.sha},
            "base": {"sha": self.base_sha},
            "merge_commit_sha": self.merge_sha,
            "html_url": URL,
        }

    def get_commit(self, sha):
        return {"parents": [{"sha": value} for value in self.get_merge_parents()]}

    def list_open_pull_requests(self):
        here = self.get_pull_request(self.number)
        return ([here] if self.state == "open" else []) + self.other_open_prs

    def list_issue_comments(self, number):
        return self.comments

    def create_commit_status(self, sha, decision):
        self.statuses.append((sha, decision))


class ScopeTests(unittest.TestCase):
    def test_current_pr_must_appear_in_complete_open_pr_listing(self):
        with self.assertRaises(RuntimeError):
            gate._merge_scope_is_unique(133, HEAD, OLD_HEAD, "b" * 40, [])

    def test_same_head_different_base_and_merge_is_not_ambiguous(self):
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
            "merge_commit_sha": "c" * 40,
        }
        self.assertTrue(gate._merge_scope_is_unique(
            133, HEAD, OLD_HEAD, "b" * 40,
            [{"number": 133}, other],
        ))

    def test_shared_merge_sha_is_ambiguous_even_across_bases(self):
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
            "merge_commit_sha": "b" * 40,
        }
        self.assertFalse(gate._merge_scope_is_unique(
            133, HEAD, OLD_HEAD, "b" * 40,
            [{"number": 133}, other],
        ))

    def test_same_head_and_base_is_ambiguous_even_without_other_merge_sha(self):
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": None,
        }
        self.assertFalse(gate._merge_scope_is_unique(
            133, HEAD, OLD_HEAD, "b" * 40,
            [{"number": 133}, other],
        ))

    def test_invalid_open_pr_response_fails_closed(self):
        with self.assertRaises(ValueError):
            gate._merge_scope_is_unique(133, HEAD, OLD_HEAD, "b" * 40, [{"number": "133"}])

    def test_open_pr_list_paginates_exhaustively(self):
        class Client(gate.GitHubAPI):
            def __init__(self):
                super().__init__("example/repo", "dummy")
                self.pages = []

            def _request(self, path, payload=None):
                self.pages.append(path)
                if path.endswith("&page=1"):
                    return [{"number": i} for i in range(100)]
                return [{"number": 101}]

        api = Client()
        results = api.list_open_pull_requests()
        self.assertEqual(len(results), 101)
        self.assertEqual(len(api.pages), 2)


class IntegrationTests(unittest.TestCase):
    def test_status_targets_current_pr_test_merge_not_raw_head(self):
        api = FakeAPI(comments=[summary(sha=OLD_HEAD)])
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertEqual([s[0] for s in api.statuses], ["b" * 40] * 2)
        self.assertTrue(all(s[1].state == "pending" for s in api.statuses))

    def test_current_head_review_passes_only_verified_test_merge(self):
        api = FakeAPI()
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "success")
        self.assertEqual([s[0] for s in api.statuses], ["b" * 40] * 2)
        self.assertEqual([s[1].state for s in api.statuses], ["pending", "success"])
        self.assertNotIn(HEAD, [s[0] for s in api.statuses])

    def test_missing_test_merge_never_writes_raw_head(self):
        api = FakeAPI(merge_sha=None)
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertEqual(api.statuses, [])

    def test_unverified_test_merge_does_not_pass(self):
        api = FakeAPI()
        api.get_merge_parents = lambda: [HEAD, OLD_HEAD]
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertEqual([s[1].state for s in api.statuses], ["pending"])

    def test_shared_head_different_base_prs_cannot_cross_pass(self):
        a = FakeAPI(other_open_prs=[{
            "number": 134, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
            "merge_commit_sha": "c" * 40,
        }])
        b = FakeAPI(
            number=134, base_sha="a" * 40, merge_sha="c" * 40, comments=[],
            other_open_prs=[a.get_pull_request(133)],
        )
        self.assertEqual(gate.evaluate_pr(a, 133).state, "success")
        self.assertEqual(gate.evaluate_pr(b, 134).state, "pending")
        self.assertEqual(a.statuses[-1][0], "b" * 40)
        self.assertEqual(b.statuses[-1][0], "c" * 40)
        self.assertNotIn(HEAD, [s[0] for s in a.statuses + b.statuses])

    def test_same_head_and_base_multiple_prs_never_pass(self):
        api = FakeAPI(other_open_prs=[{
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": "c" * 40,
        }])
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertIn("ambiguous", result.description)
        self.assertNotIn("success", [status.state for _, status in api.statuses])

    def test_same_test_merge_shared_by_other_pr_is_pending(self):
        api = FakeAPI(other_open_prs=[{
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
            "merge_commit_sha": "b" * 40,
        }])
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")

    def test_deleted_summary_revokes_prior_success_on_same_test_merge(self):
        api = FakeAPI()
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        api.comments = []  # After issue_comment.deleted, re-fetch finds no summary.
        self.assertEqual(gate.evaluate_pr(api, 133).state, "pending")
        self.assertEqual([x[1].state for x in api.statuses],
                         ["pending", "success", "pending", "pending"])
        self.assertEqual([x[0] for x in api.statuses], ["b" * 40] * 4)

    def test_deleted_summary_overrides_stale_older_summary(self):
        older = summary(updated="2026-10-19T02:20:00Z")
        api = FakeAPI(comments=[older])
        result = gate.evaluate_pr(api, 133, deleted_summary=True)
        self.assertEqual(result.state, "pending")
        self.assertNotIn("success", [x[1].state for x in api.statuses])

    def test_comment_api_failure_leaves_prior_status_revoked(self):
        api = FakeAPI()
        api.list_issue_comments = lambda num: (_ for _ in ()).throw(RuntimeError("no API"))
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        self.assertEqual([x[1].state for x in api.statuses], ["pending"])

    def test_open_pr_scan_failure_leaves_pending(self):
        api = FakeAPI()
        api.list_open_pull_requests = lambda: (_ for _ in ()).throw(RuntimeError("API down"))
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        self.assertEqual([x[1].state for x in api.statuses], ["pending"])

    def test_closed_pull_request_does_not_post_status(self):
        api = FakeAPI(state="closed")
        self.assertIsNone(gate.evaluate_pr(api, 133))
        self.assertEqual(api.statuses, [])


if __name__ == "__main__":
    unittest.main()
