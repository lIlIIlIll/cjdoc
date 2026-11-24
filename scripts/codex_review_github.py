"""Bounded GitHub REST reads and SHA-scoped status publication for the review gate."""

from __future__ import annotations

import json
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

if __package__:
    from .codex_review_evidence import GateDecision
else:
    from codex_review_evidence import GateDecision

STATUS_CONTEXT = "codex-review-current-head"


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
