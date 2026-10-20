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

    def decide(open_prs: list[dict], comments: list[dict]) -> GateDecision:
        """The decision this PR's current data supports.

        One function, so the post-publication revalidation asks exactly the same
        question against fresh data instead of comparing a reclassified review
        against a decision that also encoded merge-scope ambiguity.
        """
        if not _merge_scope_is_unique(number, head_sha, base_sha, merge_sha, open_prs):
            return GateDecision(
                "pending", "Shared merge/head+base across PRs; review scope ambiguous", pr_url
            )
        if deleted_summary:
            if deletion_is_stale(deleted_comment, comments):
                print(f"PR #{number}: the deletion event is stale; a newer summary governs")
                return classify_codex_review(head_sha, comments, pr_url)
            return GateDecision("pending", "Codex review summary deleted; re-review required", pr_url)
        return classify_codex_review(head_sha, comments, pr_url)

    decision = decide(api.list_open_pull_requests(), api.list_issue_comments(number))

    def withdraw_all(reason: str) -> None:
        """Withdraw BOTH targets, each attempted independently.

        A status belongs to a SHA, not to a PR, so the test-merge commit and the
        HEAD can each carry a conclusion this run cannot confirm. Isolating the
        attempts means one failing endpoint cannot prevent the other withdrawal;
        if any attempt fails the run fails, because a success that cannot be
        withdrawn must never be left standing.
        """
        withdrawn = GateDecision("pending", reason, pr_url)
        errors: list[str] = []
        for target in (merge_sha, head_sha):
            try:
                api.create_commit_status(target, withdrawn)
            except Exception as error:  # noqa: BLE001 - any transport failure
                errors.append(f"{target[:10]}: {error}")
        if errors:
            raise RuntimeError("could not withdraw every published status: "
                               + "; ".join(errors))

    head_status = "not published"
    # Every write lives inside one guard: any failure after a publication must
    # withdraw BOTH targets and propagate. Reporting success while a target sits
    # at `pending`, or worse at a stale success, would leave the PR either
    # unmergeable or wrongly authorized with no guaranteed event to repair it.
    try:
        current = api.get_pull_request(number)
        if (
            (current.get("head") or {}).get("sha") != head_sha
            or (current.get("base") or {}).get("sha") != base_sha
            or current.get("merge_commit_sha") != merge_sha
        ):
            print(f"PR #{number}: the PR changed during evaluation; nothing is published")
            withdraw_all("PR changed during evaluation")
            return GateDecision("pending", "Awaiting current PR test merge", pr_url)

        scope_now = api.list_open_pull_requests()
        publish_head = _head_scope_is_unique(number, head_sha, scope_now)
        api.create_commit_status(merge_sha, decision)
        if publish_head:
            api.create_commit_status(head_sha, decision)

        after = api.get_pull_request(number)
        if (
            (after.get("head") or {}).get("sha") != head_sha
            or (after.get("base") or {}).get("sha") != base_sha
            or after.get("merge_commit_sha") != merge_sha
        ):
            withdraw_all("The PR changed while publishing; conclusion withdrawn")
            return GateDecision("pending", "Awaiting current PR test merge", pr_url)
        fresh_decision = decide(api.list_open_pull_requests(), api.list_issue_comments(number))
        if fresh_decision != decision:
            # The world moved while this run was publishing, so this run's
            # decision is superseded. Publishing `pending` here would be a
            # regression that can outlive the newer run (each run has its own
            # concurrency group, so an older one can finish last) and would
            # strand a valid result with no guaranteed repair. Instead converge
            # on the decision the CURRENT data supports -- computed by the same
            # `decide`, so this is not an upgrade from stale reasoning.
            api.create_commit_status(merge_sha, fresh_decision)
            if _head_scope_is_unique(number, head_sha, api.list_open_pull_requests()):
                api.create_commit_status(head_sha, fresh_decision)
                head_status = f"converged ({fresh_decision.state})"
            else:
                revoke_head_status(
                    api, head_sha,
                    GateDecision("pending", "HEAD shared with another open PR; withheld", pr_url),
                )
                head_status = "withheld (HEAD is shared with another open PR)"
            return fresh_decision
        if publish_head and not _head_scope_is_unique(number, head_sha,
                                                      api.list_open_pull_requests()):
            revoke_head_status(
                api, head_sha,
                GateDecision("pending", "HEAD shared with another open PR; withheld", pr_url),
            )
            head_status = "revoked (HEAD became shared)"
        else:
            head_status = ("published" if publish_head
                           else "withheld (HEAD is shared with another open PR)")
    except Exception as error:  # noqa: BLE001 - any transport or protocol failure
        withdraw_all("Publication could not be confirmed")
        if isinstance(error, (ValueError, RuntimeError)):
            raise
        raise RuntimeError(f"PR #{number} publication failed: {error}") from error
    # Reporting sits outside the guard on purpose: both targets were published and
    # revalidated, so a logging failure is NOT a publication failure, and
    # withdrawing confirmed statuses would strand a valid review. It still fails
    # the run, so nothing is silent.
    try:
        print(f"PR #{number} HEAD {head_sha} test merge {merge_sha}: "
              f"{STATUS_CONTEXT} = {decision.state}")
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
    except OSError as error:
        raise RuntimeError(
            f"PR #{number}: reporting failed after the gate confirmed its statuses: {error}"
        ) from error
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


def reevaluate_head_owners(api: GitHubAPI, head_sha: str, skip: set[int]) -> None:
    """Re-evaluate every open PR that owns `head_sha`, except `skip`.

    When no open PR owns the HEAD any more, no re-evaluation can withdraw the
    status it still carries, and a later PR reusing that commit would inherit
    valid-looking review evidence. So the HEAD is revoked first and
    unconditionally: denial is always safe, and this is the last moment any
    event is guaranteed to look at it.
    """
    failures: list[str] = []
    try:
        revoke_head_status(
            api, head_sha,
            GateDecision("pending", "Rechecking HEAD ownership after a PR left", ""),
        )
    except Exception as error:  # noqa: BLE001 - any transport failure
        # Aggregated rather than raised: abandoning the fanout here would leave
        # every surviving owner unevaluated, and the callers already treat a
        # raised aggregate as a failure.
        failures.append(f"HEAD {head_sha[:10]} revocation: {error}")
    for pull_request in api.list_open_pull_requests():
        if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
            raise ValueError("invalid entry in open-PR response")
        if pull_request["number"] in skip:
            continue
        if (pull_request.get("head") or {}).get("sha") != head_sha:
            continue
        # Isolate each owner: a transient failure evaluating one must not stop
        # the others, or their HEADs stay in whatever state this left.
        try:
            evaluate_pr(api, pull_request["number"])
        except Exception as error:  # noqa: BLE001 - any transport failure
            failures.append(f"PR #{pull_request['number']}: {error}")
    if failures:
        raise RuntimeError("HEAD owner re-evaluation failed: " + "; ".join(failures))


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


def reopen_aware_skip_set(api: GitHubAPI, event_name: str, event: dict,
                           number: int) -> set[int]:
    """PRs to exclude from HEAD-owner cleanup, honouring a delayed `closed`.

    A `closed` delivery can arrive after the PR was reopened. Skipping it would
    revoke its HEAD and then never restore it, and no later event is guaranteed,
    so the skip set follows the CURRENT state. When that state cannot be read the
    PR is INCLUDED (re-evaluated) rather than skipped: re-evaluation is always
    safe, while skipping may strand a live owner.
    """
    skip = {number}
    if event_name != "pull_request_target" or event.get("action") != "closed":
        return skip
    try:
        if reopened_head_owner(api, number):
            print(f"PR #{number} is open again; it is re-evaluated as a HEAD owner")
            return set()
    except Exception as error:  # noqa: BLE001 - any transport failure
        print(f"PR #{number}: could not re-read its state ({error}); "
              f"re-evaluating it anyway", file=sys.stderr)
        return set()
    return skip


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
        # Revoke from the HEADs already listed above rather than re-fetching each
        # PR: this fanout runs before the (also bounded) evaluation phase, and a
        # hard job timeout mid-way would leave every later HEAD still carrying a
        # success validated against the previous base. One request per candidate
        # instead of two keeps the window as small as this API allows.
        listed: dict[int, str] = {}
        for pull_request in api.list_open_pull_requests():
            if not isinstance(pull_request, dict) or not isinstance(pull_request.get("number"), int):
                raise ValueError("invalid entry in open-PR response")
            sha = (pull_request.get("head") or {}).get("sha")
            if isinstance(sha, str) and SHA_PATTERN.fullmatch(sha):
                listed[pull_request["number"]] = sha
        for candidate in candidates:
            # Best effort per candidate: a transient failure here must not abort
            # the loop, or the later HEADs would keep their previous-base success
            # while this run reports the first error.
            try:
                head = listed.get(candidate)
                if head is None:
                    head = (api.get_pull_request(candidate).get("head") or {}).get("sha")
                if isinstance(head, str) and SHA_PATTERN.fullmatch(head):
                    revoke_head_status(
                        api, head,
                        GateDecision("pending", "Base branch advanced; revalidating", ""),
                    )
            except Exception as error:  # noqa: BLE001 - any transport failure
                failures.append(f"PR #{candidate} revocation: {error}")
        for candidate in candidates:
            # Every candidate must be attempted: the push is the only guaranteed
            # event for these unchanged HEADs, so one transient failure must not
            # leave the rest still authorized against the previous base.
            try:
                evaluate_pr(api, candidate)
                print(f"re-evaluated PR #{candidate} after a push to {branch}")
            except Exception as error:  # noqa: BLE001 - any transport failure
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
        # The skip set is computed exactly as on the normal path, so a delayed
        # `closed` after a reopen is not stranded by this route either.
        try:
            recovery_skip = reopen_aware_skip_set(api, event_name, event, number)
        except Exception:  # noqa: BLE001 - never mask the original failure
            recovery_skip = {number}
        for head_sha in affected_shared_heads(event_name, event):
            try:
                reevaluate_head_owners(api, head_sha, recovery_skip)
            except Exception as error:  # noqa: BLE001 - any transport failure
                print(f"could not re-evaluate the remaining owners of {head_sha}: {error}",
                      file=sys.stderr)
        raise
    # Nothing else failed, so a survivor that cannot be re-evaluated is this
    # run's only problem: report it instead of exiting 0, because no later event
    # is guaranteed to retry it and its required check would stay pending.
    # A `closed` event that arrives after a reopen must not skip that PR, or its
    # HEAD would stay revoked with nothing left to restore it.
    skip = reopen_aware_skip_set(api, event_name, event, number)
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
