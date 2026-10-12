#!/usr/bin/env python3
"""Contract tests for the CI-08.3 uniform build-parameter check.

These exercise the check against a real copy of the repository with targeted
mutations. They are deliberately shell-free: the release matrix builds on Windows,
where `bash` may only resolve to an unconfigured WSL, so the check must not depend
on executing the wrapper.
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
MODULE = "scripts/sts_compile_override.py"
WRAPPER = "scripts/with_sts_o1_cjpm.sh"


def run_check(repo: Path, platform: str = "linux-x64",
              workflow: Path | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(SCRIPT), "--repo", str(repo), "--platform", platform]
    if workflow is not None:
        command += ["--workflow", str(workflow)]
    return subprocess.run(command, capture_output=True, text=True, timeout=600)


class BuildParameterTests(unittest.TestCase):
    """Uniformity must be established from real artefacts, and refused when unprovable."""

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
                # The option is computed through the wrapper's own function, not
                # read from cjpm.toml, whose override is deliberately empty.
                self.assertEqual(payload["effectiveCompileOption"], "-O1")
                self.assertEqual(payload["command"], ["cjpm", "build", "--jobs", "1"])

    def test_the_check_does_not_depend_on_a_shell(self) -> None:
        """Windows has no guaranteed bash, so the check must not exec one."""
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("subprocess", source)
        self.assertNotIn("os.system", source)
        # The shell this check must not need is named only to justify avoiding it.
        self.assertLessEqual(source.count("bash"), 1)

    def test_a_different_applied_option_is_refused(self) -> None:
        # The shared definition is the only way the effective option can change,
        # so changing it there must be caught.
        self.edit(MODULE, 'OPTION = "-O1"', 'OPTION = "-O2"')
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    def test_the_wrapper_must_delegate_to_the_shared_definition(self) -> None:
        """A second copy of the rewrite could drift from what the check computes."""
        self.edit(WRAPPER,
                  "from sts_compile_override import apply_to",
                  "def apply_to(contents, expected_name):\n        return contents")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)

    def test_the_wrapper_may_not_carry_its_own_rewrite(self) -> None:
        self.edit(WRAPPER,
                  "updates = [(manifest, apply_to(manifest.read_text(encoding=\"utf-8\"), expected))",
                  "updates = [(manifest, manifest.read_text(encoding=\"utf-8\").replace("
                  "'override-compile-option = \"\"', 'override-compile-option = \"-O1\"', 1))")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)

    def test_a_platform_specific_argument_is_refused(self) -> None:
        # The invocation still starts with the uniform prefix the first version
        # searched for, but the effective command now differs per platform.
        self.edit(".github/workflows/release.yml",
                  "          cjpm build --jobs 1\n",
                  "          extra=()\n"
                  "          if [[ \"${{ matrix.platform }}\" == \"macos-arm64\" ]]; then\n"
                  "            extra+=(\"--cfg\" \"target=apple\")\n"
                  "          fi\n"
                  "          cjpm build --jobs 1 ${extra[@]+\"${extra[@]}\"}\n")
        result = run_check(self.repo, "macos-arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interpolated argument", result.stderr)

    def test_two_build_commands_in_the_candidate_job_are_refused(self) -> None:
        self.edit(".github/workflows/release.yml",
                  "          cjpm build --jobs 1\n",
                  "          cjpm build --jobs 1\n          cjpm build --jobs 1\n")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 cjpm commands", result.stderr)

    def test_a_missing_wrapper_is_refused(self) -> None:
        (self.repo / WRAPPER).unlink()
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_an_unknown_platform_is_refused(self) -> None:
        result = run_check(self.repo, "solaris-sparc")
        self.assertNotEqual(result.returncode, 0)

    def test_a_manifest_with_an_unexpected_option_is_refused(self) -> None:
        self.edit("cjpm.toml", 'override-compile-option = ""',
                  'override-compile-option = "-O3"')
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)

    def test_the_probe_leaves_the_manifest_untouched(self) -> None:
        before = (self.repo / "cjpm.toml").read_bytes()
        self.assertEqual(run_check(self.repo).returncode, 0)
        self.assertEqual((self.repo / "cjpm.toml").read_bytes(), before)

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
