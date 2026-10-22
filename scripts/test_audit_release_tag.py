"""A default-branch audit detects tags that predate the release guard.

GitHub evaluates tag-triggered workflows from the tagged commit. A `v*` tag on
an older commit therefore runs the old `release.yml` without the guard.
`release-audit.yml` is triggered by `workflow_run` from the default branch and
reports off-main publications for manual cleanup. It is read-only because no
GitHub API operation atomically binds release deletion and tag deletion to the
commit that was audited.

* the event commit is on `main` -- the run succeeds;
* it is off `main` and the release/live tag match -- the run fails and requests
  manual cleanup without changing either;
* history or API state is uncertain -- the run fails without changing either.
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

    def run_audit(self, tag: str, commit: str, *, exists=True
                  ) -> tuple[int, mock.Mock]:
        lookup = exists if callable(exists) else lambda _slug, _tag: exists
        with mock.patch.object(audit, "verify_live_tag") as verify:
            code = audit.audit(str(self.repository.root), tag, commit, "owner/repo",
                               exists=lookup)
        return code, verify

    def test_a_release_of_main_is_left_alone(self) -> None:
        code, verify = self.run_audit("v0.7.4", self.repository.main_commit)
        self.assertEqual(code, audit.ALLOWED)
        verify.assert_called_once_with("owner/repo", "v0.7.4", self.repository.main_commit)

    def test_an_off_main_release_requests_manual_cleanup(self) -> None:
        code, verify = self.run_audit("v0.7.2-rc2", self.repository.branch_commit)
        self.assertEqual(code, audit.REFUSED)
        verify.assert_called_once_with("owner/repo", "v0.7.2-rc2",
                                       self.repository.branch_commit)

    def test_an_off_main_tag_without_a_release_fails(self) -> None:
        code, verify = self.run_audit("v0.7.2-rc2", self.repository.branch_commit,
                                      exists=lambda slug, name: False)
        self.assertEqual(code, audit.REFUSED)
        verify.assert_called_once_with("owner/repo", "v0.7.2-rc2",
                                       self.repository.branch_commit)

    def test_an_unreadable_history_is_undetermined(self) -> None:
        exists = mock.Mock(return_value=True)
        with mock.patch.object(audit, "verify_live_tag"):
            with mock.patch.object(audit, "ancestry",
                                   side_effect=guard.TagNotAllowed("cannot run git")):
                code = audit.audit(str(self.repository.root), "v0.7.2-rc2",
                                   self.repository.branch_commit, "owner/repo",
                                   exists=exists)
        self.assertEqual(code, audit.UNDETERMINED)
        exists.assert_not_called()

    def test_a_release_api_failure_is_undetermined(self) -> None:
        exists = mock.Mock(side_effect=guard.TagNotAllowed("rate limited"))
        with mock.patch.object(audit, "verify_live_tag") as verify:
            code = audit.audit(str(self.repository.root), "v0.7.2-rc2",
                               self.repository.branch_commit, "owner/repo", exists=exists)
        self.assertEqual(code, audit.UNDETERMINED)
        verify.assert_called_once_with("owner/repo", "v0.7.2-rc2",
                                       self.repository.branch_commit)

    def test_a_moved_live_tag_is_undetermined(self) -> None:
        with mock.patch.object(audit, "verify_live_tag",
                               side_effect=guard.TagNotAllowed("remote tag moved")):
            code = audit.audit(
                str(self.repository.root), "v0.7.2-rc2", self.repository.branch_commit,
                "owner/repo", exists=lambda slug, name: True)
        self.assertEqual(code, audit.UNDETERMINED)

    def test_a_main_tag_moved_after_release_is_undetermined(self) -> None:
        with mock.patch.object(audit, "verify_live_tag",
                               side_effect=guard.TagNotAllowed("remote tag moved")):
            code = audit.audit(str(self.repository.root), "v0.7.4",
                               self.repository.main_commit, "owner/repo")
        self.assertEqual(code, audit.UNDETERMINED)

    def test_a_tag_outside_the_release_namespace_is_ignored(self) -> None:
        code, verify = self.run_audit("not-a-release", self.repository.branch_commit)
        self.assertEqual(code, audit.ALLOWED)
        verify.assert_not_called()




class ReleaseLookupTest(unittest.TestCase):
    def test_lookup_requests_the_release_endpoint_with_status(self) -> None:
        calls: list[list[str]] = []

        def request(arguments, **_kwargs):
            calls.append(arguments)
            return subprocess.CompletedProcess(arguments, 1, "HTTP/2.0 404 Not Found\n", "")

        self.assertFalse(audit.release_exists("owner/repo", "v0.7.2-rc2", run=request))
        self.assertEqual(calls, [[
            "gh", "api", "--include", "repos/owner/repo/releases/tags/v0.7.2-rc2"]])

    def test_only_a_404_means_missing(self) -> None:
        missing = subprocess.CompletedProcess([], 1, "HTTP/2.0 404 Not Found\n", "not found")
        self.assertFalse(audit.release_exists("owner/repo", "v0.7.2-rc2",
                                              run=lambda *_args, **_kwargs: missing))

    def test_a_successful_lookup_means_present(self) -> None:
        found = subprocess.CompletedProcess([], 0, "HTTP/2.0 200 OK\n{}", "")
        self.assertTrue(audit.release_exists("owner/repo", "v0.7.2-rc2",
                                             run=lambda *_args, **_kwargs: found))

    def test_rate_limit_is_not_misreported_as_absence(self) -> None:
        limited = subprocess.CompletedProcess([], 1, "HTTP/2.0 403 Forbidden\n", "rate limited")
        with self.assertRaises(guard.TagNotAllowed):
            audit.release_exists("owner/repo", "v0.7.2-rc2",
                                 run=lambda *_args, **_kwargs: limited)

    def test_transport_failure_is_not_misreported_as_absence(self) -> None:
        unavailable = subprocess.CompletedProcess([], 1, "", "connection refused")
        with self.assertRaises(guard.TagNotAllowed):
            audit.release_exists("owner/repo", "v0.7.2-rc2",
                                 run=lambda *_args, **_kwargs: unavailable)

    def test_subprocess_errors_are_refusals(self) -> None:
        def timeout(*_args, **_kwargs):
            raise subprocess.TimeoutExpired("gh api", 120)

        with self.assertRaises(guard.TagNotAllowed):
            audit.release_exists("owner/repo", "v0.7.2-rc2", run=timeout)




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

    def test_it_has_read_only_permissions(self) -> None:
        self.assertIn("permissions:\n  contents: read", self.text)
        self.assertNotIn("contents: write", self.text)
        self.assertNotIn("actions: write", self.text)

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
