"""Fixed host-build command, failure preservation, and archive immutability."""
from pathlib import Path
import subprocess
import re
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import highlight_host_diagnostic as diagnostic
from native_capture_support import inventory


class HostDiagnosticTests(unittest.TestCase):
    def attempt(self, directory, code=0, mutate=False, attempt_type=diagnostic.HostBuildAttempt):
        root = Path(directory)
        source = root / "product"
        source.mkdir()
        (source / "tracked.cj").write_text("package example\n")
        output = root / "output"
        output.mkdir()
        attempt = attempt_type(source, output, "windows-x64" if attempt_type is diagnostic.ProviderBuildAttempt else "macos-arm64")
        attempt.environment["PATH"] = str(Path(subprocess.__file__).parent)
        attempt.evidence["sourceBefore"] = {"files": inventory(source, ["tracked.cj"])}
        calls = []
        def call(phase, argv, cwd=None, checked=True):
            calls.append((phase, argv, cwd))
            if phase == "tracked-source":
                with tarfile.open(attempt.private / "source.tar", "w") as bundle:
                    bundle.add(source / "tracked.cj", arcname="tracked.cj")
            if phase == "prerequisite-root":
                binary = cwd / "target/release/bin/main"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"fixture CLI executable")
            if phase == "target" and mutate:
                (cwd / "tracked.cj").write_text("changed")
            return subprocess.CompletedProcess(argv, code if phase == "target" else 0,
                                               "public output", "public error")
        attempt.call = call
        attempt.host_command = lambda shell: [shell, "--noprofile", "--norc", "-c", "original host build"]
        return attempt, calls

    def test_target_is_single_original_bounded_build_and_retains_nonzero_exit(self):
        for code in (0, 1, 124):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                attempt, calls = self.attempt(directory, code)
                with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"):
                    attempt.target()
                self.assertEqual([p[0] for p in calls], ["tracked-source", "target"])
                argv = calls[-1][1]
                self.assertEqual(argv[2:4], ["1200", "--"])
                self.assertEqual(attempt.exit_code, code)
                self.assertEqual(attempt.evidence["processExitCode"], code)
                self.assertEqual(attempt.evidence["targetInvocations"], 1)
                self.assertTrue(attempt.evidence["archiveTrackedSourcesUnchanged"])
                self.assertEqual(attempt.evidence["backendTrace"]["backendInvocations"], 0)
                self.assertEqual(attempt.build_log, "public outputpublic error")

    def test_execute_reaches_one_host_target_without_inherited_ir_preflight(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt, calls = self.attempt(directory, code=1)
            snapshot = attempt.evidence["sourceBefore"]
            attempt.git.snapshot = lambda *args: snapshot
            attempt.identity = lambda: {"controller": "fixed"}
            attempt.authenticate = lambda: None
            attempt.lock_pins = lambda: None
            attempt.dependencies = lambda **kwargs: {"yjson": {"commit": "fixed"}}
            attempt.resolve_sources = lambda: None
            with patch.object(diagnostic.capture.Attempt, "preflight", side_effect=AssertionError("IR preflight")), \
                    patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"), \
                    patch("native_codegen_capture.publish", return_value={}):
                self.assertEqual(attempt.execute(), 1)
            self.assertEqual([row[0] for row in calls], ["tracked-source", "target"])
            self.assertEqual(attempt.evidence["capturePreflight"]["status"], "NOT_APPLICABLE")
            self.assertEqual(attempt.evidence["targetInvocations"], 1)
            self.assertEqual(attempt.evidence["processExitCode"], 1)

    def test_windows_provider_reuses_original_command_and_frozen_product(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt, calls = self.attempt(directory, attempt_type=diagnostic.ProviderBuildAttempt)
            command = diagnostic.ProviderBuildAttempt.host_command(attempt, "bash")
            self.assertEqual(command, ["bash", "--noprofile", "--norc", "-c",
                '. scripts/with_sts_cjpm.sh; cd tests/fixtures/projects/provider_plugin; '
                'cjpm run --build-args "--jobs 1"'])
            self.assertEqual(attempt.source_commit, diagnostic.HostBuildAttempt.source_commit)
            self.assertEqual(attempt.source_tree, diagnostic.HostBuildAttempt.source_tree)
            with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"):
                attempt.target()
            self.assertEqual([row[0] for row in calls], ["tracked-source", "prerequisite-root", "target"])
            self.assertEqual(attempt.evidence["prerequisiteInvocations"], 1)
            self.assertEqual(attempt.evidence["targetInvocations"], 1)
            self.assertEqual(attempt.evidence["prerequisiteBinary"]["bytes"], len(b"fixture CLI executable"))
            self.assertEqual(attempt.evidence["status"], "PROVIDER_RUN_SUCCEEDED")
            self.assertIn("no backend observation", attempt.evidence["diagnosticScope"])

    def test_provider_prerequisite_failure_preserves_exit_and_does_not_start_target(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt, calls = self.attempt(directory, attempt_type=diagnostic.ProviderBuildAttempt)
            real_call = attempt.call
            def fail_prerequisite(phase, argv, **kwargs):
                result = real_call(phase, argv, **kwargs)
                return subprocess.CompletedProcess(argv, 7, result.stdout, result.stderr) if phase == "prerequisite-root" else result
            attempt.call = fail_prerequisite
            with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"):
                with self.assertRaises(diagnostic.capture.ChildFailed):
                    attempt.target()
            self.assertEqual([row[0] for row in calls], ["tracked-source", "prerequisite-root"])
            self.assertEqual(attempt.evidence["targetInvocations"], 0)
            self.assertEqual(attempt.evidence["prerequisiteInvocations"], 1)
            self.assertEqual(attempt.exit_code, 7)

    def test_failed_prerequisite_keeps_first_exit_when_postcheck_cannot_read_input(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt, calls = self.attempt(directory, attempt_type=diagnostic.ProviderBuildAttempt)
            snapshot = attempt.evidence["sourceBefore"]
            attempt.git.snapshot = lambda *args: snapshot
            attempt.git.read = lambda *args, **kwargs: subprocess.CompletedProcess([], 0, "", "")
            attempt.identity = lambda: {"controller": "fixed"}
            attempt.authenticate = lambda: None
            attempt.lock_pins = lambda: None
            attempt.dependencies = lambda **kwargs: {"yjson": {"commit": "fixed"}}
            attempt.resolve_sources = lambda: None
            real_call = attempt.call
            def fail_and_remove(phase, argv, **kwargs):
                result = real_call(phase, argv, **kwargs)
                if phase == "prerequisite-root":
                    (kwargs["cwd"] / "tracked.cj").unlink()
                    return subprocess.CompletedProcess(argv, 7, result.stdout, result.stderr)
                return result
            attempt.call = fail_and_remove
            with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"), \
                    patch("native_codegen_capture.publish", return_value={}):
                self.assertEqual(attempt.execute(), 7)
            self.assertEqual([row[0] for row in calls], ["tracked-source", "prerequisite-root"])
            self.assertEqual(attempt.evidence["firstChildFailureExitCode"], 7)
            self.assertEqual(attempt.evidence["targetInvocations"], 0)

    def test_main_root_runs_one_original_command_without_prerequisite(self):
        for code in (0, 7, 124):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                attempt, calls = self.attempt(directory, code=code,
                                             attempt_type=diagnostic.RootBuildAttempt)
                self.assertEqual(diagnostic.RootBuildAttempt.host_command(attempt, "bash"),
                    ["bash", "--noprofile", "--norc", "-c",
                     '. scripts/with_sts_cjpm.sh; cjpm build --jobs 1'])
                with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"):
                    attempt.target()
                self.assertEqual([row[0] for row in calls], ["tracked-source", "target"])
                self.assertEqual(attempt.evidence["targetInvocations"], 1)
                self.assertEqual(attempt.exit_code, code)
                self.assertEqual(attempt.evidence["backendTrace"]["backendInvocations"], 0)

    def test_main_profiles_bind_the_merged_source_and_native_target(self):
        self.assertEqual(diagnostic.PROFILES["windows-root-main"],
                         (diagnostic.RootBuildAttempt, "windows-x64"))
        self.assertEqual(diagnostic.PROFILES["macos-provider-main"],
                         (diagnostic.ProviderBuildAttempt, "macos-arm64"))
        self.assertEqual(diagnostic.HostBuildAttempt.source_commit,
                         "8cc8f71a296b1c6321e575b56fadbd0c379e242a")
        self.assertEqual(diagnostic.HostBuildAttempt.source_tree,
                         "8bc115f09ed8823cdbe8dd66fdd940bf29b35af8")
        caller = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()
        self.assertIn("if: ${{ inputs.target == 'windows-root-main' }}", caller)
        self.assertIn("if: ${{ inputs.target == 'macos-provider-main' }}", caller)

    def test_tracked_archive_mutation_stops_the_diagnostic(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt, _ = self.attempt(directory, mutate=True)
            with patch("highlight_host_diagnostic.shutil.which", return_value="/bin/bash"):
                with self.assertRaisesRegex(ValueError, "changed a tracked archive input"):
                    attempt.target()

    def test_workflow_freezes_source_and_allows_only_reviewed_files(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/highlight-host-diagnostic.yml").read_text()
        self.assertIn("ref: " + diagnostic.HostBuildAttempt.source_commit, workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("workflow_call:", workflow)
        timeout = re.search(r"timeout-minutes:.*&& (\d+) \|\| (\d+)", workflow)
        self.assertIsNotNone(timeout)
        self.assertGreater(int(timeout[1]) * 60, 2 * 1200)
        self.assertGreater(int(timeout[2]) * 60, 1200)
        job_environment = workflow.split("jobs:",1)[1].split("steps:",1)[0]
        self.assertIn('GIT_CONFIG_KEY_0: core.autocrlf', job_environment)
        self.assertIn('GIT_CONFIG_VALUE_0: "false"', job_environment)
        caller = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()
        self.assertIn("uses: ./.github/workflows/highlight-host-diagnostic.yml", caller)
        self.assertIn("if: ${{ inputs.target == 'macos-host' }}", caller)
        self.assertIn("if: ${{ inputs.target == 'windows-root' }}", caller)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertIn("retention-days: 3", workflow)
        self.assertNotIn("public/*", workflow)
        self.assertNotIn("private/", workflow)


if __name__ == "__main__":
    unittest.main()
