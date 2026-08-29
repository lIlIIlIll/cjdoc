#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from scripts.install_cangjie_sdk import archive_name, extract, sdk_root, verify_sha256


class InstallCangjieSdkTest(unittest.TestCase):
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
            with self.assertRaisesRegex(ValueError, "escapes destination"):
                extract(archive, destination)

    def test_verifies_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sdk.zip"
            archive.write_bytes(b"sdk")
            expected = hashlib.sha256(b"sdk").hexdigest()
            verify_sha256(archive, expected)
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                verify_sha256(archive, "0" * 64)


if __name__ == "__main__":
    unittest.main()
