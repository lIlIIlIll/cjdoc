#!/usr/bin/env python3
"""Publish a PR-scoped, head-bound completion status for managed Codex reviews.

The workflow executing this file MUST use trusted default-branch code, never
checkout the untrusted PR head with a write-capable GITHUB_TOKEN.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


STATUS_CONTEXT = "codex-review-current-head"
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
    # In the real managed Codex summary, queued/running reviews carry null
    # finding flags (and may not have selected a commit yet).
    if status == "completed" and (
        reviewed_sha is None
        or not isinstance(review.get("has_unresolved_findings"), bool)
    ):
        raise ValueError("Completed Codex review lacks full SHA or finding flags")
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
        if code_review["has_unresolved_findings"]:
            message = "Codex reviewed HEAD; unresolved findings need triage"
        else:
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


class GitHubAPI:
    def __init__(self, repo: str, token: str, api_url: str = "https://api.github.com"):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("invalid GITHUB_REPOSITORY")
        if not token:
            raise ValueError("missing GITHUB_TOKEN")
        self.repo = repo
        self.token = token
        self.api_url = api_url.rstrip("/")

    def _request(self, path: str, payload: dict | None = None):
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        req = Request(
            f"{self.api_url}/repos/{self.repo}/{path}",
            data=data,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                **({"Content-Type": "application/json"} if data else {}),
            },
            method="POST" if data is not None else "GET",
        )
        try:
            with urlopen(req, timeout=20) as response:
                return json.load(response)
        except HTTPError as exc:
            raise RuntimeError(f"GitHub API {req.get_method()} {path}: HTTP {exc.code}") from exc
        except URLError as exc:
            raise RuntimeError(f"GitHub API {req.get_method()} {path}: unavailable") from exc

    def get_pull_request(self, number: int) -> dict:
        return self._request(f"pulls/{number}")

    def get_commit(self, sha: str) -> dict:
        return self._request(f"commits/{sha}")

    def list_open_pull_requests(self) -> list[dict]:
        """Exhaustively check concurrent PRs before publishing scoped success.

        GitHub commit statuses belong to a SHA+context, not to a PR. A shared
        test-merge SHA cannot safely carry different PR review conclusions.
        """
        result: list[dict] = []
        for page in range(1, 102):
            query = urlencode({"state": "open", "per_page": 100, "page": page})
            batch = self._request(f"pulls?{query}")
            if not isinstance(batch, list):
                raise ValueError("unexpected GitHub open-PR response")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise RuntimeError("too many open PRs to check merge identity safely")

    def list_issue_comments(self, number: int) -> list[dict]:
        result: list[dict] = []
        for page in range(1, 102):
            query = urlencode({"per_page": 100, "page": page})
            batch = self._request(f"issues/{number}/comments?{query}")
            if not isinstance(batch, list):
                raise ValueError("unexpected GitHub comments response")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise RuntimeError("too many comments to validate Codex review safely")

    def create_commit_status(self, sha: str, decision: GateDecision) -> None:
        self._request(
            f"statuses/{sha}",
            {
                "state": decision.state,
                "context": STATUS_CONTEXT,
                "description": decision.description[:140],
                "target_url": decision.target_url,
            },
        )


def _merge_scope_is_unique(
    number: int, head_sha: str, base_sha: str, merge_sha: str, open_prs: list[dict]
) -> bool:
    """A PR-independent status is safe only on a PR-distinguishing merge SHA.

    Conservatively refuse when another open PR has the same head+base, even
    if GitHub temporarily reports a different or absent merge SHA for it.
    If the repository's open-PR listing is incomplete, do not grant success.
    """
    found_current = False
    for other in open_prs:
        if not isinstance(other, dict) or not isinstance(other.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if other["number"] == number:
            found_current = True
            continue
        other_head = (other.get("head") or {}).get("sha")
        other_base = (other.get("base") or {}).get("sha")
        if (
            other.get("merge_commit_sha") == merge_sha
            or (other_head == head_sha and other_base == base_sha)
        ):
            return False
    if not found_current:
        raise RuntimeError("current PR is missing from open-PR response")
    return True


def revoke_head_decision(api: GitHubAPI, number: int, head_sha: str,
                         pr_url: str) -> GateDecision:
    """Revoke the HEAD and return the "awaiting test merge" decision."""
    decision = GateDecision("pending", "Awaiting current PR test merge", pr_url)
    revoke_head_status(api, head_sha, decision)
    return decision


def revoke_head_status(api: GitHubAPI, head_sha: str, decision: GateDecision) -> None:
    """Withdraw a possible earlier `success` from the HEAD.

    A previous run -- possibly for a different PR that reused this commit -- may
    have left `success` here, and the ruleset reads the HEAD, so a stale success
    would authorize a merge this run has not verified.

    Only a non-success decision may be published by this function, and it is
    published unconditionally: denial is always safe. Even if another open PR
    currently shares this HEAD, no legitimate `success` can exist there (that PR
    would have had to refuse one too), so withdrawing it cannot destroy a valid
    conclusion. Leaving a stale `success` would be the dangerous outcome.
    """
    if decision.state == "success":
        raise ValueError("revoke_head_status must not publish a success")
    api.create_commit_status(head_sha, decision)


def _head_scope_is_unique(number: int, head_sha: str, open_prs: list[dict]) -> bool:
    """A status on the raw HEAD is safe only when one open PR owns that HEAD.

    The ruleset's required check is evaluated against the PR HEAD, but a status
    belongs to a SHA+context and not to a PR. Publishing on the HEAD is therefore
    allowed only when every open PR carrying that same HEAD is the current one --
    otherwise two PRs with different bases would share one review conclusion,
    which is exactly what the test-merge-only design was protecting against.
    """
    found_current = False
    for other in open_prs:
        if not isinstance(other, dict) or not isinstance(other.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if (other.get("head") or {}).get("sha") != head_sha:
            continue
        if other["number"] == number:
            found_current = True
        else:
            return False
    if not found_current:
        raise RuntimeError("current PR is missing from open-PR response")
    return True


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


def evaluate_pr(api: GitHubAPI, number: int, *, deleted_summary: bool = False,
                deleted_comment: dict | None = None) -> GateDecision | None:
    pr = api.get_pull_request(number)
    if pr.get("state") != "open":
        print(f"PR #{number} is not open; no commit status to publish")
        return None
    head_sha = (pr.get("head") or {}).get("sha")
    base_sha = (pr.get("base") or {}).get("sha")
    merge_sha = pr.get("merge_commit_sha")
    pr_url = pr["html_url"]
    if not isinstance(head_sha, str) or not SHA_PATTERN.fullmatch(head_sha):
        raise ValueError("GitHub PR response lacks a full HEAD SHA")

    # A HEAD can retain `success` from an earlier run, and this PR may be a new
    # one reusing the same commit. Revoke the HEAD FIRST, before any branch that
    # returns early, so a missing/invalid test merge cannot leave an old success
    # standing as an authorization for the check the ruleset reads.
    revoke_head_status(
        api, head_sha,
        GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
    )

    # A passing status is published on the test-merge SHA, never blindly on the
    # raw head: two distinct PRs may share that SHA with different base-dependent
    # diffs and reviews. The HEAD is written only under `_head_scope_is_unique`.
    if (
        not isinstance(base_sha, str)
        or not SHA_PATTERN.fullmatch(base_sha)
        or not isinstance(merge_sha, str)
        or not SHA_PATTERN.fullmatch(merge_sha)
        or merge_sha == head_sha
    ):
        print(f"PR #{number}: no candidate test-merge SHA; keep gate unreported")
        # The HEAD was already revoked above, so no second status is needed.
        return GateDecision("pending", "Awaiting current PR test merge", pr_url)

    # Revoke any previous success BEFORE further network calls. If the API
    # fails while we revalidate summary/merge, the gate stays pending.
    api.create_commit_status(
        merge_sha,
        GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
    )
    revoke_head_status(
        api, head_sha,
        GateDecision("pending", "Verifying PR-specific Codex review evidence", pr_url),
    )

    # Re-read the PR immediately before deciding. Another run (a base push, or
    # the base advancing while this run was in flight) may have changed the base
    # or HEAD since the first read, and publishing against the stale snapshot
    # would re-authorize a test merge that no longer describes this PR.
    fresh = api.get_pull_request(number)
    if (
        (fresh.get("head") or {}).get("sha") != head_sha
        or (fresh.get("base") or {}).get("sha") != base_sha
        or fresh.get("merge_commit_sha") != merge_sha
    ):
        print(f"PR #{number}: the PR changed during evaluation; keep gate unreported")
        return revoke_head_decision(api, number, head_sha, pr_url)

    merge = api.get_commit(merge_sha)
    parents = merge.get("parents") or []
    if not (
        len(parents) == 2
        and parents[0].get("sha") == base_sha
        and parents[1].get("sha") == head_sha
    ):
        print(f"PR #{number}: candidate test merge does not match current base/head")
        return GateDecision("pending", "Unverified test merge for current PR", pr_url)

    open_prs = api.list_open_pull_requests()
    if not _merge_scope_is_unique(number, head_sha, base_sha, merge_sha, open_prs):
        decision = GateDecision(
            "pending", "Shared merge/head+base across PRs; review scope ambiguous", pr_url
        )
    elif deleted_summary:
        # Do not trust an older duplicate canonical summary or a temporarily
        # stale comment-list response after issue_comment.deleted.
        decision = GateDecision("pending", "Codex review summary deleted; re-review required", pr_url)
    else:
        comments = api.list_issue_comments(number)
        if deleted_summary and deletion_is_stale(deleted_comment, comments):
            # A newer canonical summary exists; this deletion is a stale delivery.
            decision = classify_codex_review(head_sha, comments, pr_url)
            print(f"PR #{number}: the deletion event is stale; a newer summary governs")
        elif deleted_summary:
            decision = GateDecision("pending", "Codex review summary deleted; re-review required", pr_url)
        else:
            decision = classify_codex_review(head_sha, comments, pr_url)

    api.create_commit_status(merge_sha, decision)
    # The ruleset's required check is evaluated against the PR HEAD, so the
    # verified result must also land there or no merge can ever satisfy it.
    # This is guarded: only a HEAD that exactly one open PR owns gets a status,
    # so a shared HEAD can never carry another PR's conclusion.
    #
    # The scope is re-read immediately before publishing and re-verified after,
    # because another PR can start sharing this HEAD in between. A status belongs
    # to a SHA, not a PR, so the window cannot be closed completely; publishing
    # success only when the scope still holds, and revoking at once if it stops
    # holding, is the strongest guarantee this API allows. The residual case is
    # two open PRs on the same commit with different bases, which the issue
    # already requires a maintainer to resolve.
    # The test-merge commit received `decision` immediately above. Everything
    # that follows can still fail, and the HEAD is the commit the ruleset reads,
    # so any failure past this point must withdraw BOTH targets and propagate:
    # reporting success while the HEAD sits at `pending` (or worse, at a stale
    # success) would leave the PR unmergeable or wrongly authorized with no
    # guaranteed event to repair it.
    head_status = "not published"
    try:
        scope_now = api.list_open_pull_requests()
        if _head_scope_is_unique(number, head_sha, scope_now):
            api.create_commit_status(head_sha, decision)
            # Revalidate BOTH conditions that justified this success, after the
            # write. A concurrent run can change either one while we publish:
            # HEAD ownership (another PR starts sharing it) or the review
            # evidence itself (the Codex summary was edited or deleted, and the
            # summary-deletion run already published `pending`). Checking only
            # ownership would let this older run re-authorize deleted evidence.
            fresh_decision = classify_codex_review(head_sha, api.list_issue_comments(number), pr_url)
            still_owned = _head_scope_is_unique(number, head_sha, api.list_open_pull_requests())
            if fresh_decision != decision or not still_owned:
                reason = ("the Codex review evidence changed"
                          if fresh_decision != decision else "the HEAD became shared")
                withdrawn = GateDecision("pending", f"Conclusion withdrawn: {reason}", pr_url)
                revoke_head_status(api, head_sha, withdrawn)
                api.create_commit_status(merge_sha, withdrawn)
                head_status = f"revoked ({reason})"
                # Withdraw only. This revalidation exists to stop a stale write
                # from standing; it must never upgrade the decision, so the
                # caller keeps the decision this run actually computed.
            else:
                head_status = "published"
        else:
            # The HEAD is shared with another open PR, so no HEAD conclusion can
            # distinguish them. The test-merge result stands; the HEAD keeps only
            # the revocation written earlier.
            head_status = "withheld (HEAD is shared with another open PR)"
    except (ValueError, RuntimeError) as error:
        withdrawn = GateDecision("pending", "Publication could not be confirmed", pr_url)
        try:
            revoke_head_status(api, head_sha, withdrawn)
            api.create_commit_status(merge_sha, withdrawn)
        except (ValueError, RuntimeError) as revoke_error:
            raise RuntimeError(
                f"PR #{number} publication failed and its withdrawal failed: {revoke_error}"
            ) from error
        raise
    print(f"PR #{number} HEAD {head_sha} test merge {merge_sha}: {STATUS_CONTEXT} = {decision.state}")
    print(f"PR #{number} HEAD {head_sha}: {STATUS_CONTEXT} {head_status}")
    print(decision.description)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as file:
            file.write(
                f"### Codex review gate\n\n- PR: #{number}\n- HEAD: `{head_sha}`"
                f"\n- Test merge: `{merge_sha}`\n- Status: **{decision.state}**"
                f"\n- Result: {decision.description}"
                "\n\nThis check verifies review completion, not that findings are resolved.\n"
            )
    return decision


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
        # The previous HEAD may still be owned by another open PR.
        before = event.get("before")
        if isinstance(before, str) and SHA_PATTERN.fullmatch(before):
            return [before]
        return []
    return []


def reevaluate_head_owners(api: GitHubAPI, head_sha: str, skip: set[int]) -> None:
    """Re-evaluate every open PR that owns `head_sha`, except `skip`.

    When no open PR owns the HEAD any more, no re-evaluation can withdraw the
    status it still carries, and a later PR reusing that commit would inherit
    valid-looking review evidence. So the HEAD is revoked first and
    unconditionally: denial is always safe, and this is the last moment any
    event is guaranteed to look at it.
    """
    revoke_head_status(
        api, head_sha,
        GateDecision("pending", "Rechecking HEAD ownership after a PR left", ""),
    )
    for pull_request in api.list_open_pull_requests():
        if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if pull_request["number"] in skip:
            continue
        if (pull_request.get("head") or {}).get("sha") != head_sha:
            continue
        evaluate_pr(api, pull_request["number"])


def open_prs_targeting_branch(api: GitHubAPI, branch: str) -> list[int]:
    """Open PR numbers whose base is `branch`.

    A rewritten base branch does not change a PR's HEAD, so a `success` left on
    that immutable SHA would keep authorizing a review validated against an
    earlier base. GitHub sends no per-PR event for that, so the base push itself
    must re-evaluate every PR that targets it.
    """
    numbers: list[int] = []
    for pull_request in api.list_open_pull_requests():
        if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if (pull_request.get("base") or {}).get("ref") == branch:
            numbers.append(pull_request["number"])
    return numbers


def reopened_head_owner(api: GitHubAPI, number: int) -> bool:
    """Is the PR of a `closed` event actually open again?

    A delayed `closed` delivery can arrive after the PR was reopened. Skipping
    that PR in the owner re-evaluation would leave its HEAD revoked forever, with
    no later event guaranteed, so the skip set must follow the current state.
    """
    return api.get_pull_request(number).get("state") == "open"


def run_gate(event_name: str, event: dict, api: GitHubAPI) -> int:
    """Evaluate the event's PR, then anyone else affected by the same HEAD.

    Kept separate from `main` so the orchestration itself is testable: dropping
    the re-evaluation, or re-evaluating the triggering PR twice, must fail a test
    rather than pass unnoticed.
    """
    if event_name == "push":
        # A base branch advanced; every open PR targeting it must be re-evaluated
        # so its HEAD status cannot keep authorizing a stale validation.
        branch = (event.get("ref") or "").removeprefix("refs/heads/")
        if not branch:
            print("push event without a branch; skip")
            return 0
        candidates = open_prs_targeting_branch(api, branch)
        # Withdraw every candidate's HEAD FIRST. A hard job timeout would
        # otherwise terminate this fanout mid-way and leave the later HEADs
        # still authorized against the previous base, with no chance to run the
        # error handling. Revocation is cheap and can only deny.
        failures: list[str] = []
        for candidate in candidates:
            # Best effort per candidate: a transient failure here must not abort
            # the loop, or the later HEADs would keep their previous-base success
            # while this run reports the first error.
            try:
                head = (api.get_pull_request(candidate).get("head") or {}).get("sha")
                if isinstance(head, str) and SHA_PATTERN.fullmatch(head):
                    revoke_head_status(
                        api, head,
                        GateDecision("pending", "Base branch advanced; revalidating", ""),
                    )
            except (ValueError, RuntimeError) as error:
                failures.append(f"PR #{candidate} revocation: {error}")
        for candidate in candidates:
            # Every candidate must be attempted: the push is the only guaranteed
            # event for these unchanged HEADs, so one transient failure must not
            # leave the rest still authorized against the previous base.
            try:
                evaluate_pr(api, candidate)
                print(f"re-evaluated PR #{candidate} after a push to {branch}")
            except (ValueError, RuntimeError) as error:
                failures.append(f"PR #{candidate}: {error}")
        if failures:
            raise RuntimeError("base push re-evaluation failed: " + "; ".join(failures))
        return 0
    number = pr_number_from_event(event_name, event)
    if number is None:
        print("Issue comment does not belong to a PR; skip")
        return 0
    # A HEAD shared by several PRs stays pending for all of them, so a PR that
    # closes or moves away must not leave the remaining owner stuck: re-evaluate
    # whoever still owns the HEAD this event changed, never the triggering PR.
    #
    # This runs even when the triggering PR's own evaluation raises: a transient
    # API or status-publication error there must not strand the surviving owner
    # with a `pending` check that no later event is guaranteed to clear. The
    # original error is re-raised after the survivors have had their chance.
    # The deleted comment is needed to decide whether a deletion delivery is
    # stale (a replacement summary may already have been reviewed).
    deleted_comment = (event.get("comment") or {}) if event_name == "issue_comment" else None
    try:
        evaluate_pr(api, number, deleted_summary=deleted_codex_summary(event_name, event),
                    deleted_comment=deleted_comment)
    except BaseException:
        # The triggering PR failed; re-evaluate the survivors best effort so this
        # error does not also strand them, then propagate the original failure.
        for head_sha in affected_shared_heads(event_name, event):
            try:
                reevaluate_head_owners(api, head_sha, {number})
            except (ValueError, RuntimeError) as error:
                print(f"could not re-evaluate the remaining owners of {head_sha}: {error}",
                      file=sys.stderr)
        raise
    # Nothing else failed, so a survivor that cannot be re-evaluated is this
    # run's only problem: report it instead of exiting 0, because no later event
    # is guaranteed to retry it and its required check would stay pending.
    # A `closed` event that arrives after a reopen must not skip that PR, or its
    # HEAD would stay revoked with nothing left to restore it.
    skip = {number}
    if event_name == "pull_request_target" and event.get("action") == "closed":
        if reopened_head_owner(api, number):
            skip = set()
            print(f"PR #{number} is open again; it is re-evaluated as a HEAD owner")
    for head_sha in affected_shared_heads(event_name, event):
        reevaluate_head_owners(api, head_sha, skip)
        print(f"re-evaluated the remaining owners of {head_sha}")
    return 0


def main() -> int:
    environment_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    api = GitHubAPI(
        os.environ["GITHUB_REPOSITORY"],
        os.environ["GITHUB_TOKEN"],
        os.environ.get("GITHUB_API_URL", "https://api.github.com"),
    )
    return run_gate(environment_name, event, api)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError, RuntimeError) as error:
        print(f"Codex review gate: {error}", file=sys.stderr)
        sys.exit(1)
