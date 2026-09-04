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
from scripts.verify_repository_inputs import GOLDEN_NAMES, SCHEMA_NAMES

class ReleaseMetadataTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_release_metadata_binds_tag_commit_tree_and_clean_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_release_repo(Path(temporary))
            evidence = verify_release.verify_repository(repo, "v0.7.0", commit)
            self.assertEqual(evidence["version"], "0.7.0")
            self.assertEqual(evidence["commit"], commit)
            self.assertEqual(evidence["tagCommit"], commit)
            self.assertFalse(evidence["dirty"])
            self.assertEqual(evidence["docIrSchemaVersion"], "cjdoc.doc-ir/8")
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
        for version in (6, 7, 8):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                repo, _ = self.make_release_repo(Path(temporary))
                missing = f"tests/fixtures/golden-v{version}/basic.docs.json"
                self.git(repo, "rm", "-q", "--cached", "--", missing)
                with self.assertRaisesRegex(ValueError, "not tracked"):
                    verify_repository_inputs.verify_repository_inputs(
                        repo, require_tracked=True
                    )

    def test_repository_inputs_reject_missing_extra_and_modified_vendor_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            missing = repo / "tests/fixtures/golden-v8/basic.docs.json"
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "missing"):
                verify_repository_inputs.verify_repository_inputs(repo)
            missing.write_text('{"schemaVersion":"cjdoc.doc-ir/8"}\n', encoding="utf-8")

            extra = repo / "tests/fixtures/golden-v7/not-a-fixture.docs.json"
            extra.write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unexpected"):
                verify_repository_inputs.verify_repository_inputs(repo)
            extra.unlink()

            vendor = repo / "vendor/yjson_algorithms/src/work_limits.cj"
            vendor.write_text(vendor.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                verify_repository_inputs.verify_repository_inputs(repo)

    def test_repository_inputs_reject_legacy_schema_drift_and_vendor_extras(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            schema = repo / "docs/schema/doc-ir-v7.schema.json"
            schema.write_bytes(schema.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "byte-frozen"):
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
            schema_path = repo / "docs/schema/doc-ir-v8.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$defs"] = {}
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "critical definitions"):
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

    def test_repository_inputs_freeze_legacy_sources_and_receipt_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            legacy = repo / "tests/fixtures/golden-v6/basic.docs.json"
            legacy.write_bytes(legacy.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "legacy input is not byte-frozen"):
                verify_repository_inputs.verify_repository_inputs(repo)

        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary))
            receipt = repo / "tests/fixtures/legacy-migration-v8.json"
            receipt.write_bytes(receipt.read_bytes() + b"\n")
            with self.assertRaisesRegex(ValueError, "receipt manifest is not byte-frozen"):
                verify_repository_inputs.verify_repository_inputs(repo)

    @unittest.skipIf(os.name == "nt", "fixture executable uses a POSIX shebang")
    def test_same_output_for_every_legacy_golden_does_not_satisfy_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, _ = self.make_release_repo(root / "repo")
            binary = root / "fake-cjdoc"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "p=sys.argv[sys.argv.index('--input')+1]\n"
                "v=json.load(open(p,encoding='utf-8'))\n"
                "if v.get('corrupt'): raise SystemExit(2)\n"
                "print(json.dumps({'schemaVersion':'cjdoc.doc-ir/8'}))\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "semantic receipt"):
                verify_repository_inputs.verify_legacy_migrations(repo, binary)


