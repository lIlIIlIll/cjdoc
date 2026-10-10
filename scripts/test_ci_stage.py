#!/usr/bin/env python3
"""Stage accounting and identity-gate tests for scripts/ci_stage.py."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ci_stage


def write_binary(path: Path, body: str = "#!/bin/sh\necho 'cjdoc 0.7.2'\n") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


class StageRecordTest(unittest.TestCase):
    def test_records_are_timed_appended_and_never_lose_history(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = Path(temporary)
            records: list[dict] = []
            with ci_stage.stage("alpha", ["true"], kind="build", records=records) as handle:
                handle.record({"goldens": 9})
            with self.assertRaises(RuntimeError):
                with ci_stage.stage("beta", ["false"], kind="cli", records=records):
                    raise RuntimeError("boom")
            self.assertEqual([item["stageId"] for item in records], ["alpha", "beta"])
            self.assertEqual([item["status"] for item in records], ["passed", "failed"])
            self.assertEqual(records[0]["goldens"], 9)
            self.assertTrue(all(item["timingSource"] == "monotonic" for item in records))
            self.assertTrue(all(item["wallMs"] >= 0 for item in records))

            path = evidence / ci_stage.STAGES_FILE
            ci_stage.write_stage_evidence(path, records[:1])
            ci_stage.write_stage_evidence(path, records[1:])
            merged = ci_stage.load_records(evidence)
            self.assertEqual([item["stageId"] for item in merged], ["alpha", "beta"])
            # Re-writing the same record must not duplicate it.
            ci_stage.write_stage_evidence(path, records)
            self.assertEqual(len(ci_stage.load_records(evidence)), 2)

    def test_unknown_kind_and_field_overwrite_are_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            with ci_stage.stage("x", ["true"], kind="not-a-kind"):
                pass
        with self.assertRaises(SystemExit):
            with ci_stage.stage("x", ["true"], kind="build") as handle:
                handle.record({"wallMs": 1})

    def test_summarize_reports_stage_state(self) -> None:
        records = [{"stageId": "cli", "kind": "cli", "wallMs": 12.5, "exitCode": 0,
                    "status": "passed", "environment": {"platform": "linux-x64",
                                                        "checkoutCommit": "a" * 40,
                                                        "cache": {"cjv": "hit"}}}]
        summary = ci_stage.summarize(records)
        self.assertIn("| cli | cli | 12.5 | 0 | passed | cjv=hit |", summary)

    def test_invalid_cache_state_is_rejected(self) -> None:
        with self.assertRaises(SystemExit):
            ci_stage.parse_cache("cjv=maybe")


class IdentityGateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = write_binary(self.root / "main")

    def manifest(self, *, version: str = "cjdoc 0.7.2") -> Path:
        document = {
            "schemaVersion": ci_stage.BUILD_MANIFEST_SCHEMA,
            "mainBinary": {"path": "main", "sha256": ci_stage.sha256_file(self.binary),
                           "size": self.binary.stat().st_size, "versionOutput": version},
        }
        path = self.root / "build-manifest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def run_gate(self, manifest: Path, *extra: str) -> int:
        return ci_stage.verify_identity(manifest, self.binary, None, None,
                                        require_runnable="--skip-version-check" not in extra)

    def test_matching_identity_passes(self) -> None:
        self.assertEqual(self.run_gate(self.manifest()), 0)

    def test_digest_and_size_mismatches_fail(self) -> None:
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"]["sha256"] = "0" * 64
        path = self.root / "bad-digest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

        document["mainBinary"]["sha256"] = ci_stage.sha256_file(self.binary)
        document["mainBinary"]["size"] = 1
        path = self.root / "bad-size.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

    def test_wrong_version_fails_and_a_missing_record_fails(self) -> None:
        self.assertEqual(self.run_gate(self.manifest(version="cjdoc 9.9.9")), 1)
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"].pop("versionOutput")
        path = self.root / "no-version.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(self.run_gate(path), 1)

    def test_unrunnable_binary_fails_by_default_but_is_allowed_explicitly(self) -> None:
        """A digest-only check must be an explicit, recorded choice."""
        document = json.loads(self.manifest().read_text(encoding="utf-8"))
        document["mainBinary"]["versionOutput"] = "cjdoc 0.7.2"
        path = self.root / "unrunnable.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        broken = write_binary(self.root / "broken", "")  # empty file: cannot exec
        self.assertEqual(
            ci_stage.verify_identity(path, broken, None, None, require_runnable=True), 1)
        # With the digest corrected for the actual file, skipping the run check passes.
        document["mainBinary"].update({
            "sha256": ci_stage.sha256_file(broken), "size": broken.stat().st_size,
            "versionOutput": "cjdoc 0.7.2"})
        path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(
            ci_stage.verify_identity(path, broken, None, None, require_runnable=True), 1)
        self.assertEqual(
            ci_stage.verify_identity(path, broken, None, None, require_runnable=False), 0)

    def test_wrong_manifest_schema_is_rejected(self) -> None:
        path = self.root / "wrong.json"
        path.write_text(json.dumps({"schemaVersion": "other/1"}), encoding="utf-8")
        with self.assertRaises(SystemExit):
            ci_stage.verify_identity(path, self.binary, None, None)

    def test_run_subcommand_returns_the_child_exit_code_and_logs(self) -> None:
        evidence = self.root / "evidence"
        code = ci_stage.run_stage(
            "probe", "cli",
            [sys.executable, "-c", "import sys; print('out'); sys.stderr.write('err'); sys.exit(7)"],
            evidence)
        self.assertEqual(code, 7)
        record = ci_stage.load_records(evidence)[0]
        self.assertEqual((record["status"], record["exitCode"]), ("failed", 7))
        log = (evidence / "probe.log").read_text(encoding="utf-8")
        self.assertIn("out", log)
        self.assertIn("err", log)


if __name__ == "__main__":
    unittest.main()
