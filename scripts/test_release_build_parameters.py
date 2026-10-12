#!/usr/bin/env python3
"""Contract tests for the CI-08.3 uniform build-parameter check."""

from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_build_parameters as params

PROJECT_ROOT = Path(__file__).resolve().parent.parent
TOML = '''[package]
  cjdoc-test = true
  override-compile-option = "%s"
'''


class BuildParameterTests(unittest.TestCase):
    def make_repo(self, override: str = "", wrapper: str | None = None) -> Path:
        root = Path(self.temporary.name)
        (root / "scripts").mkdir(parents=True, exist_ok=True)
        (root / "cjpm.toml").write_text(TOML % override, encoding="utf-8")
        (root / "scripts/with_sts_o1_cjpm.sh").write_text(
            wrapper if wrapper is not None else 'x = \'override-compile-option = "-O1"\'\n',
            encoding="utf-8")
        return root

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    def run_check(self, repo: Path, platform: str = "linux-x64", wrapper_active: bool = True):
        environ = {"CJDOC_REAL_CJPM": "/usr/bin/cjpm"} if wrapper_active else {}
        with mock.patch.dict(os.environ, environ, clear=True):
            return params.check(repo, platform, "-O1")

    def test_a_uniform_tree_passes_for_every_platform(self) -> None:
        repo = self.make_repo()
        for platform in params.PLATFORMS:
            with self.subTest(platform=platform):
                result = self.run_check(repo, platform)
                self.assertEqual(result["effectiveCompileOption"], "-O1")
                self.assertEqual(result["uniformAcross"], list(params.PLATFORMS))

    def test_building_without_the_wrapper_is_refused(self) -> None:
        repo = self.make_repo()
        # Without the wrapper the committed (empty) override would be used, which
        # is not what the release is supposed to ship.
        with self.assertRaisesRegex(SystemExit, "without the -O1 wrapper active"):
            self.run_check(repo, wrapper_active=False)

    def test_a_platform_divergence_produces_a_named_failure(self) -> None:
        repo = self.make_repo(wrapper='x = "no override here"\n')
        with self.assertRaisesRegex(SystemExit, "no longer forces"):
            self.run_check(repo)

    def test_a_committed_override_other_than_the_shared_one_is_refused(self) -> None:
        repo = self.make_repo(override="-O2")
        with self.assertRaisesRegex(SystemExit, "neither the shared default"):
            self.run_check(repo)

    def test_an_unknown_platform_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            self.run_check(self.make_repo(), "solaris-sparc")

    def test_the_release_workflow_calls_the_check_before_building(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertIn("scripts/release_build_parameters.py", candidate)
        # Compare against the real build line, not the prose in the comment above.
        check_at = candidate.index("release_build_parameters.py")
        build_at = candidate.index("\n          cjpm build --jobs 1")
        self.assertLess(check_at, build_at,
                        "the parameters must be validated before anything is built")


if __name__ == "__main__":
    unittest.main()
