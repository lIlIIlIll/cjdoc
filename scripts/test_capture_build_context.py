"""Behavioral boundaries for the explicit build-input receipt observer."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

try:
    from . import capture_build_context as capture
except ImportError:
    import capture_build_context as capture


class BuildContextObservationTests(unittest.TestCase):
    def test_artifact_larger_than_source_limit_is_streamed_without_relaxing_source_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / 'component.bin'
            size = capture.MAX_FILE + 17
            with artifact.open('wb') as stream:
                stream.truncate(size)
                stream.seek(size - 1)
                stream.write(b'\x7f')
            expected = hashlib.sha256()
            remaining = size - 1
            zeros = bytes(64 * 1024)
            while remaining:
                count = min(remaining, len(zeros))
                expected.update(zeros[:count])
                remaining -= count
            expected.update(b'\x7f')
            self.assertEqual(capture.identity(artifact, False), 'sha256:' + expected.hexdigest())
            artifact.rename(root / 'oversized.cj')
            with self.assertRaisesRegex(ValueError, 'source inventory per-file'):
                capture.identity(root)

    def test_distinct_artifacts_share_the_same_accumulating_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / 'first.bin'
            second = Path(directory) / 'second.bin'
            first.write_bytes(b'ab')
            second.write_bytes(b'cd')
            budget = capture.ObservationBudget()
            budget.remaining = 3
            self.assertEqual(capture.identity(first, False, budget), 'sha256:' + hashlib.sha256(b'ab').hexdigest())
            with self.assertRaisesRegex(ValueError, 'aggregate observation'):
                capture.identity(second, False, budget)
            self.assertEqual(budget.remaining, 1)

    def test_a_changed_expected_file_is_rejected_before_hashing(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / 'component.bin'
            artifact.write_bytes(b'old')
            expected_size = artifact.stat().st_size
            artifact.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError, 'changed before hashing'):
                capture.artifact_digest(artifact, expected_size)


class BuildContextManifestPathTests(unittest.TestCase):
    @staticmethod
    def project(root, name):
        root.mkdir(parents=True, exist_ok=True)
        (root / "src").mkdir()
        (root / "cjpm.toml").write_text(
            f'[package]\nname = "{name}"\nversion = "1.0.0"\n', encoding="utf-8")
        (root / "src/api.cj").write_text(f"package {name}\npublic class Widget {{}}\n", encoding="utf-8")

    def record(self, root, destination, *extra, selection="ignored-environment-value"):
        environment = os.environ.copy()
        environment["SELECTED_LIBRARY"] = selection
        result = subprocess.run([sys.executable, str(Path(capture.__file__).resolve()),
            "--project", str(root), "--output", str(destination), "--target", "example-target", *extra],
            env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(destination.read_text(encoding="utf-8")), result.stderr

    def test_environment_tokens_do_not_select_literal_or_ambient_source_directories(self):
        for token in ("$SELECTED_LIBRARY", "${SELECTED_LIBRARY}"):
            with self.subTest(token=token), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "app"
                self.project(root, "app")
                self.project(root / token, "library")
                actual = Path(directory) / "actual"
                self.project(actual, "library")
                with (root / "cjpm.toml").open("a", encoding="utf-8") as manifest:
                    manifest.write(f'\n[dependencies]\nlibrary = {{ path = "{token}" }}\n')
                first, warning = self.record(root, Path(directory) / "first.json", selection=str(actual))
                second, _ = self.record(root, Path(directory) / "second.json", selection="different-value")
                self.assertEqual(first, second, "observer environment changed the selection record")
                self.assertEqual([module["name"] for module in first["modules"]], ["app"])
                self.assertEqual(first["modules"][0]["dependencies"], [])
                self.assertIn("not automatically selected", warning)

    def test_explicit_resolved_source_and_artifact_inputs_remain_observable(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, actual = base / "app", base / "actual"
            self.project(root, "app")
            self.project(actual, "library")
            with (root / "cjpm.toml").open("a", encoding="utf-8") as manifest:
                manifest.write('\n[dependencies]\nlibrary = { path = "${SELECTED_LIBRARY}" }\n')
            artifact = base / "native.a"
            artifact.write_bytes(b"actual-artifact-input")
            record, _ = self.record(root, base / "context.json",
                "--source-dependency", f"app:source:library={actual}",
                "--dependency", f"app:binary:native={artifact}")
            owner = next(module for module in record["modules"] if module["name"] == "app")
            dependencies = {item["name"]: item for item in owner["dependencies"]}
            self.assertEqual(dependencies["library"]["identity"], capture.identity(actual))
            self.assertEqual(dependencies["native"]["identity"], capture.identity(artifact, False))
            self.assertEqual(dependencies["library"]["content"], "source")
            self.assertEqual(dependencies["native"]["content"], "artifact")
            self.assertEqual({module["name"] for module in record["modules"]}, {"app", "library"})

    def test_plain_manifest_path_still_records_actual_source_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, actual = base / "app", base / "actual"
            self.project(root, "app")
            self.project(actual, "library")
            with (root / "cjpm.toml").open("a", encoding="utf-8") as manifest:
                manifest.write('\n[dependencies]\nlibrary = { path = "../actual" }\n')
            record, warning = self.record(root, base / "context.json")
            owner = next(module for module in record["modules"] if module["name"] == "app")
            self.assertEqual(owner["dependencies"][0]["identity"], capture.identity(actual))
            self.assertEqual(warning, "")


if __name__ == "__main__":
    unittest.main()
