#!/usr/bin/env python3
"""Tests for the CI-08.3 override observation.

This script's only job is to confirm the wrapper applies the pinned option to the
manifest the build reads. The command question is answered from the wrapper's own
invocation record — see `test_verify_build_invocations.py` — so there is deliberately
no test here for recognising a spelled, nested or indirect build.
"""

from __future__ import annotations

import functools
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import release_build_parameters as params  # noqa: E402

SCRIPT = PROJECT_ROOT / "scripts/release_build_parameters.py"
MODULE = "scripts/sts_compile_override.py"
WRAPPER = "scripts/with_sts_cjpm.sh"
PATCHER = "scripts/apply_sts_override.py"


def requires_shell(test):
    """Skip where the wrapper cannot run: observing it needs a POSIX shell."""
    @functools.wraps(test)
    def wrapper(self, *args, **kwargs):
        if not params.shell_is_usable():
            self.skipTest("no usable POSIX shell: the wrapper's override cannot be observed")
        return test(self, *args, **kwargs)
    return wrapper


class BuildParameterTests(unittest.TestCase):
    """The observed option must come from the manifest the build would consume."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = (Path(self.temporary.name) / "repo").resolve()
        shutil.copytree(PROJECT_ROOT, self.repo, ignore=shutil.ignore_patterns(
            ".git", "target", "__pycache__", "*.pyc"))
        self.assertTrue((self.repo / "cjpm.toml").is_file(), "fixture copy is incomplete")

    def edit(self, relative: str, old: str, new: str) -> None:
        path = self.repo / relative
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count(old), 1, f"anchor missing in {relative}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def run_check(self, platform: str = "linux-x64"):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), "--platform", platform],
            capture_output=True, text=True, timeout=900)

    @requires_shell
    def test_a_uniform_tree_passes_for_every_platform(self) -> None:
        for platform in ("linux-x64", "windows-x64", "macos-arm64"):
            with self.subTest(platform=platform):
                result = self.run_check(platform)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["effectiveCompileOption"], "-O2 --fno-chir-function-inlining")

    @requires_shell
    def test_the_observed_option_is_taken_from_the_manifest(self) -> None:
        """Not from the wrapper's text, which mentions the option in a comment."""
        self.edit(MODULE,
                  "        return contents.replace(needle, f'override-compile-option = \"{option}\"', 1)",
                  "        return contents")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("override-compile-option=''", result.stderr)

    @requires_shell
    def test_a_changed_shared_option_is_refused(self) -> None:
        self.edit(MODULE, 'OPTION = "-O2 --fno-chir-function-inlining"', 'OPTION = "-O1"')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O1", result.stderr)

    @requires_shell
    def test_plain_o2_is_refused_when_the_required_extra_flag_is_missing(self) -> None:
        self.edit(MODULE, 'OPTION = "-O2 --fno-chir-function-inlining"', 'OPTION = "-O2"')
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--fno-chir-function-inlining", result.stderr)

    @requires_shell
    def test_a_wrapper_that_stops_patching_is_refused(self) -> None:
        self.edit(WRAPPER,
                  '"${CJDOC_PYTHON:-python}" "${CJDOC_STS_OVERRIDE_MODULE}/apply_sts_override.py" "${arguments[@]}"',
                  ": # patcher call removed")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("override-compile-option=''", result.stderr)

    @requires_shell
    def test_the_checked_tree_is_left_untouched(self) -> None:
        before = (self.repo / "cjpm.toml").read_bytes()
        self.assertEqual(self.run_check().returncode, 0)
        self.assertEqual((self.repo / "cjpm.toml").read_bytes(), before)

    @requires_shell
    def test_failed_o2_build_restores_manifest_without_retry(self) -> None:
        import os
        import shlex

        probe = self.repo / "probe-bin"
        probe.mkdir()
        observed = self.repo / "observed-builds.jsonl"
        log = self.repo / "invocations.jsonl"
        (probe / "cjc").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (probe / "cjpm").write_text(
            "#!/usr/bin/env bash\n"
            'if [[ "${1:-}" == "-v" ]]; then exit 0; fi\n'
            + shlex.quote(sys.executable) + ' - "$@" <<\'PY\'\n'
            "import json, os, pathlib, sys, tomllib\n"
            "package = tomllib.loads(pathlib.Path('cjpm.toml').read_text())['package']\n"
            "assert package['override-compile-option'] == '-O2 --fno-chir-function-inlining'\n"
            "with open(os.environ['CJDOC_PROBE_OBSERVED'], 'a') as output:\n"
            "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "raise SystemExit(37)\nPY\n", encoding="utf-8")
        for path in probe.iterdir():
            path.chmod(0o755)
        before = (self.repo / "cjpm.toml").read_bytes()
        environment = dict(os.environ, GITHUB_WORKSPACE=str(self.repo),
                           RUNNER_TEMP=self.temporary.name, CJDOC_PYTHON=sys.executable,
                           CJDOC_PROBE_OBSERVED=str(observed), CJDOC_STS_INVOCATION_LOG=str(log))
        environment['PATH'] = str(probe) + os.pathsep + environment.get('PATH', '')
        command = ". " + shlex.quote(str(self.repo / WRAPPER)) + "; cjpm build --jobs 1"
        result = subprocess.run([params.usable_shell(), '-c', command], cwd=self.repo,
                                env=environment, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual((self.repo / "cjpm.toml").read_bytes(), before)
        self.assertEqual(len(observed.read_text().splitlines()), 1)
        self.assertEqual(json.loads(log.read_text().strip())['option'], '-O2 --fno-chir-function-inlining')

    def test_a_missing_wrapper_is_refused(self) -> None:
        (self.repo / WRAPPER).unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing", result.stderr)

    def test_an_unknown_platform_is_refused(self) -> None:
        result = self.run_check("solaris-sparc")
        self.assertNotEqual(result.returncode, 0)

    def test_the_check_does_not_parse_workflow_text(self) -> None:
        """Command spelling is answered by the invocation record, not by patterns."""
        # The script may build its own probe command; what it must not do is read the
        # workflow and reason about the text in it.
        source = SCRIPT.read_text(encoding="utf-8").split('"""', 2)[2]
        for pattern in ("release-candidate:", "publish:", "SHELL_CONTROL", "read_text(encoding=\"utf-8\").split"):
            self.assertNotIn(pattern, source,
                             f"{pattern} suggests the workflow text is being parsed again")
        self.assertNotIn("WORKFLOW", source, "the workflow is no longer this check's input")

    def test_the_release_workflow_calls_the_check_before_building(self) -> None:
        workflow = (self.repo / ".github/workflows/release.yml").read_text(encoding="utf-8")
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        check_at = candidate.index("release_build_parameters.py")
        build_at = candidate.index("\n          cjpm build --jobs 1")
        self.assertLess(check_at, build_at,
                        "the override must be confirmed before anything is built")

    @requires_shell
    def test_the_workflows_exact_invocation_actually_runs(self) -> None:
        """The workflow line must be executable, not merely present."""
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
        import shlex
        result = subprocess.run([sys.executable, *shlex.split(invocation.removeprefix("python "))],
                                cwd=self.repo, capture_output=True, text=True, timeout=900)
        self.assertEqual(result.returncode, 0,
                         f"the workflow invocation failed: {result.stderr.strip()}")


if __name__ == "__main__":
    unittest.main()
