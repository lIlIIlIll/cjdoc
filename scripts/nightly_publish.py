#!/usr/bin/env python3
"""Publish one immutable GitHub Nightly prerelease per source commit and SDK.

Two modes share one definition of a published Nightly:

``status``
    Read-only. It answers whether the exact ``nightly-<sdk>-<commit>`` tag is
    already public, and it refuses to answer "existing" unless the live tag
    still peels to the source commit, the release is an immutable prerelease,
    and its assets are a non-empty set of expected archive/checksum pairs whose
    SHA-256 digests agree with each other. Only HTTP 404 means "missing"; every
    other unreadable state is an error, because publishing over an unknown
    release is how a good release gets replaced by a worse one.

``publish``
    The only mode allowed to mutate. It reads this run attempt's jobs, accepts
    only platform packages whose job and embedded candidate receipt agree on
    the same run, attempt, source tree and toolchain, creates or recovers a
    workflow-owned draft, uploads only verified assets, re-reads the remote
    names and digests, and only then publishes the prerelease. A public release
    is never modified, and an interrupted draft may lose only assets this
    workflow owns.

Both modes read the workflow's mapping of ``NIGHTLY_SDK_VERSION``,
``NIGHTLY_RELEASE_VERSION``, ``NIGHTLY_TAG`` and ``NIGHTLY_MATRIX``, the normal
``GITHUB_*`` identity variables, and hand ``GH_TOKEN`` to the `gh` CLI.
"""

from __future__ import annotations

import argparse
from collections.abc import Mapping
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Any
from urllib.parse import quote

sys.dont_write_bytecode = True

try:
    from .release_package_contracts import (
        COMMIT,
        NIGHTLY_SDK_VERSION,
        SHA256,
        nightly_release_version,
        nightly_tag,
        release_core,
        validate_release_stdx_version,
    )
    from .release_package_payload import verify_repository_payload
    from .strict_json import strict_loads
    from .verify_release_package import inspect_archive
    from .verify_remote_tag import resolve_remote_tag, verify_remote_tag
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from release_package_contracts import (
        COMMIT,
        NIGHTLY_SDK_VERSION,
        SHA256,
        nightly_release_version,
        nightly_tag,
        release_core,
        validate_release_stdx_version,
    )
    from release_package_payload import verify_repository_payload
    from strict_json import strict_loads
    from verify_release_package import inspect_archive
    from verify_remote_tag import resolve_remote_tag, verify_remote_tag
    from worktree_identity import exact_worktree_identity


PLATFORMS = ("linux-x64", "windows-x64", "macos-arm64")
# The workflow's candidate job id. The receipt records it as `GITHUB_JOB`.
CANDIDATE_JOB = "candidate"
JOB_NAME = "Nightly candidate / {platform}"
ARTIFACT_NAME = "nightly-{platform}-{run_id}-{run_attempt}"
RECEIPT_MEMBER = "release-candidate.json"
RECEIPT_SCHEMA = "cjdoc.release-candidate/2"
# A fixed marker in the notes is how a draft proves it was created by this
# workflow. Only a draft carrying it may have assets replaced or removed.
DRAFT_MARKER = "<!-- cjdoc-nightly-draft: owned by nightly-release workflow -->"
CHECKSUM_LINE = re.compile(r"([0-9a-f]{64})  ([^\r\n/\\]+)\n")
ASSET_DIGEST = re.compile(r"sha256:([0-9a-f]{64})")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SERVER_ORIGIN = re.compile(r"^https://[A-Za-z0-9.-]+(?::[0-9]+)?$")
RUN_ID = re.compile(r"^[1-9][0-9]*$")
MATRIX_KEYS = frozenset({
    "platform", "runner", "sdk_url", "sdk_sha256", "stdx_url", "stdx_sha256",
    "stdx_version", "unavailable_reason",
})
MAX_PAGES = 20
STREAM_BLOCK = 1024 * 1024


class NightlyPublishError(Exception):
    """The Nightly release state cannot be accepted or published."""


class ApiError(NightlyPublishError):
    """A GitHub API request failed for a reason other than a missing resource."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


class ApiMissing(ApiError):
    """The requested resource does not exist (HTTP 404)."""

    def __init__(self, message: str) -> None:
        super().__init__(404, message)


@dataclass(frozen=True)
class Inputs:
    """One exact Nightly identity, as the workflow resolved it."""

    repository: str
    commit: str
    run_id: str
    run_attempt: int
    server_url: str
    sdk_version: str
    release_version: str
    tag: str
    rows: dict[str, dict[str, str]]

    @property
    def actions_url(self) -> str:
        return (f"{self.server_url}/{self.repository}/actions/runs/"
                f"{self.run_id}/attempts/{self.run_attempt}")

    def available_platforms(self) -> list[str]:
        return [platform for platform in PLATFORMS
                if not self.rows[platform]["unavailable_reason"]]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(STREAM_BLOCK), b""):
            digest.update(block)
    return digest.hexdigest()


def regular_file(path: Path, description: str) -> os.stat_result:
    """Return the metadata of a regular, non-symlink file or fail."""
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise NightlyPublishError(f"{description} is missing: {path.name}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise NightlyPublishError(f"{description} is not a regular file: {path.name}")
    return metadata


def append_output(path: Path, name: str, value: str) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(f"{name}={value}\n")


# ------------------------------------------------------------------ inputs

def load_inputs(env: Mapping[str, str]) -> Inputs:
    """Validate the workflow mapping before any read or write happens."""
    def required(name: str) -> str:
        value = env.get(name)
        if not isinstance(value, str) or not value.strip():
            raise NightlyPublishError(f"{name} is missing")
        return value

    repository = required("GITHUB_REPOSITORY")
    if not REPOSITORY.fullmatch(repository):
        raise NightlyPublishError("GITHUB_REPOSITORY must be OWNER/REPO")
    commit = required("GITHUB_SHA")
    if not COMMIT.fullmatch(commit):
        raise NightlyPublishError("GITHUB_SHA must be a lowercase 40-hex commit")
    run_id = required("GITHUB_RUN_ID")
    if not RUN_ID.fullmatch(run_id):
        raise NightlyPublishError("GITHUB_RUN_ID must be a positive run id")
    run_attempt = required("GITHUB_RUN_ATTEMPT")
    if not RUN_ID.fullmatch(run_attempt):
        raise NightlyPublishError("GITHUB_RUN_ATTEMPT must be a positive attempt number")
    server_url = required("GITHUB_SERVER_URL").rstrip("/")
    if not SERVER_ORIGIN.fullmatch(server_url):
        raise NightlyPublishError("GITHUB_SERVER_URL must be an https origin")

    sdk_version = required("NIGHTLY_SDK_VERSION")
    if not NIGHTLY_SDK_VERSION.fullmatch(sdk_version):
        raise NightlyPublishError(
            "NIGHTLY_SDK_VERSION must be the full <x.y.z-alpha.NNNNNNNNNNNNNN> Nightly version")
    try:
        expected_tag = nightly_tag(sdk_version, commit)
    except ValueError as error:
        raise NightlyPublishError(str(error)) from error
    tag = required("NIGHTLY_TAG")
    if tag != expected_tag:
        raise NightlyPublishError(
            f"NIGHTLY_TAG {tag!r} does not name this SDK version and source commit")

    release_version = required("NIGHTLY_RELEASE_VERSION")
    try:
        expected_release = nightly_release_version(
            release_core(release_version), sdk_version, commit)
    except ValueError as error:
        raise NightlyPublishError(
            f"NIGHTLY_RELEASE_VERSION is not a Nightly release version: {error}") from error
    if release_version != expected_release:
        raise NightlyPublishError(
            "NIGHTLY_RELEASE_VERSION does not carry this SDK version and source commit")

    rows = parse_matrix(strict_loads(required("NIGHTLY_MATRIX"),
                                     description="Nightly matrix"),
                        sdk_version, release_version, commit)
    return Inputs(repository=repository, commit=commit, run_id=run_id,
                  run_attempt=int(run_attempt), server_url=server_url,
                  sdk_version=sdk_version, release_version=release_version,
                  tag=tag, rows=rows)


def parse_matrix(document: Any, sdk_version: str, release_version: str,
                 commit: str) -> dict[str, dict[str, str]]:
    """Require one complete, unambiguous row per supported platform."""
    if not isinstance(document, dict) or set(document) != {"include"}:
        raise NightlyPublishError("NIGHTLY_MATRIX must be an object with only an include list")
    include = document["include"]
    if not isinstance(include, list):
        raise NightlyPublishError("NIGHTLY_MATRIX include must be a list")
    rows: dict[str, dict[str, str]] = {}
    for row in include:
        if not isinstance(row, dict):
            raise NightlyPublishError("NIGHTLY_MATRIX rows must be objects")
        platform = row.get("platform")
        if not isinstance(platform, str) or platform not in PLATFORMS:
            raise NightlyPublishError("NIGHTLY_MATRIX row names an unsupported platform")
        if platform in rows:
            raise NightlyPublishError(f"NIGHTLY_MATRIX repeats platform {platform}")
        if set(row) != MATRIX_KEYS:
            raise NightlyPublishError(
                f"NIGHTLY_MATRIX row {platform} must carry exactly "
                + ",".join(sorted(MATRIX_KEYS)))
        for key in MATRIX_KEYS:
            if not isinstance(row[key], str):
                raise NightlyPublishError(f"NIGHTLY_MATRIX row {platform} has a non-string {key}")
        if not row["runner"]:
            raise NightlyPublishError(f"NIGHTLY_MATRIX row {platform} names no runner")
        if not row["unavailable_reason"]:
            for key in ("sdk_url", "stdx_url"):
                if not row[key].startswith("https://"):
                    raise NightlyPublishError(
                        f"NIGHTLY_MATRIX row {platform} {key} must be https")
            for key in ("sdk_sha256", "stdx_sha256"):
                if not SHA256.fullmatch(row[key]):
                    raise NightlyPublishError(
                        f"NIGHTLY_MATRIX row {platform} {key} must be lowercase 64-hex")
            try:
                validate_release_stdx_version(release_version, sdk_version, commit,
                                              row["stdx_version"])
            except ValueError as error:
                raise NightlyPublishError(
                    f"NIGHTLY_MATRIX row {platform} has an invalid stdx version: {error}") from error
        rows[platform] = dict(row)
    missing = [platform for platform in PLATFORMS if platform not in rows]
    if missing:
        raise NightlyPublishError(
            "NIGHTLY_MATRIX omits platform(s): " + ",".join(missing))
    return rows


def expected_assets(release_version: str, platform: str) -> tuple[str, str]:
    """The archive and its checksum sidecar, in the paired release convention."""
    extension = ".zip" if platform.startswith("windows-") else ".tar.gz"
    archive = f"cjdoc-{release_version}-{platform}{extension}"
    return archive, f"{archive}.sha256"


def parse_sidecar(content: bytes, description: str) -> tuple[str, str]:
    """Return (digest, archive name) from one `<digest>  <name>\\n` sidecar."""
    try:
        text = content.decode("ascii")
    except UnicodeDecodeError as error:
        raise NightlyPublishError(f"{description} is not ASCII") from error
    match = CHECKSUM_LINE.fullmatch(text)
    if match is None:
        raise NightlyPublishError(f"{description} is not '<sha256>  <archive>'")
    return match.group(1), match.group(2)


# ------------------------------------------------------------------ GitHub

def _split_include(text: str) -> tuple[int | None, str]:
    """Split one `gh api --include` response into (status, body)."""
    parts = re.split(r"\r?\n\r?\n", text, maxsplit=1)
    statuses = re.findall(r"(?m)^HTTP/[0-9.]+ ([0-9]{3})", parts[0])
    body = parts[1] if len(parts) > 1 else ""
    return (int(statuses[-1]) if statuses else None), body


class Gh:
    """The `gh` CLI, with 404 kept distinct from every other failure."""

    def __init__(self, timeout: int = 120, *, token: str | None = None) -> None:
        self.timeout = timeout
        self.environment = None if token is None else {**os.environ, "GH_TOKEN": token}

    def _run(self, argv: list[str], payload: bytes | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(argv, input=payload, capture_output=True,
                              check=False, env=self.environment, timeout=self.timeout)

    def _request(self, method: str, path: str,
                 body: dict[str, object] | None = None) -> Any:
        argv = ["gh", "api", "--include", "--method", method, path]
        payload = None
        if body is not None:
            argv += ["--header", "Content-Type: application/json", "--input", "-"]
            payload = json.dumps(body, ensure_ascii=True,
                                 separators=(",", ":")).encode("utf-8")
        completed = self._run(argv, payload)
        stderr = completed.stderr.decode("utf-8", "replace").strip()
        stdout = completed.stdout.decode("utf-8", "replace")
        status, text = _split_include(stdout)
        if status is None:
            match = re.search(r"HTTP ([0-9]{3})", stderr)
            status = int(match.group(1)) if match else None
        if status is None:
            raise ApiError(0, f"gh api {method} {path} failed: {(stderr or stdout)[:400]}")
        if status == 404:
            raise ApiMissing(f"gh api {method} {path} is missing")
        if not 200 <= status < 300:
            raise ApiError(status, f"gh api {method} {path} failed: HTTP {status}: {stderr[:400]}")
        if not text.strip():
            return None
        try:
            return strict_loads(text, description=f"GitHub API response for {path}")
        except ValueError as error:
            raise ApiError(status, f"gh api {method} {path} returned invalid JSON") from error

    def json(self, path: str) -> dict[str, Any]:
        value = self._request("GET", path)
        if not isinstance(value, dict):
            raise ApiError(0, f"gh api {path} did not return an object")
        return value

    def raw(self, path: str) -> bytes:
        completed = self._run(["gh", "api", path,
                               "--header", "Accept: application/octet-stream"])
        if completed.returncode != 0:
            stderr = completed.stderr.decode("utf-8", "replace").strip()
            match = re.search(r"HTTP ([0-9]{3})", stderr)
            status = int(match.group(1)) if match else 0
            if status == 404:
                raise ApiMissing(f"gh api {path} is missing")
            raise ApiError(status, f"gh api {path} failed: {(stderr or 'no output')[:400]}")
        return completed.stdout

    def send(self, method: str, path: str,
             body: dict[str, object] | None = None) -> Any:
        return self._request(method, path, body)

    def upload(self, repository: str, tag: str, path: Path) -> None:
        completed = self._run(["gh", "release", "upload", tag, str(path),
                               "--repo", repository])
        if completed.returncode != 0:
            stderr = completed.stderr.decode("utf-8", "replace").strip()
            raise ApiError(0, f"gh release upload {path.name} failed: {(stderr or 'no output')[:400]}")


def remote_request(api: Any):
    """Adapt the API to `verify_remote_tag`'s request callable."""
    def request(path: str) -> dict[str, Any]:
        try:
            return api.json(path)
        except NightlyPublishError as error:
            raise ValueError(str(error)) from error
    return request


def tag_commit(api: Any, repository: str, tag: str) -> str | None:
    """Peel the live tag to a commit, or return None when it does not exist."""
    class _MissingTag(Exception):
        pass

    def request(path: str) -> dict[str, Any]:
        try:
            return api.json(path)
        except ApiMissing as error:
            raise _MissingTag(str(error)) from error
        except NightlyPublishError as error:
            raise ValueError(str(error)) from error

    try:
        return resolve_remote_tag(repository, tag, request)
    except _MissingTag:
        return None


def _release_document(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NightlyPublishError("GitHub release response is not an object")
    if type(value.get("id")) is not int or value["id"] <= 0:
        raise NightlyPublishError("GitHub release response omits a positive id")
    if not isinstance(value.get("tag_name"), str) or not value["tag_name"]:
        raise NightlyPublishError("GitHub release response omits its tag")
    if not isinstance(value.get("draft"), bool):
        raise NightlyPublishError("GitHub release response omits its draft flag")
    if not isinstance(value.get("prerelease"), bool):
        raise NightlyPublishError("GitHub release response omits its prerelease flag")
    return value


def get_release_by_tag(api: Any, repository: str, tag: str) -> dict[str, Any] | None:
    try:
        value = api.json(f"repos/{repository}/releases/tags/{quote(tag, safe='')}")
    except ApiMissing:
        return None
    return _release_document(value)


def get_release(api: Any, repository: str, release_id: int) -> dict[str, Any]:
    return _release_document(api.json(f"repos/{repository}/releases/{release_id}"))


def release_assets(release: dict[str, Any], *,
                   starter_ids: list[int] | None = None) -> dict[str, dict[str, Any]]:
    """Validate uploaded assets; only draft recovery may collect empty starters."""
    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise NightlyPublishError("GitHub release response omits its asset list")
    assets: dict[str, dict[str, Any]] = {}
    seen_names: set[str] = set()
    seen_ids: set[int] = set()
    for asset in raw_assets:
        if not isinstance(asset, dict):
            raise NightlyPublishError("GitHub release asset entry is malformed")
        name = asset.get("name")
        asset_id = asset.get("id")
        size = asset.get("size")
        if not isinstance(name, str) or not name:
            raise NightlyPublishError("GitHub release asset omits its name")
        if type(asset_id) is not int or asset_id <= 0:
            raise NightlyPublishError(f"GitHub release asset {name} omits a positive id")
        if type(size) is not int or size < 0:
            raise NightlyPublishError(f"GitHub release asset {name} omits its size")
        if name in seen_names or asset_id in seen_ids:
            raise NightlyPublishError(f"GitHub release repeats asset {name}")
        seen_names.add(name)
        seen_ids.add(asset_id)
        # GitHub can leave an empty starter asset after a failed upload (HTTP 502).
        if starter_ids is not None and release.get("draft") is True \
                and asset.get("state") == "starter" and size == 0 \
                and asset.get("digest") in (None, ""):
            starter_ids.append(asset_id)
            continue
        if asset.get("state") != "uploaded":
            raise NightlyPublishError(
                f"GitHub release asset {name} is not in the uploaded state")
        match = ASSET_DIGEST.fullmatch(str(asset.get("digest") or ""))
        if match is None:
            raise NightlyPublishError(
                f"GitHub release asset {name} publishes no SHA-256 digest")
        assets[name] = {"id": asset_id, "size": size, "sha256": match.group(1)}
    return assets


def asset_endpoint(repository: str, asset_id: int) -> str:
    return f"repos/{repository}/releases/assets/{asset_id}"


def verify_public_release(api: Any, inputs: Inputs,
                          release: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Verify one public release against this exact identity.

    Returns the remote asset map (name -> {sha256, size}) so the caller can
    compare it with what it is about to publish.
    """
    release = _release_document(release)
    if release["tag_name"] != inputs.tag:
        raise NightlyPublishError(
            f"public release is tagged {release['tag_name']!r}, not {inputs.tag!r}")
    if release["draft"] is not False:
        raise NightlyPublishError("a draft release is not a published Nightly")
    if release["prerelease"] is not True:
        raise NightlyPublishError("public Nightly release is not a prerelease")
    if release.get("immutable") is not True:
        raise NightlyPublishError(
            "public Nightly release is not immutable, so its assets may have changed")
    verify_remote_tag(inputs.repository, inputs.tag, inputs.commit,
                      request=remote_request(api))

    assets = release_assets(release)
    # The published name space is the supported platform set, not this run's
    # availability: a release that appeared earlier may legitimately carry a
    # platform today's matrix row cannot build.
    expected = {name for platform in PLATFORMS
                for name in expected_assets(inputs.release_version, platform)}
    unknown = set(assets) - expected
    if unknown:
        raise NightlyPublishError(
            "public Nightly release carries unexpected assets: " + ",".join(sorted(unknown)))
    if not assets:
        raise NightlyPublishError("public Nightly release publishes no assets")

    # Every asset must belong to a complete pair, so a bare archive can never
    # ride along beside one valid pair.
    for name in assets:
        if name.endswith(".sha256"):
            if name[:-len(".sha256")] not in assets:
                raise NightlyPublishError(
                    f"public Nightly release publishes {name} without "
                    f"{name[:-len('.sha256')]}")
        elif f"{name}.sha256" not in assets:
            raise NightlyPublishError(
                f"public Nightly release publishes {name} without {name}.sha256")

    digests: dict[str, dict[str, Any]] = {}
    for name, asset in assets.items():
        digests[name] = {"sha256": asset["sha256"], "size": asset["size"]}
        if not name.endswith(".sha256"):
            continue
        archive_name = name[:-len(".sha256")]
        content = api.raw(asset_endpoint(inputs.repository, asset["id"]))
        if hashlib.sha256(content).hexdigest() != asset["sha256"]:
            raise NightlyPublishError(f"public checksum sidecar {name} changed after upload")
        recorded_digest, recorded_name = parse_sidecar(
            content, f"public checksum sidecar {name}")
        if recorded_name != archive_name:
            raise NightlyPublishError(
                f"public checksum sidecar {name} names {recorded_name!r}")
        if assets[archive_name]["sha256"] != recorded_digest:
            raise NightlyPublishError(
                f"public checksum sidecar {name} does not match {archive_name}")
    return digests


def existing_public_release(api: Any, inputs: Inputs
                            ) -> tuple[dict[str, Any] | None, dict[str, dict[str, Any]]]:
    """Return the verified public release for this tag, or None when absent."""
    release = get_release_by_tag(api, inputs.repository, inputs.tag)
    if release is None or release["draft"] is True:
        return None, {}
    return release, verify_public_release(api, inputs, release)


# ------------------------------------------------------------------ status

def status(env: Mapping[str, str], api: Any | None = None) -> dict[str, Any]:
    inputs = load_inputs(env)
    client = Gh() if api is None else api
    release, digests = existing_public_release(client, inputs)
    existing = release is not None
    output = env.get("GITHUB_OUTPUT")
    if isinstance(output, str) and output:
        append_output(Path(output), "existing", "true" if existing else "false")
    return {"existing": existing, "tag": inputs.tag, "assets": sorted(digests)}


# ------------------------------------------------------------------ publish

def attempt_jobs(api: Any, inputs: Inputs) -> dict[str, dict[str, Any]]:
    """Require exactly one terminal candidate job per platform in this attempt."""
    path = (f"repos/{inputs.repository}/actions/runs/{inputs.run_id}"
            f"/attempts/{inputs.run_attempt}/jobs")
    jobs: list[dict[str, Any]] = []
    page = 1
    while True:
        document = api.json(f"{path}?per_page=100&page={page}")
        if not isinstance(document, dict):
            raise NightlyPublishError("Actions jobs response is not an object")
        batch = document.get("jobs")
        total = document.get("total_count")
        if not isinstance(batch, list) or type(total) is not int:
            raise NightlyPublishError("Actions jobs response omits its job list")
        jobs.extend(item for item in batch if isinstance(item, dict))
        if len(jobs) >= total or not batch:
            break
        page += 1
        if page > MAX_PAGES:
            raise NightlyPublishError("Actions jobs listing exceeds the page limit")
    by_platform: dict[str, dict[str, Any]] = {}
    for job in jobs:
        name = job.get("name")
        for platform in PLATFORMS:
            if name != JOB_NAME.format(platform=platform):
                continue
            if platform in by_platform:
                raise NightlyPublishError(
                    f"this run attempt lists more than one {name} job")
            if job.get("status") != "completed":
                raise NightlyPublishError(
                    f"{name} is not terminal in this run attempt")
            if job.get("conclusion") not in {
                    "success", "failure", "cancelled", "skipped", "timed_out",
                    "action_required", "neutral", "stale"}:
                raise NightlyPublishError(f"{name} has no terminal conclusion")
            by_platform[platform] = job
    missing = [platform for platform in PLATFORMS if platform not in by_platform]
    if missing:
        raise NightlyPublishError(
            "this run attempt has no " + ", ".join(JOB_NAME.format(platform=platform)
                                                   for platform in missing) + " job")
    return by_platform


def successful_platforms(jobs: dict[str, dict[str, Any]]) -> list[str]:
    successes = [platform for platform in PLATFORMS
                 if jobs[platform].get("conclusion") == "success"]
    if not successes:
        raise NightlyPublishError(
            "no platform candidate succeeded in this run attempt, so nothing is published")
    return successes


def collect_artifacts(root: Path, inputs: Inputs,
                      successes: list[str]) -> dict[str, Path]:
    """Require the downloaded artifact set to be exactly the successful platforms."""
    if not root.is_dir() or root.is_symlink():
        raise NightlyPublishError(f"Nightly asset root is not a directory: {root}")
    expected = {ARTIFACT_NAME.format(platform=platform, run_id=inputs.run_id,
                                     run_attempt=inputs.run_attempt): platform
                for platform in successes}
    observed: dict[str, Path] = {}
    for entry in root.iterdir():
        if entry.name not in expected:
            raise NightlyPublishError(
                f"unknown Nightly artifact entry may not be published: {entry.name}")
        if entry.is_symlink() or not entry.is_dir():
            raise NightlyPublishError(f"Nightly artifact {entry.name} is not a directory")
        observed[entry.name] = entry
    missing = sorted(set(expected) - set(observed))
    if missing:
        raise NightlyPublishError(
            "successful platform artifact is missing: " + ",".join(missing))
    return {platform: observed[ARTIFACT_NAME.format(
                platform=platform, run_id=inputs.run_id,
                run_attempt=inputs.run_attempt)]
            for platform in successes}


def validate_receipt(receipt: Any, *, platform: str, inputs: Inputs, tree: str,
                     row: dict[str, str]) -> None:
    """Bind the embedded receipt to this run, source tree and toolchain."""
    if not isinstance(receipt, dict) or receipt.get("schemaVersion") != RECEIPT_SCHEMA:
        raise NightlyPublishError(f"{platform}: unexpected release candidate receipt schema")
    source = receipt.get("source")
    if not isinstance(source, dict):
        raise NightlyPublishError(f"{platform}: receipt omits its source identity")
    if source.get("tag") != inputs.tag:
        raise NightlyPublishError(f"{platform}: receipt is for a different tag")
    if source.get("commit") != inputs.commit:
        raise NightlyPublishError(f"{platform}: receipt is for a different source commit")
    if source.get("tree") != tree:
        raise NightlyPublishError(f"{platform}: receipt is for a different source tree")
    if source.get("releaseVersion") != inputs.release_version:
        raise NightlyPublishError(f"{platform}: receipt is for a different release version")
    if source.get("dirty") is not False:
        raise NightlyPublishError(f"{platform}: receipt was produced from a dirty worktree")

    execution = receipt.get("execution")
    if not isinstance(execution, dict):
        raise NightlyPublishError(f"{platform}: receipt omits its execution identity")
    if str(execution.get("runId")) != inputs.run_id:
        raise NightlyPublishError(f"{platform}: receipt is from a different run")
    if type(execution.get("runAttempt")) is not int or \
            execution["runAttempt"] != inputs.run_attempt:
        raise NightlyPublishError(f"{platform}: receipt is from a different run attempt")
    if execution.get("job") != CANDIDATE_JOB:
        raise NightlyPublishError(f"{platform}: receipt is not from the candidate job")

    declared = receipt.get("platform")
    if not isinstance(declared, dict) or declared.get("id") != platform:
        raise NightlyPublishError(f"{platform}: receipt declares a different platform")

    toolchain = receipt.get("toolchain")
    if not isinstance(toolchain, dict):
        raise NightlyPublishError(f"{platform}: receipt omits its toolchain")
    expected = {"sdkVersion": inputs.sdk_version,
                "sdkArchiveSha256": row["sdk_sha256"],
                "stdxVersion": row["stdx_version"],
                "stdxArchiveSha256": row["stdx_sha256"]}
    for key, value in expected.items():
        if toolchain.get(key) != value:
            raise NightlyPublishError(
                f"{platform}: receipt {key} does not match this Nightly toolchain")

    gates = receipt.get("gates")
    if not isinstance(gates, dict):
        raise NightlyPublishError(f"{platform}: receipt omits its accepted gates")
    for name, digest in gates.items():
        if not isinstance(name, str) or not SHA256.fullmatch(str(digest)):
            raise NightlyPublishError(f"{platform}: receipt gate {name} has no SHA-256 digest")
    # Every accepted platform records the stage evidence it ran, so its digest is
    # the necessary binding to the gates behind the receipt.
    if "stages.json" not in gates:
        raise NightlyPublishError(f"{platform}: receipt omits the stages.json acceptance evidence")
    if platform == "linux-x64" and "real-repository.json" not in gates:
        raise NightlyPublishError(
            "linux-x64: receipt omits the accepted real-repository smoke gate")


def validate_platform(directory: Path, platform: str, inputs: Inputs,
                      tree: str, repo: Path) -> tuple[str, int]:
    """Verify one platform's package bytes and return (sha256, size).

    The archive is inspected, never executed: `inspect_archive` and
    `verify_repository_payload` read members and compare them with the exact
    source tree, so a substituted or hand-edited package cannot pass.
    """
    row = inputs.rows[platform]
    archive_name, checksum_name = expected_assets(inputs.release_version, platform)
    entries: dict[str, Path] = {}
    for entry in directory.iterdir():
        if entry.name not in (archive_name, checksum_name):
            raise NightlyPublishError(
                f"{platform}: unexpected file in the candidate artifact: {entry.name}")
        regular_file(entry, f"{platform} candidate asset")
        entries[entry.name] = entry
    missing = [name for name in (archive_name, checksum_name) if name not in entries]
    if missing:
        raise NightlyPublishError(f"{platform}: candidate asset is missing: " + ",".join(missing))

    recorded_digest, recorded_name = parse_sidecar(
        entries[checksum_name].read_bytes(), f"{platform} checksum sidecar")
    if recorded_name != archive_name:
        raise NightlyPublishError(
            f"{platform}: checksum sidecar names {recorded_name!r}, not {archive_name!r}")
    archive = entries[archive_name]
    digest = sha256_file(archive)
    if digest != recorded_digest:
        raise NightlyPublishError(f"{platform}: checksum sidecar does not match the archive")

    manifest, members, _ = inspect_archive(
        archive, platform, inputs.release_version, inputs.sdk_version,
        row["sdk_sha256"], inputs.commit, row["stdx_version"], row["stdx_sha256"])
    verify_repository_payload(members, repo, inputs.commit)
    if manifest.get("releaseTag") != inputs.tag:
        raise NightlyPublishError(f"{platform}: package manifest names a different tag")
    if manifest.get("sourceTree") != tree:
        raise NightlyPublishError(f"{platform}: package manifest names a different source tree")
    receipt_member = members.get(RECEIPT_MEMBER)
    if receipt_member is None or receipt_member.content is None:
        raise NightlyPublishError(f"{platform}: package omits its candidate receipt")
    receipt = strict_loads(receipt_member.content,
                           description=f"{platform} release candidate receipt")
    validate_receipt(receipt, platform=platform, inputs=inputs, tree=tree, row=row)
    return digest, archive.lstat().st_size


def release_title(inputs: Inputs) -> str:
    return f"cjdoc Nightly {inputs.sdk_version} ({inputs.commit[:12]})"


def release_notes(inputs: Inputs, successes: list[str],
                  jobs: dict[str, dict[str, Any]]) -> str:
    """Notes that name the resolved SDK, the source, the run and every platform."""
    lines = [
        DRAFT_MARKER,
        "",
        f"cjdoc built against Cangjie Nightly SDK `{inputs.sdk_version}`.",
        "",
        f"- SDK: `{inputs.sdk_version}`",
        f"- Source commit: `{inputs.commit}`",
        f"- Actions run: {inputs.actions_url}",
        "",
        "## Platforms",
        "",
    ]
    for platform in PLATFORMS:
        row = inputs.rows[platform]
        if platform in successes:
            archive, checksum = expected_assets(inputs.release_version, platform)
            lines.append(f"- `{platform}`: published `{archive}` with `{checksum}`")
        elif row["unavailable_reason"]:
            lines.append(f"- `{platform}`: unavailable ({row['unavailable_reason']})")
        else:
            lines.append(f"- `{platform}`: not published "
                         f"(job conclusion `{jobs[platform].get('conclusion')}`)")
    lines += [
        "",
        "This prerelease records one exact source commit and SDK. "
        "An already published partial release does not gain new assets.",
        "",
    ]
    return "\n".join(lines)


def require_owned_draft(api: Any, inputs: Inputs, release: dict[str, Any]) -> dict[str, Any]:
    """Re-read a draft and prove it is this workflow's, at this exact tag."""
    release = _release_document(release)
    if release["draft"] is not True:
        raise NightlyPublishError(
            "the Nightly release is already public; a public release is never modified")
    if release["tag_name"] != inputs.tag:
        raise NightlyPublishError("draft release is for a different tag")
    if release["prerelease"] is not True:
        raise NightlyPublishError("draft Nightly release is not a prerelease")
    body = release.get("body")
    if not isinstance(body, str) or DRAFT_MARKER not in body:
        raise NightlyPublishError(
            "draft release is not owned by this workflow, so its assets are left alone")
    verify_remote_tag(inputs.repository, inputs.tag, inputs.commit,
                      request=remote_request(api))
    return release


def ensure_tag(api: Any, inputs: Inputs) -> None:
    """Make the exact nightly tag resolve to the source commit before any release write."""
    if not inputs.tag.startswith("nightly-"):
        raise NightlyPublishError("Nightly publication requires an explicit nightly- tag")
    existing = tag_commit(api, inputs.repository, inputs.tag)
    if existing is None:
        try:
            api.send("POST", f"repos/{inputs.repository}/git/refs",
                     {"ref": f"refs/tags/{inputs.tag}", "sha": inputs.commit})
        except ApiError as error:
            if error.status not in (409, 422):
                raise
            # A concurrent run may have created the same tag; fall through to
            # the read-back, which still has to name this exact commit.
        existing = tag_commit(api, inputs.repository, inputs.tag)
    if existing != inputs.commit:
        raise NightlyPublishError(
            f"live tag {inputs.tag} resolves to {existing or 'nothing'}, "
            f"not the source commit {inputs.commit}")
    verify_remote_tag(inputs.repository, inputs.tag, inputs.commit,
                      request=remote_request(api))


def check_immutable_repository(api: Any, repository: str) -> None:
    """Fail before any mutation unless GitHub confirms the setting."""
    try:
        document = api.json(f"repos/{repository}/immutable-releases")
    except ApiError as error:
        if error.status in (401, 403, 404):
            raise NightlyPublishError(
                "cannot read the immutable releases setting; configure the "
                "NIGHTLY_RELEASE_SETTINGS_TOKEN secret with repository Administration: read"
            ) from error
        raise
    if document.get("enabled") is not True and document.get("enforced_by_owner") is not True:
        raise NightlyPublishError("immutable releases are disabled for this repository")


def lookup_release_for_write(api: Any, inputs: Inputs) -> dict[str, Any] | None:
    # REST's release-by-tag lookup only sees published releases.
    owner, name = inputs.repository.split("/")
    query = """
        query($owner: String!, $name: String!, $tag: String!) {
          repository(owner: $owner, name: $name) {
            release(tagName: $tag) { databaseId }
          }
        }
    """
    response = api.send("POST", "graphql", {
        "query": query, "variables": {"owner": owner, "name": name, "tag": inputs.tag},
    })
    if not isinstance(response, dict) or response.get("errors"):
        raise NightlyPublishError("GitHub could not look up the Nightly draft")
    data = response.get("data")
    repository = data.get("repository") if isinstance(data, dict) else None
    if not isinstance(repository, dict) or "release" not in repository:
        raise NightlyPublishError("GitHub omitted the Nightly draft lookup result")
    match = repository["release"]
    if match is None:
        return None
    release_id = match.get("databaseId") if isinstance(match, dict) else None
    if type(release_id) is not int or release_id <= 0:
        raise NightlyPublishError("GitHub draft lookup returned an invalid release ID")
    return get_release(api, inputs.repository, release_id)


def create_draft(api: Any, inputs: Inputs) -> dict[str, Any]:
    body = {
        "tag_name": inputs.tag,
        "target_commitish": inputs.commit,
        "name": release_title(inputs),
        "body": DRAFT_MARKER + "\n",
        "draft": True,
        "prerelease": True,
        "generate_release_notes": False,
    }
    try:
        created = api.send("POST", f"repos/{inputs.repository}/releases", body)
    except ApiError as error:
        if error.status != 422:
            raise
        # A release for this tag appeared concurrently. It is only usable if it
        # is a workflow-owned draft, which the caller checks.
        existing = lookup_release_for_write(api, inputs)
        if existing is None:
            raise NightlyPublishError(
                "GitHub refused to create the Nightly draft and none is visible") from error
        return _release_document(existing)
    return _release_document(created)


def reconcile_assets(api: Any, inputs: Inputs, release: dict[str, Any],
                     local: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Upload only verified assets and remove only workflow-owned stale ones."""
    release_id = release["id"]
    released = require_owned_draft(api, inputs, get_release(api, inputs.repository, release_id))
    starters: list[int] = []
    current = release_assets(released, starter_ids=starters)
    for asset_id in starters:
        api.send("DELETE", asset_endpoint(inputs.repository, asset_id))
    # A previous, interrupted attempt can leave assets with older digests for
    # the same source and SDK. They are only touched on a draft proven above.
    for name in sorted(set(current) - set(local)):
        api.send("DELETE", asset_endpoint(inputs.repository, current[name]["id"]))
        del current[name]
    released = require_owned_draft(api, inputs, get_release(api, inputs.repository, release_id))
    current = release_assets(released)
    for name in sorted(local):
        wanted = local[name]
        if name in current and current[name]["sha256"] == wanted["sha256"] \
                and current[name]["size"] == wanted["size"]:
            continue
        if name in current:
            api.send("DELETE", asset_endpoint(inputs.repository, current[name]["id"]))
            del current[name]
        api.upload(inputs.repository, inputs.tag, wanted["path"])
    released = require_owned_draft(api, inputs, get_release(api, inputs.repository, release_id))
    current = release_assets(released)
    if set(current) != set(local):
        raise NightlyPublishError(
            "remote Nightly assets do not match the verified set after upload")
    for name, wanted in local.items():
        if current[name]["sha256"] != wanted["sha256"] or \
                current[name]["size"] != wanted["size"]:
            raise NightlyPublishError(
                f"remote Nightly asset {name} does not match the verified bytes")
    return released


def publish(assets_root: Path, *, env: Mapping[str, str], api: Any | None = None,
            repo: Path | None = None, sleep=time.sleep) -> dict[str, Any]:
    inputs = load_inputs(env)
    client = Gh() if api is None else api
    source = Path.cwd() if repo is None else repo
    identity = exact_worktree_identity(source, inputs.commit)
    tree = str(identity["tree"])

    jobs = attempt_jobs(client, inputs)
    successes = successful_platforms(jobs)
    directories = collect_artifacts(assets_root, inputs, successes)
    verified = {platform: validate_platform(directories[platform], platform, inputs, tree,
                                            source)
                for platform in successes}

    local: dict[str, dict[str, Any]] = {}
    for platform in successes:
        archive_name, checksum_name = expected_assets(inputs.release_version, platform)
        archive_digest, archive_size = verified[platform]
        checksum = directories[platform] / checksum_name
        local[archive_name] = {"path": directories[platform] / archive_name,
                               "sha256": archive_digest, "size": archive_size}
        local[checksum_name] = {"path": checksum, "sha256": sha256_file(checksum),
                                "size": checksum.lstat().st_size}

    summary: dict[str, Any] = {"tag": inputs.tag, "available": successes,
                               "missing": {platform: (
                                   inputs.rows[platform]["unavailable_reason"]
                                   or f"job conclusion {jobs[platform].get('conclusion')}")
                                   for platform in PLATFORMS if platform not in successes}}

    existing, digests = existing_public_release(client, inputs)
    if existing is not None:
        if _same_assets(digests, local):
            return {"status": "unchanged", **summary}
        raise NightlyPublishError(
            "a public Nightly release already exists for this tag with different "
            "assets; it is never modified")

    settings_token = env.get("NIGHTLY_RELEASE_SETTINGS_TOKEN")
    settings_client = Gh(token=settings_token) if api is None and settings_token else client
    check_immutable_repository(settings_client, inputs.repository)
    # Re-check immediately before the first mutation: another run may have
    # published between the two reads.
    if existing_public_release(client, inputs)[0] is not None:
        raise NightlyPublishError(
            "a public Nightly release appeared before publication; it is never modified")

    release = lookup_release_for_write(client, inputs)
    if release is None:
        ensure_tag(client, inputs)
        release = create_draft(client, inputs)
    require_owned_draft(client, inputs, release)

    notes = release_notes(inputs, successes, jobs)
    release = reconcile_assets(client, inputs, release, local)
    require_owned_draft(client, inputs, release)
    client.send("PATCH", f"repos/{inputs.repository}/releases/{release['id']}",
                {"draft": False, "prerelease": True, "make_latest": "false",
                 "body": notes, "name": release_title(inputs)})

    published = None
    for attempt in range(4):
        published = get_release_by_tag(client, inputs.repository, inputs.tag)
        if published is not None and published["draft"] is False and \
                published.get("immutable") is True:
            break
        if attempt < 3:
            sleep(1.0)
    if published is None:
        raise NightlyPublishError("the published Nightly release is not visible")
    digests = verify_public_release(client, inputs, published)
    if not _same_assets(digests, local):
        raise NightlyPublishError(
            "the published Nightly release does not match the verified assets")
    return {"status": "published", **summary}


def _same_assets(remote: dict[str, dict[str, Any]],
                 local: dict[str, dict[str, Any]]) -> bool:
    if set(remote) != set(local):
        return False
    return all(remote[name]["sha256"] == local[name]["sha256"] and
               remote[name]["size"] == local[name]["size"] for name in local)


# ------------------------------------------------------------------ CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    modes = parser.add_subparsers(dest="mode", required=True)
    modes.add_parser("status", help="report whether this exact Nightly is public")
    publishing = modes.add_parser("publish", help="verify and publish this attempt")
    publishing.add_argument("--assets", type=Path, required=True,
                            help="downloaded nightly-<platform>-<run>-<attempt> root")
    args = parser.parse_args(argv)
    try:
        if args.mode == "status":
            document = status(os.environ)
        else:
            document = publish(args.assets, env=os.environ)
    except (NightlyPublishError, ValueError, OSError) as error:
        print("Nightly publication failed: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(document, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
