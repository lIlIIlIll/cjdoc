#!/usr/bin/env python3
"""Resolve the exact Cangjie Nightly SDK and stdx inputs for one source commit.

Two upstream documents are read, and each answers exactly one question:

* the version manifest names the newest Nightly version, so an unpinned run has
  something to freeze on;
* the GitCode release for that exact version lists the assets, and each asset's
  `digest` is the only SHA-256 this tool will trust.

Nothing else is taken on faith. The version comes from the manifest (or the
explicit pin), the archive names are computed from the pinned version instead of
being read back, and the download URL is the pinned GitCode namespace joined
with that name. An asset that only matches by accident -- a sanitizer build, the
Windows installer, a previous Nightly -- is therefore never selected.

A platform whose SDK or stdx archive cannot be pinned is reported as
`unavailable_reason` in its matrix row rather than failing the whole resolution:
one platform missing its stdx build must not hide the platform that has one.
Everything that would make the run's identity wrong -- a malformed manifest or
release document, a release tagged as something other than the requested
version, a draft release, a malformed commit or version -- fails closed.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable
import urllib.request

sys.dont_write_bytecode = True

try:
    from .package_release import committed_package_version
    from .release_package_contracts import (
        NIGHTLY_SDK_VERSION,
        nightly_release_version,
        nightly_tag,
    )
    from .strict_json import strict_loads
except ImportError:  # Direct script execution.
    from package_release import committed_package_version
    from release_package_contracts import (
        NIGHTLY_SDK_VERSION,
        nightly_release_version,
        nightly_tag,
    )
    from strict_json import strict_loads


MANIFEST_URL = "https://raw.githubusercontent.com/Zxilly/cangjie-version-manifest/master/nightly.json"
RELEASE_URL = "https://api.gitcode.com/api/v5/repos/Cangjie/nightly_build/releases/tags/{version}"
# The only download namespace trusted for an archive: the release page of the
# exact version. A response that points anywhere else leaves its platform
# unavailable instead of redirecting the build somewhere unverified.
DOWNLOAD_NAMESPACE = "https://gitcode.com/Cangjie/nightly_build/releases/download"
MAX_MANIFEST_BYTES = 8 * 1024 * 1024
MAX_RELEASE_BYTES = 4 * 1024 * 1024
REQUEST_TIMEOUT_SECONDS = 30
# Transport failures are retried; malformed content is not, because the same
# bytes would be decoded the same way a second time.
RETRY_DELAYS = (1.0, 2.0)
SHA256_DIGEST = re.compile(r"sha256:([0-9a-f]{64})")
# A stdx component revision always starts at 1, matching the release contracts:
# `<sdk version>.<revision>` identifies a rebuild of the same SDK version.
STDX_REVISION = r"([1-9][0-9]*)"


class NightlyError(Exception):
    """The Nightly inputs cannot be frozen, so no candidate may be produced."""


@dataclass(frozen=True)
class Platform:
    """One supported cjdoc platform and the base names its archives use."""

    platform: str  # matrix id, and the id release receipts carry
    runner: str
    native: str  # platform token inside the native SDK archive name
    stdx: str  # platform token inside the stdx archive name
    suffix: str  # archive extension of the native SDK


PLATFORMS = (
    Platform("linux-x64", "ubuntu-22.04", "linux-x64", "linux-x64", ".tar.gz"),
    Platform("windows-x64", "windows-2022", "windows-x64", "windows-x64", ".zip"),
    Platform("macos-arm64", "macos-15", "mac-aarch64", "mac-aarch64", ".tar.gz"),
)

MatrixRow = dict[str, str]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse redirects outright: the exact allowlisted URL is the only source."""

    def redirect_request(self, req: urllib.request.Request, fp: Any, code: int,
                         msg: str, headers: Any, newurl: str) -> None:
        raise NightlyError("upstream metadata redirects are forbidden")


def fetch_bytes(url: str, limit: int) -> bytes:
    """Read one bounded upstream document from its exact allowlisted URL."""
    # Ignore environment proxies: only the exact public host is read, and only
    # the exact URL is accepted, so a rewritten request cannot be served.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    request = urllib.request.Request(url, headers={
        "User-Agent": "cjdoc-nightly-sdk/1",
        "Accept": "application/json",
        "Accept-Encoding": "identity",
    })
    with opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        if response.status != 200 or response.geturl() != url:
            raise NightlyError(
                "upstream metadata answered something other than the requested document")
        if response.headers.get("Content-Encoding", "identity") != "identity":
            raise NightlyError("encoded upstream metadata is forbidden")
        payload = response.read(limit + 1)
    if len(payload) > limit:
        raise NightlyError("upstream metadata exceeds the size bound")
    return payload


Fetcher = Callable[[str, int], bytes]


def _decode(payload: bytes, description: str) -> Any:
    try:
        return strict_loads(payload, description=description)
    except ValueError as error:
        raise NightlyError(str(error)) from error


def _fetch_json(url: str, limit: int, fetch: Fetcher, description: str) -> Any:
    failure: OSError | None = None
    for attempt in range(len(RETRY_DELAYS) + 1):
        if attempt:
            time.sleep(RETRY_DELAYS[attempt - 1])
        try:
            payload = fetch(url, limit)
        # HTTPError, URLError and socket failures are all OSError subclasses.
        except OSError as error:
            failure = error
            continue
        if not isinstance(payload, (bytes, bytearray)):
            raise NightlyError(f"{description} is not a byte document")
        if len(payload) > limit:
            raise NightlyError(f"{description} exceeds the size bound")
        return _decode(bytes(payload), description)
    raise NightlyError(f"cannot read {description}: {type(failure).__name__}")


def manifest_latest(manifest: Any) -> str:
    """Return the newest Nightly version the upstream manifest names."""
    if not isinstance(manifest, dict):
        raise NightlyError("upstream Nightly manifest is not an object")
    versions = manifest.get("versions")
    if not isinstance(versions, dict):
        raise NightlyError("upstream Nightly manifest omits its version table")
    latest = manifest.get("latest")
    if not isinstance(latest, str) or not NIGHTLY_SDK_VERSION.fullmatch(latest):
        raise NightlyError("upstream Nightly manifest latest is not a full Nightly SDK version")
    if latest not in versions:
        raise NightlyError("upstream Nightly manifest latest is not one of its versions")
    return latest


def sdk_archive_name(platform: Platform, sdk_version: str) -> str:
    """The one native SDK archive a Nightly release publishes for a platform."""
    return f"cangjie-sdk-{platform.native}-{sdk_version}{platform.suffix}"


def stdx_archive_pattern(platform: Platform, sdk_version: str) -> re.Pattern[str]:
    """The stdx archive for a platform, with its component revision captured.

    The revision is part of the name, so a rebuild of the same Nightly version is
    a different archive and must be matched rather than assumed.
    """
    return re.compile(
        rf"cangjie-stdx-{re.escape(platform.stdx)}-{re.escape(sdk_version)}\."
        rf"{STDX_REVISION}\.zip"
    )


def download_url(sdk_version: str, name: str) -> str:
    """The pinned release URL for one archive of one exact Nightly version."""
    return f"{DOWNLOAD_NAMESPACE}/{sdk_version}/{name}"


def _release_assets(document: Any, sdk_version: str) -> list[dict[str, Any]]:
    if not isinstance(document, dict):
        raise NightlyError("upstream Nightly release is not an object")
    tag = document.get("tag_name")
    if not isinstance(tag, str) or tag != sdk_version:
        raise NightlyError("upstream Nightly release is tagged for a different version")
    if document.get("draft"):
        raise NightlyError("upstream Nightly release is a draft")
    assets = document.get("assets")
    if not isinstance(assets, list):
        raise NightlyError("upstream Nightly release omits its asset list")
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str) \
                or not asset["name"]:
            raise NightlyError("upstream Nightly release asset entries are malformed")
    return assets


def _one_asset(assets: list[dict[str, Any]], name: str) -> tuple[dict[str, Any] | None, str]:
    matches = [asset for asset in assets if asset["name"] == name]
    if not matches:
        return None, f"no {name}"
    if len(matches) > 1:
        return None, f"{len(matches)} assets named {name}"
    return matches[0], ""


def _digest(asset: dict[str, Any]) -> tuple[str, str]:
    """The SHA-256 an asset publishes, or why it publishes none this tool can use."""
    value = asset.get("digest")
    if value is None:
        return "", "asset publishes no digest"
    if not isinstance(value, str):
        return "", "asset digest is not a string"
    match = SHA256_DIGEST.fullmatch(value)
    if match is None:
        return "", "asset digest is not sha256:<64 lowercase hex>"
    return match.group(1), ""


def _archive_identity(assets: list[dict[str, Any]], sdk_version: str,
                      name: str) -> tuple[str, str]:
    """Return (sha256, problem) for the one archive named `name`."""
    asset, problem = _one_asset(assets, name)
    if asset is None:
        return "", problem
    expected = download_url(sdk_version, name)
    if asset.get("browser_download_url") != expected:
        return "", "asset download URL is outside the pinned release namespace"
    return _digest(asset)


def platform_row(platform: Platform, sdk_version: str,
                 assets: list[dict[str, Any]]) -> MatrixRow:
    """Pin one platform's two archives, or explain why it cannot be built."""
    problems: list[str] = []
    sdk_url = sdk_sha256 = stdx_url = stdx_sha256 = ""
    stdx_version = ""

    name = sdk_archive_name(platform, sdk_version)
    digest, problem = _archive_identity(assets, sdk_version, name)
    if digest:
        sdk_url, sdk_sha256 = download_url(sdk_version, name), digest
    else:
        problems.append(f"sdk: {problem}")

    pattern = stdx_archive_pattern(platform, sdk_version)
    matches = [(asset, pattern.fullmatch(asset["name"])) for asset in assets]
    matches = [(asset, match) for asset, match in matches if match is not None]
    if not matches:
        problems.append(f"stdx: no cangjie-stdx-{platform.stdx}-{sdk_version}.<revision>.zip")
    elif len(matches) > 1:
        problems.append(
            f"stdx: {len(matches)} archives named "
            f"cangjie-stdx-{platform.stdx}-{sdk_version}.<revision>.zip"
        )
    else:
        asset, match = matches[0]
        expected = download_url(sdk_version, asset["name"])
        if asset.get("browser_download_url") != expected:
            problems.append("stdx: asset download URL is outside the pinned release namespace")
        else:
            digest, problem = _digest(asset)
            if digest:
                stdx_url, stdx_sha256 = expected, digest
                stdx_version = f"{sdk_version}.{match.group(1)}"
            else:
                problems.append(f"stdx: {problem}")

    return {
        "platform": platform.platform,
        "runner": platform.runner,
        "sdk_url": sdk_url,
        "sdk_sha256": sdk_sha256,
        "stdx_url": stdx_url,
        "stdx_sha256": stdx_sha256,
        "stdx_version": stdx_version,
        "unavailable_reason": "; ".join(problems),
    }


def resolve_metadata(source_commit: str, requested_version: str, package_version: str,
                     *, fetch: Fetcher | None = None) -> dict[str, Any]:
    """Freeze the Nightly inputs for one commit into the workflow's documents."""
    # Resolved at call time so a test (or a caller) can substitute the transport.
    read = fetch or fetch_bytes
    requested = requested_version.strip()
    if requested:
        if not NIGHTLY_SDK_VERSION.fullmatch(requested):
            raise NightlyError(
                "an explicit Nightly SDK version must be the full <x.y.z-alpha.NNNNNNNNNNNNNN>"
            )
        sdk_version = requested
    else:
        manifest = _fetch_json(MANIFEST_URL, MAX_MANIFEST_BYTES, read,
                               "upstream Nightly manifest")
        sdk_version = manifest_latest(manifest)

    try:
        tag = nightly_tag(sdk_version, source_commit)
        release_version = nightly_release_version(package_version, sdk_version, source_commit)
    except ValueError as error:
        raise NightlyError(str(error)) from error

    url = RELEASE_URL.format(version=sdk_version)
    document = _fetch_json(url, MAX_RELEASE_BYTES, read,
                           f"upstream Nightly release {sdk_version}")
    assets = _release_assets(document, sdk_version)
    return {
        "sdk_version": sdk_version,
        "release_version": release_version,
        "tag": tag,
        "matrix": {"include": [platform_row(platform, sdk_version, assets)
                               for platform in PLATFORMS]},
    }


def write_github_output(path: Path, document: dict[str, Any]) -> None:
    """Append the four single-line step outputs the workflow consumes."""
    lines = [
        f"sdk_version={document['sdk_version']}",
        f"release_version={document['release_version']}",
        f"tag={document['tag']}",
        "matrix=" + json.dumps(document["matrix"], ensure_ascii=True, separators=(",", ":")),
    ]
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--commit", required=True, help="exact source commit to build")
    parser.add_argument("--version", default="",
                        help="exact Nightly SDK version; empty selects upstream latest")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args(argv)
    try:
        package_version = committed_package_version(args.repo, args.commit)
        document = resolve_metadata(args.commit, args.version, package_version)
        if args.github_output:
            write_github_output(args.github_output, document)
        print(json.dumps(document, ensure_ascii=True, indent=2, sort_keys=True))
    except (NightlyError, ValueError, OSError) as error:
        # Local paths and URL credentials never reach the log.
        detail = str(error) if isinstance(error, NightlyError) else type(error).__name__
        print("Nightly SDK resolution failed: " + detail, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
