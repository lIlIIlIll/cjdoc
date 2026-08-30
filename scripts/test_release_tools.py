from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts import package_release
from scripts import perf_gate
from scripts import real_repository_smoke
from scripts import verify_release


class ReleaseToolsTest(unittest.TestCase):
    def make_release_repo(self, root: Path) -> Path:
        (root / "docs/schema").mkdir(parents=True)
        (root / "tests/perf").mkdir(parents=True)
        (root / "README.md").write_text("# fixture\n", encoding="utf-8")
        (root / "LICENSE").write_text("fixture\n", encoding="utf-8")
        commit = "a" * 40
        (root / "cjpm.toml").write_text(
            "[package]\nname=\"cjdoc\"\nversion=\"0.6.0\"\n"
            "[dependencies]\nlib={git=\"https://example.invalid/lib.git\","
            f"commitId=\"{commit}\"}}\n",
            encoding="utf-8",
        )
        (root / "cjpm.lock").write_text(
            "version=0\n[requires]\n"
            f"lib={{git=\"https://example.invalid/lib.git\",commitId=\"{commit}\"}}\n",
            encoding="utf-8",
        )
        schema = {"properties": {"schemaVersion": {"const": "cjdoc.doc-ir/7"}}}
        for name in ("doc-ir.schema.json", "doc-ir-v7.schema.json"):
            (root / "docs/schema" / name).write_text(json.dumps(schema), encoding="utf-8")
        (root / "tests/perf/baseline.json").write_text(json.dumps({
            "schemaVersion": "cjdoc.perf-baseline/1",
            "state": "frozen",
        }), encoding="utf-8")
        return root

    def test_release_metadata_requires_exact_tag_and_git_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = self.make_release_repo(Path(temporary))
            evidence = verify_release.verify_repository(repo, "v0.6.0")
            self.assertEqual(evidence["version"], "0.6.0")
            with self.assertRaisesRegex(ValueError, "does not match"):
                verify_release.verify_repository(repo, "v0.6.1")
            manifest = (repo / "cjpm.toml").read_text(encoding="utf-8")
            (repo / "cjpm.toml").write_text(
                manifest.replace(f'commitId="{"a" * 40}"', 'branch="main"'), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "not pinned"):
                verify_release.verify_repository(repo, "v0.6.0")

    def test_release_archive_is_reproducible_and_manifested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = self.make_release_repo(root / "repo")
            binary = repo / "main"
            binary.write_bytes(b"fixture binary\n")
            output = root / "output"
            first = package_release.build_archive(repo, binary, "linux-x64", output).read_bytes()
            second = package_release.build_archive(repo, binary, "linux-x64", output).read_bytes()
            self.assertEqual(first, second)
            self.assertTrue((output / "cjdoc-0.6.0-linux-x64.tar.gz.sha256").is_file())

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
            perf_gate.verify_limits(baseline, result)

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
            perf_gate.verify_limits(baseline, result)

    def test_tree_digest_detects_byte_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "docs.json"
            path.write_bytes(b"one")
            first = real_repository_smoke.tree_digests(root)
            path.write_bytes(b"two")
            second = real_repository_smoke.tree_digests(root)
            self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
