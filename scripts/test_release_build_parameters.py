#!/usr/bin/env python3
"""Contract tests for the CI-08.3 uniform build-parameter check.

Run against a real copy of the repository with targeted mutations. The check
observes the release's real artefacts — the wrapper's own patch step and the
candidate job's build statement — so these tests mutate those artefacts and assert
that a false voucher is refused.
"""

from __future__ import annotations

import functools
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import release_build_parameters as params  # noqa: E402


def requires_shell(test):
    """Skip where the wrapper cannot run: observing it needs a POSIX shell.

    The release candidate job is `ubuntu-22.04`, so that is where this check does
    its work. On Windows `bash` resolves to the WSL launcher and refuses every
    command, which must not be reported as a parameter divergence.
    """
    @functools.wraps(test)
    def wrapper(self, *args, **kwargs):
        if not params.shell_is_usable():
            self.skipTest("no usable POSIX shell: the wrapper's override cannot be observed")
        return test(self, *args, **kwargs)
    return wrapper
SCRIPT = PROJECT_ROOT / "scripts/release_build_parameters.py"
MODULE = "scripts/sts_compile_override.py"
WRAPPER = "scripts/with_sts_o1_cjpm.sh"
PATCHER = "scripts/apply_sts_override.py"
PATCHER_CALL = '"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"'


def run_check(repo: Path, platform: str = "linux-x64",
              workflow: Path | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(SCRIPT), "--repo", str(repo), "--platform", platform]
    if workflow is not None:
        command += ["--workflow", str(workflow)]
    return subprocess.run(command, capture_output=True, text=True, timeout=900)


class BuildParameterTests(unittest.TestCase):
    """Uniformity must be observed from the real call path, and refused otherwise."""

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

    @requires_shell
    def test_a_uniform_tree_passes_for_every_platform(self) -> None:
        for platform in ("linux-x64", "windows-x64", "macos-arm64"):
            with self.subTest(platform=platform):
                result = run_check(self.repo, platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                payload = json.loads(result.stdout)
                # From the receipt the wrapper's patch step wrote, not from the
                # manifest, whose override is deliberately empty.
                self.assertEqual(payload["effectiveCompileOption"], "-O1")
                self.assertEqual(payload["command"], ["cjpm", "build", "--jobs", "1"])
                self.assertEqual(payload["appliedTo"], [{"option": "-O1", "package": "cjdoc"}])

    def test_the_provider_fixture_keeps_its_own_package_name(self) -> None:
        """Its directory and package names differ, which broke the first version."""
        result = subprocess.run(
            [sys.executable, "-c",
             "import sys; sys.path.insert(0, 'scripts');"
             "from sts_compile_override import manifest_package;"
             "print(manifest_package(open(sys.argv[1]).read()))",
             str(self.repo / "tests/fixtures/projects/provider_plugin/cjpm.toml")],
            cwd=self.repo, capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "provider_plugin_fixture")

    @requires_shell
    def test_a_definition_that_stops_applying_the_override_is_refused(self) -> None:
        self.edit(MODULE,
                  "        return contents.replace(NEEDLE, f'override-compile-option = \"{OPTION}\"', 1)",
                  "        return contents")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the required", result.stderr)

    @requires_shell
    def test_a_changed_shared_option_is_refused(self) -> None:
        self.edit(MODULE, 'OPTION = "-O1"', 'OPTION = "-O2"')
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    @requires_shell
    def test_a_wrapper_that_fails_to_patch_is_refused(self) -> None:
        self.edit(WRAPPER, PATCHER_CALL, ": # patcher call removed")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("applied no override", result.stderr)

    def test_a_compound_build_statement_is_refused(self) -> None:
        """`&& cjpm build --jobs 4` would package a second, differently built binary."""
        self.edit(".github/workflows/release.yml",
                  "          cjpm build --jobs 1\n",
                  "          cjpm build --jobs 1 && cjpm build --jobs 4\n")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("'&&'", result.stderr)

    def test_a_platform_specific_argument_is_refused(self) -> None:
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

    def test_two_build_statements_in_the_candidate_job_are_refused(self) -> None:
        self.edit(".github/workflows/release.yml",
                  "          cjpm build --jobs 1\n",
                  "          cjpm build --jobs 1\n          cjpm build --jobs 1\n")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("2 cjpm statements", result.stderr)

    def test_a_non_build_cjpm_statement_is_refused(self) -> None:
        self.edit(".github/workflows/release.yml",
                  "          cjpm build --jobs 1\n",
                  "          cjpm test\n")
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plain `cjpm build`", result.stderr)

    def test_a_missing_wrapper_is_refused(self) -> None:
        (self.repo / WRAPPER).unlink()
        result = run_check(self.repo)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_an_unknown_platform_is_refused(self) -> None:
        result = run_check(self.repo, "solaris-sparc")
        self.assertNotEqual(result.returncode, 0)

    @requires_shell
    def test_the_checked_tree_is_left_untouched(self) -> None:
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

    @requires_shell
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
                                capture_output=True, text=True, timeout=900)
        self.assertEqual(result.returncode, 0,
                         f"the workflow invocation failed: {result.stderr.strip()}")


if __name__ == "__main__":
    unittest.main()
