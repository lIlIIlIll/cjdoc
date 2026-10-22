"""A tag that predates the release guard must still not keep its release.

Issue #96 fixed the publication path by refusing a tag that is not a release of
`main`, but GitHub evaluates a tag-triggered workflow from the tagged commit. A
`v*` tag on an older commit runs the older `release.yml`, which has no guard, so
the fix alone leaves the original incident reachable. `release-audit.yml` is
triggered by `workflow_run`, always read from the default branch, and removes
what such a tag published.

Three outcomes, and the difference between the last two is the point:

* the commit is on `main` -- nothing is deleted;
* it is not -- the release is deleted and the job fails;
* git cannot answer -- the job fails and **nothing is deleted**. A wrong deletion
  is a second incident, so uncertainty must never be read as refusal.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import audit_release_tag as audit
import verify_release_tag_allowed as guard


def git(repository: Path, *arguments: str) -> str:
    # `core.hooksPath` is overridden so a developer's global hooks cannot run
    # inside a throwaway repository; the commits here are pure fixture setup.
    result = subprocess.run(["git", "-C", str(repository), "-c", "core.hooksPath=/dev/null",
                             *arguments], text=True, capture_output=True, check=True)
    return result.stdout.strip()


class Repository:
    """A throwaway repository with `main` and a branch that is not on it."""

    def __init__(self, root: Path) -> None:
        self.root = root
        git(root, "init", "--initial-branch=main", "-q")
        git(root, "config", "user.email", "audit@example.test")
        git(root, "config", "user.name", "audit")
        git(root, "config", "commit.gpgsign", "false")
        (root / "file").write_text("one\n")
        git(root, "add", "file")
        git(root, "commit", "-q", "-m", "one")
        self.main_commit = git(root, "rev-parse", "HEAD")
        git(root, "checkout", "-q", "-b", "feature")
        (root / "file").write_text("two\n")
        git(root, "commit", "-q", "-am", "two")
        self.branch_commit = git(root, "rev-parse", "HEAD")
        git(root, "checkout", "-q", "main")
        # The audit resolves `refs/remotes/origin/main`, exactly as CI does after
        # `actions/checkout` with a remote configured.
        git(root, "update-ref", "refs/remotes/origin/main", self.main_commit)


class AuditTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repository = Repository(Path(self.temporary.name))

    def run_audit(self, tag: str, commit: str, *, exists: bool = True,
                  container_on_main: bool = True) -> tuple[int, list[tuple[str, str]]]:
        deleted: list[tuple[str, str]] = []

        def remove(slug: str, name: str) -> None:
            deleted.append((slug, name))

        code = audit.audit(str(self.repository.root), tag, commit, "owner/repo",
                           remove=remove, exists=lambda slug, name: exists)
        return code, deleted

    def test_a_release_of_main_is_left_alone(self) -> None:
        code, deleted = self.run_audit("v0.7.4", self.repository.main_commit)
        self.assertEqual(code, audit.ALLOWED)
        self.assertEqual(deleted, [])

    def test_a_tag_off_main_is_deleted(self) -> None:
        code, deleted = self.run_audit("v0.7.2-rc2", self.repository.branch_commit)
        self.assertEqual(code, audit.REMOVED)
        self.assertEqual(deleted, [("owner/repo", "v0.7.2-rc2")])

    def test_a_tag_that_published_nothing_still_fails(self) -> None:
        code, deleted = self.run_audit("v0.7.2-rc2", self.repository.branch_commit,
                                       exists=False)
        self.assertEqual(code, audit.REMOVED)
        self.assertEqual(deleted, [])

    def test_an_unreadable_history_deletes_nothing(self) -> None:
        """Uncertainty must alarm, never destroy."""
        deleted: list[tuple[str, str]] = []
        with mock.patch.object(audit, "ancestry",
                               side_effect=guard.TagNotAllowed("cannot run git")):
            code = audit.audit(str(self.repository.root), "v0.7.2-rc2",
                               self.repository.branch_commit, "owner/repo",
                               remove=lambda slug, name: deleted.append((slug, name)),
                               exists=lambda slug, name: True)
        self.assertEqual(code, audit.UNDETERMINED)
        self.assertEqual(deleted, [])

    def test_a_failed_deletion_is_not_reported_as_removed(self) -> None:
        def failing(slug: str, name: str) -> None:
            raise guard.TagNotAllowed("cannot delete release")

        code = audit.audit(str(self.repository.root), "v0.7.2-rc2",
                           self.repository.branch_commit, "owner/repo",
                           remove=failing, exists=lambda slug, name: True)
        self.assertEqual(code, audit.UNDETERMINED)

    def test_a_tag_outside_the_release_namespace_is_ignored(self) -> None:
        code, deleted = self.run_audit("not-a-release", self.repository.branch_commit)
        self.assertEqual(code, audit.ALLOWED)
        self.assertEqual(deleted, [])


class WorkflowTest(unittest.TestCase):
    """The backstop is only a backstop if it is wired to the default branch."""

    def setUp(self) -> None:
        self.text = (SCRIPTS.parent / ".github/workflows/release-audit.yml").read_text()

    def test_it_is_triggered_by_the_release_workflow(self) -> None:
        self.assertIn("workflow_run:", self.text)
        self.assertIn('workflows: ["Release"]', self.text)

    def test_it_only_audits_tag_pushes(self) -> None:
        self.assertIn("workflow_run.event == 'push'", self.text)
        self.assertIn("startsWith(github.event.workflow_run.head_branch, 'v')", self.text)

    def test_it_passes_the_tag_and_commit_from_the_trigger(self) -> None:
        self.assertIn("github.event.workflow_run.head_branch", self.text)
        self.assertIn("github.event.workflow_run.head_sha", self.text)

    def test_it_does_not_check_out_the_tagged_commit(self) -> None:
        """Checking out the tag would run the guard-less code the tag selected."""
        self.assertNotIn("ref: ${{ github.event.workflow_run.head_branch }}", self.text)
        self.assertNotIn("ref: ${{ github.event.workflow_run.head_sha }}", self.text)

    def test_it_checks_out_full_history_for_ancestry(self) -> None:
        self.assertIn("fetch-depth: 0", self.text)

    def test_it_runs_the_audit_against_the_trigger_identity(self) -> None:
        self.assertIn("python scripts/audit_release_tag.py", self.text)
        self.assertIn('--tag "${TAG}"', self.text)
        self.assertIn('--commit "${COMMIT}"', self.text)

    def test_the_guard_names_this_file_as_its_backstop(self) -> None:
        """The release guard must not claim a protection it cannot provide."""
        release = (SCRIPTS.parent / ".github/workflows/release.yml").read_text()
        self.assertIn("`release-audit.yml` is the", release)
        self.assertIn("from the tagged commit", release)


class FetchTest(unittest.TestCase):
    """A default-branch checkout need not contain the tagged commit.

    Without the object, `merge-base --is-ancestor` fails for a reason unrelated
    to ancestry -- which this module must not read as either verdict.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.remote = root / "remote.git"
        git(root, "init", "-q", "--bare", str(self.remote))
        work = root / "work"
        git(root, "clone", "-q", self.remote.as_uri(), str(work))
        git(work, "config", "user.email", "audit@example.test")
        git(work, "config", "user.name", "audit")
        (work / "file").write_text("one\n")
        git(work, "add", "file")
        git(work, "commit", "-q", "-m", "one")
        git(work, "push", "-q", "origin", "HEAD:main")
        git(work, "checkout", "-q", "-b", "feature")
        (work / "file").write_text("two\n")
        git(work, "commit", "-q", "-am", "two")
        git(work, "push", "-q", "origin", "feature")
        self.branch_commit = git(work, "rev-parse", "HEAD")
        self.shallow = root / "shallow"
        # `file://` is required: a plain local path makes git ignore `--depth`,
        # and the fixture would silently contain the commit under test.
        git(root, "clone", "-q", "--depth", "1", "--branch", "main",
            self.remote.as_uri(), str(self.shallow))

    def test_a_missing_commit_is_fetched_before_ancestry(self) -> None:
        missing = subprocess.run(
            ["git", "-C", str(self.shallow), "cat-file", "-e", self.branch_commit],
            capture_output=True)
        self.assertNotEqual(missing.returncode, 0, "fixture already has the commit")

        guard.ensure_commit_present(str(self.shallow), self.branch_commit)

        self.assertFalse(guard.ancestry(str(self.shallow), self.branch_commit,
                                        "refs/remotes/origin/main"))


if __name__ == "__main__":
    unittest.main()
