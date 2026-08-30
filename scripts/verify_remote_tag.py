#!/usr/bin/env python3
"""Resolve a GitHub tag through annotated-tag objects and bind it to one commit."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from typing import Callable
from urllib.parse import quote

try:
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    from strict_json import strict_loads


COMMIT = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
MAX_TAG_DEPTH = 16


def gh_json(endpoint: str) -> dict[str, object]:
    result = subprocess.run(
        ["gh", "api", "--method", "GET", endpoint],
        text=True, capture_output=True, check=False, timeout=30,
    )
    if result.returncode != 0:
        raise ValueError(
            f"GitHub API request failed for {endpoint}: " +
            (result.stderr or result.stdout).strip()
        )
    try:
        value = strict_loads(result.stdout, description=f"GitHub API response for {endpoint}")
    except ValueError as error:
        raise ValueError(f"GitHub API returned invalid JSON for {endpoint}") from error
    if not isinstance(value, dict):
        raise ValueError(f"GitHub API returned a non-object for {endpoint}")
    return value


def object_identity(value: dict[str, object], description: str) -> tuple[str, str]:
    raw = value.get("object")
    if not isinstance(raw, dict):
        raise ValueError(f"{description} omits its Git object")
    kind = raw.get("type")
    sha = raw.get("sha")
    if kind not in ("commit", "tag") or not isinstance(sha, str) or not COMMIT.fullmatch(sha):
        raise ValueError(f"{description} has an invalid Git object identity")
    return kind, sha


def resolve_remote_tag(repository: str, tag: str,
                       request: Callable[[str], dict[str, object]] = gh_json) -> str:
    if not REPOSITORY.fullmatch(repository):
        raise ValueError("GitHub repository must be OWNER/REPO")
    if not tag or any(character in tag for character in "\r\n\x00"):
        raise ValueError("release tag is invalid")
    endpoint = f"repos/{repository}/git/ref/tags/{quote(tag, safe='')}"
    kind, sha = object_identity(request(endpoint), "remote tag ref")
    seen: set[str] = set()
    for _ in range(MAX_TAG_DEPTH):
        if kind == "commit":
            return sha
        if sha in seen:
            raise ValueError("annotated release tag chain contains a cycle")
        seen.add(sha)
        kind, sha = object_identity(
            request(f"repos/{repository}/git/tags/{sha}"), "annotated tag object"
        )
    raise ValueError("annotated release tag chain exceeds the depth limit")


def verify_remote_tag(repository: str, tag: str, expected_commit: str,
                      request: Callable[[str], dict[str, object]] = gh_json) -> str:
    if not COMMIT.fullmatch(expected_commit):
        raise ValueError("expected release commit must be lowercase 40-hex")
    actual = resolve_remote_tag(repository, tag, request)
    if actual != expected_commit:
        raise ValueError(
            f"remote release tag moved: expected {expected_commit}, resolved {actual}"
        )
    return actual


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME"))
    parser.add_argument("--expected-commit", default=os.environ.get("GITHUB_SHA"))
    args = parser.parse_args()
    try:
        if args.repository is None or args.tag is None or args.expected_commit is None:
            raise ValueError("repository, tag, and expected commit are required")
        commit = verify_remote_tag(args.repository, args.tag, args.expected_commit)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps({"repository": args.repository, "tag": args.tag, "commit": commit},
                     sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
