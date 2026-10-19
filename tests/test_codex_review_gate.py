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
        evaluated = []
        original = gate.evaluate_pr
        gate.evaluate_pr = lambda a, n, **kw: evaluated.append(n)
        try:
            event = {"action": "closed",
                     "pull_request": {"number": 133, "head": {"sha": HEAD}}}
            gate.run_gate("pull_request_target", event, api)
        finally:
            gate.evaluate_pr = original
        self.assertEqual(evaluated, [133, 200])

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


    def test_failed_post_publish_scan_withdraws_an_already_published_head(self):
        api = FakeAPI()
        calls = {"n": 0}
        original = api.list_open_pull_requests

        def failing():
            calls["n"] += 1
            if calls["n"] >= 3:  # the post-publish re-check
                raise RuntimeError("transient API error")
            return original()

        api.list_open_pull_requests = failing
        self.assertEqual(gate.evaluate_pr(api, 133).state, "success")
        head_events = [(s.state, s.description) for sha, s in api.statuses if sha == HEAD]
        self.assertIn("success", [state for state, _ in head_events])
        self.assertEqual(head_events[-1][0], "pending")
        self.assertIn("could not be reconfirmed", head_events[-1][1])



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
        self.assertEqual(evaluated, [133, 200])

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
        self.assertEqual(evaluated, [133, 200])

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
        self.assertEqual(attempted, [133, 200, 300])

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
        with self.assertRaisesRegex(RuntimeError, "still authorized"):
            gate.evaluate_pr(api, 133)


    def test_closed_pull_request_does_not_post_status(self):
        api = FakeAPI(state="closed")
        self.assertIsNone(gate.evaluate_pr(api, 133))
        self.assertEqual(api.statuses, [])


if __name__ == "__main__":
    unittest.main()
