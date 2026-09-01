from __future__ import annotations

import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.package_standalone import package


class PackageStandaloneTest(unittest.TestCase):
    def test_packages_all_platform_names_and_checksum(self) -> None:
        for platform, suffix in (("linux-x64", ""), ("macos-arm64", ""),
                                 ("windows-x64", ".exe")):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / ("main.exe" if suffix else "main")
                binary.write_bytes(b"standalone-cjdoc")
                output = root / "out"
                asset, checksum = package(binary, output, platform, "0.7.0")
                self.assertEqual(asset.name, f"cjdoc-0.7.0-{platform}{suffix}")
                self.assertEqual(asset.read_bytes(), b"standalone-cjdoc")
                digest = hashlib.sha256(b"standalone-cjdoc").hexdigest()
                self.assertEqual(checksum.read_text(encoding="ascii"),
                                 f"{digest}  {asset.name}\n")

    def test_refuses_overwrite_and_symlink_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "main"
            binary.write_bytes(b"binary")
            output = root / "out"
            package(binary, output, "linux-x64", "0.7.0")
            with self.assertRaisesRegex(ValueError, "already exists"):
                package(binary, output, "linux-x64", "0.7.0")
            link = root / "link"
            link.symlink_to(binary)
            with self.assertRaisesRegex(ValueError, "regular non-symlink"):
                package(link, root / "other", "linux-x64", "0.7.0")

    def test_publish_races_fail_closed_without_overwriting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "main"
            binary.write_bytes(b"binary")
            output = root / "out"
            real_link = __import__("os").link

            def race_asset(source: Path, destination: Path, **kwargs: object) -> None:
                destination.write_bytes(b"other-writer")
                real_link(source, destination, **kwargs)

            with mock.patch("scripts.package_standalone.os.link", side_effect=race_asset):
                with self.assertRaisesRegex(ValueError, "already exists"):
                    package(binary, output, "linux-x64", "0.7.0")
            asset = output / "cjdoc-0.7.0-linux-x64"
            self.assertEqual(asset.read_bytes(), b"other-writer")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "main"
            binary.write_bytes(b"binary")
            output = root / "out"
            victim = root / "victim"
            victim.write_bytes(b"keep")
            calls = 0

            def race_checksum(source: Path, destination: Path, **kwargs: object) -> None:
                nonlocal calls
                calls += 1
                if calls == 2:
                    destination.symlink_to(victim)
                real_link(source, destination, **kwargs)

            with mock.patch("scripts.package_standalone.os.link", side_effect=race_checksum):
                with self.assertRaisesRegex(ValueError, "already exists"):
                    package(binary, output, "linux-x64", "0.7.0")
            self.assertEqual(
                (output / "cjdoc-0.7.0-linux-x64").read_bytes(), b"binary",
            )
            self.assertTrue((output / "cjdoc-0.7.0-linux-x64.sha256").is_symlink())
            self.assertEqual(victim.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
