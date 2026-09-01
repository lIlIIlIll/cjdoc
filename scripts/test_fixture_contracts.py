from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tomllib
import unittest


REPO = Path(__file__).resolve().parent.parent
GOLDEN_OR_CHECK_FIXTURES = {
    "basic", "conditional", "extend_visibility", "functions", "html_security",
    "path_dependencies", "provider_plugin", "source_edges", "types", "unsupported",
    "workspace",
}
CANGJIE_CONTRACT_FIXTURES = {
    "binary_punctuation", "cfg_owner", "frontend_gaps", "frontend_regressions", "lint",
    "local_assets", "manifest_headers", "markdown_limits", "private_file_scope", "recovery",
    "reexports",
}
CLI_CONTRACT_FIXTURES = {
    "cached_dependencies", "conditional_complex", "deep_binary", "duplicate",
    "lint_quality", "override", "path_dependencies_invalid", "workspace_invalid",
}


class FixtureContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        candidate = REPO / "target/release/bin/main"
        if not candidate.is_file():
            candidate = Path(f"{candidate}.exe")
        if not candidate.is_file():
            raise AssertionError("fixture contracts require the built cjdoc binary")
        cls.binary = candidate
        manifest = tomllib.loads((REPO / "cjpm.toml").read_text(encoding="utf-8"))
        cls.package_version = manifest["package"]["version"]

    def generate(self, fixture: str, *options: str,
                 expected_exit: int) -> tuple[dict[str, object], str]:
        result = subprocess.run([
            str(self.binary), "generate",
            "--project", str(REPO / "tests/fixtures/projects" / fixture),
            "--format", "json", "--stdout", "--no-cache", *options,
        ], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, expected_exit, msg=result.stderr)
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            self.fail(f"{fixture} did not emit one valid JSON document: {error}; stderr={result.stderr}")
        self.assertEqual(document.get("schemaVersion"), "cjdoc.doc-ir/8")
        self.assertEqual(document.get("generator"), {
            "name": "cjdoc", "version": self.package_version,
        })
        declarations = document.get("declarations")
        diagnostics = document.get("diagnostics")
        self.assertIsInstance(declarations, list)
        self.assertIsInstance(diagnostics, list)
        ids = [item.get("id") for item in declarations]
        self.assertEqual(len(ids), len(set(ids)), msg=f"{fixture} emitted duplicate SymbolIds")
        known_ids = set(ids)
        self.assertNotIn(str(REPO), json.dumps(document, ensure_ascii=False))
        for diagnostic in diagnostics:
            symbol_id = diagnostic.get("symbolId")
            self.assertTrue(
                symbol_id is None or symbol_id in known_ids,
                msg=f"{fixture} emitted a dangling diagnostic SymbolId: {symbol_id}",
            )
        for declaration in declarations:
            for field in ("typeRelationships", "symbolRelationships"):
                for relationship in declaration.get(field, []):
                    target = relationship.get("targetSymbolId")
                    self.assertTrue(
                        target is None or target in known_ids,
                        msg=f"{fixture} emitted a dangling {field} target: {target}",
                    )
        return document, result.stderr

    @staticmethod
    def codes(document: dict[str, object]) -> set[str]:
        return {item["code"] for item in document["diagnostics"]}

    @staticmethod
    def names(document: dict[str, object]) -> set[str]:
        return {item["name"] for item in document["declarations"]}

    def test_every_project_fixture_has_an_explicit_gate_owner(self) -> None:
        actual = {
            path.name for path in (REPO / "tests/fixtures/projects").iterdir()
            if path.is_dir()
        }
        expected = GOLDEN_OR_CHECK_FIXTURES | CANGJIE_CONTRACT_FIXTURES | \
            CLI_CONTRACT_FIXTURES
        self.assertEqual(actual, expected)

    def test_binary_version_matches_package_manifest(self) -> None:
        result = subprocess.run(
            [str(self.binary), "--version"], text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertEqual(result.stdout, f"cjdoc {self.package_version}\n")

    def test_public_imports_emit_canonical_reexport_bindings(self) -> None:
        document, _ = self.generate(
            "reexports", "--include-path-dependencies", expected_exit=0,
        )
        packages = {item["name"]: item for item in document["packages"]}
        reexports = packages["reexport_root"]["reExports"]
        ordinary = [
            item for item in reexports
            if item["targetPackageName"] not in {
                "reexport_dep.conflict", "reexport_dep.alias_target",
            }
        ]
        self.assertEqual({item["state"] for item in ordinary}, {"resolved"})
        empty_wildcards = [
            item for item in reexports
            if item["kind"] == "all" and item["targetPackageName"] == "reexport_dep.empty"
        ]
        self.assertEqual(len(empty_wildcards), 1)
        self.assertEqual(empty_wildcards[0]["bindings"], [])
        package_aliases = [
            item for item in reexports
            if item["kind"] == "packageAlias" and item["alias"] == "emptyPackage"
        ]
        self.assertEqual(len(package_aliases), 1)
        self.assertEqual(package_aliases[0]["state"], "resolved")
        self.assertEqual(package_aliases[0]["bindings"], [])
        alias_collisions = [
            item for item in reexports
            if item["alias"] == "ambiguousTarget"
        ]
        self.assertEqual(len(alias_collisions), 1)
        self.assertEqual(alias_collisions[0]["state"], "ambiguous")
        self.assertEqual(alias_collisions[0]["bindings"], [])
        conflicts = [
            item for item in reexports
            if item["targetPackageName"] == "reexport_dep.conflict"
        ]
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0]["state"], "ambiguous")
        self.assertEqual(conflicts[0]["bindings"], [])
        relay = packages["reexport_root.relay"]["reExports"]
        self.assertEqual(len(relay), 1)
        self.assertEqual(relay[0]["state"], "unavailable")
        self.assertEqual(relay[0]["bindings"], [])
        exposed = {
            (binding["exposedName"], target)
            for item in reexports
            for binding in item["bindings"]
            for target in binding["targetSymbolIds"]
        }
        self.assertTrue(any(name == "create" for name, _ in exposed))
        self.assertTrue(any(name == "aliasName" for name, _ in exposed))
        self.assertTrue(any(name == "overload" for name, _ in exposed))
        self.assertTrue(any(name == "orgCreate" for name, _ in exposed))
        self.assertTrue(any(item["organization"] == "acme" for item in reexports))
        declaration_ids = {item["id"] for item in document["declarations"]}
        self.assertTrue(all(target in declaration_ids for _, target in exposed))
        hidden_ids = {
            item["id"] for item in document["declarations"] if item["name"] == "hidden"
        }
        self.assertTrue(hidden_ids)
        self.assertTrue(all(target not in hidden_ids for _, target in exposed))

    def test_cached_dependencies_use_only_the_selected_fixture_cache(self) -> None:
        document, _ = self.generate(
            "cached_dependencies",
            "--include-cached-dependencies",
            "--cjpm-cache", str(REPO / "tests/fixtures/cjpm_cache"),
            expected_exit=0,
        )
        self.assertEqual(document["status"], "partial")
        self.assertEqual(len(document["modules"]), 3)
        self.assertEqual(self.names(document), {"rootApi", "cachedApi", "transitiveApi"})
        self.assertIn("CJDOC1021", self.codes(document))

    def test_deep_binary_failure_remains_machine_readable(self) -> None:
        document, _ = self.generate("deep_binary", expected_exit=1)
        self.assertEqual(document["status"], "partial")
        self.assertIn("CJDOC1012", self.codes(document))

    def test_lint_quality_keeps_declarations_and_stable_diagnostics(self) -> None:
        document, _ = self.generate(
            "lint_quality", "--lint-profile", "standard", expected_exit=0
        )
        self.assertEqual(self.names(document), {"noValue", "undocumented"})
        self.assertTrue({"CJDOC3022", "CJDOC3023"}.issubset(self.codes(document)))

    def test_override_relationship_is_explicitly_unavailable_in_ast_fallback(self) -> None:
        document, _ = self.generate("override", expected_exit=0)
        derived = [
            declaration for declaration in document["declarations"]
            if declaration["name"] == "read" and "DerivedReader" in (declaration.get("ownerId") or "")
        ]
        self.assertEqual(len(derived), 1)
        self.assertEqual(derived[0]["symbolRelationships"], [{
            "kind": "override",
            "targetDisplay": "read",
            "state": "unavailable",
            "targetSymbolId": None,
        }])

    def test_invalid_path_dependencies_do_not_drop_the_root_api(self) -> None:
        document, _ = self.generate(
            "path_dependencies_invalid", "--include-path-dependencies", expected_exit=0
        )
        self.assertEqual(self.names(document), {"available"})
        self.assertTrue({"CJDOC1015", "CJDOC1016"}.issubset(self.codes(document)))

    def test_missing_cfg_omits_simple_and_complex_conditional_declarations(self) -> None:
        simple, _ = self.generate("conditional", expected_exit=0)
        self.assertEqual(simple["status"], "partial")
        self.assertEqual(simple["declarations"], [])
        self.assertEqual(len(simple["unsupportedDeclarations"]), 2)
        self.assertIn("CJDOC1019", self.codes(simple))

        complex_document, _ = self.generate("conditional_complex", expected_exit=0)
        self.assertEqual(complex_document["status"], "partial")
        self.assertEqual(complex_document["declarations"], [])
        self.assertEqual(len(complex_document["unsupportedDeclarations"]), 4)
        self.assertIn("CJDOC1019", self.codes(complex_document))

    def test_duplicate_symbols_fail_with_valid_partial_doc_ir(self) -> None:
        document, _ = self.generate("duplicate", expected_exit=1)
        self.assertEqual(document["status"], "partial")
        self.assertIn("CJDOC2006", self.codes(document))

    def test_invalid_workspace_failure_remains_machine_readable(self) -> None:
        document, _ = self.generate("workspace_invalid", expected_exit=1)
        self.assertEqual(document["status"], "partial")
        self.assertIn("CJDOC1010", self.codes(document))


if __name__ == "__main__":
    unittest.main()
