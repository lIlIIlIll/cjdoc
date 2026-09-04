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

class ReleaseEvidenceTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_performance_limits_fail_closed(self) -> None:
        baseline = {"profiles": [{
            "name": "basic",
            "referenceDocsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]}
        result = [{
            "name": "basic",
            "docsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 11, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]
        with self.assertRaisesRegex(ValueError, "elapsed"):
            perf_gate.verify_hard_ceiling(baseline, result)

    def test_performance_limits_reject_stale_doc_ir_baseline(self) -> None:
        baseline = {"profiles": [{
            "name": "basic",
            "referenceDocsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]}
        result = [{
            "name": "basic",
            "docsSha256": "b" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
                "warm": {"maxElapsedMs": 10, "maxPeakRssKiB": 20},
            },
        }]
        with self.assertRaisesRegex(ValueError, "Doc IR checksum"):
            perf_gate.verify_hard_ceiling(baseline, result)

    def test_recorded_performance_baseline_is_explicitly_a_hard_ceiling(self) -> None:
        results = [{
            "name": "basic", "project": ".", "minDeclarations": 1,
            "docsSha256": "a" * 64,
            "variants": {
                "cold": {"maxElapsedMs": 10, "medianElapsedMs": 9,
                         "maxPeakRssKiB": 20, "medianPeakRssKiB": 19},
                "warm": {"maxElapsedMs": 8, "medianElapsedMs": 7,
                         "maxPeakRssKiB": 18, "medianPeakRssKiB": 17},
            },
        }]
        baseline = perf_gate.baseline_from_results(results, 1, 0)
        self.assertEqual(baseline["purpose"], "hard-ceiling")
        self.assertEqual(baseline["state"], "candidate")

    def test_performance_receipt_is_published_only_after_ceiling_passes(self) -> None:
        baseline = {"profiles": [{
            "name": "basic", "referenceDocsSha256": "a" * 64,
            "variants": {"cold": {"maxElapsedMs": 10, "maxPeakRssKiB": None}},
        }]}
        evidence = {"schemaVersion": "cjdoc.perf-evidence/2", "kind": "hard-ceiling"}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "performance.json"
            failing = [{
                "name": "basic", "docsSha256": "a" * 64,
                "variants": {"cold": {"maxElapsedMs": 11, "maxPeakRssKiB": None}},
            }]
            with self.assertRaisesRegex(ValueError, "hard ceiling failed"):
                perf_gate.publish_check_evidence(path, evidence, baseline, failing)
            self.assertFalse(path.exists())
            passing = [{
                "name": "basic", "docsSha256": "a" * 64,
                "variants": {"cold": {"maxElapsedMs": 10, "maxPeakRssKiB": None}},
            }]
            receipt = perf_gate.publish_check_evidence(path, evidence, baseline, passing)
            self.assertEqual(receipt["verdict"], "passed")
            self.assertEqual(json.loads(path.read_text())["verdict"], "passed")

    def test_tree_digest_detects_byte_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "docs.json"
            path.write_bytes(b"one")
            first = real_repository_smoke.tree_digests(root)
            path.write_bytes(b"two")
            second = real_repository_smoke.tree_digests(root)
            self.assertNotEqual(first, second)

    def test_real_repository_subprocesses_do_not_create_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "helper.py").write_text("VALUE = 'ok'\n", encoding="utf-8")
            probe = root / "probe.py"
            probe.write_text("import helper\nprint(helper.VALUE)\n", encoding="utf-8")

            result = real_repository_smoke.run([sys.executable, str(probe)], root)

            self.assertEqual(result.stdout.strip(), "ok")
            self.assertFalse((root / "__pycache__").exists())

    def test_evidence_sources_reject_dirty_as_trusted_or_record_untrusted_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "cjpm.toml").write_text("[package]\nname='fixture'\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", "cjpm.toml")
            self.git(repo, "commit", "-q", "-m", "fixture")
            clean = source_identity.source_identity(repo)
            self.assertTrue(clean["trustedCommit"])
            self.assertFalse(clean["dirty"])

            (repo / "cjpm.toml").write_text("[package]\nname='dirty'\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                source_identity.source_identity(repo)
            self.assertIsNone(real_repository_smoke.source_commit(repo, allow_dirty=True))
            self.assertIsNone(perf_gate.source_commit(repo, allow_dirty=True))
            dirty = source_identity.source_identity(repo, allow_dirty=True)
            self.assertFalse(dirty["trustedCommit"])
            self.assertTrue(dirty["dirty"])
            self.assertRegex(str(dirty["workingTreeSha256"]), r"^[0-9a-f]{64}$")

    def test_evidence_source_identity_rejects_ignored_uncommitted_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / ".gitignore").write_text("/ignored/\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", ".gitignore")
            self.git(repo, "commit", "-q", "-m", "fixture")
            project = repo / "ignored"
            project.mkdir()
            (project / "cjpm.toml").write_text(
                "[package]\nname='ignored'\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "not represented in HEAD"):
                source_identity.source_identity(project)
            identity = source_identity.source_identity(project, allow_dirty=True)
            self.assertFalse(identity["trustedCommit"])
            self.assertIsNone(identity["pathTree"])
            self.assertEqual(identity["pathRelative"], "ignored")

    def test_strict_json_rejects_duplicate_keys_and_non_finite_numbers(self) -> None:
        with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
            strict_json.strict_loads('{"outer":{"same":1,"same":2}}')
        for token in ("NaN", "Infinity", "-Infinity", "1e9999", "-1e9999"):
            with self.subTest(token=token), self.assertRaisesRegex(
                ValueError, "non-finite JSON number"
            ):
                strict_json.strict_loads(f'{{"value":{token}}}')
        value = strict_json.strict_loads('{"value":1.25}')
        self.assertIsInstance(value["value"], float)
        self.assertEqual(value["value"], 1.25)

    def test_exact_worktree_identity_rejects_hidden_and_untracked_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / ".gitignore").write_text("ignored.cj\n", encoding="utf-8")
            (repo / "input.cj").write_text("package fixture\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", ".gitignore", "input.cj")
            self.git(repo, "commit", "-q", "-m", "fixture")
            self.assertTrue(worktree_identity.exact_worktree_identity(repo)["trustedCommit"])

            self.git(repo, "update-index", "--assume-unchanged", "input.cj")
            with self.assertRaisesRegex(ValueError, "hidden state"):
                worktree_identity.exact_worktree_identity(repo)
            self.git(repo, "update-index", "--no-assume-unchanged", "input.cj")

            self.git(repo, "update-index", "--skip-worktree", "input.cj")
            with self.assertRaisesRegex(ValueError, "hidden state"):
                worktree_identity.exact_worktree_identity(repo)
            self.git(repo, "update-index", "--no-skip-worktree", "input.cj")

            (repo / "untracked.cj").write_text("package unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)
            (repo / "untracked.cj").unlink()
            (repo / "ignored.cj").write_text("package ignored\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "ignored/untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)
            (repo / "ignored.cj").unlink()
            (repo / "target/generated.bin").parent.mkdir()
            (repo / "target/generated.bin").write_bytes(b"generated")
            worktree_identity.exact_worktree_identity(repo)

    def test_exact_worktree_identity_uses_raw_bytes_not_eol_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            (repo / ".gitattributes").write_text("*.cj -text\n", encoding="utf-8")
            source = repo / "fixture.cj"
            source.write_bytes(b"package fixture\r\n")
            self.git(repo, "add", ".gitattributes", "fixture.cj")
            self.git(repo, "commit", "-q", "-m", "raw CRLF")
            (repo / ".gitattributes").write_text(
                "*.cj text eol=crlf\n", encoding="utf-8"
            )
            self.git(repo, "add", ".gitattributes")
            self.git(repo, "commit", "-q", "-m", "declare CRLF checkout")
            status = self.git(repo, "status", "--porcelain=v1", "--", "fixture.cj")
            # Git's EOL status classification depends on platform checkout
            # configuration and its cached stat data. The release identity must
            # accept the file in either case because its raw bytes still match
            # the committed blob exactly.
            self.assertIn(status, ("", "M fixture.cj"))
            self.assertEqual(
                subprocess.run(
                    ["git", "-C", str(repo), "show", "HEAD:fixture.cj"],
                    capture_output=True, check=True,
                ).stdout,
                source.read_bytes(),
            )
            worktree_identity.exact_worktree_identity(repo)

    def test_exact_worktree_identity_rejects_executable_unchecked_hash_pyc(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            module = repo / "release_helper.py"
            module.write_text("VALUE = 'trusted-head'\n", encoding="utf-8")
            self.git(repo, "init", "-q")
            self.git(repo, "config", "user.name", "Fixture")
            self.git(repo, "config", "user.email", "fixture@example.invalid")
            self.git(repo, "add", "release_helper.py")
            self.git(repo, "commit", "-q", "-m", "fixture")

            py_compile.compile(
                str(module), doraise=True,
                invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH,
            )
            module.write_text("VALUE = 'dirty-source'\n", encoding="utf-8")
            loaded = subprocess.run(
                [sys.executable, "-c", "import release_helper; print(release_helper.VALUE)"],
                cwd=repo, text=True, capture_output=True, check=True,
            )
            self.assertEqual(loaded.stdout.strip(), "trusted-head")
            with self.assertRaisesRegex(ValueError, "ignored/untracked worktree input"):
                worktree_identity.exact_worktree_identity(repo)

    def test_repository_verifier_direct_execution_does_not_create_bytecode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, _ = self.make_release_repo(Path(temporary) / "repo")
            scripts = repo / "scripts"
            scripts.mkdir()
            for name in (
                "safe_output_root.py",
                "strict_json.py",
                "verify_repository_inputs.py",
                "worktree_identity.py",
                "repository_input_contracts.py",
                "repository_input_files.py",
                "repository_input_migrations.py",
                "repository_input_vendor.py",
            ):
                shutil.copyfile(PROJECT_ROOT / "scripts" / name, scripts / name)
            self.git(repo, "add", "scripts")
            self.git(repo, "commit", "-q", "-m", "add verifier")

            result = subprocess.run(
                [sys.executable, "scripts/verify_repository_inputs.py", "--require-tracked"],
                cwd=repo, text=True, capture_output=True, check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
            self.assertFalse((scripts / "__pycache__").exists())

    @unittest.skipIf(os.name == "nt", "fake validator uses a POSIX shebang")
    def test_real_binary_path_round_trips_all_v8_goldens_and_rejects_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, _ = self.make_release_repo(root / "repo")
            binary = root / "fake-cjdoc"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import json,sys\n"
                "p=sys.argv[sys.argv.index('--input')+1]\n"
                "raw=open(p,'rb').read(); value=json.loads(raw)\n"
                "if 'generator' not in value: raise SystemExit(2)\n"
                "sys.stdout.buffer.write(raw)\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            verified = verify_repository_inputs.verify_current_goldens(repo, binary)
            self.assertEqual(len(verified), len(GOLDEN_NAMES))


