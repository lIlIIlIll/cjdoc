#!/usr/bin/env python3
"""Report a published release whose tag commit is not on `main`.

GitHub evaluates a tag-triggered workflow from the tagged commit. A `v*` tag on
a commit older than the guard in `release.yml` therefore runs the old,
guard-less workflow. This audit is triggered by `workflow_run`, whose workflow
is read from the default branch, so an old tag cannot select a revision that
omits the check.

The audit is read-only. GitHub exposes release deletion and tag deletion as
separate, unconditional operations; a tag could move after a check and before
cleanup, causing a valid replacement release to be deleted. An off-main
publication therefore fails this workflow with the release and commit identity
for a maintainer to verify and clean up manually.

* the event commit is on `main` -- the run succeeds;
* it is off `main` and a release exists for the unchanged live tag -- the run
  fails and requests manual cleanup;
* history, release lookup, or live-tag lookup is uncertain -- the run fails
  without changing release or tag state.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from urllib.parse import quote

from verify_release_tag_allowed import (
    RELEASE_BRANCH,
    TagNotAllowed,
    ancestry,
    ensure_commit_present,
    resolve_commit,
)

from verify_remote_tag import verify_remote_tag

ALLOWED = 0
REFUSED = 1
UNDETERMINED = 2

REMOTE_BRANCH = f"refs/remotes/origin/{RELEASE_BRANCH}"


def tag_targets_release(tag: str) -> bool:
    """Mirror `release.yml`'s `v*` trigger, so a non-release run is ignored."""
    return tag.startswith("v")


def release_exists(slug: str, tag: str, run=subprocess.run) -> bool:
    """Whether a GitHub release exists, distinguishing 404 from API failure."""
    endpoint = f"repos/{slug}/releases/tags/{quote(tag, safe='')}"
    try:
        result = run(["gh", "api", "--include", endpoint],
                     text=True, capture_output=True, check=False, timeout=120)
    except (OSError, subprocess.SubprocessError) as error:
        raise TagNotAllowed(f"cannot check release {tag} in {slug}: {error}") from error
    status = re.match(r"HTTP/\d(?:\.\d)?\s+(\d{3})\b", result.stdout)
    if status is None:
        message = (result.stderr or result.stdout).strip()
        raise TagNotAllowed(
            f"cannot determine whether release {tag} exists in {slug}: {message}")
    if status.group(1) == "200":
        return True
    if status.group(1) == "404":
        return False
    raise TagNotAllowed(
        f"cannot determine whether release {tag} exists in {slug}: "
        f"GitHub API returned HTTP {status.group(1)}")



def verify_live_tag(slug: str, tag: str, commit: str,
                    verify=verify_remote_tag) -> None:
    """Require the live tag to match the triggering event before reporting."""
    try:
        verify(slug, tag, commit)
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise TagNotAllowed(
            f"cannot verify live tag {tag} in {slug}; manual review required: {error}") from error


def audit(repository: str, tag: str, commit: str, slug: str,
          exists=release_exists) -> int:
    """Classify the tag without modifying release or tag state."""
    if not tag_targets_release(tag):
        print(f"release tag audit: {tag} is not a release tag; nothing to audit")
        return ALLOWED
    try:
        resolved = resolve_commit(repository, commit)
        ensure_commit_present(repository, resolved)
    except TagNotAllowed as error:
        print(f"release tag audit: cannot resolve event commit for {tag}; "
              f"no release or tag was changed: {error}", file=sys.stderr)
        return UNDETERMINED
    try:
        verify_live_tag(slug, tag, resolved)
    except TagNotAllowed as error:
        print(f"release tag audit: {error}; no release or tag was changed", file=sys.stderr)
        return UNDETERMINED
    try:
        contained = ancestry(repository, resolved, REMOTE_BRANCH)
    except TagNotAllowed as error:
        print(f"release tag audit: cannot determine whether {tag} is on "
              f"{RELEASE_BRANCH}; no release or tag was changed: {error}", file=sys.stderr)
        return UNDETERMINED
    if contained:
        print(f"release tag audit: {tag} -> {resolved} is on {RELEASE_BRANCH}")
        return ALLOWED
    try:
        has_release = exists(slug, tag)
    except TagNotAllowed as error:
        print(f"release tag audit: {error}; no release or tag was changed", file=sys.stderr)
        return UNDETERMINED
    if not has_release:
        print(f"release tag audit: {tag} -> {resolved} is not on {RELEASE_BRANCH}; "
              "no release exists and no release or tag was changed", file=sys.stderr)
        return REFUSED
    print(f"release tag audit: release {tag} exists for off-main commit {resolved}; "
          "manual cleanup required; no release or tag was changed", file=sys.stderr)
    return REFUSED


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_WORKSPACE"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--slug", default=os.environ.get("GITHUB_REPOSITORY"))
    args = parser.parse_args()
    if not args.repository or not args.slug:
        parser.error("repository and slug are required")
    return audit(args.repository, args.tag, args.commit, args.slug)


if __name__ == "__main__":
    raise SystemExit(main())
