#!/usr/bin/env python3
"""Delete a published release whose tag is not on `main`.

The `guard` job in `release.yml` refuses such a tag before a single platform
build starts, but GitHub evaluates a tag-triggered workflow from the tagged
commit. Pushing a `v*` tag onto a commit older than that job therefore runs the
older `release.yml`, which has no guard, and publishes anyway. This audit is
triggered by `workflow_run`, and those workflows are always taken from the
default branch, so no tag can select a revision that omits it.

It deletes rather than merely reporting, because the published pre-release *is*
the damage: issue #96 records every throwaway tag having to be removed by hand.

The three outcomes are deliberately distinct:

* the tag's commit is on `main` -- nothing happens;
* git says it is not -- the release and its tag are removed, and the job fails;
* git cannot answer -- the job fails and **nothing is deleted**. Destroying a
  release on an unreadable history would be its own incident, so the refusal
  direction is "alarm, do not act".
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

from verify_release_tag_allowed import (
    RELEASE_BRANCH,
    TagNotAllowed,
    ancestry,
    ensure_commit_present,
    resolve_commit,
)

ALLOWED = 0
REMOVED = 1
UNDETERMINED = 2

REMOTE_BRANCH = f"refs/remotes/origin/{RELEASE_BRANCH}"


def tag_targets_release(tag: str) -> bool:
    """Mirror `release.yml`'s `v*` trigger, so a non-release run is ignored."""
    return tag.startswith("v")


def release_exists(slug: str, tag: str, run=subprocess.run) -> bool:
    """Whether a GitHub release exists for `tag`.

    A missing release is not an error: the tag may have been pushed without the
    release being created, which is still a refusal but has nothing to remove.
    """
    result = run(["gh", "release", "view", tag, "--repo", slug, "--json", "tagName"],
                 text=True, capture_output=True, check=False, timeout=120)
    return result.returncode == 0


def delete_release(slug: str, tag: str, run=subprocess.run) -> None:
    """Remove the release and its tag, or explain why that could not happen."""
    result = run(["gh", "release", "delete", tag, "--repo", slug, "--cleanup-tag", "--yes"],
                 text=True, capture_output=True, check=False, timeout=120)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise TagNotAllowed(f"cannot delete release {tag} in {slug}: {message}")


def audit(repository: str, tag: str, commit: str, slug: str,
          remove=delete_release, exists=release_exists) -> int:
    """Classify the tag and, when git is certain, remove what it published."""
    if not tag_targets_release(tag):
        print(f"release tag audit: {tag} is not a release tag; nothing to audit")
        return ALLOWED
    try:
        resolved = resolve_commit(repository, commit)
        ensure_commit_present(repository, resolved)
        contained = ancestry(repository, resolved, REMOTE_BRANCH)
    except TagNotAllowed as error:
        print(f"release tag audit: cannot determine whether {tag} is a release of "
              f"{RELEASE_BRANCH}, and nothing was deleted: {error}", file=sys.stderr)
        return UNDETERMINED
    if contained:
        print(f"release tag audit: {tag} -> {resolved} is on {RELEASE_BRANCH}")
        return ALLOWED
    if exists(slug, tag):
        try:
            remove(slug, tag)
        except TagNotAllowed as error:
            print(f"release tag audit: {error}", file=sys.stderr)
            return UNDETERMINED
        print(f"release tag audit: removed release {tag}; {resolved} is not on "
              f"{RELEASE_BRANCH}", file=sys.stderr)
    else:
        print(f"release tag audit: no release to remove for {tag}, but {resolved} is "
              f"not on {RELEASE_BRANCH}", file=sys.stderr)
    return REMOVED


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
