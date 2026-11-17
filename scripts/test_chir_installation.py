"""Exercise installed CHIR discovery through the real public CLI."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts import publication_ir


REPO = Path(__file__).resolve().parent.parent
SUFFIX = ".exe" if os.name == "nt" else ""


class InstalledChirWorkerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Path(os.environ.get(
            "CJDOC_BINARY", REPO / ("target/release/bin/main" + SUFFIX))).resolve()
        cls.worker = Path(os.environ.get(
            "CJDOC_CHIR_WORKER", cls.binary.parent / ("chir-worker-main" + SUFFIX))).resolve()
        if not cls.binary.is_file() or not cls.worker.is_file():
            raise AssertionError("installed CHIR contracts require built cjdoc and companion binaries")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cjdoc-installed-chir-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.bin = self.root / "installation" / "bin"
        self.bin.mkdir(parents=True)
        self.installed = self.bin / ("cjdoc" + SUFFIX)
        self.companion = self.bin / ("chir-worker-main" + SUFFIX)
        shutil.copy2(self.binary, self.installed)
        self.project = self.root / "project"
        (self.project / "src").mkdir(parents=True)
        (self.project / "cjpm.toml").write_text(
            '[package]\nname = "installed_chir"\nversion = "0.1.0"\n'
            'cjc-version = "1.2.0"\noutput-type = "static"\n', encoding="utf-8")
        (self.project / "src" / "api.cj").write_text(
            "package installed_chir\n"
            "public func identity(value: Int64): Int64 { value }\n", encoding="utf-8")
        self.cwd = self.root / "unrelated-working-directory"
        self.cwd.mkdir()

    def generate(self, *, executable=None, prefix=(), options=(), environment=None):
        result = subprocess.run([
            *prefix, str(executable or self.installed), "generate", "--project", str(self.project),
            "--format", "json", "--stdout", "--no-cache", "--lint-profile", "off", *options,
        ], cwd=self.cwd, env=environment, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        document = json.loads(result.stdout)
        declaration = next(item for item in document["declarations"] if item["name"] == "identity")
        return result, document, declaration

    def assert_chir_resolved(self, result, document, declaration):
        self.assertNotIn("CJDOC21", result.stderr)
        self.assertTrue(any(item["name"] == "chir" for item in document["providers"]))
        self.assertEqual(declaration["returnType"]["semanticState"], "resolved")
        self.assertEqual(declaration["returnType"]["semanticProvider"], "chir")

    def test_default_chir_uses_relocated_adjacent_worker(self):
        shutil.copy2(self.worker, self.companion)
        self.assert_chir_resolved(*self.generate())

    def test_default_and_unavailable_chir_preserve_public_extension_navigation(self):
        fixture = REPO / "tests/fixtures/projects/extend_visibility"
        shutil.copy2(fixture / "cjpm.toml", self.project / "cjpm.toml")
        (self.project / "src/api.cj").write_text(
            (fixture / "src/fixture.cj").read_text(encoding="utf-8") +
            "\npublic func identity(value: Int64): Int64 { value }\n", encoding="utf-8")
        shutil.copy2(self.worker, self.companion)
        for options in ((), ("--chir-worker", str(self.root / ("missing-worker" + SUFFIX)))):
            with self.subTest(options=options):
                result, document, identity = self.generate(options=options)
                published = publication_ir.project(document)
                names = {item["name"] for item in published["declarations"]}
                self.assertTrue({"length", "pretty", "identity"} <= names)
                self.assertTrue({"hiddenMember", "hiddenExtensionMember", "packageOnly", "fileOnly"}.isdisjoint(names))
                box = next(item for item in published["declarations"] if item["name"] == "Box")
                extensions = [item for item in published["declarations"] if item["kind"] == "extend"]
                self.assertEqual(len(extensions), 2)
                for extension in extensions:
                    self.assertTrue(any(
                        relation["kind"] == "extensionTarget" and relation["state"] == "resolved" and
                        relation.get("targetSymbolId") == box["id"]
                        for relation in extension["symbolRelationships"]))
                if options:
                    self.assertIn("CJDOC2101", result.stderr)
                else:
                    self.assertEqual(identity["returnType"]["semanticState"], "resolved")
                    self.assertEqual(identity["returnType"]["semanticProvider"], "chir")

    def test_missing_worker_preserves_source_with_diagnostic(self):
        result, _, declaration = self.generate()
        self.assertIn("CJDOC2101", result.stderr)
        self.assertEqual(declaration["returnType"]["spelling"], "Int64")
        self.assertEqual(declaration["semantic"]["state"], "unavailable")

    def test_wrong_product_is_rejected_and_explicit_worker_overrides_it(self):
        shutil.copy2(self.binary, self.companion)
        result, _, declaration = self.generate()
        self.assertIn("CJDOC2104", result.stderr)
        self.assertEqual(declaration["returnType"]["spelling"], "Int64")
        self.assertEqual(declaration["semantic"]["state"], "unavailable")
        self.assert_chir_resolved(*self.generate(options=("--chir-worker", str(self.worker))))

    def test_source_mode_needs_no_companion(self):
        result, document, declaration = self.generate(options=("--semantic", "source"))
        self.assertNotIn("CJDOC21", result.stderr)
        self.assertFalse(any(item["name"] == "chir" for item in document["providers"]))
        self.assertEqual(declaration["returnType"]["spelling"], "Int64")

    def test_compiler_failure_keeps_source_and_deterministic_doc_ir(self):
        shutil.copy2(self.worker, self.companion)
        (self.project / "src" / "api.cj").write_text(
            "package installed_chir\n"
            "public func identity(value: Int64): Int64 { missingOperation(value) }\n", encoding="utf-8")
        first, first_document, declaration = self.generate()
        second, second_document, _ = self.generate()
        self.assertIn("CJDOC2103", first.stderr)
        self.assertIn("CJDOC2103", second.stderr)
        self.assertEqual(declaration["returnType"]["spelling"], "Int64")
        self.assertEqual(declaration["semantic"]["state"], "unavailable")
        self.assertEqual(first_document, second_document)

    @unittest.skipIf(os.name == "nt", "symlink creation requires Windows privileges")
    def test_path_and_symlink_invocations_ignore_other_worker_locations(self):
        shutil.copy2(self.worker, self.companion)
        # A different product in cwd/PATH must never replace the installed companion.
        shutil.copy2(self.binary, self.cwd / "chir-worker-main")
        environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.assert_chir_resolved(*self.generate(executable="cjdoc", environment=environment))
        alias = self.cwd / "cjdoc-alias"
        alias.symlink_to(self.installed)
        self.assert_chir_resolved(*self.generate(executable=alias))

    @unittest.skipIf(os.name == "nt", "argv0 replacement uses a POSIX shell")
    def test_replaced_argv0_cannot_redirect_companion_or_source_parser(self):
        shutil.copy2(self.worker, self.companion)
        self.assert_chir_resolved(*self.generate(prefix=(
            "bash", "--noprofile", "--norc", "-c",
            'executable=$1; shift; exec -a not-a-real-cjdoc "$executable" "$@"', "cjdoc-argv-probe")))


if __name__ == "__main__":
    unittest.main()
