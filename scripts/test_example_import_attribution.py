#!/usr/bin/env python3
"""Prove the #207/#209 fixes against compiler-accepted import spellings.

Each fixture is first built by the real `cjpm`, so a case only proves something
when the language itself accepts the spelling. The same fixture then runs through
`cjdoc generate` twice: once for CHIR dependency selection and once for example
dependency selection.

Issue #209: a legal Tab, `private`, `internal`, alias or `{...}` import must not
lose its dependency. Issue #207: a `must-fail` example may only be satisfied by a
diagnostic inside the body; header, import and option failures stay context
errors, and `failureContains` only matches body diagnostics.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
PACKAGE = "import_probe"
HELPER = f"{PACKAGE}.helper"


def installed_executable(path: Path) -> Path:
    windows = path.with_suffix(".exe")
    executable = windows if os.name == "nt" and windows.is_file() else path
    if not executable.is_file():
        raise AssertionError(f"missing required executable: {path.name}")
    return executable.resolve()

MANIFEST = f'''[package]
cjc-version = "1.2.0"
name = "{PACKAGE}"
version = "1.0.0"
output-type = "static"
'''

DOC_COMMENT = '''/**
 * Answer.
 * @return Value.
 * @example Sample {__PIN____ERROR__}
 * ```cangjie
 * __BODY__
 * ```
 */
'''


def import_variants():
    """Compiler-accepted spellings that all name the same dependency."""
    return {
        "space": f"import {HELPER}.value",
        "tab": f"import\t{HELPER}.value",
        "private": f"private import {HELPER}.value",
        "internal": f"internal import {HELPER}.value",
        "protected": f"protected import {HELPER}.value",
        "comment": f"import /* keep */ {HELPER}.value",
        "alias": f"import {HELPER}.value as value",
        "selection": f"import {HELPER}.{{value}}",
        "wildcard": f"import {HELPER}.*",
        "mixed": f"import std.collection.ArrayList\nimport\t{HELPER}.value",
    }


def run(args, *, cwd=None, expected=None, timeout=300):
    result = subprocess.run(args, cwd=cwd, capture_output=True, encoding="utf-8",
                            timeout=timeout)
    if expected is not None and result.returncode != expected:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result


class ImportVariants:
    """One fixture project per legal import spelling."""

    def __init__(self, root: Path):
        self.root = root

    def project(self, label: str, import_line: str, *, pin: str = "must-pass",
                error: str | None = None, body: str = "let result = answer()",
                example_import: str | None = None) -> Path:
        project = self.root / label
        (project / "src" / "helper").mkdir(parents=True)
        (project / "cjpm.toml").write_text(MANIFEST, encoding="utf-8")
        directive = pin + (f' error="{error}"' if error else "")
        header = import_line
        if example_import is not None:
            header = example_import + "\n" + import_line
        (project / "src" / "api.cj").write_text(
            f"package {PACKAGE}\n{header}\n"
            + DOC_COMMENT.replace("__PIN__", directive).replace("__ERROR__", "")
            .replace("__BODY__", body)
            + "public func answer(): Int64 { value() }\n", encoding="utf-8")
        (project / "src" / "helper" / "api.cj").write_text(
            f"package {HELPER}\npublic func value(): Int64 {{ 42 }}\n", encoding="utf-8")
        return project


class ImportDependencyVariantsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = installed_executable(Path(os.environ.get("CJDOC_BINARY", REPO / "target/release/bin/main")))
        cls.worker = installed_executable(Path(os.environ.get("CJDOC_CHIR_WORKER", cls.binary.with_name("chir-worker-main"))))
        if shutil.which("cjc") is None or shutil.which("cjpm") is None:
            raise AssertionError("the native fixture requires cjc and cjpm")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-import-variants-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.variants = ImportVariants(self.root)

    def generate(self, project: Path, semantic: str, *extra: str):
        args = [str(self.binary), "generate", "--project", str(project),
                "--semantic", semantic, "--format", "json", "--stdout", "--no-cache",
                "--lint-profile", "off", *extra]
        if semantic == "chir":
            args += ["--chir-worker", str(self.worker), "--cjc", shutil.which("cjc")]
        return run(args, timeout=600)

    def native_build(self, project: Path) -> None:
        result = run(["cjpm", "build", "--jobs", "1"], cwd=project)
        self.assertEqual(result.returncode, 0,
                         (project.name, result.stdout, result.stderr))

    def diagnostics(self, payload):
        return [(entry["severity"], entry["code"], entry["message"])
                for entry in payload.get("diagnostics", [])]

    def test_every_accepted_import_spelling_keeps_its_chir_dependency(self):
        for label, import_line in import_variants().items():
            with self.subTest(spelling=label):
                project = self.variants.project(f"chir-{label}", import_line)
                self.native_build(project)
                result = self.generate(project, "chir")
                self.assertEqual(result.returncode, 0, result.stderr)
                document = json.loads(result.stdout)
                codes = [code for _, code, _ in self.diagnostics(document)]
                self.assertNotIn("CJDOC2103", codes,
                                 (label, self.diagnostics(document)))
                self.assertNotIn("CJDOC2104", codes, (label, self.diagnostics(document)))
                self.assertEqual(document["providers"][0]["name"], "chir")
                self.assertNotEqual(document["providers"][0]["state"], "unavailable",
                                    (label, document["providers"][0]))
                capabilities = document["providers"][0]["capabilities"]
                for capability in ("sourceBinding", "ownership", "visibility",
                                   "canonicalTypes"):
                    self.assertTrue(capabilities[capability], (label, capability))

    def test_every_accepted_import_spelling_keeps_its_example_dependency(self):
        for label, import_line in import_variants().items():
            with self.subTest(spelling=label):
                project = self.variants.project(f"example-{label}", import_line,
                                                example_import="import std.collection.ArrayList")
                self.native_build(project)
                result = self.generate(project, "source", "--check-examples")
                self.assertEqual(result.returncode, 0,
                                 (label, result.stdout, result.stderr))
                codes = [code for _, code, _ in self.diagnostics(json.loads(result.stdout))]
                self.assertNotIn("CJDOC3030", codes, label)
                self.assertNotIn("CJDOC3031", codes, label)
                self.assertNotIn("CJDOC3070", codes, label)

    def test_mixed_spellings_keep_every_real_dependency(self):
        extra = f"{PACKAGE}.second"
        project = self.variants.project(
            "example-mixed-spellings",
            f"import\t{HELPER}.value",
            example_import=f"import std.collection.ArrayList\nprivate import {extra}.secondValue")
        extra_file = project / "src/second/api.cj"
        extra_file.parent.mkdir()
        extra_file.write_text(f"package {extra}\npublic func secondValue(): Int64 {{ 2 }}\n", encoding="utf-8")
        api = project / "src/api.cj"
        api.write_text(api.read_text(encoding="utf-8").replace("{ value() }", "{ value() + secondValue() }"),
                       encoding="utf-8")
        self.native_build(project)
        for semantic, flags in (("source", ("--check-examples",)), ("chir", ())):
            result = self.generate(project, semantic, *flags)
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(result.stdout)
            codes = [code for _, code, _ in self.diagnostics(document)]
            self.assertFalse({"CJDOC2103", "CJDOC2104", "CJDOC3030", "CJDOC3031", "CJDOC3070"} & set(codes))
            self.assertTrue({(HELPER, "value"), (extra, "secondValue")} <=
                            {(item["packageName"], item["name"]) for item in document["declarations"]})


class MustFailAttributionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = installed_executable(Path(os.environ.get("CJDOC_BINARY", REPO / "target/release/bin/main")))
        if shutil.which("cjc") is None or shutil.which("cjpm") is None:
            raise AssertionError("the native fixture requires cjc and cjpm")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-must-fail-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.variants = ImportVariants(self.root)

    def check(self, project: Path):
        result = run([str(self.binary), "generate", "--project", str(project),
                      "--semantic", "source", "--format", "json", "--stdout", "--no-cache",
                      "--lint-profile", "off", "--check-examples"], timeout=600)
        document = json.loads(result.stdout)
        summary = [(entry["code"], entry["message"])
                   for entry in document.get("diagnostics", [])]
        return result.returncode, summary

    def codes(self, summary):
        return [code for code, _ in summary]

    def test_private_import_context_failure_is_not_credit_for_must_fail(self):
        project = self.variants.project("private-must-fail",
                                        "private import absent_helper.value",
                                        pin="must-fail")
        code, summary = self.check(project)
        self.assertNotEqual(code, 0, summary)
        self.assertIn("CJDOC3031", self.codes(summary), summary)
        self.assertIn("CJDOC3070", self.codes(summary), summary)
        self.assertNotIn("CJDOC3030", self.codes(summary), summary)

    def test_legal_private_import_with_valid_body_fails_the_pin_as_successful_compile(self):
        project = self.variants.project("valid-private-pin", f"private import {HELPER}.value", pin="must-fail")
        code, summary = self.check(project)
        self.assertEqual(code, 1, summary)
        self.assertIn("pinned to fail but compiled successfully", " ".join(
            message for key, message in summary if key == "CJDOC3070"))
        self.assertNotIn("CJDOC3031", self.codes(summary), summary)

    def test_valid_body_with_context_failure_reports_context_only(self):
        project = self.variants.project("valid-body-context-failure",
                                        "private import absent_helper.value")
        code, summary = self.check(project)
        self.assertNotEqual(code, 0, summary)
        self.assertIn("CJDOC3031", self.codes(summary), summary)
        self.assertNotIn("CJDOC3030", self.codes(summary), summary)

    def test_must_fail_satisfied_by_a_real_body_error(self):
        project = self.variants.project("body-must-fail",
                                        f"import {HELPER}.value",
                                        pin="must-fail")
        (project / "src/api.cj").write_text(
            (project / "src/api.cj").read_text(encoding="utf-8").replace(
                "let result = answer()", "let result = missingApi(1, 2)"),
            encoding="utf-8")
        code, summary = self.check(project)
        self.assertEqual(code, 0, summary)
        self.assertEqual([item for item in self.codes(summary)
                          if item in ("CJDOC3030", "CJDOC3031", "CJDOC3070")], [], summary)

    def test_mixed_body_and_other_file_errors_still_reject_the_context(self):
        project = self.variants.project("mixed-errors", f"private import {HELPER}.value",
                                        pin="must-fail", error="Struct-String",
                                        body="let result: Int64 = false")
        (project / "src/broken.cj").write_text(
            f"package {PACKAGE}\nfunc broken(): String {{ true }}\n", encoding="utf-8")
        code, summary = self.check(project)
        self.assertEqual(code, 1, summary)
        context = " ".join(message for key, message in summary if key == "CJDOC3031")
        self.assertIn("Struct-String", context)
        self.assertNotIn("<generated-example>", context)
        pin = " ".join(message for key, message in summary if key == "CJDOC3070")
        self.assertIn("failed without the pinned message", pin)
        self.assertIn("<generated-example>", pin)

    def test_failure_contains_ignores_context_diagnostics(self):
        project = self.variants.project("context-message", "private import absent_helper.value",
                                        pin="must-fail", error="absent_helper")
        code, summary = self.check(project)
        self.assertNotEqual(code, 0, summary)
        self.assertIn("CJDOC3070", self.codes(summary), summary)
        self.assertIn("did not fail inside the example", " ".join(
            message for code, message in summary if code == "CJDOC3070"))

    def test_rejected_compiler_option_never_satisfies_a_pin(self):
        project = self.variants.project("option-must-fail", f"import {HELPER}.value",
                                        pin="must-fail")
        (project / "src/api.cj").write_text(
            (project / "src/api.cj").read_text(encoding="utf-8").replace(
                "{must-fail}", '{must-fail error="builtin condition" flags="--cfg os=Linux"}'),
            encoding="utf-8")
        code, summary = self.check(project)
        self.assertNotEqual(code, 0, summary)
        self.assertIn("CJDOC3031", self.codes(summary), summary)
        self.assertIn("CJDOC3070", self.codes(summary), summary)
        self.assertIn("builtin condition", " ".join(
            message for key, message in summary if key == "CJDOC3031"))

    def test_failure_contains_matches_body_diagnostics(self):
        project = self.variants.project("body-message", f"import {HELPER}.value",
                                        pin="must-fail", error="missingApi")
        (project / "src/api.cj").write_text(
            (project / "src/api.cj").read_text(encoding="utf-8").replace(
                "let result = answer()", "let result = missingApi(1, 2)"),
            encoding="utf-8")
        code, summary = self.check(project)
        self.assertEqual(code, 0, summary)
        self.assertEqual([item for item in self.codes(summary)
                          if item in ("CJDOC3030", "CJDOC3031", "CJDOC3070")], [], summary)


if __name__ == "__main__":
    unittest.main()
