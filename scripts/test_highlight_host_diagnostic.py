"""Fixed host-build command, failure preservation, and archive immutability."""
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import highlight_host_diagnostic as diagnostic
from native_capture_support import inventory


class HostDiagnosticTests(unittest.TestCase):
    def attempt(self, directory, code=0, mutate=False):
        root = Path(directory)
        source = root / "product"
        source.mkdir()
        (source / "tracked.cj").write_text("package example\n")
        output = root / "output"
        output.mkdir()
        attempt = diagnostic.HostBuildAttempt(source, output, "macos-arm64")
        attempt.environment["PATH"] = str(Path(subprocess.__file__).parent)
        attempt.evidence["sourceBefore"] = {"files": inventory(source, ["tracked.cj"])}
        calls = []
        def call(phase, argv, cwd=None, checked=True):
            calls.append((phase, argv, cwd))
            if phase == "tracked-source":
                with tarfile.open(attempt.private / "source.tar", "w") as bundle:
                    bundle.add(source / "tracked.cj", arcname="tracked.cj")
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
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("  push:", workflow)
        self.assertIn("retention-days: 3", workflow)
        self.assertNotIn("public/*", workflow)
        self.assertNotIn("private/", workflow)


if __name__ == "__main__":
    unittest.main()
