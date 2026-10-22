"""Negative evidence gates; fixtures are not native execution evidence."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from check_showcase_source import native_check_identity
from showcase_contract.site import ContractError
SPEC = importlib.util.spec_from_file_location("pocketkit_reproduce", ROOT / "examples/pocketkit/reproduce.py")
REPRODUCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPRODUCE)


class NativeExampleEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.binary = self.root / "cjdoc"
        self.binary.write_bytes(b"test executable")
        self.source = self.root / "source"
        for name, content in (("cjpm.toml", '[package]\nname="checks"\n'),
                              ("cjdoc.toml", "# explicit --check-examples\n"),
                              ("src/api.cj", "package checks\n")):
            path = self.source / "check-modes" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
        self.output = self.root / "output"
        self.output.mkdir()

    def capture(self, stderr: str = "warning: [CJDOC3032] no executable code", exit_code: int = 0) -> Path:
        checked = subprocess.CompletedProcess([], exit_code, "", stderr)
        compiler = subprocess.CompletedProcess([], 0, "Cangjie Compiler 1.2.0", "")
        with patch.object(REPRODUCE.subprocess, "run", side_effect=[checked, compiler]) as runner:
            destination = REPRODUCE.check_directive_examples(self.binary, self.source, self.output)
        self.assertIn("--check-examples", runner.call_args_list[0].args[0])
        return destination / "native-check.json"

    def test_successful_aggregate_evidence_retains_exact_sources_without_per_example_results(self) -> None:
        path = self.capture()
        evidence = json.loads(path.read_text())
        self.assertEqual(evidence["scope"], "aggregate command evidence; no per-example result claim")
        self.assertNotIn("results", evidence)
        self.assertEqual(evidence["executableSha256"], hashlib.sha256(self.binary.read_bytes()).hexdigest())
        self.assertEqual(len(evidence["sources"]), 3)
        self.assertEqual(native_check_identity(path)["exitCode"], 0)
        self.assertFalse((self.output / "doctest").exists())

    def test_unexpected_native_diagnostics_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "exact expected skip diagnostic"):
            self.capture("warning: [CJDOC3070] expected compile failure did not occur")

    def test_failed_command_is_not_published_as_success(self) -> None:
        with self.assertRaises(subprocess.CalledProcessError):
            self.capture("error: [CJDOC3070] unexpected compile success", 1)

    def test_reproduction_rejects_changed_inputs(self) -> None:
        path = self.capture()
        (path.parent / "src/api.cj").write_text("modified", encoding="utf-8")
        with self.assertRaisesRegex(ContractError, "source inventory or hash mismatch"):
            native_check_identity(path)

    def test_reproduction_rejects_unsupported_schema_scope_command_or_exit(self) -> None:
        path = self.capture()
        original = json.loads(path.read_text())
        for key, value in (("schemaVersion", "unsupported"), ("scope", "per-example results"),
                           ("command", ["cjdoc", "check"]), ("exitCode", 1)):
            with self.subTest(key=key):
                changed = {**original, key: value}
                path.write_text(json.dumps(changed), encoding="utf-8")
                with self.assertRaises(ContractError):
                    native_check_identity(path)


class StandaloneTimingTests(unittest.TestCase):
    """The shipped source archive has no `showcase_build`; timing must degrade."""

    def test_timing_falls_back_when_the_repository_package_is_absent(self) -> None:
        import builtins

        real_import = builtins.__import__

        def refuse_showcase_build(name, *args, **kwargs):
            if name == "showcase_build" or name.startswith("showcase_build."):
                raise ImportError("simulated standalone source archive")
            return real_import(name, *args, **kwargs)

        module = importlib.util.module_from_spec(SPEC)
        SPEC.loader.exec_module(module)

        # The block must stay in force while timing_module() resolves the helper,
        # which is the call that failed inside the shipped archive.
        builtins.__import__ = refuse_showcase_build
        try:
            timing = module.timing_module()
        finally:
            builtins.__import__ = real_import

        self.assertIs(timing, module._NullTiming)
        with timing.phase("probe") as record:
            self.assertIsInstance(record, dict)
        self.assertIsNone(timing.flush())

    def test_repository_package_still_supplies_real_timing(self) -> None:
        timing = REPRODUCE.timing_module()
        self.assertTrue(hasattr(timing, "phase"))
        self.assertTrue(hasattr(timing, "flush"))


if __name__ == "__main__":
    unittest.main()
