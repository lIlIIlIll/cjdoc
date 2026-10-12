#!/usr/bin/env python3
"""Tests for the CI-08.3 invocation verification.

The point of these is the difference from a text check: the evidence is the record
the wrapper wrote while running, so a build that never went through the wrapper, or
went through it with a different option, is visible.
"""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = PROJECT_ROOT / "scripts/verify_build_invocations.py"
LOGGER = PROJECT_ROOT / "scripts/log_invocation.py"


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, *args], capture_output=True, text=True, timeout=300)


def record(option: str = "-O1", argv: list[str] | None = None) -> str:
    return json.dumps({
        "schemaVersion": "cjdoc.sts-invocation/1",
        "package": "cjdoc",
        "option": option,
        "argv": argv or ["build", "--jobs", "1"],
        "platform": "Linux",
        "workspace": "/w",
    }, sort_keys=True)


class InvocationVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.log = Path(self.temporary.name) / "invocations.jsonl"

    def write(self, *lines: str) -> None:
        self.log.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")

    def check(self, since: int = 0, expect: str = "-O1") -> subprocess.CompletedProcess[str]:
        return run([str(SCRIPT), "--log", str(self.log), "--since", str(since),
                    f"--expect-compile-option={expect}"])

    def test_a_single_build_with_the_required_option_passes(self) -> None:
        self.write(record())
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["builds"], 1)
        self.assertEqual(payload["option"], "-O1")

    def test_invocations_before_the_offset_are_ignored(self) -> None:
        self.write(record(argv=["test"]), record(argv=["build", "--jobs", "1"]))
        offset = len((record(argv=["test"]) + "\n").encode("utf-8"))
        result = self.check(since=offset)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["builds"], 1)

    def test_a_build_with_a_different_option_is_refused(self) -> None:
        self.write(record(option="-O2"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    def test_a_second_build_under_another_option_is_refused(self) -> None:
        """The acceptance gates rebuild; a differently optioned build invalidates it."""
        self.write(record(), record(option="-O2"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    def test_several_builds_under_the_required_option_pass(self) -> None:
        self.write(record(), record(), record())
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["builds"], 3)

    def test_no_build_at_all_is_refused(self) -> None:
        """A build that bypassed the wrapper leaves no record, which must not pass."""
        self.write(record(argv=["test"]))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no `cjpm build`", result.stderr)

    def test_an_empty_log_is_refused(self) -> None:
        self.write()
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("performed no", result.stderr)

    def test_a_missing_log_is_refused(self) -> None:
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no invocation log", result.stderr)

    def test_an_offset_beyond_the_log_is_refused(self) -> None:
        self.write(record())
        result = self.check(since=10_000)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shrank", result.stderr)

    def test_the_logger_appends_a_parseable_record(self) -> None:
        result = run([str(LOGGER), "--log", str(self.log), "--package", "cjdoc",
                      "--option=-O1", "--", "build", "--jobs", "1"])
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(entry["schemaVersion"], "cjdoc.sts-invocation/1")
        self.assertEqual(entry["package"], "cjdoc")
        self.assertEqual(entry["option"], "-O1")
        self.assertEqual(entry["argv"], ["build", "--jobs", "1"])
        # No --binary was given, so no digest is claimed.
        self.assertIsNone(entry["binary"])

    def test_a_binary_that_the_recorded_build_did_not_produce_is_refused(self) -> None:
        binary = Path(self.temporary.name) / "main"
        binary.write_bytes(b"replaced")
        import hashlib
        self.write(json.dumps({
            "schemaVersion": "cjdoc.sts-invocation/1", "package": "cjdoc", "option": "-O1",
            "argv": ["build", "--jobs", "1"], "platform": "Linux", "workspace": "/w",
            "binary": {"sha256": hashlib.sha256(b"original").hexdigest(), "size": 8},
        }, sort_keys=True))
        result = run([str(SCRIPT), "--log", str(self.log), "--since", "0",
                      "--binary", str(binary)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not the one the last recorded build produced", result.stderr)

    def test_a_binary_matching_the_recorded_build_passes(self) -> None:
        binary = Path(self.temporary.name) / "main"
        binary.write_bytes(b"built")
        import hashlib
        line = json.dumps({
            "schemaVersion": "cjdoc.sts-invocation/1", "package": "cjdoc", "option": "-O1",
            "argv": ["build", "--jobs", "1"], "platform": "Linux", "workspace": "/w",
            "binary": {"sha256": hashlib.sha256(b"built").hexdigest(), "size": 5},
        }, sort_keys=True)
        self.write(line)
        result = run([str(SCRIPT), "--log", str(self.log), "--since", "0",
                      "--binary", str(binary)])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_build_that_recorded_no_binary_is_refused_when_one_is_expected(self) -> None:
        binary = Path(self.temporary.name) / "main"
        binary.write_bytes(b"built")
        self.write(record())
        result = run([str(SCRIPT), "--log", str(self.log), "--since", "0",
                      "--binary", str(binary)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recorded no produced binary", result.stderr)

    def test_a_second_build_disguised_in_the_text_is_still_recorded(self) -> None:
        """The record comes from what ran, so disguising the spelling changes nothing."""
        self.write(record(), record(option="-O2"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("-O2", result.stderr)

    def test_the_wrapper_resolves_the_windows_executable_suffix(self) -> None:
        """Windows produces `main.exe`; the digest must be of the built file."""
        wrapper = (PROJECT_ROOT / "scripts" / "with_sts_o1_cjpm.sh").read_text(encoding="utf-8")
        self.assertIn("main.exe", wrapper)
        # The suffix is resolved after the build, not before it exists.
        run_at = wrapper.index('"${CJDOC_REAL_CJPM}" "$@"')
        self.assertLess(run_at, wrapper.index("cjdoc_binary="))

    def test_the_workflow_verifies_the_invocations_after_the_build(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        candidate = workflow.split("\n  release-candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertIn("verify_build_invocations.py", candidate)
        build_at = candidate.index("cjpm build --jobs 1")
        verify_at = candidate.index("verify_build_invocations.py")
        self.assertLess(build_at, verify_at,
                        "the invocations must be checked after the build runs")
        # The acceptance gates rebuild, so the binding must happen at packaging time.
        package_at = candidate.index("name: Build the deterministic package")
        self.assertLess(package_at, verify_at,
                        "the final binary must be bound to its build when packaged")


if __name__ == "__main__":
    unittest.main()
