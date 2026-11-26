"""Nightly input freezing: exact archive selection, digests, and fail-closed metadata."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts import nightly_sdk

COMMIT = "1" * 40
SDK = "1.3.0-alpha.20261125001016"
PACKAGE = "0.7.0"
TAG = f"nightly-{SDK}-{COMMIT}"
RELEASE_VERSION = f"{PACKAGE}-nightly.sdk{SDK}.g{COMMIT}"
MANIFEST = nightly_sdk.MANIFEST_URL
RELEASE = nightly_sdk.RELEASE_URL.format(version=SDK)


def asset(name: str, digest: str | None = None, url: str | None = None) -> dict:
    entry = {
        "name": name,
        "type": "attach",
        "browser_download_url": url if url is not None
        else nightly_sdk.download_url(SDK, name),
    }
    if digest is not None:
        entry["digest"] = digest
    return entry


def sha(token: str) -> str:
    return "sha256:" + token * 64


def native(*, platform: str = "linux-x64", suffix: str = ".tar.gz") -> dict:
    return asset(f"cangjie-sdk-{platform}-{SDK}{suffix}", sha("a"))


def stdx(platform: str = "linux-x64", revision: int = 1) -> dict:
    return asset(f"cangjie-stdx-{platform}-{SDK}.{revision}.zip", sha("b"))


def full_assets() -> list[dict]:
    return [
        native(platform="linux-x64"),
        native(platform="windows-x64", suffix=".zip"),
        native(platform="mac-aarch64"),
        stdx("linux-x64"),
        stdx("windows-x64"),
        stdx("mac-aarch64"),
    ]


class FakeUpstream:
    """Serve the two allowlisted documents and record what was requested."""

    def __init__(self, manifest: object, release: object) -> None:
        self.manifest = manifest
        self.release = release
        self.requests: list[str] = []

    def __call__(self, url: str, limit: int) -> bytes:
        self.requests.append(url)
        if url == MANIFEST:
            return json.dumps(self.manifest).encode()
        if url == RELEASE:
            return json.dumps(self.release).encode()
        raise AssertionError(f"unexpected upstream URL: {url}")


def release_document(assets: list[dict], **overrides: object) -> dict:
    document = {"tag_name": SDK, "draft": False, "assets": assets}
    document.update(overrides)
    return document


def manifest_document(latest: object = SDK, versions: dict | None = None) -> dict:
    return {"latest": latest, "versions": versions if versions is not None else {SDK: {}}}


def resolve(assets: list[dict], *, manifest: object | None = None,
            release: object | None = None) -> dict:
    upstream = FakeUpstream(
        manifest if manifest is not None else manifest_document(),
        release if release is not None else release_document(assets),
    )
    return nightly_sdk.resolve_metadata(COMMIT, "", PACKAGE, fetch=upstream)


def row(document: dict, platform: str) -> dict:
    matches = [entry for entry in document["matrix"]["include"] if entry["platform"] == platform]
    assert len(matches) == 1, matches
    return matches[0]


class PinnedInputsTest(unittest.TestCase):
    def test_every_platform_pins_its_native_and_stdx_archive(self) -> None:
        document = resolve(full_assets())
        self.assertEqual(document["sdk_version"], SDK)
        self.assertEqual(document["tag"], TAG)
        self.assertEqual(document["release_version"], RELEASE_VERSION)
        self.assertEqual([entry["platform"] for entry in document["matrix"]["include"]],
                         ["linux-x64", "windows-x64", "macos-arm64"])
        self.assertEqual([entry["runner"] for entry in document["matrix"]["include"]],
                         ["ubuntu-22.04", "windows-2022", "macos-15"])
        for platform, sdk_name, stdx_name in (
            ("linux-x64", f"cangjie-sdk-linux-x64-{SDK}.tar.gz",
             f"cangjie-stdx-linux-x64-{SDK}.1.zip"),
            ("windows-x64", f"cangjie-sdk-windows-x64-{SDK}.zip",
             f"cangjie-stdx-windows-x64-{SDK}.1.zip"),
            ("macos-arm64", f"cangjie-sdk-mac-aarch64-{SDK}.tar.gz",
             f"cangjie-stdx-mac-aarch64-{SDK}.1.zip"),
        ):
            entry = row(document, platform)
            self.assertEqual(entry["unavailable_reason"], "")
            self.assertEqual(entry["sdk_sha256"], "a" * 64)
            self.assertEqual(entry["stdx_sha256"], "b" * 64)
            self.assertEqual(entry["stdx_version"], f"{SDK}.1")
            self.assertEqual(entry["sdk_url"], nightly_sdk.download_url(SDK, sdk_name))
            self.assertEqual(entry["stdx_url"], nightly_sdk.download_url(SDK, stdx_name))

    def test_explicit_version_skips_the_manifest(self) -> None:
        upstream = FakeUpstream(None, release_document(full_assets()))
        document = nightly_sdk.resolve_metadata(COMMIT, SDK, PACKAGE, fetch=upstream)
        self.assertEqual(upstream.requests, [RELEASE])
        self.assertEqual(document["sdk_version"], SDK)

    def test_sanitizer_installer_and_older_versions_are_never_selected(self) -> None:
        decoys = [
            asset(f"cangjie-sdk-linux-x64-{SDK}-sanitizer.tar.gz", sha("c")),
            asset(f"cangjie-sdk-windows-x64-{SDK}.exe", sha("c")),
            asset(f"cangjie-sdk-windows-x64-{SDK}.zip.sha256", sha("c")),
            asset("cangjie-sdk-linux-x64-1.3.0-alpha.20261124001016.tar.gz", sha("c")),
            asset(f"cangjie-stdx-linux-x64-{SDK}.0.zip", sha("c")),
            asset(f"cangjie-stdx-linux-x64-1.3.0-alpha.20261124001016.1.zip", sha("c")),
        ]
        document = resolve(full_assets() + decoys)
        for entry in document["matrix"]["include"]:
            self.assertEqual(entry["unavailable_reason"], "")
            self.assertEqual(entry["stdx_version"], f"{SDK}.1")

    def test_wrong_platform_archives_leave_the_other_platforms_intact(self) -> None:
        assets = [
            # A Linux SDK under the macOS platform token and vice versa.
            native(platform="linux-x64"),
            native(platform="mac-aarch64", suffix=".zip"),
            stdx("linux-x64"),
            stdx("mac-aarch64"),
        ]
        document = resolve(assets)
        self.assertEqual(row(document, "linux-x64")["unavailable_reason"], "")
        windows = row(document, "windows-x64")
        self.assertEqual(windows["sdk_url"], "")
        self.assertIn("sdk:", windows["unavailable_reason"])
        self.assertIn("stdx:", windows["unavailable_reason"])
        macos = row(document, "macos-arm64")
        self.assertIn("cangjie-sdk-mac-aarch64-" + SDK + ".tar.gz", macos["unavailable_reason"])
        self.assertEqual(macos["stdx_version"], f"{SDK}.1")

    def test_missing_stdx_reports_only_that_component(self) -> None:
        assets = [entry for entry in full_assets()
                  if not entry["name"].startswith("cangjie-stdx-windows-x64")]
        windows = row(resolve(assets), "windows-x64")
        self.assertEqual(windows["sdk_sha256"], "a" * 64)
        self.assertEqual(windows["stdx_url"], "")
        self.assertEqual(windows["stdx_version"], "")
        self.assertEqual(windows["unavailable_reason"].split(":")[0], "stdx")

    def test_ambiguous_stdx_revision_is_unavailable(self) -> None:
        # Two component revisions of one SDK version cannot both be the pinned
        # archive, so the platform is skipped rather than guessing the newer one.
        assets = full_assets() + [asset(f"cangjie-stdx-linux-x64-{SDK}.2.zip", sha("b"))]
        entry = row(resolve(assets), "linux-x64")
        self.assertEqual(entry["sdk_sha256"], "a" * 64)
        self.assertEqual(entry["stdx_url"], "")
        self.assertEqual(entry["stdx_sha256"], "")
        self.assertEqual(entry["stdx_version"], "")
        self.assertIn("stdx: 2 archives named", entry["unavailable_reason"])

    def test_duplicate_asset_names_are_unavailable(self) -> None:
        assets = full_assets() + [native(platform="linux-x64")]
        entry = row(resolve(assets), "linux-x64")
        self.assertEqual(entry["sdk_url"], "")
        self.assertIn("2 assets named", entry["unavailable_reason"])

    def test_missing_digest_is_unavailable(self) -> None:
        assets = [
            asset(f"cangjie-sdk-linux-x64-{SDK}.tar.gz"),
            asset(f"cangjie-stdx-linux-x64-{SDK}.1.zip"),
            native(platform="windows-x64", suffix=".zip"),
            stdx("windows-x64"),
        ]
        document = resolve(assets)
        linux = row(document, "linux-x64")
        self.assertEqual(linux["sdk_url"], "")
        self.assertEqual(linux["stdx_url"], "")
        self.assertEqual(linux["unavailable_reason"].count("no digest"), 2)
        # The platform that did publish digests is still buildable.
        self.assertEqual(row(document, "windows-x64")["unavailable_reason"], "")

    def test_malformed_digest_is_unavailable(self) -> None:
        for value in ("md5:" + "a" * 32, "sha256:" + "A" * 64, "sha256:" + "a" * 63, 7, ""):
            assets = [
                asset(f"cangjie-sdk-linux-x64-{SDK}.tar.gz", value),
                asset(f"cangjie-stdx-linux-x64-{SDK}.1.zip", value),
            ]
            entry = row(resolve(assets), "linux-x64")
            self.assertEqual(entry["sdk_url"], "", value)
            self.assertIn("digest", entry["unavailable_reason"], value)

    def test_asset_url_outside_the_pinned_namespace_is_unavailable(self) -> None:
        assets = [
            asset(f"cangjie-sdk-linux-x64-{SDK}.tar.gz", sha("a"),
                  url=f"https://example.test/cangjie-sdk-linux-x64-{SDK}.tar.gz"),
            asset(f"cangjie-stdx-linux-x64-{SDK}.1.zip", sha("b"),
                  url=f"http://gitcode.com/Cangjie/nightly_build/releases/download/{SDK}/x.zip"),
        ]
        entry = row(resolve(assets), "linux-x64")
        self.assertEqual(entry["sdk_sha256"], "")
        self.assertEqual(entry["stdx_sha256"], "")
        self.assertEqual(entry["unavailable_reason"].count("namespace"), 2)

    def test_all_platforms_unavailable_still_resolves(self) -> None:
        document = resolve([])
        self.assertEqual(document["tag"], TAG)
        for entry in document["matrix"]["include"]:
            self.assertTrue(entry["unavailable_reason"])
            self.assertEqual(entry["sdk_url"], "")
            self.assertEqual(entry["stdx_url"], "")


class FailedClosedTest(unittest.TestCase):
    def assertRefused(self, assets: list[dict] | None = None, **kwargs: object) -> None:
        documents = assets if assets is not None else full_assets()
        upstream = FakeUpstream(
            kwargs.pop("manifest", manifest_document()),
            kwargs.pop("release", release_document(documents)),
        )
        with self.assertRaises(nightly_sdk.NightlyError):
            nightly_sdk.resolve_metadata(COMMIT, "", PACKAGE, fetch=upstream)

    def test_release_tag_mismatch_fails_closed(self) -> None:
        self.assertRefused(release=release_document(full_assets(),
                                                    tag_name="1.3.0-alpha.20261124001016"))

    def test_draft_release_fails_closed(self) -> None:
        self.assertRefused(release=release_document(full_assets(), draft=True))

    def test_release_without_assets_fails_closed(self) -> None:
        self.assertRefused(release={"tag_name": SDK, "draft": False})

    def test_malformed_asset_entry_fails_closed(self) -> None:
        self.assertRefused(release=release_document(full_assets() + [{"digest": sha("c")}]))

    def test_manifest_without_latest_fails_closed(self) -> None:
        self.assertRefused(manifest={"versions": {SDK: {}}})

    def test_manifest_latest_absent_from_versions_fails_closed(self) -> None:
        self.assertRefused(manifest=manifest_document(versions={}))

    def test_manifest_latest_must_be_a_full_nightly_version(self) -> None:
        for latest in ("1.3.0", "1.3.0-alpha", "v1.3.0-alpha.20261125001016", 7, ""):
            self.assertRefused(manifest=manifest_document(latest=latest))

    def test_non_object_documents_fail_closed(self) -> None:
        self.assertRefused(manifest=[])
        self.assertRefused(release=[])

    def test_malformed_json_fails_closed(self) -> None:
        with self.assertRaises(nightly_sdk.NightlyError):
            nightly_sdk._fetch_json(MANIFEST, 1024, lambda url, limit: b"{not json", "manifest")

    def test_oversized_document_fails_closed(self) -> None:
        payload = b'{"latest": "' + SDK.encode() + b'"}'
        with self.assertRaises(nightly_sdk.NightlyError):
            nightly_sdk._fetch_json(MANIFEST, len(payload) - 1, lambda url, limit: payload,
                                    "manifest")

    def test_explicit_version_must_be_the_full_nightly_spelling(self) -> None:
        upstream = FakeUpstream(manifest_document(), release_document(full_assets()))
        for bad in ("1.3.0", "1.3.0-alpha", "1.3.0-alpha.2026112500101", "../x"):
            with self.assertRaises(nightly_sdk.NightlyError):
                nightly_sdk.resolve_metadata(COMMIT, bad, PACKAGE, fetch=upstream)
        self.assertEqual(upstream.requests, [])

    def test_bad_package_version_fails_closed(self) -> None:
        upstream = FakeUpstream(manifest_document(), release_document(full_assets()))
        with self.assertRaises(nightly_sdk.NightlyError):
            nightly_sdk.resolve_metadata(COMMIT, "", "0.7.0-rc.1", fetch=upstream)

    def test_bad_commit_fails_closed(self) -> None:
        upstream = FakeUpstream(manifest_document(), release_document(full_assets()))
        with self.assertRaises(nightly_sdk.NightlyError):
            nightly_sdk.resolve_metadata("abc", "", PACKAGE, fetch=upstream)

    def test_transport_failure_retries_then_fails(self) -> None:
        attempts: list[str] = []

        def broken(url: str, limit: int) -> bytes:
            attempts.append(url)
            raise OSError("connection reset")

        with mock.patch.object(nightly_sdk, "RETRY_DELAYS", (0.0, 0.0)), \
                self.assertRaises(nightly_sdk.NightlyError) as caught:
            nightly_sdk.resolve_metadata(COMMIT, SDK, PACKAGE, fetch=broken)
        self.assertEqual(len(attempts), 3)  # one try plus two retries
        self.assertIn("OSError", str(caught.exception))

    def test_retry_recovers_from_one_transport_failure(self) -> None:
        attempts: list[str] = []

        def flaky(url: str, limit: int) -> bytes:
            attempts.append(url)
            if len(attempts) == 1:
                raise OSError("connection reset")
            return json.dumps(release_document(full_assets())).encode()

        with mock.patch.object(nightly_sdk, "RETRY_DELAYS", (0.0, 0.0)):
            document = nightly_sdk.resolve_metadata(COMMIT, SDK, PACKAGE, fetch=flaky)
        self.assertEqual(len(attempts), 2)
        self.assertEqual(document["sdk_version"], SDK)


class GithubOutputTest(unittest.TestCase):
    def write_output(self, document: dict, path: Path) -> dict[str, str]:
        nightly_sdk.write_github_output(path, document)
        self.assertTrue(path.read_text(encoding="utf-8").endswith("\n"))
        parsed: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            parsed[key] = value
        return parsed

    def test_outputs_are_single_line_and_parse_as_the_matrix(self) -> None:
        document = resolve(full_assets())
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "output"
            path.write_text("", encoding="utf-8")
            parsed = self.write_output(document, path)
        self.assertEqual(set(parsed), {"sdk_version", "release_version", "tag", "matrix"})
        self.assertEqual(parsed["sdk_version"], SDK)
        self.assertEqual(parsed["release_version"], RELEASE_VERSION)
        self.assertEqual(parsed["tag"], TAG)
        self.assertNotIn("\n", parsed["matrix"])
        matrix = json.loads(parsed["matrix"])
        self.assertEqual(len(matrix["include"]), 3)
        self.assertEqual(matrix["include"], document["matrix"]["include"])
        for entry in matrix["include"]:
            self.assertEqual(set(entry), {
                "platform", "runner", "sdk_url", "sdk_sha256",
                "stdx_url", "stdx_sha256", "stdx_version", "unavailable_reason",
            })

    def test_output_is_appended_so_earlier_steps_survive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "output"
            path.write_text("previous=kept\n", encoding="utf-8")
            self.write_output(resolve(full_assets()), path)
            self.assertTrue(path.read_text(encoding="utf-8").startswith("previous=kept\n"))


class CommandLineTest(unittest.TestCase):
    def make_repo(self, root: Path, package_version: str = PACKAGE) -> tuple[Path, str]:
        root.mkdir(parents=True)
        (root / "cjpm.toml").write_text(
            f'[package]\nname="cjdoc"\nversion="{package_version}"\n', encoding="utf-8")
        for args in (
            ["init", "--quiet"],
            ["-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
             "add", "cjpm.toml"],
            ["-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
             "commit", "--quiet", "-m", "fixture"],
        ):
            subprocess.run(
                ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0",
                 "-c", "commit.gpgSign=false", "-c", "core.hooksPath=/dev/null",
                 "-C", str(root), *args],
                check=True, capture_output=True, text=True,
            )
        commit = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        return root, commit

    def test_cli_writes_the_step_outputs_for_the_committed_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_repo(Path(temporary) / "repo")
            path = Path(temporary) / "output"
            upstream = FakeUpstream(manifest_document(), release_document(full_assets()))
            with mock.patch.object(nightly_sdk, "fetch_bytes", upstream):
                status = nightly_sdk.main([
                    "--repo", str(repo), "--commit", commit, "--version", SDK,
                    "--github-output", str(path),
                ])
            self.assertEqual(status, 0)
            parsed = dict(line.split("=", 1) for line in
                          path.read_text(encoding="utf-8").splitlines())
        self.assertEqual(parsed["tag"], f"nightly-{SDK}-{commit}")
        self.assertEqual(parsed["release_version"], f"{PACKAGE}-nightly.sdk{SDK}.g{commit}")
        self.assertEqual(len(json.loads(parsed["matrix"])["include"]), 3)

    def test_cli_refuses_a_mismatched_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_repo(Path(temporary) / "repo")
            path = Path(temporary) / "output"
            upstream = FakeUpstream(manifest_document(),
                                    release_document(full_assets(), tag_name="9.9.9"))
            with mock.patch.object(nightly_sdk, "fetch_bytes", upstream):
                status = nightly_sdk.main([
                    "--repo", str(repo), "--commit", commit, "--github-output", str(path),
                ])
            self.assertEqual(status, 1)
            self.assertFalse(path.exists())

    def test_cli_reports_a_commit_whose_manifest_has_no_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo, commit = self.make_repo(Path(temporary) / "repo", "0.7.0-rc.1")
            status = nightly_sdk.main(["--repo", str(repo), "--commit", commit])
        self.assertEqual(status, 1)


if __name__ == "__main__":
    unittest.main()
