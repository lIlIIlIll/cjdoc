#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import gzip
import io
import json
import os
import stat
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile
from pathlib import Path

from scripts import archive_limits
from scripts import install_cangjie_sdk
from scripts.install_cangjie_sdk import (
    CACHE_ARCHIVE,
    CACHE_MARKER,
    archive_name,
    extract,
    sdk_root,
    validate_cached_sdk,
    validate_cached_sdk_root,
    verify_sha256,
    write_cache_marker,
)


class InstallCangjieSdkTest(unittest.TestCase):
    @staticmethod
    def write_zip64_directory(path: Path, entries: int = 1) -> int:
        name = b"sdk/file"
        central = archive_limits.CENTRAL_FILE.pack(
            archive_limits.CENTRAL_FILE_SIGNATURE,
            45, 45, 0, 0, 0, 0, 0, 0, 0,
            len(name), 0, 0, 0, 0, 0, 0,
        ) + name
        zip64_offset = len(central)
        zip64 = archive_limits.ZIP64_EOCD.pack(
            archive_limits.ZIP64_EOCD_SIGNATURE,
            44, 45, 45, 0, 0, entries, entries, len(central), 0,
        )
        locator = archive_limits.ZIP64_LOCATOR.pack(
            archive_limits.ZIP64_LOCATOR_SIGNATURE, 0, zip64_offset, 1
        )
        eocd = archive_limits.EOCD.pack(
            archive_limits.EOCD_SIGNATURE,
            0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0,
        )
        path.write_bytes(central + zip64 + locator + eocd)
        return len(central)

    def test_archive_name_prefers_download_query(self) -> None:
        url = "https://example.test/download?fileName=cangjie-sdk.zip&token=ignored"
        self.assertEqual(archive_name(url), "cangjie-sdk.zip")

    def test_extracts_zip_and_finds_sdk_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.zip"
            destination = directory / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("cangjie/envsetup.sh", "#!/usr/bin/env bash\n")
                package.writestr("cangjie/bin/cjc", "")
            extract(archive, destination)
            self.assertEqual(sdk_root(destination), destination / "cangjie")

    def test_rejects_zip_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.zip"
            destination = directory / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("../escaped", "bad")
            with self.assertRaisesRegex(ValueError, "unsafe SDK archive member"):
                extract(archive, destination)

    def test_download_enforces_streaming_limit_without_content_length(self) -> None:
        class Response(io.BytesIO):
            headers: dict[str, str] = {}

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                self.close()

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "sdk.zip"
            response = Response(b"12345")
            with mock.patch.object(install_cangjie_sdk, "MAX_ARCHIVE_SIZE", 4), \
                    mock.patch.object(
                        install_cangjie_sdk.urllib.request, "urlopen", return_value=response
                    ):
                with self.assertRaisesRegex(ValueError, "download size limit"):
                    install_cangjie_sdk.download("https://example.test/sdk.zip", output)

    def test_zip_preflight_bounds_directory_members_and_expanded_size(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.zip"
            destination = directory / "out"
            destination.mkdir()
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("sdk/one", b"1")
                package.writestr("sdk/two", b"2")
            with mock.patch.object(install_cangjie_sdk, "MAX_ARCHIVE_MEMBERS", 1):
                with self.assertRaisesRegex(ValueError, "too many members"):
                    extract(archive, destination)
            with mock.patch.object(install_cangjie_sdk, "MAX_ZIP_DIRECTORY_SIZE", 46):
                with self.assertRaisesRegex(ValueError, "central directory"):
                    extract(archive, destination)
            with mock.patch.object(install_cangjie_sdk, "MAX_MEMBER_SIZE", 0):
                with self.assertRaisesRegex(ValueError, "member is too large"):
                    extract(archive, destination)

    def test_zip64_preflight_bounds_declared_count_and_central_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sdk.zip"
            directory_size = self.write_zip64_directory(archive)
            summary = archive_limits.inspect_zip_directory(
                archive, max_entries=1, max_directory_size=directory_size
            )
            self.assertEqual(summary.entries, 1)
            self.assertEqual(summary.directory_size, directory_size)

            self.write_zip64_directory(archive, entries=2)
            with self.assertRaisesRegex(ValueError, "too many members"):
                archive_limits.inspect_zip_directory(
                    archive, max_entries=1, max_directory_size=directory_size
                )
            self.write_zip64_directory(archive)
            with self.assertRaisesRegex(ValueError, "central directory"):
                archive_limits.inspect_zip_directory(
                    archive, max_entries=1,
                    max_directory_size=archive_limits.CENTRAL_FILE.size,
                )

    @unittest.skipIf(os.name == "nt", "ZIP mode-bit fixture is POSIX-specific")
    def test_zip_preflight_rejects_symlink_entry_type(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.zip"
            destination = directory / "out"
            destination.mkdir()
            member = zipfile.ZipInfo("sdk/link")
            member.create_system = 3
            member.external_attr = (stat.S_IFLNK | 0o777) << 16
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr(member, "target")
            with self.assertRaisesRegex(ValueError, "unsupported SDK ZIP member type"):
                extract(archive, destination)

    def test_tar_preflight_rejects_special_and_sparse_member_types(self) -> None:
        for member_type in (tarfile.FIFOTYPE, tarfile.GNUTYPE_SPARSE):
            with self.subTest(member_type=member_type), \
                    tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                archive = directory / "sdk.tar"
                destination = directory / "out"
                destination.mkdir()
                with tarfile.open(archive, "w") as package:
                    member = tarfile.TarInfo("sdk/unsupported")
                    member.type = member_type
                    package.addfile(member)
                with self.assertRaisesRegex(ValueError, "unsupported.*member type"):
                    extract(archive, destination)

    def test_tar_preflight_bounds_compressed_member_before_tarfile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.tar.gz"
            destination = directory / "out"
            destination.mkdir()
            member = tarfile.TarInfo("sdk/declared-large")
            member.size = 1024
            archive.write_bytes(gzip.compress(member.tobuf() + (b"\0" * 1024)))
            with mock.patch.object(install_cangjie_sdk, "MAX_MEMBER_SIZE", 16):
                with self.assertRaisesRegex(ValueError, "member is too large"):
                    extract(archive, destination)

    def test_tar_preflight_accepts_bounded_pax_and_rejects_large_extension(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / "sdk.tar.gz"
            destination = directory / "out"
            destination.mkdir()
            content = b"compiler"
            with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as package:
                member = tarfile.TarInfo("sdk/bin/" + ("c" * 120))
                member.size = len(content)
                package.addfile(member, io.BytesIO(content))
            extract(archive, destination)
            with mock.patch.object(install_cangjie_sdk, "MAX_TAR_EXTENSION_SIZE", 8):
                with self.assertRaisesRegex(ValueError, "extension headers"):
                    extract(archive, destination)

    def test_verifies_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sdk.zip"
            archive.write_bytes(b"sdk")
            expected = hashlib.sha256(b"sdk").hexdigest()
            verify_sha256(archive, expected)
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                verify_sha256(archive, "0" * 64)

    def make_cached_sdk(self, directory: Path,
                        relative: Path = Path("cangjie")) -> Path:
        root = directory / relative
        (root / "bin").mkdir(parents=True)
        (root / "envsetup.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        (root / "bin/cjc").write_bytes(b"compiler")
        (root / "bin/cjpm").write_bytes(b"package manager")
        return root

    def add_authenticated_archive(self, destination: Path,
                                  source_root: Path | None = None) -> str:
        source_root = source_root or destination / "cangjie"
        archive = destination.parent / f"{destination.name}-source.zip"
        with zipfile.ZipFile(archive, "w") as package:
            for path in sorted(source_root.rglob("*")):
                relative = path.relative_to(destination).as_posix()
                if path.is_dir():
                    package.writestr(relative + "/", b"")
                elif path.is_file():
                    package.writestr(
                        relative, path.read_bytes()
                    )
        cached = destination / CACHE_ARCHIVE
        cached.write_bytes(archive.read_bytes())
        return hashlib.sha256(cached.read_bytes()).hexdigest()

    def test_cache_requires_sha_bound_verified_extraction_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            with self.assertRaisesRegex(ValueError, "no verified extraction marker"):
                validate_cached_sdk(destination, "sdk.zip", expected)
            with self.assertRaisesRegex(ValueError, "no verified extraction marker"):
                validate_cached_sdk_root(root, expected)

            write_cache_marker(destination, root, "sdk.zip", expected)
            self.assertEqual(validate_cached_sdk(destination, "sdk.zip", expected), root)
            self.assertEqual(
                validate_cached_sdk(destination, "renamed-sdk.zip", expected), root
            )
            self.assertEqual(validate_cached_sdk_root(root, expected), root)
            with self.assertRaisesRegex(ValueError, "requested archive"):
                validate_cached_sdk(destination, "sdk.zip", "b" * 64)
            with self.assertRaisesRegex(ValueError, "requested archive"):
                validate_cached_sdk_root(root, "b" * 64)

    def test_cache_root_validation_supports_deep_authenticated_archives(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(
                destination, Path("a/b/c/d/e/cangjie")
            )
            expected = self.add_authenticated_archive(destination, root)
            write_cache_marker(destination, root, "sdk.zip", expected)
            self.assertEqual(sdk_root(destination), root)
            self.assertEqual(
                validate_cached_sdk(destination, "sdk.zip", expected), root
            )
            self.assertEqual(validate_cached_sdk_root(root, expected), root)

    def test_cache_marker_detects_tree_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            (root / "bin/cjc").write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "tree digest"):
                validate_cached_sdk(destination, "sdk.zip", expected)

    def test_cache_marker_detects_empty_directory_deletion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            empty = root / "empty-component"
            empty.mkdir()
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            self.assertEqual(validate_cached_sdk(destination, "sdk.zip", expected), root)
            empty.rmdir()
            with self.assertRaisesRegex(ValueError, "tree digest"):
                validate_cached_sdk(destination, "sdk.zip", expected)

    @unittest.skipIf(os.name == "nt", "POSIX directory permission mode required")
    def test_cache_marker_detects_directory_mode_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            self.assertEqual(validate_cached_sdk(destination, "sdk.zip", expected), root)
            original_mode = (root / "bin").stat().st_mode & 0o777
            drifted_mode = 0o755 if original_mode == 0o700 else 0o700
            (root / "bin").chmod(drifted_mode)
            with self.assertRaisesRegex(ValueError, "tree digest"):
                validate_cached_sdk(destination, "sdk.zip", expected)

    def test_cache_marker_rejects_escaping_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            marker = json.loads((destination / CACHE_MARKER).read_text(encoding="utf-8"))
            marker["sdkRoot"] = "../outside"
            (destination / CACHE_MARKER).write_text(json.dumps(marker), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                validate_cached_sdk(destination, "sdk.zip", expected)

    def test_cache_marker_rejects_unknown_fields_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            destination = base / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            marker_path = destination / CACHE_MARKER
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            marker["trusted"] = True
            marker_path.write_text(json.dumps(marker), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "schema is unknown"):
                validate_cached_sdk(destination, "sdk.zip", expected)

            if os.name != "nt":
                outside = base / "outside-marker.json"
                outside.write_text(json.dumps(marker), encoding="utf-8")
                marker_path.unlink()
                marker_path.symlink_to(outside)
                with self.assertRaisesRegex(ValueError, "no verified extraction marker"):
                    validate_cached_sdk(destination, "sdk.zip", expected)
                with self.assertRaisesRegex(ValueError, "must not be a symlink"):
                    validate_cached_sdk_root(root, expected)

    def test_cache_marker_requires_a_valid_archive_name_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary).resolve() / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            marker_path = destination / CACHE_MARKER
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            for invalid in ("", "../sdk.zip", {"name": "sdk.zip"}):
                with self.subTest(invalid=invalid):
                    marker["archiveName"] = invalid
                    marker_path.write_text(json.dumps(marker), encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "archive name is invalid"):
                        validate_cached_sdk(destination, "sdk.zip", expected)

    def test_cache_marker_uses_strict_json_and_sdk_root_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            destination = base / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            marker_path = destination / CACHE_MARKER
            valid = marker_path.read_text(encoding="utf-8").rstrip()
            marker_path.write_text(valid[:-1] + ',"treeSha256":"NaN"}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate JSON object key"):
                validate_cached_sdk(destination, "sdk.zip", expected)

            write_cache_marker(destination, root, "sdk.zip", expected)
            marker_path.write_text(
                marker_path.read_text(encoding="utf-8").replace(
                    f'"treeSha256": "{install_cangjie_sdk.tree_sha256(destination)}"',
                    '"treeSha256": NaN',
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
                validate_cached_sdk(destination, "sdk.zip", expected)

            write_cache_marker(destination, root, "sdk.zip", expected)
            alias = base / "sdk-alias"
            alias.symlink_to(root, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "canonical regular directory"):
                validate_cached_sdk_root(alias, expected)

    def test_self_consistent_forged_marker_cannot_authenticate_a_modified_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "sdk"
            root = self.make_cached_sdk(destination)
            expected = self.add_authenticated_archive(destination)
            write_cache_marker(destination, root, "sdk.zip", expected)
            (root / "bin/cjc").write_bytes(b"attacker-controlled compiler")
            marker_path = destination / CACHE_MARKER
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
            marker["treeSha256"] = install_cangjie_sdk.tree_sha256(destination)
            marker_path.write_text(json.dumps(marker), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "authenticated archive extraction"):
                validate_cached_sdk(destination, "sdk.zip", expected)

    def test_stdx_root_requires_complete_regular_static_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            shallow = directory / "stdx"
            deep = directory / "sidecar" / "stdx"
            for root in (shallow, deep):
                root.mkdir(parents=True)
            (shallow / "stdx.chir.cjo").write_bytes(b"package")
            self.assertIsNone(install_cangjie_sdk.stdx_root(directory))
            (shallow / "libstdx.chir.a").write_bytes(b"archive")
            self.assertEqual(install_cangjie_sdk.stdx_root(directory), shallow)
            # A deeper complete root never outranks the shallowest authenticated one.
            (deep / "stdx.chir.cjo").write_bytes(b"package")
            (deep / "libstdx.chir.a").write_bytes(b"archive")
            self.assertEqual(install_cangjie_sdk.stdx_root(directory), shallow)
            if os.name != "nt":
                (shallow / "libstdx.chir.a").unlink()
                (shallow / "libstdx.chir.a").symlink_to(deep / "libstdx.chir.a")
                self.assertEqual(install_cangjie_sdk.stdx_root(directory), deep)
                (shallow / "stdx.chir.cjo").unlink()
                (shallow / "stdx.chir.cjo").symlink_to(deep / "stdx.chir.cjo")
                self.assertEqual(install_cangjie_sdk.stdx_root(directory), deep)


class CombinedCacheTest(unittest.TestCase):
    """The combined compiler+stdx cache is the release path; prove it fails closed."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.destination = self.root / "sdk-cache"
        self.sdk = self.destination / "cangjie"
        (self.sdk / "bin").mkdir(parents=True)
        (self.sdk / "envsetup.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
        (self.sdk / "bin/cjc").write_bytes(b"compiler")
        (self.sdk / "bin/cjpm").write_bytes(b"package manager")
        self.stdx = self.destination / "linux_x86_64_cjnative/static/stdx"
        self.stdx.mkdir(parents=True)
        (self.stdx / "stdx.chir.cjo").write_bytes(b"package")
        (self.stdx / "libstdx.chir.a").write_bytes(b"archive")
        self.compiler_name = "cangjie-sdk-linux-x64.tar.gz"
        self.stdx_name = "cangjie-stdx-linux-x64.zip"
        self.compiler_sha256 = self.write_archive(self.sdk, "compiler")
        self.stdx_sha256 = self.write_archive(self.stdx, "stdx")
        # A real compiler identity requires a runnable cjc; stub the query so the
        # cache tests stay hermetic while still exercising marker validation.
        with mock.patch.object(install_cangjie_sdk, "compiler_identity",
                               return_value=("1.2.0 (cjnative)", "x86_64-unknown-linux-gnu")):
            install_cangjie_sdk.write_combined_cache_marker(
                self.destination, self.sdk, self.stdx, self.compiler_name,
                self.compiler_sha256, self.stdx_name, self.stdx_sha256,
                "1.2.0 (cjnative)", "x86_64-unknown-linux-gnu")

    def write_archive(self, source_root: Path, stem: str) -> str:
        archive = self.root / f"{stem}-source.zip"
        with zipfile.ZipFile(archive, "w") as package:
            for path in sorted(source_root.rglob("*")):
                relative = path.relative_to(self.destination).as_posix()
                if path.is_dir():
                    package.writestr(relative + "/", b"")
                elif path.is_file():
                    package.writestr(relative, path.read_bytes())
        name = (install_cangjie_sdk.CACHE_ARCHIVE if stem == "compiler"
                else install_cangjie_sdk.STDX_CACHE_ARCHIVE)
        cached = self.destination / name
        cached.write_bytes(archive.read_bytes())
        return hashlib.sha256(cached.read_bytes()).hexdigest()

    def validate(self) -> tuple[Path, Path]:
        return install_cangjie_sdk.validate_combined_cache(
            self.destination, self.compiler_name, self.compiler_sha256,
            self.stdx_name, self.stdx_sha256)

    def marker(self) -> Path:
        return self.destination / CACHE_MARKER

    def restore_marker(self) -> None:
        """Rewrite the pristine marker; the authentic archives are never touched."""
        with mock.patch.object(install_cangjie_sdk, "compiler_identity",
                               return_value=("1.2.0 (cjnative)", "x86_64-unknown-linux-gnu")):
            install_cangjie_sdk.write_combined_cache_marker(
                self.destination, self.sdk, self.stdx, self.compiler_name,
                self.compiler_sha256, self.stdx_name, self.stdx_sha256,
                "1.2.0 (cjnative)", "x86_64-unknown-linux-gnu")

    def marker_document(self) -> dict:
        return json.loads(self.marker().read_text(encoding="utf-8"))

    def rewrite_marker(self, mutate) -> None:
        document = self.marker_document()
        mutate(document)
        self.marker().write_text(json.dumps(document, sort_keys=True), encoding="utf-8")

    def test_authentic_cache_resolves_both_roots(self) -> None:
        sdk, stdx = self.validate()
        self.assertEqual(sdk, self.sdk)
        self.assertEqual(stdx, self.stdx)

    def test_missing_corrupt_and_unknown_marker_fields_fail(self) -> None:
        original = self.marker().read_text(encoding="utf-8")
        malformed = (
            (lambda: self.marker().unlink(), "no verified compiler/stdx marker"),
            (lambda: self.marker().write_text("{not json", encoding="utf-8"), "marker"),
            (lambda: self.rewrite_marker(lambda d: d.__setitem__("schemaVersion", "other/1")),
             "marker schema"),
            (lambda: self.rewrite_marker(lambda d: d.update({"unexpected": 1})), "marker schema"),
            (lambda: self.rewrite_marker(lambda d: d.pop("stdxArtifacts")), "marker schema"),
            (lambda: self.rewrite_marker(lambda d: d.pop("treeSha256")), "marker schema"),
        )
        for mutate, pattern in malformed:
            with self.subTest(pattern=pattern):
                self.marker().write_text(original, encoding="utf-8")
                mutate()
                with self.assertRaisesRegex(ValueError, pattern):
                    self.validate()
        self.marker().write_text(original, encoding="utf-8")

    def test_duplicate_marker_key_is_rejected(self) -> None:
        original = self.marker().read_text(encoding="utf-8")
        try:
            document = json.loads(original)
            text = json.dumps(document, sort_keys=True)
            self.marker().write_text(text[:-1] + ',"treeSha256":"' + "0" * 64 + '"}',
                                     encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "marker"):
                self.validate()
        finally:
            self.marker().write_text(original, encoding="utf-8")

    def test_archive_name_hash_and_presence_mismatches_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not match the requested archives"):
            install_cangjie_sdk.validate_combined_cache(
                self.destination, "different-name.tar.gz", self.compiler_sha256,
                self.stdx_name, self.stdx_sha256)
        with self.assertRaisesRegex(ValueError, "does not match the requested archives"):
            install_cangjie_sdk.validate_combined_cache(
                self.destination, self.compiler_name, "9" * 64,
                self.stdx_name, self.stdx_sha256)
        archive = self.destination / install_cangjie_sdk.STDX_CACHE_ARCHIVE
        original = archive.read_bytes()
        archive.write_bytes(original + b"trailing")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            self.validate()
        archive.write_bytes(original)
        archive.unlink()
        self.assertRaises(ValueError, self.validate)
        archive.write_bytes(original)

    def test_symlinked_and_special_archive_entries_fail(self) -> None:
        archive = self.destination / install_cangjie_sdk.CACHE_ARCHIVE
        original = archive.read_bytes()
        if os.name != "nt":
            archive.unlink()
            archive.symlink_to(self.root / "elsewhere")
            try:
                self.assertRaises(ValueError, self.validate)
            finally:
                archive.unlink()
        archive.write_bytes(original)
        archive.unlink()
        archive.mkdir()
        try:
            self.assertRaises(ValueError, self.validate)
        finally:
            archive.rmdir()
            archive.write_bytes(original)

    def test_tampered_compiler_stdx_and_added_entries_fail(self) -> None:
        compiler = self.sdk / "bin/cjc"
        original_compiler = compiler.read_bytes()
        compiler.write_bytes(b"modified compiler")
        with self.assertRaisesRegex(ValueError, "tree digest"):
            self.validate()
        compiler.write_bytes(original_compiler)

        # Any byte change to the stdx payload changes the authenticated tree, which
        # is checked before the per-artifact digests.
        artifact = self.stdx / "libstdx.chir.a"
        original_artifact = artifact.read_bytes()
        artifact.write_bytes(b"modified archive")
        with self.assertRaisesRegex(ValueError, "tree digest"):
            self.validate()
        artifact.write_bytes(original_artifact)

        extra = self.sdk / "bin/new-tool"
        extra.write_bytes(b"unexpected addition")
        with self.assertRaisesRegex(ValueError, "tree digest"):
            self.validate()
        extra.unlink()

    def test_stdx_artifact_digest_is_checked_against_the_marker(self) -> None:
        # Keep the tree digest honest so the artifact digest check itself is exercised.
        def drop_one_artifact(document: dict) -> None:
            document["stdxArtifacts"] = {
                name: digest for name, digest in document["stdxArtifacts"].items()
                if name != "libstdx.chir.a"}
            document["treeSha256"] = install_cangjie_sdk.tree_sha256(self.destination)

        self.rewrite_marker(drop_one_artifact)
        with self.assertRaisesRegex(ValueError, "stdx artifact digest"):
            self.validate()

    def test_deleted_and_permission_drifted_entries_fail(self) -> None:
        removed = self.sdk / "bin/cjpm"
        original = removed.read_bytes()
        removed.unlink()
        with self.assertRaisesRegex(ValueError, "tree digest"):
            self.validate()
        removed.write_bytes(original)

        if os.name != "nt":
            directory = self.sdk / "bin"
            mode = stat.S_IMODE(directory.stat().st_mode)
            directory.chmod(0o700 if mode != 0o700 else 0o755)
            try:
                with self.assertRaisesRegex(ValueError, "tree digest"):
                    self.validate()
            finally:
                directory.chmod(mode)

    def test_self_consistent_forged_marker_cannot_hide_a_modified_tree(self) -> None:
        (self.sdk / "bin/cjc").write_bytes(b"forged compiler")

        def recompute(document: dict) -> None:
            document["stdxArtifacts"] = install_cangjie_sdk.stdx_artifact_digests(self.stdx)
            document["treeSha256"] = install_cangjie_sdk.tree_sha256(self.destination)

        self.rewrite_marker(recompute)
        # The marker now describes the modified tree exactly, but the
        # checksum-pinned archives no longer reproduce it, so authentication
        # still fails instead of trusting the marker's self-description.
        with self.assertRaisesRegex(ValueError, "authenticated archives do not match"):
            self.validate()

    def test_root_escape_and_wrong_root_binding_fail(self) -> None:
        self.rewrite_marker(lambda document: document.update(sdkRoot="../outside"))
        with self.assertRaisesRegex(ValueError, "root is unsafe"):
            self.validate()
        # Pointing the stdx root at a real but non-stdx directory must not resolve.
        self.restore_marker()
        self.rewrite_marker(lambda document: document.update(stdxRoot="cangjie"))
        with self.assertRaisesRegex(ValueError, "stdx root"):
            self.validate()

    def test_install_combined_reports_no_success_on_failure(self) -> None:
        output = self.root / "github-output"
        self.rewrite_marker(lambda document: document.update(compilerArchiveSha256="0" * 64))
        args = mock.Mock(url="https://example.test/cangjie-sdk-linux-x64.tar.gz",
                         sha256=self.compiler_sha256,
                         stdx_url="https://example.test/cangjie-stdx-linux-x64.zip",
                         stdx_sha256=self.stdx_sha256, stdx_archive_name=self.stdx_name,
                         destination=self.destination, github_output=output)
        with self.assertRaises(ValueError):
            install_cangjie_sdk.install_combined(args)
        self.assertFalse(output.exists())

    def test_warm_marker_matches_a_cold_extraction_identity(self) -> None:
        """A warm restore must describe the same tree and stdx a cold extract yields."""
        marker = self.marker_document()
        fresh = self.root / "fresh"
        fresh.mkdir()
        for name in (install_cangjie_sdk.CACHE_ARCHIVE, install_cangjie_sdk.STDX_CACHE_ARCHIVE):
            with zipfile.ZipFile(self.destination / name) as package:
                package.extractall(fresh)
        self.assertEqual(install_cangjie_sdk.tree_sha256(fresh), marker["treeSha256"])
        fresh_stdx = install_cangjie_sdk.stdx_root(fresh)
        self.assertIsNotNone(fresh_stdx)
        self.assertEqual(install_cangjie_sdk.stdx_artifact_digests(fresh_stdx),
                         marker["stdxArtifacts"])
        self.assertEqual((marker["compilerVersion"], marker["compilerTarget"]),
                         ("1.2.0 (cjnative)", "x86_64-unknown-linux-gnu"))


if __name__ == "__main__":
    unittest.main()
