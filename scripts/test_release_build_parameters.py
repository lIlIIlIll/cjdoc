#!/usr/bin/env python3
"""Contract tests for the CI-08.3 uniform build-parameter check.

These exercise the check against the *real* repository artefacts — a copy of the
tree is mutated and the check is run in a subprocess, because the interesting
failures (a wrapper that stops applying the override, a workflow that gains a
platform-specific argument) can only be observed behaviourally.
"""

from __future__ import annotations

import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT_ROOT / "scripts/release_build_parameters.py"
PROBE_MARKER = "CJDOC_PROBE_OVERRIDE="


def run_check(repo: Path, platform: str = "linux-x64",
              workflow: Path | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(SCRIPT), "--repo", str(repo), "--platform", platform]
    if workflow is not None:
        command += ["--workflow", str(workflow)]
    return subprocess.run(command, capture_output=True, text=True, timeout=600)


class BuildParameterTests(unittest.TestCase):
    """The check must confirm uniformity from real artefacts, and refuse to guess."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo"
        shutil.copytree(PROJECT_ROOT, self.repo, ignore=shutil.ignore_patterns(
            ".git", "target", "__pycache__", "*.pyc"))
        self.assertTrue((self.repo / "cjpm.toml").is_file(), "fixture copy is incomplete")

    def edit(self, relative: str, old: str, new: str) -> None:
        path = self.repo / relative
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), 1, f"anchor missing in {relative}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def test_a_uniform_tree_passes_for_every_platform(self) -> None:
        for platform in ("linux-x64", "windows-x64", "macos-arm64"):
            with self.subTest(platform=platform):
                result = run_check(self.repo, platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                # The option comes from probing the wrapper, not from the manifest.
                self.assertEqual(payload["effectiveCompileOption"], "-O1")
                self.assertEqual(payload["command"], ["cjpm", "build", "--jobs", "1"])

    def test_the_probe_leaves_the_manifest_untouched(self) -> None:
        before = (self.repo / "cjpm.toml").read_bytes()
        self.assertEqual(run_check(self.repo).returncode, 0)
        self.assertEqual((self.repo / "cjpm.toml").read_bytes(), before)

    def test_a_wrapper_that_stops_applying_the_override_is_refused(self) -> None:
        # Comments still mention -O1, so a text search would pass; only running the
        # wrapper reveals that the override is no longer applied.
        self.edit("scripts/with_sts_o1_cjpm.sh",
                  """        if contents.count(needle) != 1:
            raise SystemExit(f"expected one default override-compile-option in {manifest}")
        updated = contents.replace(needle, 'override-compile-option = "-O1"', 1)""",
                  """        updated = contents""")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("override-compile-option=''", result.stderr)

    def test_a_wrapper_that_applies_a_different_option_is_refused(self) -> None:
        # Rewrite the applied option only; the wrapper still runs to completion.
        self.edit("scripts/with_sts_o1_cjpm.sh",
                  """updated = contents.replace(needle, 'override-compile-option = "-O1"', 1)""",
                  """updated = contents.replace(needle, 'override-compile-option = "-O2"', 1)""")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    def test_a_platform_specific_argument_is_refused(self) -> None:
        # The invocation still starts with the uniform prefix the old check
        # searched for, but the effective command now differs per platform.
        self.edit(".github/workflows/release.yml",
                  '          cjpm build --jobs 1\n',
                  '          extra=()\n'
                  '          if [[ "${{ matrix.platform }}" == "macos-arm64" ]]; then\n'
                  '            extra+=("--cfg" "target=apple")\n'
                  '          fi\n'
                  '          cjpm build --jobs 1 ${extra[@]+"${extra[@]}"}\n')
        result = run_check(self.repo, "macos-arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interpolated argument", result.stderr)

    def test_two_build_commands_in_the_candidate_job_are_refused(self) -> None:
        self.edit(".github/workflows/release.yml",
                  '          cjpm build --jobs 1\n',
                  '          cjpm build --jobs 1\n          cjpm build --jobs 1\n')
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 cjpm commands", result.stderr)

    def test_a_missing_wrapper_is_refused(self) -> None:
        (self.repo / "scripts/with_sts_o1_cjpm.sh").unlink()
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_an_unknown_platform_is_refused(self) -> None:
        result = run_check(self.repo, "solaris-sparc")
        self.assertNotEqual(result.returncode, 0)

    def test_the_release_workflow_calls_the_check_before_building(self) -> None:
        workflow = (self.repo / ".github/workflows/release.yml").read_text(encoding="utf-8")
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertIn("scripts/release_build_parameters.py", candidate)
        check_at = candidate.index("release_build_parameters.py")
        # Compare against the real build line, not the prose in the comment above.
        build_at = candidate.index("\n          cjpm build --jobs 1")
        self.assertLess(check_at, build_at,
                        "the parameters must be validated before anything is built")

    def test_the_workflows_exact_invocation_actually_runs(self) -> None:
        """The workflow line must be executable, not merely present.

        Checking only that the script is named would pass with an argument the
        parser rejects, and with `set -euo pipefail` that stops the job before the
        build — so no release is ever produced.
        """
        workflow = (self.repo / ".github/workflows/release.yml").read_text(encoding="utf-8")
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        # Collect the invocation including its shell line continuations.
        lines = [line.strip() for line in candidate.splitlines()]
        starts = [index for index, line in enumerate(lines)
                  if line.startswith("python scripts/release_build_parameters.py")]
        self.assertEqual(len(starts), 1, "expected exactly one invocation to exercise")
        invocation = lines[starts[0]]
        index = starts[0]
        while invocation.endswith("\\"):
            index += 1
            invocation = invocation[:-1].rstrip() + " " + lines[index]
        invocation = invocation.replace("${{ matrix.platform }}", "linux-x64")
        invocation = invocation.removeprefix("python ")
        result = subprocess.run([sys.executable, *shlex.split(invocation)], cwd=self.repo,
                                capture_output=True, text=True, timeout=600)
        self.assertEqual(result.returncode, 0,
                         f"the workflow invocation failed: {result.stderr.strip()}")


if __name__ == "__main__":
    unittest.main()
