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

class ReleaseSecurityTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_safe_output_root_rejects_symlink_special_and_outside_paths(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            repo.mkdir()
            target = safe_output_root.safe_target_root(repo)
            outside = root / "outside"
            outside.mkdir()
            linked = target / "linked"
            linked.symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                safe_output_root.safe_output_directory(repo, linked)
            linked.unlink()
            special = target / "special"
            special.write_text("not a directory", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "special/non-directory"):
                safe_output_root.safe_output_directory(repo, special)
            with self.assertRaisesRegex(ValueError, "inside the canonical"):
                safe_output_root.safe_output_directory(repo, outside)

            regular = target / "regular-binary"
            regular.write_bytes(b"binary")
            self.assertEqual(safe_output_root.safe_regular_file(regular), regular)
            alias = target / "binary-alias"
            alias.symlink_to(regular)
            with self.assertRaisesRegex(ValueError, "canonical regular non-symlink"):
                safe_output_root.safe_regular_file(alias, description="cjdoc binary")

            evidence = target / "evidence.json"
            evidence.symlink_to(regular)
            with self.assertRaisesRegex(ValueError, "regular non-symlink"):
                safe_output_root.safe_output_file(evidence, description="evidence")

    def test_safe_output_root_normalizes_only_verified_darwin_system_alias(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            canonical = root / "private-var"
            canonical.mkdir()
            alias = root / "var"
            alias.symlink_to(canonical, target_is_directory=True)
            nested = canonical / "nested"
            nested.mkdir()
            outside = root / "outside"
            outside.mkdir()
            (nested / "user-link").symlink_to(outside, target_is_directory=True)
            with mock.patch.object(safe_output_root.sys, "platform", "darwin"), \
                    mock.patch.object(
                        safe_output_root, "_DARWIN_SYSTEM_ALIASES", {alias: canonical}
                    ):
                self.assertEqual(
                    safe_output_root.lexical_absolute(alias / "nested"), nested
                )
                with self.assertRaisesRegex(ValueError, "contains a symlink"):
                    safe_output_root.verify_directory_chain(alias / "nested" / "user-link")

    def test_release_archive_rejects_oversized_file_and_too_many_tar_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            oversized = root / "oversized.bin"
            oversized.write_bytes(b"123456789")
            with mock.patch.object(verify_release_package, "MAX_ARCHIVE_SIZE", 8):
                with self.assertRaisesRegex(ValueError, "archive size"):
                    verify_release_package.read_archive(oversized)

            large_member = root / "large-member.zip"
            with zipfile.ZipFile(large_member, "w") as package:
                package.writestr("root/large", b"x")
            with mock.patch.object(verify_release_package, "MAX_MEMBER_SIZE", 0):
                with self.assertRaisesRegex(ValueError, "member is too large"):
                    verify_release_package.read_archive(large_member)

            many_zip = root / "many.zip"
            with zipfile.ZipFile(many_zip, "w") as package:
                for index in range(verify_release_package.MAX_MEMBERS + 1):
                    package.writestr(f"root/member-{index:03d}", b"")
            with self.assertRaisesRegex(ValueError, "too many (members|headers)"):
                verify_release_package.read_archive(many_zip)

            archive = root / "many.tar"
            with tarfile.open(archive, "w") as package:
                for index in range(verify_release_package.MAX_MEMBERS + 1):
                    info = tarfile.TarInfo(f"root/member-{index:03d}")
                    info.size = 0
                    package.addfile(info)
            with self.assertRaisesRegex(ValueError, "too many (members|headers)"):
                verify_release_package.read_archive(archive)

    def test_release_workflow_separates_read_only_builds_from_single_publisher(self) -> None:
        workflow = (PROJECT_ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        daily = workflow.split("\n  daily-acceptance:\n", 1)[1].split(
            "\n  package:\n", 1
        )[0]
        package = workflow.split("\n  package:\n", 1)[1].split("\n  publish:\n", 1)[0]
        publish = workflow.split("\n  publish:\n", 1)[1]
        self.assertIn(
            "if: ${{ vars.CANGJIE_DAILY_LINUX_X64_URL != '' && "
            "vars.CANGJIE_DAILY_LINUX_X64_SHA256 != '' }}",
            daily,
        )
        self.assertIn("needs.daily-acceptance.result == 'success'", package)
        self.assertIn("needs.daily-acceptance.result == 'skipped'", package)
        self.assertIn("needs.release-gate.result == 'success'", package)
        self.assertIn("needs.platform-acceptance.result == 'success'", package)
        self.assertIn("contents: read", package)
        self.assertIn("persist-credentials: false", package)
        self.assertIn(
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            package,
        )
        self.assertNotIn("GH_TOKEN", package)
        self.assertNotIn("gh release", package)
        self.assertEqual(package.count("python scripts/verify_release.py"), 2)
        build_offset = package.index("cjpm build")
        self.assertLess(package.index("python scripts/verify_release.py"), build_offset)
        self.assertGreater(package.rindex("python scripts/verify_release.py"), build_offset)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn(
            "if: ${{ always() && needs.package.result == 'success' }}", publish
        )
        self.assertIn("persist-credentials: false", publish)
        self.assertIn(
            "actions/download-artifact@70fc10c6e5e1ce46ad2ea6f2b72d43f7d47b13c3",
            publish,
        )
        self.assertNotIn("skip-decompress", publish)
        self.assertNotIn("cjpm build", publish)
        self.assertNotIn("package_release.py", publish)
        self.assertLess(
            publish.index("Verify exact tag and all package artifacts"),
            publish.index("Upload to draft and publish"),
        )
        self.assertGreaterEqual(publish.count("require_draft"), 4)
        self.assertIn(
            "verify_remote_tag\n          require_draft\n          gh release upload", publish
        )
        self.assertIn(
            "verify_remote_tag\n          require_draft\n          gh release edit", publish
        )
        self.assertGreaterEqual(publish.count("verify_remote_tag"), 4)

    def test_remote_release_tag_is_recursively_peeled_to_the_workflow_commit(self) -> None:
        first = "1" * 40
        second = "2" * 40
        commit = "3" * 40
        responses = {
            "repos/owner/repo/git/ref/tags/v0.7.0": {
                "object": {"type": "tag", "sha": first}
            },
            f"repos/owner/repo/git/tags/{first}": {
                "object": {"type": "tag", "sha": second}
            },
            f"repos/owner/repo/git/tags/{second}": {
                "object": {"type": "commit", "sha": commit}
            },
        }
        calls: list[str] = []

        def request(endpoint: str) -> dict[str, object]:
            calls.append(endpoint)
            return responses[endpoint]

        self.assertEqual(
            verify_remote_tag.verify_remote_tag(
                "owner/repo", "v0.7.0", commit, request=request
            ),
            commit,
        )
        self.assertEqual(calls, list(responses))
        with self.assertRaisesRegex(ValueError, "remote release tag moved"):
            verify_remote_tag.verify_remote_tag(
                "owner/repo", "v0.7.0", "4" * 40, request=request
            )


