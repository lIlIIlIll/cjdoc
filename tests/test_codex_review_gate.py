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

    def test_ordinary_issue_comment_is_ignored(self):
        self.assertIsNone(gate.pr_number_from_event("issue_comment", {"issue": {"number": 1}}))

    def test_dispatch_manual_refresh(self):
        self.assertEqual(
            gate.pr_number_from_event("workflow_dispatch", {"inputs": {"pr_number": "130"}}),
            130,
        )

    def test_reject_invalid_pr_number(self):
        with self.assertRaises(ValueError):
            gate.pr_number_from_event("workflow_dispatch", {"inputs": {"pr_number": "13a"}})


class FakeAPI:
    def __init__(self, sha=HEAD, comments=None, state="open", merge_sha=None):
        self.sha = sha
        self.comments = [summary()] if comments is None else comments
        self.state = state
        self.merge_sha = merge_sha
        self.statuses = []

    def get_pull_request(self, number):
        return {"state": self.state, "head": {"sha": self.sha}, "base": {"sha": OLD_HEAD}, "merge_commit_sha": self.merge_sha, "html_url": URL}

    def get_commit(self, sha):
        return {"parents": [{"sha": OLD_HEAD}, {"sha": self.sha}]}

    def list_issue_comments(self, number):
        return self.comments

    def create_commit_status(self, sha, decision):
        self.statuses.append((sha, decision))


class IntegrationTests(unittest.TestCase):
    def test_status_targets_live_head_and_not_stale_event_payload(self):
        api = FakeAPI(sha=HEAD, comments=[summary(sha=OLD_HEAD)])
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertEqual(api.statuses[0][0], HEAD)

    def test_current_head_review_posts_success_to_head(self):
        api = FakeAPI()
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "success")
        self.assertEqual(api.statuses[0][0], HEAD)

    def test_verified_test_merge_also_receives_status(self):
        merge_sha = "b" * 40
        api = FakeAPI(merge_sha=merge_sha)
        gate.evaluate_pr(api, 133)
        self.assertEqual([s[0] for s in api.statuses], [HEAD, merge_sha])

    def test_unverified_test_merge_never_receives_status(self):
        merge_sha = "b" * 40
        api = FakeAPI(merge_sha=merge_sha)
        api.get_commit = lambda sha: {"parents": [{"sha": HEAD}, {"sha": OLD_HEAD}]}
        gate.evaluate_pr(api, 133)
        self.assertEqual([s[0] for s in api.statuses], [HEAD])

    def test_closed_pull_request_does_not_post_status(self):
        api = FakeAPI(state="closed")
        self.assertIsNone(gate.evaluate_pr(api, 133))
        self.assertEqual(api.statuses, [])


if __name__ == "__main__":
    unittest.main()
