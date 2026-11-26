from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from scripts import package_release, verify_release_package
from scripts.release_package_contracts import (
    candidate_release_version,
    nightly_tag,
)
from scripts.release_tools_test_support import PROJECT_ROOT, SDK_SHA256, ReleaseToolsTestSupport


class NightlyPackageTest(ReleaseToolsTestSupport, unittest.TestCase):
    def test_package_keeps_public_tag_and_requires_matching_stdx(self) -> None:
        sdk = "1.3.0-alpha.20261125001016"
        stdx = f"{sdk}.1"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            repo, commit = self.make_release_repo(root / "repo")
            tag = nightly_tag(sdk, commit)
            version = candidate_release_version(tag, "0.7.0", sdk, commit)
            binary = root / "main"
            binary.write_bytes(b"nightly CLI")
            receipt = self.make_candidate_receipt(repo, binary, commit, sdk_version=sdk, stdx_version=stdx)
            receipt["source"].update(tag=tag, releaseVersion=version)
            output = repo / "target/release-package"
            recorded = dict(source_commit=commit, sdk_version=sdk, sdk_sha256=SDK_SHA256,
                            release_version=version, stdx_sha256="2" * 64, candidate_receipt=receipt)
            asset = package_release.build_archive(repo, binary, "linux-x64", output,
                                                  stdx_version=stdx, **recorded)
            manifest, members, executables = verify_release_package.inspect_archive(
                asset, "linux-x64", version, sdk, SDK_SHA256, commit, stdx, "2" * 64)
            self.assertEqual(manifest["releaseTag"], tag)
            self.assertEqual(manifest["runtime"]["stdxVersion"], stdx)
            self.assertEqual(set(executables.values()), {"cjdoc", "chir-worker-main"})
            self.assertIn("release-candidate.json", members)
            for wrong in ("1.2.0", "1.3.0-alpha.20261124001016.1"):
                with self.subTest(stdx=wrong), self.assertRaisesRegex(ValueError, "same SDK version"):
                    package_release.build_archive(repo, binary, "linux-x64", output,
                                                  stdx_version=wrong, **recorded)
            with self.assertRaisesRegex(ValueError, "same SDK version"):
                verify_release_package.inspect_archive(
                    asset, "linux-x64", version, sdk, SDK_SHA256, commit, "1.2.0", "2" * 64)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "requires POSIX Bash")
class NightlyRetryTest(unittest.TestCase):
    def test_exhausted_attempts_leave_no_uploadable_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            result = subprocess.run(
                ["bash", "scripts/nightly_candidate.sh"], cwd=PROJECT_ROOT,
                env={**os.environ, "NIGHTLY_PLATFORM": "linux-x64", "NIGHTLY_UNAVAILABLE_REASON": "",
                     "GITHUB_WORKSPACE": str(root / "missing-checkout"), "RUNNER_TEMP": str(root)},
                text=True, capture_output=True, timeout=20,
            )
            self.assertEqual(result.returncode, 128, result.stdout + result.stderr)
            self.assertEqual(result.stderr.count("does not exist"), 4, result.stderr)
            self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
