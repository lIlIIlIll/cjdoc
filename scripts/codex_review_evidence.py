"""Interpret official Codex summaries and GitHub event evidence without network I/O."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass


CODEX_BOT_LOGIN = "chatgpt-codex-connector[bot]"
CODEX_BOT_ID = 199175422
SHA_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SUMMARY_PREFIX = "<!-- codex-pull-request-review-summary -->\n"
STATE_MARKER = re.compile(r"(?m)^<!-- codex-review-state:v1 (\{[^\r\n]*\}) -->\r?$")


@dataclass(frozen=True)
class GateDecision:
    state: str
    description: str
    target_url: str


def _no_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate review-state field: {key}")
        result[key] = value
    return result


def _is_official_summary(comment: dict) -> bool:
    user = comment.get("user") or {}
    return (
        isinstance(user, dict)
        and user.get("login") == CODEX_BOT_LOGIN
        and user.get("id") == CODEX_BOT_ID
        and user.get("type") == "Bot"
        and isinstance(comment.get("body"), str)
        and comment["body"].startswith(SUMMARY_PREFIX)
        and (
            not isinstance(comment.get("performed_via_github_app"), dict)
            or comment["performed_via_github_app"].get("slug")
            == "chatgpt-codex-connector"
        )
    )


def _read_review_state(comment: dict) -> dict:
    match = STATE_MARKER.search(comment["body"])
    if match is None:
        raise ValueError("Codex summary has no v1 review-state marker")
    state = json.loads(match.group(1), object_pairs_hook=_no_duplicate_keys)
    if not isinstance(state, dict) or not isinstance(state.get("code_review"), dict):
        raise ValueError("Codex summary is missing code_review state")
    review = state["code_review"]
    status = review.get("status")
    if not isinstance(status, str):
        raise ValueError("Codex summary has no code_review status")
    reviewed_sha = review.get("commit_sha")
    if reviewed_sha is not None and (
        not isinstance(reviewed_sha, str) or not SHA_PATTERN.fullmatch(reviewed_sha)
    ):
        raise ValueError("Codex summary has an invalid reviewed commit SHA")
    # Queued/running reviews carry null finding flags and may not have selected a
    # commit yet; that is normal and stays `pending` in the classifier.
    if status == "completed" and reviewed_sha is None:
        raise ValueError("Completed Codex review lacks a full reviewed SHA")
    # The managed reviewer reports its finding flags as `null` on some completions
    # (observed on PR #139, 2026-10-20). A completed review with no reported
    # findings is treated as completed: the required check verifies that a review
    # ran for this HEAD, not that it was clean. Losing a flag must therefore not
    # fail the gate closed. An explicitly non-boolean, non-null value is still a
    # malformed schema and is rejected.
    unresolved = review.get("has_unresolved_findings")
    if unresolved is not None and not isinstance(unresolved, bool):
        raise ValueError("Codex summary has a malformed has_unresolved_findings flag")
    any_findings = review.get("has_any_findings")
    if any_findings is not None and not isinstance(any_findings, bool):
        raise ValueError("Codex summary has a malformed has_any_findings flag")
    return review


def classify_codex_review(head_sha: str, comments: list[dict], pr_url: str) -> GateDecision:
    """Gate on review completion, NOT on a clean verdict or zero threads."""
    if not SHA_PATTERN.fullmatch(head_sha):
        raise ValueError("PR HEAD is not a full commit SHA")

    summaries = [c for c in comments if isinstance(c, dict) and _is_official_summary(c)]
    if not summaries:
        return GateDecision("pending", "Awaiting Codex review summary for HEAD", pr_url)

    # There should be one canonical summary. If multiple exist, use the newest
    # rather than trusting an older Completed summary after a new review starts.
    latest = max(
        summaries,
        key=lambda c: (c.get("updated_at") or "", c.get("id") or 0),
    )
    target = latest.get("html_url") or pr_url
    try:
        code_review = _read_review_state(latest)
    except (ValueError, json.JSONDecodeError) as exc:
        return GateDecision("error", f"Unrecognized Codex summary: {exc}"[:140], target)

    if code_review.get("commit_sha") is None:
        return GateDecision("pending", "Awaiting Codex reviewed commit SHA", target)
    if code_review["commit_sha"] != head_sha:
        return GateDecision("pending", "Codex review covers an older HEAD", target)

    state = code_review["status"]
    if state == "completed":
        if code_review.get("has_unresolved_findings") is True:
            message = "Codex reviewed HEAD; unresolved findings need triage"
        else:
            # False, or null when the reviewer reported no flag: in both cases no
            # unresolved finding is being claimed for this HEAD.
            message = "Codex review completed for current HEAD"
        return GateDecision("success", message, target)
    if state in {"failed", "error", "cancelled", "timed_out"}:
        return GateDecision("failure", f"Codex code review ended: {state}", target)
    return GateDecision("pending", f"Waiting for Codex code review ({state})"[:140], target)


def deleted_codex_summary(event_name: str, event: dict) -> bool:
    """Revoke a deleted bot summary, even if GitHub still returns stale data.

    The deleted webhook may omit the old body. We conservatively treat such a
    bot deletion as a potential canonical summary deletion, but avoid revoking
    a known non-summary bot comment.
    """
    if event_name != "issue_comment" or event.get("action") != "deleted":
        return False
    comment = event.get("comment") or {}
    user = comment.get("user") or {}
    if user.get("login") != CODEX_BOT_LOGIN or user.get("id") != CODEX_BOT_ID:
        return False
    body = comment.get("body")
    return body is None or (isinstance(body, str) and body.startswith(SUMMARY_PREFIX))


def deletion_is_stale(deleted_comment: dict | None, comments: list[dict]) -> bool:
    """Is a newer canonical summary present than the one that was deleted?

    A delayed `issue_comment.deleted` delivery can arrive after a replacement
    summary has already been reviewed and published as `success`. Forcing every
    deletion to `pending` would then overwrite a newer valid result and leave the
    current HEAD stuck, because no later event is guaranteed. GitHub orders
    comments, so if the newest canonical summary is strictly newer than the
    deleted one the deletion is stale and the normal classification applies.
    """
    if not isinstance(deleted_comment, dict):
        return False
    deleted_key = (deleted_comment.get("updated_at") or "", deleted_comment.get("id") or 0)
    for comment in comments:
        if not isinstance(comment, dict) or not _is_official_summary(comment):
            continue
        if (comment.get("updated_at") or "", comment.get("id") or 0) > deleted_key:
            return True
    return False


def pr_number_from_event(event_name: str, event: dict) -> int | None:
    """Return None only for issue comments that do not concern a PR."""
    if event_name == "workflow_dispatch":
        number = (event.get("inputs") or {}).get("pr_number")
    elif event_name == "issue_comment":
        issue = event.get("issue") or {}
        if not issue.get("pull_request"):
            return None
        number = issue.get("number")
    elif event_name == "pull_request_target":
        number = (event.get("pull_request") or {}).get("number")
    else:
        raise ValueError(f"unexpected event: {event_name}")
    if isinstance(number, bool) or not str(number).isdigit() or int(number) < 1:
        raise ValueError("missing or invalid PR number")
    return int(number)


def affected_shared_heads(event_name: str, event: dict) -> list[str]:
    """HEAD SHAs whose set of owning open PRs changed in this event.

    A HEAD shared by two open PRs is left pending for both. When one of them
    closes or pushes elsewhere, the remaining PR now owns the old HEAD alone and
    must be re-evaluated, but the triggering event only concerns the PR that
    changed. These are the SHAs whose remaining owners must be revisited.
    """
    if event_name != "pull_request_target":
        return []
    action = event.get("action")
    pull_request = event.get("pull_request") or {}
    if action == "closed":
        head = (pull_request.get("head") or {}).get("sha")
        if isinstance(head, str) and SHA_PATTERN.fullmatch(head):
            return [head]
        return []
    if action == "synchronize":
        before = event.get("before")
        if not isinstance(before, str) or not SHA_PATTERN.fullmatch(before):
            return []
        # A delayed delivery can arrive after the PR already moved back to this
        # commit (A -> B -> A). This PR then owns the reported `before` again, so
        # its HEAD must be re-evaluated rather than excluded from the cleanup.
        after = (pull_request.get("head") or {}).get("sha")
        if after == before:
            return []
        return [before]
    return []
