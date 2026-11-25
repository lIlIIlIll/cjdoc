"""Nightly publication: identity, status and publish-side refusal tests.

Every test runs the production decision logic against a scripted GitHub API, so
the interesting cases are the refusals: a moved tag, a mutable release, a
missing sidecar, a stale receipt, an unknown artifact directory, or a public
release that is not the one this run would produce. None of them may mutate a
release, and the tests assert that by counting the writes the fake observed.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from scripts import nightly_publish as publisher
from scripts import package_release
from scripts.release_package_contracts import nightly_release_version, nightly_tag
from scripts.release_tools_test_support import (
    PROJECT_ROOT,
    SDK_SHA256,
    ReleaseToolsTestSupport,
)

COMMIT = "c" * 40
SDK = "1.3.0-alpha.20261125001016"
STDX_VERSION = f"{SDK}.1"
STDX_SHA256 = "2" * 64
TAG = nightly_tag(SDK, COMMIT)
RELEASE_VERSION = nightly_release_version("0.7.0", SDK, COMMIT)
RUN_ID = "4242"
RUN_ATTEMPT = 3
LINUX_ARCHIVE, LINUX_CHECKSUM = publisher.expected_assets(RELEASE_VERSION, "linux-x64")


def matrix(*, unavailable: dict[str, str] | None = None) -> dict:
    rows = []
    for platform, runner in (("linux-x64", "ubuntu-22.04"),
                             ("windows-x64", "windows-2022"),
                             ("macos-arm64", "macos-15")):
        reason = (unavailable or {}).get(platform, "")
        rows.append({
            "platform": platform,
            "runner": runner,
            "sdk_url": "" if reason else f"https://gitcode.example/{SDK}/sdk-{platform}",
            "sdk_sha256": "" if reason else SDK_SHA256,
            "stdx_url": "" if reason else f"https://gitcode.example/{SDK}/stdx-{platform}",
            "stdx_sha256": "" if reason else STDX_SHA256,
            "stdx_version": "" if reason else STDX_VERSION,
            "unavailable_reason": reason,
        })
    return {"include": rows}


def environment(**overrides: str) -> dict[str, str]:
    values = {
        "GITHUB_REPOSITORY": "o/r",
        "GITHUB_SHA": COMMIT,
        "GITHUB_RUN_ID": RUN_ID,
        "GITHUB_RUN_ATTEMPT": str(RUN_ATTEMPT),
        "GITHUB_SERVER_URL": "https://github.example",
        "NIGHTLY_SDK_VERSION": SDK,
        "NIGHTLY_RELEASE_VERSION": RELEASE_VERSION,
        "NIGHTLY_TAG": TAG,
        "NIGHTLY_MATRIX": json.dumps(matrix(), separators=(",", ":")),
    }
    values.update(overrides)
    return {key: value for key, value in values.items() if value is not None}


def job(platform: str, conclusion: str, status: str = "completed") -> dict:
    return {"name": publisher.JOB_NAME.format(platform=platform),
            "status": status, "conclusion": conclusion}


def artifact_name(platform: str, run_id: str = RUN_ID,
                  attempt: int = RUN_ATTEMPT) -> str:
    return f"nightly-{platform}-{run_id}-{attempt}"


def digest_of(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def release_document(tag: str, *, draft: bool, prerelease: bool, immutable: bool,
                     release_id: int = 1, body: str = "", assets=()) -> dict:
    return {"id": release_id, "tag_name": tag, "draft": draft,
            "prerelease": prerelease, "immutable": immutable, "body": body,
            "name": "Nightly", "assets": list(assets)}


class FakeGitHub:
    """A scripted subset of the REST and CLI surface the publisher uses."""

    def __init__(self, *, jobs=(), refs=None, contents=None,
                 immutable_readable: bool = True) -> None:
        self.repo = "o/r"
        self.jobs = list(jobs)
        self.refs = dict(refs or {})
        self.releases: dict[int, dict] = {}
        self.tag_ids: dict[str, int] = {}
        self.asset_owner: dict[int, int] = {}
        self.contents: dict[int, bytes] = dict(contents or {})
        self.calls: list[tuple[str, str]] = []
        self.uploads: list[str] = []
        self.immutable_setting: dict | None = None
        if immutable_readable:
            self.immutable_setting = {"enabled": True, "enforced_by_owner": False}
        self._next_release = 100
        self._next_asset = 500

    # -- fixture helpers -------------------------------------------------
    def install(self, release: dict) -> dict:
        self.releases[release["id"]] = release
        self.tag_ids.setdefault(release["tag_name"], release["id"])
        return release

    def add_asset(self, release: dict, name: str, content: bytes) -> int:
        asset_id = self._next_asset
        self._next_asset += 1
        self.contents[asset_id] = content
        self.asset_owner[asset_id] = release["id"]
        release["assets"].append({
            "id": asset_id, "name": name, "size": len(content),
            "state": "uploaded", "digest": "sha256:" + digest_of(content)})
        return asset_id

    def public_release(self, tag: str, assets: dict[str, bytes], **overrides) -> dict:
        release = release_document(tag, draft=False, prerelease=True, immutable=True,
                                   release_id=self._next_release, **overrides)
        self._next_release += 1
        for name, content in assets.items():
            self.add_asset(release, name, content)
        return self.install(release)

    def draft_release(self, tag: str, *, body: str = publisher.DRAFT_MARKER) -> dict:
        release = release_document(tag, draft=True, prerelease=True, immutable=False,
                                   release_id=self._next_release, body=body)
        self._next_release += 1
        return self.install(release)

    def writes(self) -> list[tuple[str, str]]:
        return [call for call in self.calls if call[0] != "GET"]

    # -- API -------------------------------------------------------------
    def json(self, path: str) -> dict:
        self.calls.append(("GET", path))
        prefix = f"repos/{self.repo}"
        if path.startswith(f"{prefix}/actions/runs/"):
            return {"total_count": len(self.jobs), "jobs": self.jobs}
        if path == f"{prefix}/immutable-releases":
            if self.immutable_setting is None:
                raise publisher.ApiError(403, "resource not accessible by integration")
            return dict(self.immutable_setting)
        if path.startswith(f"{prefix}/git/ref/tags/"):
            tag = path.rsplit("/", 1)[1]
            if tag not in self.refs:
                raise publisher.ApiMissing("no such tag")
            return {"object": {"type": "commit", "sha": self.refs[tag]}}
        if path.startswith(f"{prefix}/releases/tags/"):
            tag = path.rsplit("/", 1)[1]
            if tag not in self.tag_ids:
                raise publisher.ApiMissing("no such release")
            if self.releases[self.tag_ids[tag]]["draft"]:
                raise publisher.ApiMissing("REST by tag only sees public releases")
            return self._copy(self.releases[self.tag_ids[tag]])
        if path.startswith(f"{prefix}/releases/"):
            release_id = int(path.rsplit("/", 1)[1])
            if release_id not in self.releases:
                raise publisher.ApiMissing("no such release")
            return self._copy(self.releases[release_id])
        raise AssertionError(f"unexpected GET {path}")

    def raw(self, path: str) -> bytes:
        self.calls.append(("GET", path))
        asset_id = int(path.rsplit("/", 1)[1])
        if asset_id not in self.contents:
            raise publisher.ApiMissing("no such asset")
        return self.contents[asset_id]

    def send(self, method: str, path: str, body: dict | None = None):
        if method == "POST" and path == "graphql":
            self.calls.append(("GET", "draft by tag"))
            release_id = self.tag_ids.get(body["variables"]["tag"])
            release = {"databaseId": release_id} if release_id else None
            return {"data": {"repository": {"release": release}}}
        self.calls.append((method, path))
        prefix = f"repos/{self.repo}"
        if method == "POST" and path == f"{prefix}/releases":
            tag = body["tag_name"]
            if tag in self.tag_ids:
                raise publisher.ApiError(422, "already_exists")
            release = release_document(
                tag, draft=body["draft"], prerelease=body["prerelease"],
                immutable=False, release_id=self._next_release, body=body["body"])
            self._next_release += 1
            return self.install(release)
        if method == "POST" and path == f"{prefix}/git/refs":
            tag = body["ref"].removeprefix("refs/tags/")
            if tag in self.refs:
                raise publisher.ApiError(422, "Reference already exists")
            self.refs[tag] = body["sha"]
            return {"ref": body["ref"], "object": {"type": "commit", "sha": body["sha"]}}
        if method == "PATCH" and path.startswith(f"{prefix}/releases/"):
            release = self.releases[int(path.rsplit("/", 1)[1])]
            if body.get("draft") is False:
                release["draft"] = False
                release["immutable"] = True
            release["prerelease"] = bool(body.get("prerelease", release["prerelease"]))
            release["body"] = body.get("body", release["body"])
            release["name"] = body.get("name", release["name"])
            return self._copy(release)
        if method == "DELETE" and "/assets/" in path:
            asset_id = int(path.rsplit("/", 1)[1])
            release = self.releases[self.asset_owner[asset_id]]
            release["assets"] = [asset for asset in release["assets"]
                                 if asset["id"] != asset_id]
            self.contents.pop(asset_id, None)
            self.asset_owner.pop(asset_id, None)
            return None
        raise AssertionError(f"unexpected {method} {path}")

    def upload(self, repository: str, tag: str, path: Path) -> None:
        self.calls.append(("UPLOAD", path.name))
        self.uploads.append(path.name)
        self.add_asset(self.releases[self.tag_ids[tag]], path.name, path.read_bytes())

    @staticmethod
    def _copy(release: dict) -> dict:
        return {**release, "assets": [dict(asset) for asset in release["assets"]]}


class InputTests(unittest.TestCase):
    def load(self, **overrides):
        return publisher.load_inputs(environment(**overrides))

    def test_the_workflow_identity_is_accepted(self):
        inputs = self.load()
        self.assertEqual(inputs.tag, TAG)
        self.assertEqual(inputs.release_version, RELEASE_VERSION)
        self.assertEqual(inputs.run_attempt, RUN_ATTEMPT)
        self.assertEqual(inputs.available_platforms(),
                         ["linux-x64", "windows-x64", "macos-arm64"])
        self.assertEqual(
            inputs.actions_url,
            f"https://github.example/o/r/actions/runs/{RUN_ID}/attempts/{RUN_ATTEMPT}")

    def test_a_tag_for_another_commit_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_TAG=nightly_tag(SDK, "e" * 40))

    def test_a_release_version_for_another_sdk_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_RELEASE_VERSION=nightly_release_version(
                "0.7.0", "1.3.0-alpha.20260101000000", COMMIT))

    def test_a_release_version_for_another_commit_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_RELEASE_VERSION=nightly_release_version(
                "0.7.0", SDK, "e" * 40))

    def test_a_missing_platform_is_refused(self):
        document = matrix()
        document["include"].pop()
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_MATRIX=json.dumps(document))

    def test_a_repeated_platform_is_refused(self):
        document = matrix()
        document["include"].append(dict(document["include"][0]))
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_MATRIX=json.dumps(document))

    def test_an_unavailable_row_can_describe_the_sdk_without_stdx(self):
        document = matrix()
        document["include"][0].update(
            unavailable_reason="no stdx", stdx_url="", stdx_sha256="", stdx_version="")
        inputs = self.load(NIGHTLY_MATRIX=json.dumps(document))
        self.assertNotIn("linux-x64", inputs.available_platforms())

    def test_an_unavailable_row_is_excluded_from_publication(self):
        document = matrix(unavailable={"windows-x64": "no stdx build"})
        inputs = self.load(NIGHTLY_MATRIX=json.dumps(document))
        self.assertEqual(inputs.available_platforms(), ["linux-x64", "macos-arm64"])

    def test_a_stdlib_version_from_another_sdk_is_refused(self):
        document = matrix()
        document["include"][0]["stdx_version"] = "1.2.0.1"
        with self.assertRaises(publisher.NightlyPublishError):
            self.load(NIGHTLY_MATRIX=json.dumps(document))

    def test_missing_identity_variables_are_refused(self):
        for name in ("GITHUB_REPOSITORY", "GITHUB_SHA", "NIGHTLY_TAG",
                     "NIGHTLY_MATRIX", "GITHUB_RUN_ATTEMPT"):
            with self.subTest(name=name), self.assertRaises(publisher.NightlyPublishError):
                self.load(**{name: ""})


class SidecarTests(unittest.TestCase):
    def test_a_well_formed_sidecar_is_decoded(self):
        self.assertEqual(
            publisher.parse_sidecar(b"a" * 64 + b"  archive.tar.gz\n", "sidecar"),
            ("a" * 64, "archive.tar.gz"))

    def test_a_path_in_a_sidecar_name_is_refused(self):
        for content in (b"a" * 64 + b"  ../escape.tar.gz\n",
                        b"a" * 64 + b" archive.tar.gz\n",
                        b"A" * 64 + b"  archive.tar.gz\n",
                        b"a" * 64 + b"  archive.tar.gz",
                        b"\xff" * 64):
            with self.subTest(content=content), \
                    self.assertRaises(publisher.NightlyPublishError):
                publisher.parse_sidecar(content, "sidecar")

    def test_gh_include_output_keeps_the_status_and_body(self):
        status, body = publisher._split_include(
            'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"a":1}')
        self.assertEqual((status, body), (200, '{"a":1}'))

    def test_a_missing_response_is_recognised(self):
        status, _ = publisher._split_include("HTTP/2.0 404 Not Found\n\n{}")
        self.assertEqual(status, 404)


class StatusTests(ReleaseToolsTestSupport):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "github-output"
        self.output.write_text("", encoding="utf-8")

    def status(self, api: FakeGitHub) -> dict:
        return publisher.status(environment(GITHUB_OUTPUT=str(self.output)), api)

    def recorded(self) -> list[str]:
        return self.output.read_text(encoding="utf-8").splitlines()

    def published_assets(self) -> dict[str, bytes]:
        content = b"archive bytes"
        return {LINUX_ARCHIVE: content,
                LINUX_CHECKSUM: f"{digest_of(content)}  {LINUX_ARCHIVE}\n".encode()}

    def public(self, assets=None, **overrides) -> FakeGitHub:
        api = FakeGitHub(refs={TAG: COMMIT})
        api.public_release(TAG, self.published_assets() if assets is None else assets,
                           **overrides)
        return api

    def test_a_missing_release_reports_not_existing(self):
        self.assertFalse(self.status(FakeGitHub())["existing"])
        self.assertEqual(self.recorded(), ["existing=false"])

    def test_a_verified_public_release_reports_existing(self):
        self.assertTrue(self.status(self.public())["existing"])
        self.assertEqual(self.recorded(), ["existing=true"])

    def test_a_draft_is_not_a_published_nightly(self):
        api = FakeGitHub(refs={TAG: COMMIT})
        api.draft_release(TAG)
        self.assertFalse(self.status(api)["existing"])

    def test_a_stable_release_with_this_tag_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(prerelease=False))

    def test_a_mutable_public_release_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(immutable=False))

    def test_a_moved_tag_is_refused(self):
        api = self.public()
        api.refs[TAG] = "e" * 40
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(api)

    def test_a_release_for_another_tag_is_refused(self):
        api = FakeGitHub(refs={TAG: COMMIT})
        api.public_release("nightly-other", self.published_assets())
        with self.assertRaises(publisher.NightlyPublishError):
            publisher.verify_public_release(
                api, publisher.load_inputs(environment()),
                next(iter(api.releases.values())))

    def test_an_empty_release_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(assets={}))

    def test_a_sidecar_that_disagrees_with_its_archive_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(assets={
                LINUX_ARCHIVE: b"archive bytes",
                LINUX_CHECKSUM: f"{'0' * 64}  {LINUX_ARCHIVE}\n".encode()}))

    def test_an_archive_without_its_sidecar_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(assets={LINUX_ARCHIVE: b"archive bytes"}))

    def test_a_sidecar_without_its_archive_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(assets={
                LINUX_CHECKSUM: f"{'0' * 64}  x{LINUX_CHECKSUM}\n".encode()}))

    def test_an_asset_outside_the_expected_set_is_refused(self):
        assets = self.published_assets() | {"installer.msi": b"bytes"}
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(self.public(assets=assets))

    def test_an_unpaired_archive_beside_a_valid_pair_is_refused(self):
        windows = publisher.expected_assets(RELEASE_VERSION, "windows-x64")[0]
        assets = self.published_assets() | {windows: b"windows archive"}
        with self.assertRaises(publisher.NightlyPublishError) as caught:
            self.status(self.public(assets=assets))
        self.assertIn("without", str(caught.exception))

    def test_a_published_platform_is_accepted_even_if_unavailable_today(self):
        # The release name space is every supported platform; a later run whose
        # matrix row cannot build Windows still verifies a release that has it.
        windows = publisher.expected_assets(RELEASE_VERSION, "windows-x64")
        content = b"windows archive"
        assets = self.published_assets() | {
            windows[0]: content,
            windows[1]: f"{digest_of(content)}  {windows[0]}\n".encode()}
        api = self.public(assets=assets)
        env = environment(NIGHTLY_MATRIX=json.dumps(
            matrix(unavailable={"windows-x64": "no stdx build"})))
        output = self.output
        output.write_text("", encoding="utf-8")
        self.assertTrue(publisher.status({**env, "GITHUB_OUTPUT": str(output)},
                                         api)["existing"])

    def test_an_asset_without_a_digest_is_refused(self):
        api = self.public()
        for release in api.releases.values():
            for asset in release["assets"]:
                asset["digest"] = None
        with self.assertRaises(publisher.NightlyPublishError):
            self.status(api)

    def test_an_unreadable_api_is_not_treated_as_missing(self):
        class Broken(FakeGitHub):
            def json(self, path: str) -> dict:
                if "/releases/tags/" in path:
                    raise publisher.ApiError(500, "server error")
                return super().json(path)

        with self.assertRaises(publisher.ApiError):
            self.status(Broken())
        self.assertEqual(self.recorded(), [])


class CandidateFixture(ReleaseToolsTestSupport):
    """One real Nightly package built from a release-repository fixture."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo, self.commit, self.tree, self.binary, self.worker, self.package = \
            build_candidate(self.root / "repo", "linux-x64", with_smoke_gate=True)

    def package_directory(self, platform: str = "linux-x64") -> Path:
        return self.package

    def stage(self, *platforms: str) -> Path:
        root = Path(tempfile.mkdtemp(dir=self.root))
        for platform in platforms:
            directory = root / artifact_name(platform)
            directory.mkdir()
            extension = ".zip" if platform.startswith("windows-") else ".tar.gz"
            name = f"cjdoc-{RELEASE_VERSION}-{platform}{extension}"
            shutil.copyfile(self.package / name, directory / name)
            shutil.copyfile(self.package / f"{name}.sha256", directory / f"{name}.sha256")
        return root


def build_candidate(repo_root: Path, platform: str, *,
                    with_smoke_gate: bool = True,
                    receipt_overrides: dict | None = None
                    ) -> tuple[Path, str, str, Path, Path, Path]:
    """Build one real Nightly archive and its checksum sidecar in a fixture repo."""
    helper = ReleaseToolsTestSupport()
    repo, _ = helper.make_release_repo(repo_root)
    wrapper = repo / "scripts/with_sts_cjpm.sh"
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    wrapper.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (wrapper.parent / "sts_compile_override.py").write_bytes(
        (PROJECT_ROOT / "scripts/sts_compile_override.py").read_bytes())
    helper.git(repo, "add", "-A")
    helper.git(repo, "-c", "user.name=t", "-c", "user.email=t@example.test",
               "commit", "-q", "-m", "wrapper")
    commit = helper.git(repo, "rev-parse", "HEAD")
    tree = helper.git(repo, "rev-parse", "HEAD^{tree}")
    binary = repo / "target/release/bin/main"
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_text("#!/bin/sh\necho 'cjdoc 0.7.0'\n", encoding="utf-8")
    binary.chmod(0o755)
    worker = ReleaseToolsTestSupport.make_worker(binary)
    receipt = helper.make_candidate_receipt_for(
        repo, binary, worker, commit, platform,
        sdk_version=SDK, stdx_version=STDX_VERSION, stdx_sha256=STDX_SHA256)
    receipt["source"].update({"tag": TAG, "releaseVersion": RELEASE_VERSION,
                              "tree": tree, "dirty": False})
    receipt["execution"] = {"runId": RUN_ID, "runAttempt": RUN_ATTEMPT,
                            "job": publisher.CANDIDATE_JOB}
    receipt["gates"] = {"stages.json": "e" * 64}
    if with_smoke_gate:
        receipt["gates"]["real-repository.json"] = "f" * 64
    if receipt_overrides:
        receipt.update(receipt_overrides)
    output = repo / "target/release-package"
    package_release.build_archive(
        repo, binary, platform, output, source_commit=commit,
        sdk_version=SDK, sdk_sha256=SDK_SHA256, release_version=RELEASE_VERSION,
        stdx_version=STDX_VERSION, stdx_sha256=STDX_SHA256,
        candidate_receipt=receipt, worker=worker)
    return repo, commit, tree, binary, worker, output


class PackageValidationTests(CandidateFixture):
    def validate(self, *, repo: Path | None = None, tree: str | None = None,
                 mutate=None, directory: Path | None = None) -> None:
        target = directory or self.stage("linux-x64") / artifact_name("linux-x64")
        if mutate is not None:
            mutate(target)
        publisher.validate_platform(
            target, "linux-x64", publisher.load_inputs(environment()),
            tree or self.tree, repo or self.repo)

    def test_the_built_package_is_accepted(self):
        self.validate()

    def test_a_tampered_sidecar_is_refused(self):
        def mutate(directory: Path) -> None:
            (directory / LINUX_CHECKSUM).write_text(
                f"{'0' * 64}  {LINUX_ARCHIVE}\n", encoding="ascii")

        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(mutate=mutate)

    def test_a_sidecar_naming_another_archive_is_refused(self):
        def mutate(directory: Path) -> None:
            content = b"archive bytes"
            (directory / LINUX_ARCHIVE).write_bytes(content)
            (directory / LINUX_CHECKSUM).write_text(
                f"{digest_of(content)}  other.tar.gz\n", encoding="ascii")

        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(mutate=mutate)

    def test_an_extra_file_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(mutate=lambda directory: (directory / "notes.txt")
                          .write_text("x", encoding="utf-8"))

    def test_a_missing_sidecar_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(mutate=lambda directory: (directory / LINUX_CHECKSUM).unlink())

    def test_a_directory_in_place_of_the_archive_is_refused(self):
        def mutate(directory: Path) -> None:
            (directory / LINUX_ARCHIVE).unlink()
            (directory / LINUX_ARCHIVE).mkdir()

        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(mutate=mutate)

    def test_a_package_from_another_tree_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.validate(tree="a" * 40)


class ReceiptValidationTests(unittest.TestCase):
    """Receipt fields are checked without rebuilding a package each time."""

    def receipt(self) -> dict:
        return {
            "schemaVersion": publisher.RECEIPT_SCHEMA,
            "source": {"tag": TAG, "releaseVersion": RELEASE_VERSION,
                       "commit": COMMIT, "tree": "d" * 40, "dirty": False},
            "platform": {"id": "linux-x64"},
            "toolchain": {"sdkVersion": SDK, "sdkArchiveSha256": SDK_SHA256,
                          "stdxVersion": STDX_VERSION,
                          "stdxArchiveSha256": STDX_SHA256},
            "execution": {"runId": RUN_ID, "runAttempt": RUN_ATTEMPT,
                          "job": publisher.CANDIDATE_JOB},
            "gates": {"stages.json": "e" * 64, "real-repository.json": "f" * 64},
        }

    def validate(self, receipt: dict, platform: str = "linux-x64") -> None:
        inputs = publisher.load_inputs(environment())
        publisher.validate_receipt(receipt, platform=platform, inputs=inputs,
                                   tree="d" * 40, row=inputs.rows[platform])

    def refusal(self, mutate, platform: str = "linux-x64") -> str:
        receipt = self.receipt()
        mutate(receipt)
        with self.assertRaises(publisher.NightlyPublishError) as caught:
            self.validate(receipt, platform)
        return str(caught.exception)

    def test_a_matching_receipt_is_accepted(self):
        self.validate(self.receipt())

    def test_another_run_attempt_is_refused(self):
        self.assertIn("run attempt", self.refusal(
            lambda receipt: receipt["execution"].update({"runAttempt": RUN_ATTEMPT + 1})))

    def test_another_run_is_refused(self):
        self.assertIn("different run", self.refusal(
            lambda receipt: receipt["execution"].update({"runId": "1"})))

    def test_another_job_is_refused(self):
        self.assertIn("candidate job", self.refusal(
            lambda receipt: receipt["execution"].update({"job": "publish"})))

    def test_another_tree_is_refused(self):
        self.assertIn("source tree", self.refusal(
            lambda receipt: receipt["source"].update({"tree": "a" * 40})))

    def test_another_release_version_is_refused(self):
        self.assertIn("release version", self.refusal(
            lambda receipt: receipt["source"].update({"releaseVersion": "0.7.0"})))

    def test_a_dirty_receipt_is_refused(self):
        self.assertIn("dirty", self.refusal(
            lambda receipt: receipt["source"].update({"dirty": True})))

    def test_another_stdx_archive_is_refused(self):
        self.assertIn("stdxArchiveSha256", self.refusal(
            lambda receipt: receipt["toolchain"].update({"stdxArchiveSha256": "a" * 64})))

    def test_a_receipt_without_the_smoke_gate_is_refused(self):
        self.assertIn("real-repository", self.refusal(
            lambda receipt: receipt["gates"].pop("real-repository.json")))

    def test_a_macos_receipt_needs_no_linux_smoke_gate(self):
        receipt = self.receipt()
        receipt["platform"] = {"id": "macos-arm64"}
        receipt["gates"].pop("real-repository.json")
        self.validate(receipt, "macos-arm64")

    def test_a_receipt_without_stage_evidence_is_refused(self):
        self.assertIn("stages.json", self.refusal(
            lambda receipt: receipt["gates"].clear()))

    def test_a_gate_without_a_digest_is_refused(self):
        self.assertIn("SHA-256", self.refusal(
            lambda receipt: receipt["gates"].update({"gate.json": "not-a-digest"})))


class PublishGuardTests(CandidateFixture):
    def publish(self, api: FakeGitHub, root: Path) -> dict:
        return publisher.publish(root, env=environment(), api=api, repo=self.repo,
                                 sleep=lambda _: None)

    def test_a_missing_job_listing_is_refused(self):
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(FakeGitHub(refs={TAG: self.commit}), self.stage("linux-x64"))

    def test_a_running_job_is_not_terminal(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job("linux-x64", None, status="in_progress"),
                               job("windows-x64", "failure"),
                               job("macos-arm64", "failure")])
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_a_repeated_candidate_job_is_refused(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job("linux-x64", "success"), job("linux-x64", "success"),
                               job("windows-x64", "failure"),
                               job("macos-arm64", "failure")])
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_zero_successes_publish_nothing(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job(platform, "failure")
                               for platform in publisher.PLATFORMS])
        with self.assertRaises(publisher.NightlyPublishError) as caught:
            self.publish(api, self.stage())
        self.assertIn("nothing is published", str(caught.exception))
        self.assertEqual(api.writes(), [])

    def test_a_missing_success_artifact_is_refused(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job("linux-x64", "success"),
                               job("windows-x64", "failure"),
                               job("macos-arm64", "failure")])
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage())
        self.assertEqual(api.writes(), [])

    def test_an_unknown_artifact_directory_is_refused(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job("linux-x64", "success"),
                               job("windows-x64", "failure"),
                               job("macos-arm64", "failure")])
        root = self.stage("linux-x64")
        (root / artifact_name("macos-arm64")).mkdir()
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, root)
        self.assertEqual(api.writes(), [])

    def test_an_artifact_from_another_attempt_is_refused(self):
        api = FakeGitHub(refs={TAG: self.commit},
                         jobs=[job("linux-x64", "success"),
                               job("windows-x64", "failure"),
                               job("macos-arm64", "failure")])
        root = self.stage("linux-x64")
        (root / artifact_name("linux-x64")).rename(
            root / artifact_name("linux-x64", RUN_ID, RUN_ATTEMPT - 1))
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, root)
        self.assertEqual(api.writes(), [])


class PublishFlowTests(CandidateFixture):
    def jobs(self) -> list[dict]:
        return [job("linux-x64", "success"), job("windows-x64", "failure"),
                job("macos-arm64", "failure")]

    def publish(self, api: FakeGitHub, root: Path) -> dict:
        return publisher.publish(root, env=environment(), api=api, repo=self.repo,
                                 sleep=lambda _: None)

    def local_assets(self) -> dict[str, bytes]:
        return {LINUX_ARCHIVE: (self.package / LINUX_ARCHIVE).read_bytes(),
                LINUX_CHECKSUM: (self.package / LINUX_CHECKSUM).read_bytes()}

    def test_a_partial_success_publishes_one_immutable_prerelease(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        result = self.publish(api, self.stage("linux-x64"))
        self.assertEqual(result["status"], "published")
        self.assertEqual(result["available"], ["linux-x64"])
        release = api.releases[api.tag_ids[TAG]]
        self.assertFalse(release["draft"])
        self.assertTrue(release["immutable"])
        self.assertTrue(release["prerelease"])
        self.assertIn(SDK, release["body"])
        self.assertIn(self.commit, release["body"])
        self.assertIn(f"/actions/runs/{RUN_ID}/attempts/{RUN_ATTEMPT}", release["body"])
        self.assertIn("`linux-x64`: published", release["body"])
        self.assertIn("job conclusion `failure`", release["body"])
        self.assertEqual(sorted(api.uploads), sorted([LINUX_ARCHIVE, LINUX_CHECKSUM]))

    def test_a_platform_unavailable_at_resolution_is_named_as_such(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        env = environment(NIGHTLY_MATRIX=json.dumps(
            matrix(unavailable={"windows-x64": "no stdx build"})))
        publisher.publish(self.stage("linux-x64"), env=env, api=api, repo=self.repo,
                          sleep=lambda _: None)
        release = api.releases[api.tag_ids[TAG]]
        self.assertIn("unavailable (no stdx build)", release["body"])

    def test_publication_is_skipped_when_the_same_assets_are_public(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        api.public_release(TAG, self.local_assets())
        result = self.publish(api, self.stage("linux-x64"))
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(api.writes(), [])

    def test_a_public_release_with_other_assets_is_never_modified(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        windows = publisher.expected_assets(RELEASE_VERSION, "windows-x64")[0]
        api.public_release(TAG, self.local_assets() | {windows: b"another archive"})
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_a_public_release_that_appears_before_the_write_is_never_modified(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        original = api.public_release

        class Racing(FakeGitHub):
            pass

        calls = {"count": 0}
        real = publisher.existing_public_release

        def racing_existing(client, inputs):
            calls["count"] += 1
            if calls["count"] == 2:
                # The release became public between the two identity reads.
                original(TAG, {"stray.txt": b"stray"})
            return real(client, inputs)

        with unittest.mock.patch.object(publisher, "existing_public_release",
                                        racing_existing):
            with self.assertRaises(publisher.NightlyPublishError):
                self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.uploads, [])

    def test_a_stale_asset_on_the_owned_draft_is_replaced(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        draft = api.draft_release(TAG)
        stale = publisher.expected_assets(RELEASE_VERSION, "windows-x64")[0]
        api.add_asset(draft, stale, b"stale bytes from an interrupted attempt")
        self.publish(api, self.stage("linux-x64"))
        self.assertNotIn(stale, [asset["name"] for asset in draft["assets"]])
        self.assertEqual(sorted(api.uploads), sorted([LINUX_ARCHIVE, LINUX_CHECKSUM]))

    def test_a_draft_this_workflow_does_not_own_is_left_alone(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        draft = api.draft_release(TAG, body="hand-written notes")
        api.add_asset(draft, "someone-elses.zip", b"bytes")
        with self.assertRaises(publisher.NightlyPublishError) as caught:
            self.publish(api, self.stage("linux-x64"))
        self.assertIn("not owned", str(caught.exception))
        self.assertEqual(api.writes(), [])

    def test_an_absent_tag_is_created_as_a_lightweight_ref(self):
        api = FakeGitHub(jobs=self.jobs())
        self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.refs[TAG], self.commit)
        self.assertEqual([call for call in api.calls
                          if call == ("POST", "repos/o/r/git/refs")], [
            ("POST", "repos/o/r/git/refs")])

    def test_a_tag_that_names_another_commit_stops_publication(self):
        api = FakeGitHub(refs={TAG: "e" * 40}, jobs=self.jobs())
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_an_immutable_repository_setting_that_is_disabled_stops_publication(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        api.immutable_setting = {"enabled": False, "enforced_by_owner": False}
        with self.assertRaises(publisher.NightlyPublishError):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_an_unreadable_immutable_setting_stops_publication(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs(),
                         immutable_readable=False)
        with self.assertRaisesRegex(publisher.NightlyPublishError, "NIGHTLY_RELEASE_SETTINGS_TOKEN"):
            self.publish(api, self.stage("linux-x64"))
        self.assertEqual(api.writes(), [])

    def test_a_public_release_that_stays_draft_after_the_write_is_refused(self):
        api = FakeGitHub(refs={TAG: self.commit}, jobs=self.jobs())
        original = api.send

        def no_publish(method, path, body=None):
            if method == "PATCH":
                api.calls.append((method, path))
                return None
            return original(method, path, body)

        with unittest.mock.patch.object(api, "send", no_publish):
            with self.assertRaises(publisher.NightlyPublishError):
                self.publish(api, self.stage("linux-x64"))


if __name__ == "__main__":
    unittest.main()
