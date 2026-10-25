from __future__ import annotations

import json
import os
from pathlib import Path
import py_compile
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

from scripts import package_release
from scripts import perf_gate
from scripts import repository_input_codec
from scripts import real_repository_smoke
from scripts import safe_output_root
from scripts import source_identity
from scripts import strict_json
from scripts import verify_release
from scripts import verify_release_package
from scripts import verify_remote_tag
from scripts import verify_repository_inputs
from scripts import worktree_identity
from scripts.release_tools_test_support import (
    MARKDOWN_COMMIT,
    PROJECT_ROOT,
    ReleaseToolsTestSupport,
    SDK_SHA256,
    YJSON_COMMIT,
)
from scripts.verify_repository_inputs import (
    CURRENT_GOLDEN_VERSION,
    GOLDEN_NAMES,
    SCHEMA_CONTRACTS,
    SCHEMA_NAMES,
)

class ReleaseMetadataTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_release_metadata_binds_tag_commit_tree_and_clean_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_release_repo(Path(temporary))
            evidence = verify_release.verify_repository(repo, "v0.7.0", commit)
            self.assertEqual(evidence["version"], "0.7.0")
            self.assertEqual(evidence["commit"], commit)
            self.assertEqual(evidence["tagCommit"], commit)
            self.assertFalse(evidence["dirty"])
            self.assertEqual(evidence["docIrSchemaVersion"], f"cjdoc.doc-ir/{CURRENT_GOLDEN_VERSION}")
            self.assertEqual(evidence["performanceGateKind"], "hard-ceiling")
            self.assertIn(
                "vendor/yjson_algorithms/src/work_limits.cj", evidence["inputSha256"]
            )

            (repo / "README.md").write_text("dirty\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                verify_release.verify_repository(repo, "v0.7.0", commit)

    def test_release_metadata_rejects_wrong_tag_and_gitless_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_release_repo(Path(temporary) / "tagged")
            with self.assertRaisesRegex(ValueError, "does not match"):
                verify_release.verify_repository(repo, "v0.7.1", commit)
            self.git(repo, "tag", "-d", "v0.7.0")
            with self.assertRaisesRegex(ValueError, "rev-parse"):
                verify_release.verify_repository(repo, "v0.7.0", commit)

            gitless, _ = self.make_release_repo(Path(temporary) / "gitless", initialize_git=False)
            with self.assertRaisesRegex(ValueError, "Git top-level"):
                verify_release.verify_repository(gitless, "v0.7.0")

    def test_repository_inputs_require_every_generated_file_to_be_tracked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            missing = f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/basic.docs.json"
            self.git(repo, "rm", "-q", "--cached", "--", missing)
            with self.assertRaisesRegex(ValueError, "not tracked"):
                verify_repository_inputs.verify_repository_inputs(
                    repo, require_tracked=True
                )

    def test_repository_inputs_reject_missing_extra_and_modified_vendor_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            missing = repo / f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/basic.docs.json"
            original = missing.read_bytes()
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                verify_repository_inputs.verify_repository_inputs(repo)
            missing.write_bytes(original)

            extra = repo / f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/not-a-fixture.docs.json"
            extra.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected"):
                verify_repository_inputs.verify_repository_inputs(repo)
            extra.unlink()

            vendor = repo / "vendor/yjson_algorithms/src/work_limits.cj"
            vendor.write_text(vendor.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_showcase_inputs_cannot_be_omitted_from_tracked_release_source(self) -> None:
        for relative in ("site/showcase-catalog.json", "site/showcase-baseline.json",
                         "examples/pocketkit/demo-v2/src/catalog.cj",
                         "examples/pocketkit/check-modes/src/api.cj"):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as temporary:
                repo, _ = self.make_release_repo(Path(temporary))
                self.git(repo, "rm", "-q", "--cached", "--", relative)
                with self.assertRaisesRegex(ValueError, "not tracked"):
                    verify_repository_inputs.verify_repository_inputs(repo, require_tracked=True)

    def test_repository_inputs_reject_historical_schema_outputs_and_vendor_extras(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema = repo / "docs/schema/doc-ir-v15.schema.json"
            schema.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected=doc-ir-v15"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            (repo / "vendor/yjson_algorithms/native.o").write_bytes(b"native")
            with self.assertRaisesRegex(ValueError, "inventory mismatch"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            manifest = repo / "vendor/yjson_algorithms/cjpm.toml"
            manifest.write_text(
                manifest.read_text(encoding="utf-8") + "\n[script-dependencies]\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "audited manifest"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_inputs_validate_every_schema_identity_and_root_shape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / "docs/schema/search-index.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$id"] = "https://example.invalid/forged.schema.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "draft/id contract"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / "docs/schema/diagnostics.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["required"] = ["schemaVersion"]
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "required/property contract"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema_path = repo / f"docs/schema/doc-ir-v{CURRENT_GOLDEN_VERSION}.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$defs"] = {}
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "graph binding field|critical definitions"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_schema_gate_rejects_duplicate_and_non_finite_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            path = repo / "docs/schema/search-index.schema.json"
            text = path.read_text(encoding="utf-8")
            path.write_text(
                text.replace("{", '{"$schema":"duplicate",', 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            path = repo / "docs/schema/search-index.schema.json"
            text = path.read_text(encoding="utf-8")
            path.write_text(text.replace('"minLength": 1', '"minLength": NaN', 1),
                            encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_schema_inventory_is_complete_and_current(self) -> None:
        # The inventory is checked as a whole instead of pinning a total count:
        # every declared name must have exactly one contract, one published file
        # with the declared version, and no published file may be undeclared.
        self.assertEqual(
            list(SCHEMA_NAMES),
            list(dict.fromkeys(SCHEMA_NAMES)),
            "schema inventory contains a duplicate name",
        )
        self.assertEqual(set(SCHEMA_NAMES), set(SCHEMA_CONTRACTS))
        published = {
            path.name.removesuffix(".schema.json")
            for path in (PROJECT_ROOT / "docs/schema").glob("*.schema.json")
        }
        self.assertEqual(published, set(SCHEMA_NAMES))
        for name in SCHEMA_NAMES:
            schema_id, version, required = SCHEMA_CONTRACTS[name]
            value = json.loads((PROJECT_ROOT / f"docs/schema/{name}.schema.json").read_text())
            self.assertEqual(value["$id"], schema_id, name)
            self.assertEqual(value["properties"]["schemaVersion"]["const"], version, name)
            self.assertEqual(tuple(value["required"]), required, name)
        self.assertEqual(
            {name for name in SCHEMA_NAMES if name.startswith("doc-ir")},
            {"doc-ir", "doc-ir-v16"},
        )
        self.assertFalse(any("doctest" in name for name in SCHEMA_NAMES))
        # The frozen navigation v1 contract keeps its published identity; the
        # v2 file is a separate immutable artifact, not a silent v1 replacement.
        self.assertEqual(
            SCHEMA_CONTRACTS["navigation-index"][1], "cjdoc.navigation-index/1")
        self.assertEqual(
            SCHEMA_CONTRACTS["navigation-index-v2"][1], "cjdoc.navigation-index/2")
        # Every release artifact contract that carries its own model must be
        # declared in the inventory, alongside the frozen v1 navigation file.
        for name in ("navigation-index-v2", "agent-full-index", "declaration", "page",
                     "machine-manifest", "query-request", "query-result"):
            self.assertIn(name, SCHEMA_NAMES)
        self.assertIn("navigation-index", SCHEMA_NAMES)
        for name in ("doc-ir", "doc-ir-v16"):
            value = json.loads((PROJECT_ROOT / f"docs/schema/{name}.schema.json").read_text())
            self.assertNotIn("evidenceKey", value["$defs"]["tag"]["properties"])
            self.assertIn("navigation", value["$defs"]["tag"]["properties"])

    def test_current_golden_validation_rejects_changed_roundtrip_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            binary = repo / "fake-cjdoc"
            binary.write_bytes(b"binary")
            with mock.patch.object(repository_input_codec, "run_doc_ir_render", return_value=b"{}"):
                with self.assertRaisesRegex(ValueError, "exact strict round-trip"):
                    repository_input_codec.verify_current_goldens(repo, binary)

    def test_current_golden_validation_requires_corrupt_input_rejection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            binary = repo / "fake-cjdoc"
            binary.write_bytes(b"binary")
            with mock.patch.object(
                repository_input_codec, "run_doc_ir_render",
                side_effect=lambda _binary, source: source.read_bytes(),
            ), mock.patch.object(
                repository_input_codec.subprocess, "run",
                return_value=subprocess.CompletedProcess([], 0),
            ):
                with self.assertRaisesRegex(ValueError, "accepted a missing required field"):
                    repository_input_codec.verify_current_goldens(repo, binary)

