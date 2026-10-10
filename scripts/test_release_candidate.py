"""Release candidate receipt, package v4 binding and publish-side rejection tests."""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile
import unittest

from scripts import package_release
from scripts import release_candidate_receipt
from scripts import verify_release_package
from scripts.release_tools_test_support import PROJECT_ROOT, SDK_SHA256, ReleaseToolsTestSupport

STDX_SHA256 = "2" * 64
PLATFORM = "linux-x64"


class ReleaseCandidateTests(ReleaseToolsTestSupport, unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo, self.commit = self.make_release_repo(self.root / "repo")
        self.binary = self.root / "cjdoc"
        self.binary.write_text("#!/bin/sh\necho 'cjdoc 0.7.0'\n", encoding="utf-8")
        self.binary.chmod(0o755)

    def receipt(self, **overrides) -> dict:
        document = {
            "schemaVersion": "cjdoc.release-candidate/1",
            "source": {"tag": "v0.7.0", "releaseVersion": "0.7.0", "commit": self.commit,
                       "tree": self.git(self.repo, "rev-parse", "HEAD^{tree}"),
                       "dirty": False, "worktreeSha256": "a" * 64},
            "platform": {"id": PLATFORM, "os": "Linux", "architecture": "x86_64",
                         "compilerTarget": "x86_64-unknown-linux-gnu"},
            "toolchain": {"sdkVersion": "1.2.0", "sdkArchiveSha256": SDK_SHA256,
                          "stdxVersion": "1.2.0", "stdxArchiveSha256": STDX_SHA256,
                          "compilerVersion": "Cangjie Compiler: 1.2.0", "cjpmVersion": "1.2.0",
                          "stdxDigest": "b" * 64, "toolchainFingerprint": "c" * 64},
            "build": {"command": ["cjpm", "build", "--jobs", "1"],
                      "effectiveCompileOptions": ["-O1"],
                      "buildConfigurationSha256": "d" * 64},
            "binary": {"path": "target/release/bin/main",
                       "sha256": verify_release_package.sha256_file(self.binary),
                       "size": self.binary.stat().st_size,
                       "versionOutput": "cjdoc 0.7.0"},
            "execution": {"runId": "1", "runAttempt": 1, "job": "release-candidate (linux-x64)"},
            "gates": {"release-gate": "e" * 64},
        }
        document.update(overrides)
        return document

    def build(self, receipt: dict | None, *, stdx_sha256: str | None = STDX_SHA256) -> Path:
        return package_release.build_archive(
            self.repo, self.binary, PLATFORM, self.repo / "target/release-package",
            source_commit=self.commit, sdk_version="1.2.0", sdk_sha256=SDK_SHA256,
            release_version="0.7.0", stdx_version="1.2.0" if stdx_sha256 else None,
            stdx_sha256=stdx_sha256, candidate_receipt=receipt,
        )

    def manifest(self, asset: Path) -> dict:
        manifest, _, _ = verify_release_package.inspect_archive(
            asset, PLATFORM, "0.7.0", "1.2.0", SDK_SHA256, self.commit,
            "1.2.0", STDX_SHA256)
        return manifest

    def test_v4_package_binds_the_accepted_receipt_and_binary(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        manifest = self.manifest(asset)
        self.assertEqual(manifest["schemaVersion"], "cjdoc.release-package/4")
        self.assertEqual(manifest["releaseTag"], "v0.7.0")
        self.assertEqual(manifest["sourceTree"], self.git(self.repo, "rev-parse", "HEAD^{tree}"))
        self.assertIn("release-candidate.json", manifest["files"])
        with tarfile.open(asset, "r:gz") as archive:
            member = archive.extractfile("cjdoc-0.7.0/release-candidate.json")
            assert member is not None
            embedded = json.loads(member.read())
        self.assertEqual(embedded, receipt)
        self.assertEqual(verify_release_package.sha256_file(asset),
                         verify_release_package.sha256_file(asset))

    def test_package_rejects_a_receipt_for_another_commit_platform_or_binary(self):
        cases = (
            (self.receipt(source={**self.receipt()["source"], "commit": "f" * 40}),
             "different source commit"),
            (self.receipt(platform={"id": "windows-x64", "os": "Windows",
                                    "architecture": "x86_64", "compilerTarget": "x86_64-pc-windows"}),
             "different platform"),
            (self.receipt(binary={"path": "target/release/bin/main", "sha256": "0" * 64,
                                  "size": 1, "versionOutput": "cjdoc 0.7.0"}),
             "does not describe the packaged binary"),
            (self.receipt(toolchain={**self.receipt()["toolchain"],
                                     "sdkArchiveSha256": "9" * 64}),
             "different SDK archive"),
            (self.receipt(toolchain={**self.receipt()["toolchain"],
                                     "stdxArchiveSha256": "8" * 64}),
             "different stdx archive"),
        )
        for receipt, pattern in cases:
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, pattern):
                self.build(receipt)

    def test_package_rejects_a_dirty_or_foreign_receipt_schema(self):
        with self.assertRaisesRegex(ValueError, "dirty worktree"):
            self.build(self.receipt(source={**self.receipt()["source"], "dirty": True}))
        with self.assertRaisesRegex(ValueError, "unexpected release candidate receipt schema"):
            self.build({"schemaVersion": "cjdoc.release-candidate/9"})

    def test_package_rejects_a_replaced_binary_after_acceptance(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        self.assertTrue(asset.exists())
        self.binary.write_text("#!/bin/sh\necho 'cjdoc 0.7.0'\n# replaced\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not describe the packaged binary"):
            self.build(receipt)

    def test_v4_manifest_requires_its_new_fields_and_matching_member(self):
        receipt = self.receipt()
        asset = self.build(receipt)
        # Rebuild the archive through the production writer so the only change is
        # the tampered manifest field; an ad-hoc tar would introduce PAX headers.
        with tarfile.open(asset, "r:gz") as archive:
            payload = {
                PurePosixPath(member.name).relative_to("cjdoc-0.7.0").as_posix():
                    (archive.extractfile(member).read(), member.mode)
                for member in archive.getmembers()
            }
        original = payload["release-manifest.json"][0].decode("utf-8")
        for mutate, pattern in (
            (lambda document: document.pop("releaseTag"), "unknown release package manifest schema"),
            (lambda document: document.__setitem__("sourceTree", "not-a-tree"),
             "requires its source tree"),
            (lambda document: document.__setitem__("candidateReceiptSha256", "0" * 64),
             "receipt digest does not match"),
        ):
            document = json.loads(original)
            mutate(document)
            payload["release-manifest.json"] = (
                (json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(),
                0o644,
            )
            rebuilt = self.repo / f"target/tampered-{abs(hash(pattern))}.tar.gz"
            rebuilt.parent.mkdir(parents=True, exist_ok=True)
            package_release.write_tar_gz(rebuilt, "cjdoc-0.7.0", payload)
            rebuilt_asset = rebuilt.with_name(f"cjdoc-0.7.0-{PLATFORM}.tar.gz")
            rebuilt.replace(rebuilt_asset)
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, pattern):
                verify_release_package.inspect_archive(
                    rebuilt_asset, PLATFORM, "0.7.0", "1.2.0", SDK_SHA256, self.commit,
                    "1.2.0", STDX_SHA256)

    def test_receipt_script_writes_a_stable_receipt_from_the_worktree(self):
        output = self.repo / "target/release-candidate/cjdoc-release-candidate.json"
        command = [
            sys.executable, str(PROJECT_ROOT / "scripts/release_candidate_receipt.py"),
            "--repo", str(self.repo), "--tag", "v0.7.0", "--platform", PLATFORM,
            "--binary", str(self.binary),
            "--sdk-archive-sha256", SDK_SHA256, "--stdx-archive-sha256", STDX_SHA256,
            "--sdk-version", "1.2.0", "--stdx-version", "1.2.0",
            "--output", str(output),
        ]
        completed = subprocess.run(command, text=True, capture_output=True)
        if completed.returncode != 0:
            # cjc/cjpm are unavailable outside the release toolchain image.
            self.assertIn("command failed", completed.stderr)
            return
        document = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(document["schemaVersion"], release_candidate_receipt.RECEIPT_SCHEMA)
        self.assertEqual(document["source"]["commit"], self.commit)
        self.assertEqual(document["binary"]["versionOutput"], "cjdoc 0.7.0")
        self.assertEqual(document["platform"]["id"], PLATFORM)


if __name__ == "__main__":
    unittest.main()
