"""Negative evidence gates; fixtures are not native execution evidence."""
from __future__ import annotations

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pocketkit_reproduce", ROOT / "examples/pocketkit/reproduce.py")
REPRODUCE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPRODUCE)


class NegativeExampleGateTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "doctest").mkdir()
        self.report = {
            "schemaVersion": "cjdoc.doctest/1", "mode": "warn",
            "summary": {"passed": 0, "failed": 1, "timedOut": 0, "skipped": 1},
            "results": [
                {"qualifiedName": "pocket_diagnostics.deliberateFailure", "status": "failed",
                 "exitCode": 1, "message": "compile failed", "stderr": "error: mismatched types"},
                {"qualifiedName": "pocket_diagnostics.explanatoryExample", "status": "skipped",
                 "exitCode": None, "message": "no executable Cangjie fence", "stderr": ""},
            ],
        }

    def validate(self, report: dict) -> None:
        (self.root / "doctest/results.json").write_text(json.dumps(report), encoding="utf-8")
        REPRODUCE.validate_diagnostic_examples(self.root)

    def test_only_the_declared_negative_outcomes_are_allowed(self) -> None:
        self.validate(self.report)
        for field, value in (("qualifiedName", "pocket_diagnostics.unexpectedFailure"),
                             ("status", "timeout"), ("status", "passed"),
                             ("exitCode", 0), ("exitCode", None), ("exitCode", True),
                             ("message", "compiler unavailable"), ("message", "runtime failed"),
                             ("stderr", "linker unavailable")):
            with self.subTest(field=field, value=value):
                changed = deepcopy(self.report)
                changed["results"][0][field] = value
                with self.assertRaises(ValueError):
                    self.validate(changed)

    def test_extra_missing_duplicate_or_miscounted_results_fail(self) -> None:
        variants = []
        for results in (self.report["results"][:1], self.report["results"] * 2,
                        [self.report["results"][0]] * 2):
            changed = deepcopy(self.report)
            changed["results"] = results
            variants.append(changed)
        changed = deepcopy(self.report)
        changed["summary"]["passed"] = 1
        variants.append(changed)
        for report in variants:
            with self.subTest(report=report), self.assertRaises(ValueError):
                self.validate(report)


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
