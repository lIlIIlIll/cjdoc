"""A tag that is not a release of `main` must not publish anything.

Issue #96 records the failure this guards: the release loop was exercised by
pushing throwaway `v0.7.2-rc-*` tags on feature branches, and each one published
a real GitHub pre-release that had to be deleted by hand. The guard therefore
asks git whether the tagged commit is already on `main`; the tag's spelling
cannot answer that question, because `-rc2` on `main` is a legitimate candidate.

Every test below is about the refusal direction: a guard that answered "allowed"
when it could not see the history would be worse than no guard, because the
pipeline would look protected.
"""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import verify_release_tag_allowed as guard


class ReleaseTagPolicyTest(unittest.TestCase):
    def test_a_commit_on_main_is_allowed(self) -> None:
        commit = "a" * 40
        self.assertEqual(guard.verify_tag_allowed(commit, "main",
                                                  lambda c, b: True), commit)

    def test_a_commit_outside_main_is_refused(self) -> None:
        """The throwaway-tag case: the commit exists, but not on the release branch."""
        with self.assertRaises(guard.TagNotAllowed) as caught:
            guard.verify_tag_allowed("b" * 40, "main", lambda c, b: False)
        self.assertIn("not on main", str(caught.exception))

    def test_an_unanswerable_ancestry_is_refused(self) -> None:
        """A guard that cannot see the history must say no, not "probably yes"."""
        with self.assertRaises(guard.TagNotAllowed):
            guard.verify_tag_allowed("c" * 40, "main", lambda c, b: None)

    def test_a_missing_ancestry_source_is_refused(self) -> None:
        with self.assertRaises(guard.TagNotAllowed):
            guard.verify_tag_allowed("d" * 40, "main", None)

    def test_a_commit_that_is_not_a_full_sha_is_refused(self) -> None:
        with self.assertRaises(guard.TagNotAllowed):
            guard.verify_tag_allowed("abc123", "main", lambda c, b: True)
        with self.assertRaises(guard.TagNotAllowed):
            guard.verify_tag_allowed("A" * 40, "main", lambda c, b: True)

    def test_the_tag_spelling_cannot_allow_or_refuse(self) -> None:
        """`-rc` is not the discriminator; only reachability from `main` is.

        A naming rule would both reject legitimate candidates on `main` and accept
        throwaway branches that avoided the suffix.
        """
        allowed = guard.verify_tag_allowed("e" * 40, "main", lambda c, b: True)
        self.assertEqual(allowed, "e" * 40)
        with self.assertRaises(guard.TagNotAllowed):
            guard.verify_tag_allowed("f" * 40, "main", lambda c, b: False)


class ReleaseTagAncestryTest(unittest.TestCase):
    """The real git call, so the exit-status contract is exercised, not assumed."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        # The developer's global hooks would otherwise run against this throwaway
        # repository and reject its commit message; the fixture needs no policy.
        self.git("config", "core.hooksPath", str(self.repo / "no-hooks"))
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.test")
        (self.repo / "file").write_text("1\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "one")
        self.on_main = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "-b", "feature")
        (self.repo / "file").write_text("2\n", encoding="utf-8")
        self.git("commit", "-q", "-am", "two")
        self.on_branch = self.git("rev-parse", "HEAD")

    def git(self, *arguments: str) -> str:
        result = subprocess.run(["git", "-C", str(self.repo), *arguments],
                                text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def test_a_merged_commit_is_an_ancestor(self) -> None:
        self.assertTrue(guard.ancestry(str(self.repo), self.on_main, "main"))

    def test_an_unmerged_commit_is_not_an_ancestor(self) -> None:
        """This is the throwaway-tag case, decided by git rather than by its name."""
        self.assertFalse(guard.ancestry(str(self.repo), self.on_branch, "main"))

    def test_a_missing_ref_is_an_error_not_a_verdict(self) -> None:
        """A shallow clone without the branch must fail closed, not silently pass."""
        with self.assertRaises(guard.TagNotAllowed):
            guard.ancestry(str(self.repo), self.on_main, "no-such-branch")


class GuardEntryPointTest(unittest.TestCase):
    """`main()` is the only code the workflow runs, so it needs its own coverage.

    The policy (`verify_tag_allowed`) and the git call (`ancestry`) can both be
    correct while `main()` wires them backwards -- `is-ancestor main <commit>`
    instead of `<commit> origin/main` is true for every commit branched off
    `main`, which would make the guard an allow-all for the exact throwaway case
    it exists to refuse.
    """

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "core.hooksPath", str(self.repo / "no-hooks"))
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.test")
        (self.repo / "file").write_text("1\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "one")
        self.on_main = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "-b", "feature")
        (self.repo / "file").write_text("2\n", encoding="utf-8")
        self.git("commit", "-q", "-am", "two")
        self.on_branch = self.git("rev-parse", "HEAD")
        # What actions/checkout leaves behind: the remote-tracking branch, not a
        # local `main`.
        self.git("update-ref", "refs/remotes/origin/main", self.on_main)

    def git(self, *arguments: str) -> str:
        result = subprocess.run(["git", "-C", str(self.repo), *arguments],
                                text=True, capture_output=True, check=True)
        return result.stdout.strip()

    def run_main(self, commit: str, stderr: io.StringIO | None = None) -> int:
        argv = ["verify_release_tag_allowed.py", "--repository", str(self.repo),
                "--commit", commit]
        with unittest.mock.patch.object(sys, "argv", argv), \
                unittest.mock.patch.object(sys, "stderr", new=stderr or io.StringIO()), \
                unittest.mock.patch.object(sys, "stdout", new=io.StringIO()):
            return guard.main()

    def test_a_commit_on_the_remote_branch_is_allowed(self) -> None:
        self.assertEqual(self.run_main(self.on_main), 0)

    def test_a_feature_commit_is_refused(self) -> None:
        self.assertEqual(self.run_main(self.on_branch), 1)

    def test_a_tag_named_origin_main_cannot_shadow_the_branch(self) -> None:
        """git prefers `refs/tags/origin/main` over the remote-tracking ref.

        `checkout` fetches every tag, so an ambiguous `origin/main` would let any
        tag of that name decide the verdict. The guard names the full ref.
        """
        self.git("tag", "origin/main", self.on_branch)
        self.assertEqual(self.run_main(self.on_branch), 1)

    def test_the_policy_sees_a_commit_even_when_the_input_is_a_revision(self) -> None:
        """`main()` resolves `--commit` to a commit before asking the policy.

        `verify_tag_allowed` accepts only a lowercase 40-hex commit, so the
        resolution step is what lets the guard be driven by any revision git can
        resolve. Removing it makes the guard refuse a legitimate release whose
        `--commit` was abbreviated, which is the direction that would look like a
        policy failure rather than a bug.
        """
        short = self.on_main[:12]
        self.assertNotEqual(short, self.on_main)
        self.assertEqual(self.run_main(short), 0)

    def test_a_missing_git_binary_is_a_refusal_not_a_traceback(self) -> None:
        """The workflow log must say what failed, and the exit status must stay 1."""
        messages = io.StringIO()
        with unittest.mock.patch.object(guard.subprocess, "run",
                                        side_effect=FileNotFoundError("git")):
            self.assertEqual(self.run_main(self.on_main, stderr=messages), 1)
        self.assertIn("verify_release_tag_allowed:", messages.getvalue())
        self.assertNotIn("Traceback", messages.getvalue())

    def test_there_is_no_branch_override(self) -> None:
        """A rename flag would re-admit exactly the tags the guard refuses."""
        argv = ["verify_release_tag_allowed.py", "--branch", "feature"]
        with unittest.mock.patch.object(sys, "argv", argv), \
                unittest.mock.patch.object(sys, "stderr", new=io.StringIO()), \
                self.assertRaises(SystemExit):
            guard.main()


if __name__ == "__main__":
    unittest.main()
