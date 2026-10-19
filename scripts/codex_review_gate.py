#!/usr/bin/env python3
"""Publish a head-SHA-bound completion status for managed Codex PR reviews.

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


def evaluate_pr(api: GitHubAPI, number: int) -> GateDecision | None:
    pr = api.get_pull_request(number)
    if pr.get("state") != "open":
        print(f"PR #{number} is not open; no commit status to publish")
        return None
    head_sha = (pr.get("head") or {}).get("sha")
    if not isinstance(head_sha, str) or not SHA_PATTERN.fullmatch(head_sha):
        raise ValueError("GitHub PR response lacks a full HEAD SHA")
    comments = api.list_issue_comments(number)
    decision = classify_codex_review(head_sha, comments, pr["html_url"])
    api.create_commit_status(head_sha, decision)

    # GitHub may evaluate required checks against its synthetic test-merge
    # commit instead of the PR head. Only mirror the head-bound decision after
    # verifying this merge has the *current* base and head as parents.
    merge_sha = pr.get("merge_commit_sha")
    base_sha = (pr.get("base") or {}).get("sha")
    if (
        isinstance(merge_sha, str)
        and SHA_PATTERN.fullmatch(merge_sha)
        and merge_sha != head_sha
        and isinstance(base_sha, str)
        and SHA_PATTERN.fullmatch(base_sha)
    ):
        merge = api.get_commit(merge_sha)
        parents = merge.get("parents") or []
        if (
            len(parents) == 2
            and parents[0].get("sha") == base_sha
            and parents[1].get("sha") == head_sha
        ):
            api.create_commit_status(merge_sha, decision)
            print(f"Also published on verified test merge {merge_sha}")
        else:
            print("Ignoring merge SHA: its parents do not match current base/head")
    print(f"PR #{number} HEAD {head_sha}: {STATUS_CONTEXT} = {decision.state}")
    print(decision.description)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as file:
            file.write(
                f"### Codex review gate\n\n- PR: #{number}\n- HEAD: `{head_sha}`"
                f"\n- Status: **{decision.state}**\n- Result: {decision.description}"
                "\n\nThis check verifies review completion, not that findings are resolved.\n"
            )
    return decision


def main() -> int:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    number = pr_number_from_event(os.environ["GITHUB_EVENT_NAME"], event)
    if number is None:
        print("Issue comment does not belong to a PR; skip")
        return 0
    api = GitHubAPI(
        os.environ["GITHUB_REPOSITORY"],
        os.environ["GITHUB_TOKEN"],
        os.environ.get("GITHUB_API_URL", "https://api.github.com"),
    )
    evaluate_pr(api, number)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError, RuntimeError) as error:
        print(f"Codex review gate: {error}", file=sys.stderr)
        sys.exit(1)
