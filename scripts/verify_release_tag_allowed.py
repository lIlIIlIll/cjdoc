#!/usr/bin/env python3
"""Refuse to publish a release whose tag is not on `main`.

Issue #96 records why this exists: the release loop was verified by pushing
throwaway `v0.7.2-rc-*` tags on feature branches, and each one published a real
GitHub pre-release that then had to be deleted by hand. A tag is not an
experiment: pushing one is a publication, and nothing in the pipeline could tell
the two apart because a pre-release suffix only selects `--prerelease` while
`verify_remote_tag` checks nothing but the commit.

The distinguishing property is reachability from `main`, not the version
spelling. A one-off tag on a branch cannot be told from a real release candidate
by its name -- `-rc2` on `main` is a legitimate candidate and `-rc-perf-check`
on a branch is not -- so the guard asks the git history instead.

Deliberately strict, with no escape hatch: an override switch would be the same
hole with a different name. A hotfix that genuinely cannot land on `main` first
would need this policy changed, which is a reviewable decision rather than a
variable set on one runner.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from typing import Callable

RELEASE_BRANCH = "main"
# A guard that cannot read the history must not pass. Anything other than these
# two answers is an error, never an implicit "allowed".
ANCESTOR_EXISTS = 0
ANCESTOR_MISSING = 1


class TagNotAllowed(Exception):
    """The tag is not a release of the release branch."""


def _git(repository: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    """Run one git command, turning an unusable environment into a refusal.

    A missing binary or a repository that cannot be opened raises `OSError`
    rather than returning a status, and the docstring of this module promises a
    readable refusal instead of a traceback. The exit status is the same either
    way -- the guard never allows on an error -- but the workflow log then says
    what happened.
    """
    try:
        return subprocess.run(["git", "-C", repository, *arguments],
                              text=True, capture_output=True, check=False, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        raise TagNotAllowed(f"cannot run git in {repository}: {error}") from error


def resolve_commit(repository: str, revision: str) -> str:
    result = _git(repository, "rev-parse", "--verify", f"{revision}^{{commit}}")
    if result.returncode != 0:
        raise TagNotAllowed(
            f"cannot resolve {revision!r} in {repository}: "
            + (result.stderr or result.stdout).strip())
    return result.stdout.strip()


def ensure_commit_present(repository: str, commit: str) -> None:
    """Fetch `commit` when the checkout does not already contain it.

    `workflow_run` checkouts of the default branch need not contain a branch
    commit. Without the object, `merge-base --is-ancestor` fails for a reason
    that has nothing to do with ancestry, which would turn a real refusal into
    "cannot determine".
    """
    if _git(repository, "cat-file", "-e", f"{commit}^{{commit}}").returncode == 0:
        return
    _git(repository, "fetch", "--no-tags", "origin", commit)


def ancestry(repository: str, commit: str, branch: str) -> bool:
    """Whether `commit` is already part of `branch`.

    Uses `merge-base --is-ancestor`, whose exit status is the answer: 0 means the
    commit is contained, 1 means it is not, and every other status (a missing
    ref, a broken repository) is an error rather than a verdict.
    """
    result = _git(repository, "merge-base", "--is-ancestor", commit, branch)
    if result.returncode == ANCESTOR_EXISTS:
        return True
    if result.returncode == ANCESTOR_MISSING:
        return False
    raise TagNotAllowed(
        f"cannot check whether {commit} is on {branch}: "
        + (result.stderr or result.stdout).strip())


def verify_tag_allowed(commit: str, branch: str = RELEASE_BRANCH,
                       is_ancestor: Callable[[str, str], bool | None] | None = None) -> str:
    """Return `commit` when it is a release of `branch`, else raise.

    `is_ancestor` is injectable so the policy can be tested without a repository;
    a callable that cannot answer returns None and is treated as a refusal.
    """
    if len(commit) != 40 or any(character not in "0123456789abcdef" for character in commit):
        raise TagNotAllowed(f"release commit must be lowercase 40-hex, got {commit!r}")
    if is_ancestor is None:
        raise TagNotAllowed("no ancestry source was supplied, so the tag cannot be allowed")
    contained = is_ancestor(commit, branch)
    if contained is None:
        raise TagNotAllowed(f"cannot determine whether {commit} is on {branch}")
    if not contained:
        raise TagNotAllowed(
            f"{commit} is not on {branch}: a release tag must be pushed for a commit that "
            f"is already merged into {branch}. A throwaway tag published a real pre-release "
            "before this guard existed (issue #96).")
    return commit


def main() -> int:
    # No `--branch`: the module docstring promises no escape hatch, and a flag or
    # environment variable that renames the release branch is exactly that hole
    # under another name. The only inputs are the ones CI already supplies.
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_WORKSPACE"))
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA"))
    args = parser.parse_args()
    if not args.repository or not args.commit:
        parser.error("repository and commit are required")
    try:
        resolved = resolve_commit(args.repository, args.commit)
        verify_tag_allowed(
            resolved, RELEASE_BRANCH,
            # Fully qualified: a bare `origin/main` is ambiguous, and git prefers a
            # tag of that name over the remote-tracking ref. checkout fetches all
            # tags, so such a tag would shadow the branch and flip a refusal into
            # an allow.
            lambda commit, branch: ancestry(args.repository, commit,
                                            f"refs/remotes/origin/{branch}"))
    except TagNotAllowed as error:
        print(f"verify_release_tag_allowed: {error}", file=sys.stderr)
        return 1
    print(f"release tag allowed: {resolved} is on {RELEASE_BRANCH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
