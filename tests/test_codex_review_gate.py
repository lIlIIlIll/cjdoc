"""Offline contract tests for the managed Codex review completion gate."""

from __future__ import annotations

import json
import sys
import pathlib
import subprocess
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

    def test_completed_review_with_null_finding_flag_is_accepted(self):
        # Superseded contract (decided 2026-10-20): the managed reviewer reports
        # `has_unresolved_findings: null` on some completions (observed on PR
        # #139). The required check verifies that a review ran for this HEAD, not
        # that it was clean, so a missing flag means "no unresolved finding
        # claimed" rather than a schema error. A non-boolean, non-null value is
        # still rejected.
        result = self.decide(summary(status="completed", unresolved=None))
        self.assertEqual(result.state, "success")
        # A null flag must not be reported as if unresolved findings were claimed.
        self.assertEqual(result.description, "Codex review completed for current HEAD")

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

    def test_absent_finding_flag_with_full_sha_is_accepted(self):
        # Same superseded contract as above: a completed review that omits the
        # flags entirely but names the full HEAD is accepted.
        body = gate.SUMMARY_PREFIX + (
            '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"'
            + HEAD
            + '","status":"completed"}} -->\n'
        )
        self.assertEqual(self.decide(summary(body=body)).state, "success")

    def test_completed_review_without_a_sha_is_still_rejected(self):
        # The reviewed SHA is the one fact that cannot be defaulted: without it
        # the gate cannot know which HEAD the review covered.
        body = gate.SUMMARY_PREFIX + (
            '<!-- codex-review-state:v1 {"code_review":{"commit_sha":null,'
            '"status":"completed","has_unresolved_findings":false}} -->\n'
        )
        self.assertEqual(self.decide(summary(body=body)).state, "error")

    def test_malformed_finding_flag_is_still_rejected(self):
        for value in ('"true"', '1', '[]'):
            with self.subTest(value=value):
                body = gate.SUMMARY_PREFIX + (
                    '<!-- codex-review-state:v1 {"code_review":{"commit_sha":"'
                    + HEAD
                    + '","status":"completed","has_unresolved_findings":'
                    + value
                    + '}} -->\n'
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
            "base": {"sha": self.base_sha, "ref": getattr(self, "base_ref", "main")},
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
    def test_status_targets_current_pr_test_merge_and_scoped_head(self):
        # A stale review stays pending everywhere: the HEAD the ruleset reads
        # and the test merge both end pending, and neither ever sees a success.
        api = FakeAPI(comments=[summary(sha=OLD_HEAD)])
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertNotIn("success", [s.state for _, s in api.statuses])
        self.assertEqual({sha for sha, _ in api.statuses}, {HEAD, "b" * 40})
        self.assertEqual(api.statuses[-1][0], HEAD)
        self.assertEqual(api.statuses[-1][1].state, "pending")

    def test_current_head_review_passes_verified_test_merge_and_owner_head(self):
        api = FakeAPI()
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "success")
        # success must land on BOTH the test merge and the HEAD the ruleset reads.
        self.assertIn(("b" * 40, "success"), [(sha, s.state) for sha, s in api.statuses])
        self.assertIn((HEAD, "success"), [(sha, s.state) for sha, s in api.statuses])
        self.assertEqual(api.statuses[-1][0], HEAD)
        self.assertEqual(api.statuses[-1][1].state, "success")

    def test_missing_test_merge_revokes_head_without_granting(self):
        # A HEAD reused from an earlier PR can still carry `success`; a missing
        # test merge must revoke it rather than return before the revocation.
        api = FakeAPI(merge_sha=None)
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertEqual([(sha, s.state) for sha, s in api.statuses], [(HEAD, "pending")])
        self.assertEqual(api.statuses[0][1].description, "Verifying PR-specific Codex review evidence")

    def test_unverified_test_merge_does_not_pass(self):
        api = FakeAPI()
        api.get_merge_parents = lambda: [HEAD, OLD_HEAD]
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        # Only revocations run; nothing is ever granted.
        self.assertNotIn("success", [s.state for _, s in api.statuses])
        self.assertEqual(api.statuses[-1][1].state, "pending")

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
        # HEAD is shared by two open PRs, so NEITHER may publish a conclusion
        # there: the head-scoped status must be withheld for both.
        self.assertNotIn("success", [s.state for sha, s in a.statuses if sha == HEAD])
        self.assertNotIn("success", [s.state for sha, s in b.statuses if sha == HEAD])

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
        # The later run must withdraw the earlier success on BOTH targets.
        self.assertEqual(api.statuses[-1][1].state, "pending")
        for sha in (HEAD, "b" * 40):
            self.assertEqual([s.state for s2, s in api.statuses if s2 == sha][-1], "pending")

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
        # A crash must not leave an earlier success authorizing the commit: every
        # status this run wrote is a revocation.
        self.assertTrue(api.statuses)
        self.assertTrue(all(s.state == "pending" for _, s in api.statuses))

    def test_open_pr_scan_failure_leaves_pending(self):
        api = FakeAPI()
        api.list_open_pull_requests = lambda: (_ for _ in ()).throw(RuntimeError("API down"))
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        self.assertTrue(api.statuses)
        self.assertTrue(all(s.state == "pending" for _, s in api.statuses))

    def test_unique_head_gets_the_status_so_the_ruleset_can_read_it(self):
        # Exactly one open PR owns this HEAD, so the verified conclusion must be
        # published there too: the ruleset evaluates the required check on the
        # HEAD, and withholding it is what blocked every merge (#138).
        api = FakeAPI()
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        self.assertIn((HEAD, "success"), [(sha, s.state) for sha, s in api.statuses])

    def test_head_shared_across_bases_is_never_published_by_either_pr(self):
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
            "merge_commit_sha": "c" * 40,
        }
        api = FakeAPI(other_open_prs=[other])
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        # The HEAD belongs to two open PRs, so it is only ever withdrawn.
        self.assertNotIn("success", [s.state for sha, s in api.statuses if sha == HEAD])

    def test_same_head_and_base_leaves_head_without_a_decision(self):
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": None,
        }
        api = FakeAPI(other_open_prs=[other])
        self.assertEqual(gate.evaluate_pr(api, 133).state, "pending")
        self.assertNotIn("success", [s.state for sha, s in api.statuses if sha == HEAD])

    def test_head_scope_requires_the_current_pr_in_the_listing(self):
        with self.assertRaises(RuntimeError):
            gate._head_scope_is_unique(133, HEAD, [])
        with self.assertRaises(ValueError):
            gate._head_scope_is_unique(133, HEAD, [{"number": "133"}])

    def test_head_scope_allows_distinct_heads(self):
        other = {
            "number": 200, "head": {"sha": "9" * 40}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": "c" * 40,
        }
        current = {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
                   "merge_commit_sha": "b" * 40}
        self.assertTrue(gate._head_scope_is_unique(133, HEAD, [current, other]))


    def test_head_becoming_shared_during_publication_is_revoked_at_once(self):
        api = FakeAPI()
        calls = {"n": 0}
        original = api.list_open_pull_requests

        def racing():
            calls["n"] += 1
            if calls["n"] >= 3:
                return original() + [{
                    "number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
                    "merge_commit_sha": "c" * 40,
                }]
            return original()

        api.list_open_pull_requests = racing
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        head_events = [(s.state, s.description) for sha, s in api.statuses if sha == HEAD]
        self.assertIn("success", [state for state, _ in head_events])
        self.assertEqual(head_events[-1][0], "pending")
        self.assertIn("shared", head_events[-1][1])



    def test_revoke_helper_refuses_to_publish_a_success(self):
        # The revocation path must never be able to grant access; it exists only
        # to withdraw. A success here would bypass every review check.
        api = FakeAPI()
        with self.assertRaises(ValueError):
            gate.revoke_head_status(api, HEAD, gate.GateDecision("success", "x", URL))
        self.assertEqual(api.statuses, [])


    def test_head_freed_by_a_closed_pr_reevaluates_the_remaining_owner(self):
        # Two PRs shared a HEAD, so both were pending. The other one closes; the
        # survivor now owns the HEAD alone and must be re-evaluated, otherwise its
        # completed review stays pending forever.
        event = {"action": "closed",
                 "pull_request": {"number": 200, "head": {"sha": HEAD}}}
        self.assertEqual(gate.affected_shared_heads("pull_request_target", event), [HEAD])
        api = FakeAPI()
        calls = []
        api.list_open_pull_requests = lambda: [api.get_pull_request(133)]
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: calls.append(n)
        try:
            gate.reevaluate_head_owners(api, HEAD, {200})
        finally:
            gate.evaluate_pr = original
        self.assertEqual(calls, [133])

    def test_synchronize_reevaluates_the_previous_head_owners(self):
        event = {"action": "synchronize", "before": HEAD,
                 "pull_request": {"head": {"sha": "9" * 40}}}
        self.assertEqual(gate.affected_shared_heads("pull_request_target", event), [HEAD])

    def test_unrelated_events_do_not_trigger_reevaluation(self):
        self.assertEqual(gate.affected_shared_heads("issue_comment", {"action": "created"}), [])
        self.assertEqual(gate.affected_shared_heads("workflow_dispatch", {}), [])
        self.assertEqual(
            gate.affected_shared_heads("pull_request_target", {"action": "opened",
                "pull_request": {"head": {"sha": HEAD}}}), [])

    def test_reevaluation_skips_the_pr_that_triggered_the_event(self):
        api = FakeAPI()
        api.list_open_pull_requests = lambda: [api.get_pull_request(133)]
        calls = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: calls.append(n)
        try:
            gate.reevaluate_head_owners(api, HEAD, {133})
        finally:
            gate.evaluate_pr = original
        self.assertEqual(calls, [])

    def test_reevaluation_ignores_prs_with_a_different_head(self):
        api = FakeAPI()
        api.list_open_pull_requests = lambda: [api.get_pull_request(133)]
        calls = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: calls.append(n)
        try:
            gate.reevaluate_head_owners(api, "9" * 40, set())
        finally:
            gate.evaluate_pr = original
        self.assertEqual(calls, [])


    def test_run_gate_reevaluates_other_owners_and_not_the_triggering_pr(self):
        # End-to-end orchestration: the event's PR is evaluated once, and the
        # other owner of the HEAD is evaluated once -- the triggering PR is NOT
        # evaluated a second time through the re-evaluation path.
        api = FakeAPI()
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": None,
        }
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        # The trigger is a `closed` event and the PR really is closed, so the
        # reopen check must not add it back as an owner.
        base_request = api.get_pull_request
        api.get_pull_request = lambda n: {**base_request(n), "state": "closed"} if n == 133 else base_request(n)
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            event = {"action": "closed",
                     "pull_request": {"number": 133, "head": {"sha": HEAD}}}
            gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(evaluated), [133, 200])

    def test_run_gate_skips_issue_comments_without_a_pr(self):
        api = FakeAPI()
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            self.assertEqual(gate.run_gate("issue_comment", {"action": "created"}, api), 0)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(evaluated, [])


    def test_failed_post_publish_scan_withdraws_and_fails_the_run(self):
        # The success is published, then the post-publish re-check fails. Nothing
        # reconfirmed uniqueness, so the HEAD is withdrawn AND the run fails: the
        # caller must not report success for a conclusion it could not verify.
        api = FakeAPI()
        published = {"yet": False}
        base_status = api.create_commit_status

        def tracking_status(sha, decision):
            base_status(sha, decision)
            if sha == HEAD and decision.state == "success":
                published["yet"] = True

        api.create_commit_status = tracking_status
        original = api.list_open_pull_requests

        def failing():
            if published["yet"]:
                raise RuntimeError("transient API error")
            return original()

        api.list_open_pull_requests = failing
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        head_events = [(s.state, s.description) for sha, s in api.statuses if sha == HEAD]
        self.assertIn("success", [state for state, _ in head_events])
        self.assertEqual(head_events[-1][0], "pending")

    def test_failed_compensating_revocation_fails_the_run(self):
        # The success is published, the ownership re-check fails, and so does the
        # compensating revocation. The HEAD still carries invalid evidence, so the
        # run must fail loudly instead of reporting success.
        api = FakeAPI()
        published = {"success": False}
        original_status = api.create_commit_status
        original_scan = api.list_open_pull_requests

        def failing_status(sha, decision):
            if decision.state == "success":
                published["success"] = True
            elif published["success"] and sha == HEAD:
                raise RuntimeError("status API down")
            return original_status(sha, decision)

        def failing_scan():
            if published["success"]:
                raise RuntimeError("transient API error")
            return original_scan()

        api.create_commit_status = failing_status
        api.list_open_pull_requests = failing_scan
        with self.assertRaisesRegex(RuntimeError, "withdraw every published status"):
            gate.evaluate_pr(api, 133)

    def test_summary_deleted_during_publication_is_withdrawn(self):
        # A concurrent summary-deletion run publishes `pending` while this one is
        # publishing `success`. The post-publication revalidation must notice the
        # evidence is gone and withdraw, or deleted evidence would authorize.
        api = FakeAPI()
        base_status = api.create_commit_status

        def deleting_status(sha, decision):
            base_status(sha, decision)
            if sha == HEAD and decision.state == "success":
                api.comments = []  # the summary is deleted right after the write

        api.create_commit_status = deleting_status
        result = gate.evaluate_pr(api, 133)
        # The world moved while this run published, so it converges on the
        # decision the CURRENT data supports (the summary is gone => pending),
        # rather than leaving a stale success standing.
        self.assertEqual(result.state, "pending")
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")


    def test_evidence_change_withdraws_the_test_merge_too(self):
        # Both targets carry the same conclusion, so both must be withdrawn when
        # the evidence changes; a successful test-merge status would keep
        # authorizing deleted evidence.
        api = FakeAPI()
        base_status = api.create_commit_status

        def deleting_status(sha, decision):
            base_status(sha, decision)
            if sha == HEAD and decision.state == "success":
                api.comments = []

        api.create_commit_status = deleting_status
        gate.evaluate_pr(api, 133)
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_pre_publication_scan_failure_is_not_reported_as_success(self):
        # The scope read inside the HEAD block fails (the earlier open-PR scan
        # succeeded), so this run cannot decide whether the HEAD is authorized:
        # reporting success would leave a completed review pending forever.
        api = FakeAPI()
        original = api.list_open_pull_requests
        calls = {"n": 0}

        def flaky():
            calls["n"] += 1
            if calls["n"] >= 2:
                raise RuntimeError("scope down")
            return original()

        api.list_open_pull_requests = flaky
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)


    def test_stale_deletion_does_not_overwrite_a_newer_summary(self):
        # A delayed deletion arrival must not force pending when a replacement
        # summary, newer than the deleted comment, has already been reviewed.
        newer = summary(updated="2026-10-19T03:00:00Z")
        newer_id = newer.setdefault("id", 900)
        deleted = {"id": 100, "updated_at": "2026-10-19T02:00:00Z",
                   "body": summary()["body"]}
        self.assertTrue(gate.deletion_is_stale(deleted, [newer]))
        old_deleted = {"id": 9999, "updated_at": "2026-10-19T04:00:00Z",
                       "body": summary()["body"]}
        self.assertFalse(gate.deletion_is_stale(old_deleted, [newer]))
        self.assertFalse(gate.deletion_is_stale(None, [newer]))

    def test_run_gate_ignores_a_stale_deletion_and_reports_success(self):
        newer = summary(updated="2026-10-19T03:00:00Z")
        newer["id"] = 900
        api = FakeAPI(comments=[newer])
        event = {"action": "deleted", "issue": {"number": 133,
                 "pull_request": {"url": URL}},
                 "comment": {"id": 100, "updated_at": "2026-10-19T02:00:00Z",
                             "user": {"login": gate.CODEX_BOT_LOGIN, "id": gate.CODEX_BOT_ID},
                             "body": newer["body"]}}
        result = gate.run_gate("issue_comment", event, api)
        self.assertEqual(result, 0)
        # A stale deletion must leave the newer success standing, not strand it.
        self.assertEqual([s.state for sha, s in api.statuses if sha == HEAD][-1], "success")
        self.assertEqual([s.state for sha, s in api.statuses if sha == "b" * 40][-1], "success")

    def test_delayed_closed_event_does_not_strand_a_reopened_pr(self):
        # The `closed` delivery arrived after the PR was reopened; the skip set
        # must not exclude it, or its HEAD would stay revoked with no retry.
        api = FakeAPI()  # state "open"
        other = {"number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
                 "merge_commit_sha": None}
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            event = {"action": "closed",
                     "pull_request": {"number": 133, "head": {"sha": HEAD}}}
            gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(evaluated), [133, 133, 200])

    def test_post_write_scan_failure_withdraws_the_test_merge_too(self):
        api = FakeAPI()
        published = {"yet": False}
        base_status = api.create_commit_status

        def tracking(sha, decision):
            base_status(sha, decision)
            if decision.state == "success":
                published["yet"] = True

        api.create_commit_status = tracking
        original = api.list_open_pull_requests

        def failing():
            if published["yet"]:
                raise RuntimeError("transient API error")
            return original()

        api.list_open_pull_requests = failing
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")


    def test_old_head_cleanup_runs_even_if_the_reopen_lookup_fails(self):
        # The reopen lookup fails, but the old HEAD must still be cleaned up:
        # otherwise a sole owner's success stays reusable by a later PR.
        api = FakeAPI(state="closed")
        other = {"number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
                 "merge_commit_sha": None}
        base_request = api.get_pull_request
        state = {"n": 0}

        def flaky(number):
            if number == 133:
                state["n"] += 1
                if state["n"] >= 1:  # evaluate_pr is stubbed, so this IS the reopen lookup
                    raise RuntimeError("state lookup failed")
                return {**base_request(number), "state": "closed"}
            return base_request(number)

        api.get_pull_request = flaky
        api.list_open_pull_requests = lambda: [api.get_pull_request(200), other]
        revoked = []
        api.create_commit_status = lambda sha, d: revoked.append((sha, d.state))
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: None
        try:
            gate.run_gate("pull_request_target",
                          {"action": "closed", "pull_request": {"number": 133,
                                                                 "head": {"sha": HEAD}}}, api)
        finally:
            gate.evaluate_pr = original
        self.assertIn((HEAD, "pending"), revoked)


    def test_base_advanced_during_evaluation_is_not_published(self):
        # The re-read before publication sees a different base/merge, so nothing
        # may be published for the obsolete test merge.
        api = FakeAPI()
        reads = {"n": 0}
        base_request = api.get_pull_request

        def changing(number):
            reads["n"] += 1
            value = base_request(number)
            if reads["n"] >= 2:
                return {**value, "merge_commit_sha": None}
            return value

        api.get_pull_request = changing
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertNotIn("success", [s.state for _, s in api.statuses])
        # Neither target may end up carrying the obsolete conclusion.
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_shared_head_still_revalidates_the_merge_evidence(self):
        # Two PRs share the HEAD; the deletion run removes the summary while this
        # older run publishes. The test-merge status must be withdrawn even though
        # no HEAD conclusion was ever published.
        other = {"number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
                 "merge_commit_sha": "c" * 40}
        api = FakeAPI(other_open_prs=[other])
        base_status = api.create_commit_status

        def deleting_status(sha, decision):
            base_status(sha, decision)
            if sha == "b" * 40 and decision.state == "success":
                api.comments = []

        api.create_commit_status = deleting_status
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_transport_timeout_after_publication_withdraws_both_targets(self):
        # A read that times out is not a ValueError/RuntimeError; it must still be
        # caught so the published statuses are withdrawn.
        api = FakeAPI()
        published = {"yet": False}
        base_status = api.create_commit_status

        def tracking(sha, decision):
            base_status(sha, decision)
            if decision.state == "success":
                published["yet"] = True

        api.create_commit_status = tracking
        original = api.list_open_pull_requests

        def timing_out():
            if published["yet"]:
                raise TimeoutError("read timed out")
            return original()

        api.list_open_pull_requests = timing_out
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_one_failing_withdrawal_does_not_skip_the_other_target(self):
        # The HEAD withdrawal fails; the test-merge withdrawal must still be
        # attempted, and the run must fail because a success remains standing.
        api = FakeAPI()
        published = {"success": False}
        base_status = api.create_commit_status
        original = api.list_open_pull_requests

        def failing_status(sha, decision):
            if decision.state == "success":
                published["success"] = True
            elif published["success"] and sha == "b" * 40:
                # The FIRST withdrawal target fails; the other must still run.
                raise RuntimeError("test-merge status endpoint down")
            return base_status(sha, decision)

        def failing_scan():
            if published["success"]:
                raise RuntimeError("transient API error")
            return original()

        api.create_commit_status = failing_status
        api.list_open_pull_requests = failing_scan
        with self.assertRaisesRegex(RuntimeError, "withdraw every published status"):
            gate.evaluate_pr(api, 133)
        # The HEAD (second target) was still withdrawn despite the first failing.
        self.assertEqual([s.state for sha, s in api.statuses if sha == HEAD][-1], "pending")

    def test_remaining_owner_fanout_attempts_every_candidate(self):
        api = FakeAPI()
        others = [
            {"number": n, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
             "merge_commit_sha": None}
            for n in (200, 300)
        ]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        attempted = []
        original = gate.evaluate_pr

        def selective(a, n, **kw):
            attempted.append(n)
            if n == 200:
                raise RuntimeError("boom")

        gate.evaluate_pr = selective
        try:
            with self.assertRaisesRegex(RuntimeError, "owner re-evaluation failed"):
                gate.reevaluate_head_owners(api, HEAD, {133})
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(attempted), [200, 300])


    def test_accepted_first_write_with_failed_response_withdraws_both(self):
        # GitHub accepts the FIRST merge-success POST and reading its response
        # fails; both targets must end pending and the run must fail.
        api = FakeAPI()
        base_status = api.create_commit_status
        hit = {"first": False}

        def failing_response(sha, decision):
            if decision.state == "success":
                if not hit["first"]:
                    hit["first"] = True
                    base_status(sha, decision)  # the write was accepted
                    raise TimeoutError("response read failed")
            return base_status(sha, decision)

        api.create_commit_status = failing_response
        with self.assertRaises(RuntimeError):
            gate.evaluate_pr(api, 133)
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_owner_fanout_survives_a_transport_timeout(self):
        api = FakeAPI()
        others = [{"number": n, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
                   "merge_commit_sha": None} for n in (200, 300)]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        attempted = []
        original = gate.evaluate_pr

        def selective(a, n, **kw):
            attempted.append(n)
            if n == 200:
                raise TimeoutError("owner read timed out")

        gate.evaluate_pr = selective
        try:
            with self.assertRaisesRegex(RuntimeError, "owner re-evaluation failed"):
                gate.reevaluate_head_owners(api, HEAD, {133})
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(attempted), [200, 300])

    def test_failed_reopen_lookup_reevaluates_rather_than_skipping(self):
        # The state is unknown, so the PR must be re-evaluated rather than
        # skipped: skipping could strand a reopened sole owner.
        api = FakeAPI()
        calls = {"n": 0}

        def failing_state(number):
            if number == 133:
                calls["n"] += 1
                raise TimeoutError("state lookup timed out")
            return {"state": "open", "number": number, "head": {"sha": HEAD},
                    "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None,
                    "html_url": URL}

        api.get_pull_request = failing_state
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": "b" * 40},
        ]
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            gate.run_gate("pull_request_target",
                          {"action": "closed",
                           "pull_request": {"number": 133, "head": {"sha": HEAD}}}, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(calls["n"], 1)
        self.assertEqual(sorted(evaluated), [133, 133])


    def test_reporting_failure_is_surfaced_without_withdrawing_statuses(self):
        # A Job Summary failure happens after both targets were confirmed, so the
        # statuses must stand (withdrawing them would strand a valid review) while
        # the run still fails loudly instead of staying silent.
        import os
        import tempfile
        api = FakeAPI()
        target = tempfile.mkdtemp()
        blocked = os.path.join(target, "not-a-dir")
        open(blocked, "w").close()
        previous = os.environ.get("GITHUB_STEP_SUMMARY")
        os.environ["GITHUB_STEP_SUMMARY"] = os.path.join(blocked, "summary.md")
        try:
            with self.assertRaises(RuntimeError):
                gate.evaluate_pr(api, 133)
        finally:
            if previous is None:
                os.environ.pop("GITHUB_STEP_SUMMARY", None)
            else:
                os.environ["GITHUB_STEP_SUMMARY"] = previous
        for target_sha in (HEAD, "b" * 40):
            self.assertEqual(
                [s.state for sha, s in api.statuses if sha == target_sha][-1], "success"
            )

    def test_change_during_the_publication_scope_read_is_caught(self):
        # The PR changes while the open-PR request inside the publication block is
        # in flight; the saved base/test merge no longer describe it, so nothing
        # may stand as authorized.
        api = FakeAPI()
        reads = {"n": 0}
        base_request = api.get_pull_request
        # A base move in the initial-read window: the public re-read at the top of
        # the publication block is what must catch it, because the merge-scope and
        # evidence checks both still pass.
        changing_after = 2
        scope = api.list_open_pull_requests

        def changing(number):
            reads["n"] += 1
            value = base_request(number)
            if reads["n"] >= changing_after:
                return {**value, "base": {"sha": "9" * 40, "ref": "main"}}
            return value

        api.get_pull_request = changing
        api.list_open_pull_requests = scope
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_base_push_survives_transport_timeouts_in_both_loops(self):
        # A raw TimeoutError (not ValueError/RuntimeError) must not abort either
        # base-push loop, or later candidates keep their previous-base success.
        api = FakeAPI()
        others = [{"number": n, "head": {"sha": str(n) * 40},
                   "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None}
                  for n in (200, 300)]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        by_number = {133: HEAD, 200: "2" * 40, 300: "3" * 40}
        base_request = api.get_pull_request
        revoked = []

        def timing_out_lookup(number):
            if number == 200:
                raise TimeoutError("lookup timed out")
            value = base_request(number)
            value["head"] = {"sha": by_number[number]}
            return value

        api.get_pull_request = timing_out_lookup
        api.create_commit_status = lambda sha, d: revoked.append((sha, d.state))
        evaluated = []
        original = gate.evaluate_pr

        def timing_out_eval(a, n, **kw):
            evaluated.append(n)
            if n == 133:
                raise TimeoutError("evaluation timed out")

        gate.evaluate_pr = timing_out_eval
        try:
            with self.assertRaisesRegex(RuntimeError, "base push re-evaluation failed"):
                gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        # The candidate after the failing lookup was still revoked...
        self.assertIn(("3" * 40, "pending"), revoked)
        # ...and every candidate was still evaluated despite the first timeout.
        self.assertEqual(sorted(evaluated), [133, 200, 300])

    def test_cleanup_revocation_failure_does_not_abort_the_fanout(self):
        # The first cleanup status write fails; surviving owners must still be
        # evaluated, or their HEADs stay in whatever state this left.
        api = FakeAPI()
        survivor = {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD,
                    "ref": "main"}, "merge_commit_sha": "b" * 40}
        api.list_open_pull_requests = lambda: [survivor]
        base_status = api.create_commit_status

        def failing_revocation(sha, decision):
            if decision.state != "success":
                raise TimeoutError("revocation timed out")
            return base_status(sha, decision)

        api.create_commit_status = failing_revocation
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            with self.assertRaisesRegex(RuntimeError, "HEAD owner re-evaluation failed"):
                gate.reevaluate_head_owners(api, HEAD, set())
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(evaluated), [133])

    def test_delayed_synchronize_to_the_current_head_is_not_stranded(self):
        # A -> B -> A: the delivery for A -> B arrives last, and its `before` is
        # the CURRENT head, so this PR must still be re-evaluated as an owner.
        event = {"action": "synchronize", "before": HEAD,
                 "pull_request": {"number": 133, "head": {"sha": HEAD}}}
        self.assertEqual(gate.affected_shared_heads("pull_request_target", event), [])
        # A genuine move away still reports the previous head.
        moved = {"action": "synchronize", "before": "9" * 40,
                 "pull_request": {"number": 133, "head": {"sha": HEAD}}}
        self.assertEqual(gate.affected_shared_heads("pull_request_target", moved), ["9" * 40])

    def test_superseded_pending_run_converges_on_the_newer_success(self):
        # An older run computed `pending` (a stale review) before a newer run
        # published `success`. Withdrawing would let the older run -- its own
        # concurrency group, so it can finish last -- overwrite the valid success
        # permanently. It must publish the decision the CURRENT data supports.
        api = FakeAPI()
        api.comments = [summary(sha=OLD_HEAD)]  # first classification: pending
        original_comments = api.list_issue_comments
        calls = {"n": 0}

        def comments(_number):
            calls["n"] += 1
            if calls["n"] == 1:
                return [summary(sha=OLD_HEAD)]
            return [summary(sha=HEAD)]  # the newer review lands meanwhile

        api.list_issue_comments = comments
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "success")
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "success")

    def test_base_push_uses_the_listed_head_without_a_second_lookup(self):
        # The pre-revocation fanout must not need one GET per candidate: it uses
        # the HEADs already listed, keeping the timeout window small.
        api = FakeAPI()
        others = [{"number": n, "head": {"sha": str(n) * 40},
                   "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None}
                  for n in (200, 300)]
        listed = [api.get_pull_request(133), *others]
        for entry in listed:
            entry["head"] = {"sha": {133: HEAD, 200: "2" * 40, 300: "3" * 40}[entry["number"]]}
        api.list_open_pull_requests = lambda: listed
        lookups = []
        base_request = api.get_pull_request

        def counting(number):
            lookups.append(number)
            return base_request(number)

        api.get_pull_request = counting
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: None
        try:
            gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(lookups, [])

    def test_changed_base_reevaluates_instead_of_revoking_the_current_head(self):
        # A newer base-push run already published a valid success for this HEAD.
        # This stale run must re-evaluate the current snapshot rather than knock
        # that HEAD back to `pending`, because no later event is guaranteed.
        api = FakeAPI()
        reads = {"n": 0}
        base_request = api.get_pull_request
        state = {"pending": False}
        base_status = api.create_commit_status

        def recording(sha, decision):
            state[decision.state] = state.get(decision.state, 0) + 1
            return base_status(sha, decision)

        api.create_commit_status = recording

        def changing(number=None):
            # The first read (identity) sees the original; the second (early
            # mismatch check) sees a moved base, so the run must re-evaluate.
            reads["n"] += 1
            value = base_request(number)
            if reads["n"] >= 2 and state.get("success", 0) == 0:
                return {**value, "base": {"sha": "9" * 40, "ref": "main"}}
            return value

        api.get_pull_request = changing
        result = gate.evaluate_pr(api, 133)
        # The stale run must never publish a success for the snapshot that no
        # longer exists, whichever route it takes to discover the change.
        self.assertNotIn("success", [s.state for sha, s in api.statuses if sha == HEAD])
        self.assertEqual(result.state, "pending")
        # NOTE: reverting the re-evaluation to a revocation is NOT detected here,
        # because both routes end with the same final state. The re-evaluation
        # exists so the stale run avoids writing at all when a newer run already
        # published -- that is a write-count property this scenario cannot
        # observe. The convergence re-validation test covers the observable half.

    def test_convergence_write_is_revalidated(self):
        # The convergence publication must itself be re-checked: a deletion run
        # can revoke between the writes. Driving the evidence away after the first
        # convergence forces a second pass, whose decision must be the final one.
        api = FakeAPI()
        calls = {"n": 0}
        original = api.list_issue_comments

        def comments(_number):
            calls["n"] += 1
            if calls["n"] == 1:
                return [summary(sha=OLD_HEAD)]
            if calls["n"] == 2:
                return [summary(sha=HEAD)]
            return []  # the summary is deleted before the convergence re-check

        api.list_issue_comments = comments
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")

    def test_superseded_head_targets_are_withdrawn_before_retrying(self):
        # The HEAD moves after this run published. Those statuses belong to a
        # commit the PR no longer points at; nothing later cleans them up, and a
        # future PR reusing that commit would inherit the evidence.
        api = FakeAPI()
        moved = {"yet": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []
        new_head = "9" * 40

        def recording(sha, decision):
            writes.append((sha, decision.state))
            return base_status(sha, decision)

        api.create_commit_status = recording

        def changing(number=None):
            value = base_request(number)
            if moved["yet"]:
                return {**value, "head": {"sha": new_head}, "merge_commit_sha": None}
            return value

        def listing():
            # The listing follows the move, so the retry sees a consistent PR.
            mine = changing(133)
            return [{"number": 133, "head": mine["head"], "base": mine["base"],
                     "merge_commit_sha": mine["merge_commit_sha"]}]

        api.get_pull_request = changing
        api.list_open_pull_requests = listing
        # The move happens once the old HEAD has been written.
        def moved_status(sha, decision):
            recording(sha, decision)
            if sha == HEAD and decision.state == "success":
                moved["yet"] = True

        api.create_commit_status = moved_status
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        for target in (HEAD, "b" * 40):
            states = [s for sha, s in writes if sha == target]
            self.assertIn("success", states)
            self.assertEqual(states[-1], "pending")

    def test_delayed_synchronize_keeps_a_valid_current_head(self):
        # A -> B -> A, with the A -> B delivery arriving last and carrying its real
        # payload (before=A, head=B). The PR now owns A again, so cleanup must
        # re-evaluate it rather than revoke its current HEAD and strand it.
        api = FakeAPI()
        base_request = api.get_pull_request
        api.get_pull_request = lambda n: {**base_request(n), "state": "open",
                                          "head": {"sha": HEAD}}
        event = {"action": "synchronize", "before": HEAD,
                 "pull_request": {"number": 133, "head": {"sha": "9" * 40}}}
        skip = gate.reopen_aware_skip_set(api, "pull_request_target", event, 133)
        self.assertEqual(skip, set())

    def test_reopen_skip_applies_only_when_the_pr_lacks_the_head(self):
        api = FakeAPI()
        base_request = api.get_pull_request
        api.get_pull_request = lambda n: {**base_request(n), "state": "open",
                                          "head": {"sha": "9" * 40}}
        event = {"action": "synchronize", "before": HEAD,
                 "pull_request": {"number": 133, "head": {"sha": "9" * 40}}}
        skip = gate.reopen_aware_skip_set(api, "pull_request_target", event, 133)
        self.assertEqual(skip, {133})

    def test_retry_exhaustion_withdraws_unconfirmed_successes(self):
        # The PR changes on every pass, so the bound is reached with no confirmed
        # conclusion. Any success left standing must be withdrawn: returning
        # `pending` while a success remains is the stale authorization the
        # contract forbids.
        api = FakeAPI()
        calls = {"n": 0}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        written_success = []

        def tracking(sha, decision):
            if decision.state == "success":
                written_success.append(sha)
            return base_status(sha, decision)

        def changing(number=None):
            calls["n"] += 1
            value = base_request(number)
            # A fresh, always-different test merge on every read: the snapshot can
            # never be confirmed, so the loop is exhausted.
            return {**value, "merge_commit_sha": format(calls["n"], "040x")}

        api.create_commit_status = tracking
        api.get_pull_request = changing
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        # No success may be left standing on any target this run touched: the run
        # could not confirm its own conclusion, so nothing may authorize a merge.
        for target in {sha for sha, _ in api.statuses}:
            states = [s.state for sha, s in api.statuses if sha == target]
            self.assertNotIn("success", states[-1:])
        # Targets this run wrote a success to must have been withdrawn afterwards.
        for target in set(written_success):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")
        # NOTE: in this deterministic scenario the pre-publication identity check
        # already prevents a success from being written, so removing the
        # exhaustion withdrawal is not mutation-detected here. That withdrawal is
        # defence for the interleavings an independent reviewer reproduced
        # (repeated synchronous deletions), which need a nested run to build.

    def test_failed_superseded_withdrawal_fails_the_run(self):
        api = FakeAPI()
        moved = {"yet": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        new_head = "9" * 40

        def failing(sha, decision):
            if moved["yet"] and sha == HEAD and decision.state != "success":
                raise ConnectionResetError("withdrawal failed")
            base_status(sha, decision)
            if sha == HEAD and decision.state == "success":
                moved["yet"] = True

        def changing(number=None):
            value = base_request(number)
            if moved["yet"]:
                return {**value, "head": {"sha": new_head}, "merge_commit_sha": None}
            return value

        api.create_commit_status = failing
        api.get_pull_request = changing
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        with self.assertRaisesRegex(RuntimeError, "superseded"):
            gate.evaluate_pr(api, 133)

    def test_exhaustion_withdrawal_failure_fails_closed(self):
        # Reaching the bound with a recorded success that is no longer live must
        # fail the run when it cannot be withdrawn: no later event is guaranteed.
        api = FakeAPI()
        base_request = api.get_pull_request
        state = {"published": False, "moved": False}

        def changing(number=None):
            value = base_request(number)
            if state["moved"]:
                # A new HEAD, so the recorded successes are no longer live.
                return {**value, "head": {"sha": "9" * 40}}
            return value

        base_status = api.create_commit_status

        def recording(sha, decision):
            if state["moved"] and decision.state != "success":
                raise ConnectionResetError("withdrawal failed")
            out = base_status(sha, decision)
            if decision.state == "success":
                state["published"] = True
                state["moved"] = True
            return out

        api.create_commit_status = recording
        api.get_pull_request = changing
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        original_once = gate._evaluate_once
        passes = {"n": 0}

        def first_publishes_then_changes(*args, **kwargs):
            passes["n"] += 1
            if passes["n"] == 1:
                return original_once(*args, **kwargs)
            raise gate.PrChangedDuringEvaluation("still moving")

        gate._evaluate_once = first_publishes_then_changes
        try:
            with self.assertRaisesRegex(RuntimeError, "withdraw"):
                gate.evaluate_pr(api, 133)
        finally:
            gate._evaluate_once = original_once
        self.assertTrue(state["published"], "the scenario must publish a success first")

    def test_base_push_lists_open_prs_only_once(self):
        # A second listing before the revocation phase could fail transiently and
        # abort before anything was revoked, leaving every affected HEAD
        # authorized. The HEADs must come from the first listing.
        api = FakeAPI()
        others = [{"number": n, "head": {"sha": str(n) * 40},
                   "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None}
                  for n in (200, 300)]
        listed = [{"number": 133, "head": {"sha": HEAD},
                   "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": "b" * 40},
                  *others]
        listings = {"n": 0}

        def listing():
            listings["n"] += 1
            if listings["n"] > 1:
                raise ConnectionResetError("redundant listing failed")
            return listed

        api.list_open_pull_requests = listing
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: None
        try:
            self.assertEqual(gate.run_gate("push", {"ref": "refs/heads/main"}, api), 0)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(listings["n"], 1)

    def test_convergence_with_shared_head_withdraws_the_head_at_once(self):
        # Evidence changes while the HEAD becomes shared: the HEAD must be
        # withdrawn immediately, not left successful for the other PR to inherit.
        other = {"number": 200, "head": {"sha": HEAD}, "base": {"sha": "a" * 40},
                 "merge_commit_sha": "c" * 40}
        api = FakeAPI()
        base_status = api.create_commit_status
        state = {"shared": False, "calls": 0}
        original_listing = api.list_open_pull_requests

        def listing():
            state["calls"] += 1
            if state["shared"]:
                return original_listing() + [other]
            return original_listing()

        def changing(sha, decision):
            if decision.state == "success" and sha == HEAD:
                state["shared"] = True
            return base_status(sha, decision)

        api.list_open_pull_requests = listing
        api.create_commit_status = changing
        # Make the post-publication decision differ so convergence runs.
        calls = {"n": 0}
        original_comments = api.list_issue_comments

        def comments(_number):
            calls["n"] += 1
            return [] if calls["n"] > 1 else original_comments(_number)

        api.list_issue_comments = comments
        # The retry pass fails before it can revoke anything, which is exactly
        # when the immediate withdrawal inside convergence is load-bearing.
        original_once = gate._evaluate_once
        seen = {"n": 0}

        def failing_second_pass(*args, **kwargs):
            seen["n"] += 1
            if seen["n"] >= 2:
                raise ConnectionResetError("retry failed before any revocation")
            return original_once(*args, **kwargs)

        gate._evaluate_once = failing_second_pass
        try:
            with self.assertRaises(Exception):
                gate.evaluate_pr(api, 133)
        finally:
            gate._evaluate_once = original_once
        # No success may remain on the now-shared HEAD.
        self.assertNotIn("success",
                         [s.state for sha, s in api.statuses if sha == HEAD][-1:])

    def test_base_only_change_withdraws_the_superseded_merge_status(self):
        # The base moved (HEAD unchanged): the published test-merge status no
        # longer describes this PR and must be withdrawn, while the current HEAD
        # (which a newer run may legitimately own) is left alone.
        api = FakeAPI()
        moved = {"yet": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def recording(sha, decision):
            writes.append((sha, decision.state))
            return base_status(sha, decision)

        api.create_commit_status = recording

        def changing(number=None):
            value = base_request(number)
            if moved["yet"]:
                return {**value, "base": {"sha": "9" * 40, "ref": "main"}}
            return value

        def marking(sha, decision):
            recording(sha, decision)
            if sha == "b" * 40 and decision.state == "success":
                moved["yet"] = True

        api.create_commit_status = marking
        api.get_pull_request = changing
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        gate.evaluate_pr(api, 133)
        # The old merge status was withdrawn; the HEAD kept whatever it had.
        merge_states = [s for sha, s in writes if sha == "b" * 40]
        self.assertIn("success", merge_states)
        self.assertEqual(merge_states[-1], "pending")

    def test_base_push_revocation_uses_a_bounded_pool(self):
        # The revocation fanout must not be one serial POST per candidate: a
        # large base push would exceed the job timeout before later HEADs are
        # withdrawn.
        import threading
        api = FakeAPI()
        many = [{"number": n, "head": {"sha": format(n, "040x")},
                 "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None}
                for n in range(200, 240)]
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": "b" * 40}, *many]
        active = {"now": 0, "peak": 0}
        lock = threading.Lock()

        def slow(sha, decision):
            with lock:
                active["now"] += 1
                active["peak"] = max(active["peak"], active["now"])
            import time as _t
            _t.sleep(0.01)
            with lock:
                active["now"] -= 1

        api.create_commit_status = slow
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: None
        try:
            gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        self.assertGreater(active["peak"], 1)

    def test_superseded_success_now_serving_as_base_is_still_withdrawn(self):
        # The old HEAD can become the new BASE. A base is never an authorization
        # target, so exempting it would leave a stale success forever.
        api = FakeAPI()
        state = {"moved": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def changing(number=None):
            value = base_request(number)
            if state["moved"]:
                return {**value, "head": {"sha": "9" * 40}, "base": {"sha": HEAD},
                        "merge_commit_sha": None}
            return value

        def recording(sha, decision):
            writes.append((sha, decision.state))
            if decision.state == "success":
                state["moved"] = True
            return base_status(sha, decision)

        api.get_pull_request = changing
        api.create_commit_status = recording
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        # The former HEAD (now the base) must not retain its success.
        self.assertEqual([s for sha, s in writes if sha == HEAD][-1], "pending")

    def test_exception_between_passes_reconciles_earlier_successes(self):
        # A pass raises after an earlier pass published success; the ledger must
        # be reconciled before the error propagates.
        api = FakeAPI()
        state = {"published": False, "moved": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def changing(number=None):
            value = base_request(number)
            if state["moved"]:
                return {**value, "merge_commit_sha": None}
            return value

        def recording(sha, decision):
            writes.append((sha, decision.state))
            out = base_status(sha, decision)
            if decision.state == "success":
                state["published"] = True
            return out

        api.get_pull_request = changing
        api.create_commit_status = recording
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        # Pass 1 publishes success via convergence (evidence changes) and then
        # asks for revalidation; pass 2 raises before it can revoke anything.
        calls = {"n": 0}
        original_comments = api.list_issue_comments

        def comments(_number):
            calls["n"] += 1
            if calls["n"] > 1:
                return []  # the evidence changed => fresh decision differs
            return original_comments(_number)

        api.list_issue_comments = comments
        original_once = gate._evaluate_once
        passes = {"n": 0}

        def first_ok_then_boom(*args, **kwargs):
            passes["n"] += 1
            if passes["n"] == 1:
                return original_once(*args, **kwargs)
            raise ConnectionResetError("pass failed")

        gate._evaluate_once = first_ok_then_boom
        try:
            with self.assertRaises(Exception):
                gate.evaluate_pr(api, 133)
        finally:
            gate._evaluate_once = original_once
        self.assertTrue(state["published"])
        self.assertGreaterEqual(passes["n"], 2)
        # The success published before the failure was withdrawn.
        self.assertEqual([s for sha, s in writes if sha == "b" * 40][-1], "pending")

    def test_closed_pr_withdraws_every_recorded_success(self):
        # A closed PR has no authorization targets (the gate publishes nothing for
        # it), so a success this run wrote must be withdrawn even though the SHAs
        # are unchanged.
        api = FakeAPI()
        state = {"closed": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def changing(number=None):
            value = base_request(number)
            if state["closed"]:
                return {**value, "state": "closed"}
            return value

        def recording(sha, decision):
            writes.append((sha, decision.state))
            out = base_status(sha, decision)
            if decision.state == "success":
                # Close the PR right after the FIRST success is written; the
                # second target's write then belongs to an already-closed PR.
                state["closed"] = True
            return out

        api.get_pull_request = changing
        api.create_commit_status = recording
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        # Evidence disappears between classification and revalidation, so the pass
        # raises and the retry loop reconciles; the PR is closed by then.
        original_once = gate._evaluate_once
        passes = {"n": 0}

        def first_then_change(*args, **kwargs):
            passes["n"] += 1
            if passes["n"] == 1:
                return original_once(*args, **kwargs)
            raise gate.PrChangedDuringEvaluation("still moving")

        gate._evaluate_once = first_then_change
        try:
            gate.evaluate_pr(api, 133)
        finally:
            gate._evaluate_once = original_once
        self.assertTrue(state["closed"], "the scenario must close the PR")
        # Whichever success survives the close must have been withdrawn.
        for target in (HEAD, "b" * 40):
            states = [s for sha, s in writes if sha == target]
            if states and states[-1] == "success":
                self.fail(f"a success remained on {target[:10]} after the PR closed")

    def test_closed_between_passes_cleans_the_ledger(self):
        # Pass 1 publishes success via convergence; the PR closes before pass 2's
        # read, so pass 2 returns None. Nothing may remain authorized.
        api = FakeAPI()
        state = {"published": False, "closed": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def changing(number=None):
            value = base_request(number)
            if state["closed"]:
                return {**value, "state": "closed"}
            return value

        def recording(sha, decision):
            writes.append((sha, decision.state))
            out = base_status(sha, decision)
            if decision.state == "success":
                # The PR closes as soon as this run publishes; the run's own final
                # openness check (and the retry) must then clean up.
                state["published"] = True
                state["closed"] = True
            return out

        api.get_pull_request = changing
        api.create_commit_status = recording
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": changing(133)["head"], "base": changing(133)["base"],
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        gate.evaluate_pr(api, 133)
        self.assertTrue(state["closed"])
        # Every target this run published a success to must end pending.
        for target in {sha for sha, _ in writes}:
            states = [s for sha, s in writes if sha == target]
            self.assertNotEqual(states[-1], "success",
                                f"{target[:10]} kept a success after the PR closed")
        # NOTE: the final openness check and the None-return reconciliation are
        # deliberately redundant here -- in this harness the scope check fires
        # first and reconciles, so neither can be isolated by removal. The
        # outcome above is what the contract requires.

    def test_unconfirmed_exit_withdraws_current_target_successes(self):
        # Convergence publishes success on the CURRENT head/merge, then the
        # evidence changes again and the next pass fails. An unconfirmed write is
        # precisely the case where "still on the current SHA" proves nothing.
        api = FakeAPI()
        state = {"published": False}
        base_status = api.create_commit_status
        writes = []

        def recording(sha, decision):
            writes.append((sha, decision.state))
            out = base_status(sha, decision)
            if decision.state == "success":
                state["published"] = True
            return out

        api.create_commit_status = recording
        calls = {"n": 0}
        original_comments = api.list_issue_comments

        def comments(_number):
            calls["n"] += 1
            if calls["n"] > 1:
                return []  # evidence gone => convergence, then a differing decision
            return original_comments(_number)

        api.list_issue_comments = comments
        original_once = gate._evaluate_once
        passes = {"n": 0}

        def first_ok_then_boom(*args, **kwargs):
            passes["n"] += 1
            if passes["n"] == 1:
                return original_once(*args, **kwargs)
            raise ConnectionResetError("pass failed")

        gate._evaluate_once = first_ok_then_boom
        try:
            with self.assertRaises(Exception):
                gate.evaluate_pr(api, 133)
        finally:
            gate._evaluate_once = original_once
        self.assertTrue(state["published"], "the scenario must publish a success")
        for target in (HEAD, "b" * 40):
            states = [s for sha, s in writes if sha == target]
            if states and states[-1] == "success":
                self.fail(f"unconfirmed success remained on {target[:10]}")

    def test_base_moving_before_the_final_return_is_not_published(self):
        # The final check must compare the WHOLE snapshot: if the base/test-merge
        # moved after the revalidation, returning success would leave the OLD
        # merge commit authorized and nothing else knows about it.
        api = FakeAPI()
        state = {"reads": 0, "moved": False}
        base_request = api.get_pull_request
        base_status = api.create_commit_status
        writes = []

        def changing(number=None):
            state["reads"] += 1
            value = base_request(number)
            if state["moved"]:
                return {**value, "merge_commit_sha": "c" * 40}
            return value

        def recording(sha, decision):
            writes.append((sha, decision.state))
            out = base_status(sha, decision)
            if sha == "b" * 40 and decision.state == "success":
                state["moved"] = True
            return out

        api.get_pull_request = changing
        api.create_commit_status = recording
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": changing(133)["merge_commit_sha"]}]
        gate.evaluate_pr(api, 133)
        # The run may legitimately publish for the NEW snapshot; the invariant is
        # that the SUPERSEDED merge commit never keeps a success.
        self.assertEqual([s for sha, s in writes if sha == "b" * 40][-1], "pending")
        self.assertIn(("c" * 40, "success"), writes)
        # NOTE: this final full-snapshot check is deliberately redundant with the
        # post-publication revalidation, which observes the same change first in
        # this harness; removing only the final check is therefore not
        # mutation-detected. It closes the narrower window between that
        # revalidation and the return.

    def test_base_push_evaluation_uses_a_bounded_pool(self):
        import threading
        import time as _t
        api = FakeAPI()
        many = [{"number": n, "head": {"sha": format(n, "040x")},
                 "base": {"sha": OLD_HEAD, "ref": "main"}, "merge_commit_sha": None}
                for n in range(200, 240)]
        api.list_open_pull_requests = lambda: [
            {"number": 133, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": "b" * 40}, *many]
        api.create_commit_status = lambda sha, decision: None
        active = {"now": 0, "peak": 0}
        lock = threading.Lock()
        original = gate.evaluate_pr

        def slow_eval(*args, **kwargs):
            with lock:
                active["now"] += 1
                active["peak"] = max(active["peak"], active["now"])
            _t.sleep(0.01)
            with lock:
                active["now"] -= 1

        gate.evaluate_pr = slow_eval
        try:
            gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        # The EVALUATION phase itself must be concurrent.
        self.assertGreater(active["peak"], 1)

    def test_no_debug_probe_is_tracked_at_the_repository_root(self):
        # A one-off live-API harness was committed by accident once; the
        # repository forbids shipping debug code, so pin its absence.
        root = pathlib.Path(__file__).resolve().parents[1]
        tracked = subprocess.run(["git", "ls-files", "probe*.py", "gate_probe.py"],
                                 cwd=root, capture_output=True, text=True).stdout.split()
        self.assertEqual(tracked, [])


    def test_freed_head_owners_are_reevaluated_even_if_the_triggering_call_fails(self):
        # The triggering PR's evaluation raises (transient API/status error); the
        # surviving owner of the freed HEAD must still be re-evaluated, otherwise
        # its required check stays pending with no later event to clear it.
        api = FakeAPI()
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": None,
        }
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        evaluated = []
        original = gate.evaluate_pr

        def exploding(a, n, **kw):
            evaluated.append(n)
            if n == 133:
                raise RuntimeError("status publication failed")

        gate.evaluate_pr = exploding
        try:
            event = {"action": "closed",
                     "pull_request": {"number": 133, "head": {"sha": HEAD}}}
            with self.assertRaises(RuntimeError):
                gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original
        # The event is `closed` but the stub reports the PR open, so the reopen
        # handling deliberately re-evaluates it as a HEAD owner as well.
        self.assertEqual(sorted(evaluated), [133, 133, 200])

    def test_a_failing_reevaluation_does_not_mask_the_original_error(self):
        api = FakeAPI()
        event = {"action": "closed",
                 "pull_request": {"number": 133, "head": {"sha": HEAD}}}
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: (_ for _ in ()).throw(RuntimeError(f"boom {n}"))
        try:
            with self.assertRaisesRegex(RuntimeError, "boom 133"):
                gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original


    def test_push_to_base_reevaluates_every_open_pr_targeting_it(self):
        # A rewritten base changes no HEAD, so no per-PR event fires; the push
        # must re-evaluate every PR targeting that branch or a stale success on
        # the HEAD would keep authorizing.
        api = FakeAPI()
        other = {
            "number": 200, "head": {"sha": "9" * 40}, "base": {"sha": OLD_HEAD, "ref": "main"},
            "merge_commit_sha": None,
        }
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            self.assertEqual(gate.run_gate("push", {"ref": "refs/heads/main"}, api), 0)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(evaluated), [133, 200])

    def test_push_to_another_branch_ignores_unrelated_prs(self):
        api = FakeAPI()
        other = {
            "number": 200, "head": {"sha": "9" * 40}, "base": {"sha": OLD_HEAD, "ref": "dev"},
            "merge_commit_sha": None,
        }
        api.base_ref = "dev"
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(evaluated, [])

    def test_push_without_a_branch_is_skipped(self):
        api = FakeAPI()
        self.assertEqual(gate.run_gate("push", {}, api), 0)

    def test_failed_survivor_reevaluation_is_not_silently_successful(self):
        # The triggering PR is fine but the surviving owner cannot be
        # re-evaluated: the run must fail, because nothing else will retry it.
        api = FakeAPI()
        other = {
            "number": 200, "head": {"sha": HEAD}, "base": {"sha": OLD_HEAD},
            "merge_commit_sha": None,
        }
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), other]
        original = gate.evaluate_pr

        def selective(a, n, **kw):
            if n == 200:
                raise RuntimeError("survivor publication failed")

        gate.evaluate_pr = selective
        try:
            event = {"action": "closed",
                     "pull_request": {"number": 133, "head": {"sha": HEAD}}}
            with self.assertRaisesRegex(RuntimeError, "survivor publication failed"):
                gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original


    def test_last_owner_leaving_revokes_the_orphaned_head(self):
        # The PR that owned this HEAD closed and no open PR owns it now; nothing
        # else will ever look at it, so its success must be withdrawn.
        api = FakeAPI()
        api.list_open_pull_requests = lambda: []
        posted = []
        api.create_commit_status = lambda sha, d: posted.append((sha, d.state))
        gate.reevaluate_head_owners(api, HEAD, {133})
        self.assertEqual(posted, [(HEAD, "pending")])

    def test_a_survivor_republishes_success_after_the_owner_recheck(self):
        # The recheck revokes first, but a surviving owner that verifies must be
        # able to publish success again, so the revoke cannot be final.
        api = FakeAPI()
        api.list_open_pull_requests = lambda: [api.get_pull_request(133)]
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        gate.reevaluate_head_owners(api, HEAD, set())
        self.assertTrue(any(s.state == "success" for sha, s in api.statuses if sha == HEAD))

    def test_base_push_attempts_every_candidate_before_reporting_failure(self):
        # One candidate failing must not stop the others: the push is the only
        # guaranteed event for their unchanged HEADs.
        api = FakeAPI()
        others = [
            {"number": n, "head": {"sha": str(n) * 40}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": None}
            for n in (200, 300)
        ]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        attempted = []
        original = gate.evaluate_pr

        def selective(a, n, **kw):
            attempted.append(n)
            if n == 200:
                raise RuntimeError("transient")

        gate.evaluate_pr = selective
        try:
            with self.assertRaisesRegex(RuntimeError, "PR #200"):
                gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(sorted(attempted), [133, 200, 300])

    def test_stale_pr_snapshot_before_publication_is_not_used(self):
        # The base advanced while this run was in flight; the re-read differs, so
        # publishing against the old snapshot would re-authorize a stale merge.
        api = FakeAPI()
        state = {"reads": 0}
        original = api.get_pull_request

        def changing(number):
            state["reads"] += 1
            value = original(number)
            if state["reads"] >= 2:
                value = dict(value)
                value["base"] = {"sha": "9" * 40, "ref": "main"}
            return value

        api.get_pull_request = changing
        result = gate.evaluate_pr(api, 133)
        self.assertEqual(result.state, "pending")
        self.assertNotIn("success", [s.state for _, s in api.statuses])
        # Neither target may end up carrying the obsolete conclusion.
        for target in (HEAD, "b" * 40):
            self.assertEqual([s.state for sha, s in api.statuses if sha == target][-1], "pending")


    def test_failed_compensating_revocation_fails_the_run(self):
        # The success is published, the ownership re-check fails, and so does the
        # compensating revocation. The HEAD still carries invalid evidence, so the
        # run must fail loudly instead of reporting success.
        api = FakeAPI()
        calls = {"n": 0}
        original_scan = api.list_open_pull_requests
        original_status = api.create_commit_status

        def failing_scan():
            calls["n"] += 1
            if calls["n"] >= 3:  # the post-publish re-check
                raise RuntimeError("transient API error")
            return original_scan()

        published = {"success": False}

        def failing_status(sha, decision):
            # Only the COMPENSATING revocation fails: the success has already
            # been published, so withdrawing it must be what breaks.
            if decision.state == "success":
                published["success"] = True
            elif sha == HEAD and published["success"]:
                raise RuntimeError("status API down")
            return original_status(sha, decision)

        api.list_open_pull_requests = failing_scan
        api.create_commit_status = failing_status
        with self.assertRaisesRegex(RuntimeError, "withdraw every published status"):
            gate.evaluate_pr(api, 133)


    def test_base_push_withdraws_every_candidate_head_before_evaluating(self):
        # A hard timeout mid-fanout must not leave later HEADs authorized, so all
        # candidate revocations happen before the expensive evaluations.
        api = FakeAPI()
        others = [
            {"number": n, "head": {"sha": str(n) * 40}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": None}
            for n in (200, 300)
        ]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        by_number = {133: HEAD, 200: "2" * 40, 300: "3" * 40}
        base_request = api.get_pull_request

        def per_number(number):
            value = base_request(number)
            value["head"] = {"sha": by_number[number]}
            return value

        api.get_pull_request = per_number
        events = []

        def recording(sha, decision):
            events.append(("status", sha, decision.state))

        api.create_commit_status = recording
        original = gate.evaluate_pr

        def recording_eval(a, n, **kw):
            events.append(("eval", n))

        gate.evaluate_pr = recording_eval
        try:
            gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        # Every candidate HEAD is withdrawn before the first evaluation runs.
        first_eval = next(i for i, e in enumerate(events) if e[0] == "eval")
        withdrawn = {sha for kind, sha, __ in events[:first_eval] if kind == "status"}
        self.assertEqual(withdrawn, {HEAD, "2" * 40, "3" * 40})
        self.assertTrue(all(state == "pending" for kind, _, state in events[:first_eval]))


    def test_pre_revocation_continues_after_one_candidate_fails(self):
        # A transient failure while withdrawing one candidate must not abort the
        # revocation fanout: the later HEADs would otherwise stay authorized
        # against the previous base.
        api = FakeAPI()
        others = [
            {"number": n, "head": {"sha": str(n) * 40}, "base": {"sha": OLD_HEAD, "ref": "main"},
             "merge_commit_sha": None}
            for n in (200, 300)
        ]
        api.list_open_pull_requests = lambda: [api.get_pull_request(133), *others]
        by_number = {133: HEAD, 200: "2" * 40, 300: "3" * 40}
        base_request = api.get_pull_request

        def per_number(number):
            if number == 200:
                raise RuntimeError("transient lookup failure")
            value = base_request(number)
            value["head"] = {"sha": by_number[number]}
            return value

        api.get_pull_request = per_number
        revoked = []
        api.create_commit_status = lambda sha, d: revoked.append((sha, d.state))
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: None
        try:
            with self.assertRaisesRegex(RuntimeError, "PR #200 revocation"):
                gate.run_gate("push", {"ref": "refs/heads/main"}, api)
        finally:
            gate.evaluate_pr = original
        # The candidates after the failing one were still withdrawn.
        self.assertIn(("3" * 40, "pending"), revoked)


    def test_closed_pull_request_does_not_post_status(self):
        api = FakeAPI(state="closed")
        self.assertIsNone(gate.evaluate_pr(api, 133))
        self.assertEqual(api.statuses, [])


if __name__ == "__main__":
    unittest.main()
