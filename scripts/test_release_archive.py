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

class ReleaseArchiveTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_release_archive_is_reproducible_manifested_and_smokeable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import sys\n"
                "if sys.argv[1:] == ['--version']:\n"
                "    print('cjdoc 0.7.0')\n"
                "elif sys.argv[1:] == ['schema', 'list']:\n"
                "    print('doc-ir\\ndoc-ir-v7\\ndoc-ir-v8')\n"
                "else:\n"
                "    raise SystemExit(2)\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            output = repo / "target/release-package"
            options = {
                "source_commit": commit,
                "sdk_version": "1.1.3",
                "sdk_sha256": SDK_SHA256,
            }
            asset = package_release.build_archive(
                repo, binary, "linux-x64", output, **options
            )
            first = asset.read_bytes()
            second = package_release.build_archive(
                repo, binary, "linux-x64", output, **options
            ).read_bytes()
            self.assertEqual(first, second)
            self.assertTrue((output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256").is_file())
            sdk_root = self.make_fake_sdk(root / "sdk")
            evidence = verify_release_package.verify_archive(
                asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit,
                smoke=os.name != "nt", repository=repo, sdk_root=sdk_root,
                sdk_marker_verified=True,
            )
            files = evidence["manifest"]["files"]
            self.assertIn("THIRD_PARTY_NOTICES.md", files)
            self.assertIn("licenses/markdown-MIT.txt", files)
            self.assertIn("licenses/yjson-Apache-2.0.txt", files)
            if os.name != "nt":
                self.assertEqual(evidence["smoke"]["version"], "cjdoc 0.7.0")
                self.assertEqual(
                    evidence["sdkEnvironment"],
                    {"cjc": "tools/bin/cjc", "cjpm": "tools/bin/cjpm"},
                )
            _, members, _ = verify_release_package.inspect_archive(
                asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit
            )
            self.assertIsNone(members["README.md"].content)
            self.assertIsNotNone(members["release-manifest.json"].content)
            tampered = dict(members)
            original_member = tampered["README.md"]
            tampered_readme = b"not the tagged README\n"
            tampered["README.md"] = verify_release_package.ArchiveMember(
                "README.md", len(tampered_readme),
                verify_release_package.sha256_bytes(tampered_readme),
                original_member.mode,
            )
            with self.assertRaisesRegex(ValueError, "does not match source commit"):
                verify_release_package.verify_repository_payload(tampered, repo, commit)

            with self.assertRaisesRegex(ValueError, "does not match"):
                package_release.build_archive(
                    repo, binary, "linux-x64", output,
                    source_commit="f" * 40,
                    sdk_version="1.1.3",
                    sdk_sha256=SDK_SHA256,
                )

            readme = repo / "README.md"
            original_readme = readme.read_bytes()
            readme.write_text("dirty README\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                package_release.build_archive(repo, binary, "linux-x64", output, **options)
            readme.write_bytes(original_readme)
            schema = repo / "docs/schema/doc-ir-v8.schema.json"
            original_schema = schema.read_bytes()
            schema.write_bytes(original_schema + b"\n")
            with self.assertRaisesRegex(ValueError, "bytes differ"):
                package_release.build_archive(repo, binary, "linux-x64", output, **options)

    def test_release_archive_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("../escape", "bad")
            with self.assertRaisesRegex(ValueError, "unsafe archive member"):
                verify_release_package.read_archive(archive)

    def test_release_archive_rejects_a_symlinked_archive_path(self) -> None:
        if not hasattr(os, "symlink"):
            self.skipTest("symlink creation is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "payload.zip"
            with zipfile.ZipFile(archive, "w") as package:
                package.writestr("root/member", "payload")
            alias = root / "alias.zip"
            try:
                alias.symlink_to(archive)
            except OSError as error:
                self.skipTest(f"symlink creation is unavailable: {error}")
            with self.assertRaisesRegex(ValueError, "not a regular file"):
                verify_release_package.read_archive(alias)

    def test_release_archive_binds_platform_magic_and_exact_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            payload = package_release.collect_payload(
                repo, binary, False, "0.7.0", "linux-x64", commit,
                "1.1.3", SDK_SHA256,
            )
            output = repo / "target/release-package"
            output.mkdir(parents=True)
            asset = output / "cjdoc-0.7.0-linux-x64.tar.gz"

            with zipfile.ZipFile(asset, "w") as package:
                package.writestr("cjdoc-0.7.0/cjdoc", b"binary")
            with self.assertRaisesRegex(ValueError, "format mismatch"):
                verify_release_package.inspect_archive(
                    asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256, commit
                )

            for name, mode in (("cjdoc", 0o644), ("README.md", 0o4755)):
                with self.subTest(name=name, mode=oct(mode)):
                    modified = dict(payload)
                    content, _ = modified[name]
                    modified[name] = (content, mode)
                    package_release.write_tar_gz(asset, "cjdoc-0.7.0", modified)
                    with self.assertRaisesRegex(ValueError, "member mode mismatch"):
                        verify_release_package.inspect_archive(
                            asset, "linux-x64", "0.7.0", "1.1.3", SDK_SHA256,
                            commit,
                        )

            windows_payload = package_release.collect_payload(
                repo, binary, True, "0.7.0", "windows-x64", commit,
                "1.1.3", SDK_SHA256,
            )
            windows_asset = output / "cjdoc-0.7.0-windows-x64.zip"
            package_release.write_zip(windows_asset, "cjdoc-0.7.0", windows_payload)
            verify_release_package.inspect_archive(
                windows_asset, "windows-x64", "0.7.0", "1.1.3", SDK_SHA256,
                commit,
            )
            content, _ = windows_payload["cjdoc.exe"]
            windows_payload["cjdoc.exe"] = (content, 0o644)
            package_release.write_zip(windows_asset, "cjdoc-0.7.0", windows_payload)
            with self.assertRaisesRegex(ValueError, "member mode mismatch"):
                verify_release_package.inspect_archive(
                    windows_asset, "windows-x64", "0.7.0", "1.1.3",
                    SDK_SHA256, commit,
                )

    def test_release_tar_rejects_pax_extensions_before_tarfile(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "cjdoc-0.7.0-linux-x64.tar.gz"
            with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as package:
                member = tarfile.TarInfo("cjdoc-0.7.0/" + ("x" * 120))
                member.size = 0
                package.addfile(member)
            with self.assertRaisesRegex(ValueError, "extension headers"):
                verify_release_package.read_archive(
                    archive, expected_format="gzip-tar"
                )

    @unittest.skipIf(os.name == "nt", "fixture environment uses a POSIX shell")
    def test_package_smoke_rejects_tools_resolved_outside_declared_sdk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "sdk"
            root.mkdir()
            (root / "envsetup.sh").write_text(
                "#!/usr/bin/env bash\n"
                "export CANGJIE_HOME=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "outside the SDK root|cannot resolve"):
                verify_release_package.declared_sdk_environment(root)

    @unittest.skipIf(os.name == "nt", "fixture environment uses a POSIX shell")
    def test_package_smoke_sources_sdk_setup_without_nounset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_fake_sdk(Path(temporary) / "sdk")
            setup = root / "envsetup.sh"
            original = setup.read_text(encoding="utf-8")
            setup.write_text(
                'export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH}:sdk"\n'
                + original,
                encoding="utf-8",
            )
            environment, tools = verify_release_package.declared_sdk_environment(root)
            self.assertEqual(environment["CANGJIE_HOME"], str(root.resolve()))
            self.assertEqual(tools, {"cjc": "tools/bin/cjc", "cjpm": "tools/bin/cjpm"})

    def test_windows_sdk_setup_uses_environment_path_not_command_arguments(self) -> None:
        setup = Path("sdk root") / "envsetup.ps1"
        command, environment = (
            verify_release_package.powershell_sdk_environment_invocation(setup)
        )
        script = command[command.index("-Command") + 1]
        self.assertIn(". $env:CJDOC_SDK_SETUP", script)
        self.assertNotIn("$args", script)
        self.assertEqual(environment["CJDOC_SDK_SETUP"], str(setup))

    def test_packaging_rechecks_cleanliness_after_payload_collection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            original_collect = package_release.collect_payload

            def collect_then_dirty(*args, **kwargs):
                payload = original_collect(*args, **kwargs)
                (repo / "README.md").write_text("changed during packaging\n", encoding="utf-8")
                return payload

            with mock.patch.object(
                package_release, "collect_payload", side_effect=collect_then_dirty
            ):
                with self.assertRaisesRegex(ValueError, "bytes differ"):
                    package_release.build_archive(
                    repo, binary, "linux-x64", repo / "target/release-package",
                        source_commit=commit, sdk_version="1.1.3", sdk_sha256=SDK_SHA256,
                    )
            self.assertFalse(
                (repo / "target/release-package/cjdoc-0.7.0-linux-x64.tar.gz").exists()
            )

    def test_packaging_rechecks_source_after_archive_write_before_publish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo, commit = self.make_release_repo(root / "repo")
            binary = root / "main"
            binary.write_bytes(b"binary")
            output = repo / "target/release-package"
            output.mkdir(parents=True)
            asset = output / "cjdoc-0.7.0-linux-x64.tar.gz"
            checksum = output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256"
            asset.write_bytes(b"stale package")
            checksum.write_text("stale checksum\n", encoding="ascii")
            original_write = package_release.write_tar_gz

            def write_then_dirty(*args, **kwargs):
                original_write(*args, **kwargs)
                (repo / "README.md").write_text(
                    "changed during archive write\n", encoding="utf-8"
                )

            with mock.patch.object(
                package_release, "write_tar_gz", side_effect=write_then_dirty
            ):
                with self.assertRaisesRegex(ValueError, "bytes differ"):
                    package_release.build_archive(
                        repo, binary, "linux-x64", output,
                        source_commit=commit, sdk_version="1.1.3",
                        sdk_sha256=SDK_SHA256,
                    )
            self.assertFalse((output / "cjdoc-0.7.0-linux-x64.tar.gz").exists())
            self.assertFalse((output / "cjdoc-0.7.0-linux-x64.tar.gz.sha256").exists())


