"""Behavioral boundaries for the explicit build-input receipt observer."""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

from unittest.mock import patch

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

    def test_same_length_source_rewrite_while_reading_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'api.cj'
            source.write_bytes(b'old')
            read_bytes = Path.read_bytes

            def read_then_rewrite(path):
                content = read_bytes(path)
                before = path.stat()
                path.write_bytes(b'new')
                os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns + 1_000_000_000))
                return content

            with patch.object(Path, 'read_bytes', read_then_rewrite):
                with self.assertRaisesRegex(ValueError, 'input changed while observing'):
                    capture.identity(Path(directory))

    def test_inventory_rejects_file_added_after_enumeration(self):
        for source in (True, False):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                selected = root / 'input.cj'
                selected.write_bytes(b'old')
                read_bytes = Path.read_bytes
                artifact_digest = capture.artifact_digest

                def read_then_add(path):
                    content = read_bytes(path)
                    (root / 'added.cj').write_bytes(b'added')
                    return content

                def hash_then_add(path, size=None):
                    digest = artifact_digest(path, size)
                    (root / 'added.cj').write_bytes(b'added')
                    return digest

                with patch.object(Path, 'read_bytes', read_then_add), \
                        patch.object(capture, 'artifact_digest', hash_then_add):
                    with self.assertRaisesRegex(ValueError, 'input changed while observing'):
                        capture.identity(root, source)

    def test_inventory_rejects_earlier_replacement_during_later_read(self):
        for source in (True, False):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                earlier, later = root / 'a.cj', root / 'z.cj'
                earlier.write_bytes(b'old')
                later.write_bytes(b'later')
                read_bytes = Path.read_bytes
                artifact_digest = capture.artifact_digest

                def replace_earlier(path):
                    if path == later:
                        # Replace an already-hashed entry with different bytes
                        # while a later entry is being read. The recorded size is
                        # part of the revalidated snapshot on every platform, so
                        # the replacement is observable without depending on
                        # filesystem timestamp granularity.
                        earlier.unlink()
                        earlier.write_bytes(b'newer')

                def read_then_replace(path):
                    content = read_bytes(path)
                    replace_earlier(path)
                    return content

                def hash_then_replace(path, size=None):
                    digest = artifact_digest(path, size)
                    replace_earlier(path)
                    return digest

                with patch.object(Path, 'read_bytes', read_then_replace), \
                        patch.object(capture, 'artifact_digest', hash_then_replace):
                    with self.assertRaisesRegex(ValueError, 'input changed while observing'):
                        capture.identity(root, source)


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

    def test_receipt_paths_bind_from_canonical_output_directory(self):
        for link_kind in ("ancestor", "file"):
            with self.subTest(link_kind=link_kind), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                root, library = base / "app", base / "library"
                self.project(root, "app")
                self.project(library, "library")
                artifact = base / "native.a"
                artifact.write_bytes(b"actual-artifact-input")
                output_directory = base / "real" / "nested"
                output_directory.mkdir(parents=True)
                if link_kind == "ancestor":
                    alias = base / "alias"
                    alias.symlink_to(output_directory, target_is_directory=True)
                    destination = alias / "context.json"
                else:
                    target = output_directory / "context.json"
                    target.touch()
                    destination = base / "linked.json"
                    destination.symlink_to(target)
                record, _ = self.record(root, destination,
                    "--source-dependency", f"app:source:library={library}",
                    "--dependency", f"app:binary:native={artifact}")
                receipt_base = destination.resolve(strict=True).parent
                self.assertEqual((receipt_base / record["project"]["path"]).resolve(), root.resolve())
                for module in record["modules"]:
                    expected = root if module["name"] == "app" else library
                    self.assertEqual((receipt_base / module["path"]).resolve(), expected.resolve())
                    for dependency in module["dependencies"]:
                        expected = library if dependency["name"] == "library" else artifact
                        self.assertEqual((receipt_base / dependency["path"]).resolve(), expected.resolve())

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

    def test_project_over_half_the_budget_keeps_valid_receipt_and_rejects_new_overflow(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / "app"
            self.project(root, "app")
            observed = root / "observed"
            observed.mkdir()
            for index in range(5):
                with (observed / f"input{index}.cj").open("wb") as stream:
                    stream.truncate(54 * 1024 * 1024)
            receipt = base / "context.json"
            record, _ = self.record(root, receipt)
            self.assertEqual(record["project"]["identity"], capture.identity(root))
            retained = receipt.read_bytes()
            artifact = base / "native.bin"
            with artifact.open("wb") as stream:
                stream.truncate(250 * 1024 * 1024)
            rejected = subprocess.run([sys.executable, str(Path(capture.__file__).resolve()),
                "--project", str(root), "--output", str(receipt), "--target", "example-target",
                "--dependency", f"app:binary:native={artifact}"], capture_output=True, text=True, timeout=30)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("aggregate observation byte/work budget exceeded", rejected.stderr)
            self.assertEqual(receipt.read_bytes(), retained)

    def test_shared_source_dependency_over_half_the_budget_is_observed_once(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root, dependency = base / "app", base / "library"
            self.project(root, "app")
            self.project(dependency, "library")
            observed = dependency / "observed"
            observed.mkdir()
            for index in range(5):
                with (observed / f"input{index}.cj").open("wb") as stream:
                    stream.truncate(54 * 1024 * 1024)
            with (root / "cjpm.toml").open("a", encoding="utf-8") as manifest:
                manifest.write('\n[dependencies]\nfirst = { path = "../library" }\n'
                               'second = { path = "../library/." }\n')
            record, _ = self.record(root, base / "context.json")
            owner = next(module for module in record["modules"] if module["name"] == "app")
            actual = {item["name"]: item["identity"] for item in owner["dependencies"]}
            expected = capture.identity(dependency)
            self.assertEqual(actual, {"first": expected, "second": expected})
            library = next(module for module in record["modules"] if module["name"] == "library")
            self.assertEqual(library["identity"], expected)


if __name__ == "__main__":
    unittest.main()
