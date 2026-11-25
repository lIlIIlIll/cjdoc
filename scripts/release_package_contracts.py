from __future__ import annotations

import re

COMMIT = re.compile(r"^[0-9a-f]{40}$")
# A release ships two adjacent executables in one directory: the CLI and the
# version-matched CHIR worker it discovers next to itself. The install name is
# fixed here so the archive, the receipt, the verifier and the documented
# layout cannot drift apart.
MAIN_EXECUTABLE = "cjdoc"
WORKER_EXECUTABLE = "chir-worker-main"
WORKER_VERSION_PREFIX = "cjdoc-chir-worker "
WORKER_PROTOCOL = re.compile(r"^cjdoc-chir-worker/[0-9]+$")
WORKER_RECEIPT_KEYS = {"path", "sha256", "size", "versionOutput", "protocolVersion"}


def main_executable(windows: bool) -> str:
    """The packaged CLI file name for a platform."""
    return f"{MAIN_EXECUTABLE}.exe" if windows else MAIN_EXECUTABLE


def worker_executable(windows: bool) -> str:
    """The packaged CHIR worker file name for a platform.

    It is deliberately a sibling of `main_executable`, because the installed CLI
    resolves the worker from its own directory and never from `PATH` or the
    current directory.
    """
    return f"{WORKER_EXECUTABLE}.exe" if windows else WORKER_EXECUTABLE


SHA256 = re.compile(r"^[0-9a-f]{64}$")
# The cjpm.toml package version: the Cangjie toolchain rejects a pre-release
# suffix here, so `package.version` stays a stable three-part SemVer.
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
# A release version may carry a SemVer pre-release suffix (`0.7.2-rc.1`). The
# release tag, the packaged asset names and the release manifest use this
# spelling; `package.version` and the binary `--version` output keep the stable
# core, so a release still proves which source produced it.
RELEASE_SEMVER = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-(?:[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)
NIGHTLY_SDK_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]{14}")


def release_core(release_version: str) -> str:
    """Return the stable three-part core of a release version."""
    return release_version.split("-", 1)[0]


def release_version_from_tag(tag: str) -> str:
    """Return the release version carried by an exact `v`-prefixed release tag."""
    if not tag.startswith("v"):
        raise ValueError(f"release tag {tag!r} must start with 'v'")
    value = tag[1:]
    if not RELEASE_SEMVER.fullmatch(value):
        raise ValueError(
            f"release tag {tag!r} is not v followed by a SemVer release version"
        )
    return value


def nightly_tag(sdk_version: str, source_commit: str) -> str:
    if not NIGHTLY_SDK_VERSION.fullmatch(sdk_version) or not COMMIT.fullmatch(source_commit):
        raise ValueError("Nightly requires a full Nightly SDK version and source commit")
    return f"nightly-{sdk_version}-{source_commit}"


def nightly_release_version(package_version: str, sdk_version: str, source_commit: str) -> str:
    nightly_tag(sdk_version, source_commit)
    if not SEMVER.fullmatch(package_version):
        raise ValueError("Nightly requires a stable three-part package version")
    return f"{package_version}-nightly.sdk{sdk_version}.g{source_commit}"


def candidate_release_version(tag: str, package_version: str,
                              sdk_version: str, source_commit: str) -> str:
    if tag.startswith("nightly-"):
        if tag != nightly_tag(sdk_version, source_commit):
            raise ValueError("Nightly tag does not match the SDK version and source commit")
        return nightly_release_version(package_version, sdk_version, source_commit)
    return release_version_from_tag(tag)


def validate_release_stdx_version(version: str, sdk_version: str, source_commit: str,
                                  stdx_version: str) -> None:
    nightly = isinstance(sdk_version, str) and NIGHTLY_SDK_VERSION.fullmatch(sdk_version)
    if nightly and version == nightly_release_version(
            release_core(version), sdk_version, source_commit):
        if not isinstance(stdx_version, str) or not re.fullmatch(
                re.escape(sdk_version) + r"\.[1-9][0-9]*", stdx_version):
            raise ValueError("Nightly stdx version must identify a component of the same SDK version")
    elif not isinstance(stdx_version, str) or not SEMVER.fullmatch(stdx_version):
        raise ValueError("stdx version must be a stable three-part SemVer")


MAX_MEMBERS = 128
MAX_ARCHIVE_SIZE = 512 * 1024 * 1024
MAX_MEMBER_SIZE = 512 * 1024 * 1024
MAX_TOTAL_SIZE = 1024 * 1024 * 1024
MAX_ZIP_DIRECTORY_SIZE = 8 * 1024 * 1024
MAX_TAR_EXPANDED_SIZE = MAX_TOTAL_SIZE + (MAX_MEMBERS + 32) * 1024
MAX_MANIFEST_SIZE = 1024 * 1024
STREAM_CHUNK_SIZE = 1024 * 1024
SCHEMA_PAYLOAD = {
    "docs/schema/doc-ir.schema.json",
    "docs/schema/doc-ir-v19.schema.json",
    "docs/schema/api-surface-v3.schema.json",
    "docs/schema/api-diff-v2.schema.json",
    "docs/schema/search-index-v12.schema.json",
    "docs/schema/versions-v2.schema.json",
    "docs/schema/versions.schema.json",
    "docs/schema/translation-coverage.schema.json",
    "docs/schema/site-manifest.schema.json",
    "docs/schema/diagnostics.schema.json",
    "docs/schema/cfg-matrix.schema.json",
    "docs/schema/search-index.schema.json",
    "docs/schema/symbol-index.schema.json",
    "docs/schema/navigation-index.schema.json",
    "docs/schema/api-surface.schema.json",
    "docs/schema/api-diff.schema.json",
    "docs/schema/documentation-coverage.schema.json",
    "docs/schema/documentation-quality.schema.json",
    "docs/schema/navigation-index-v2.schema.json",
    "docs/schema/agent-full-index.schema.json",
    "docs/schema/declaration.schema.json",
    "docs/schema/page.schema.json",
    "docs/schema/machine-manifest.schema.json",
    "docs/schema/query-request.schema.json",
    "docs/schema/query-result.schema.json",
    "docs/schema/source-provenance.schema.json",
}
API_COMMENT_SKILL_FILES = (
    "skills/cjdoc-api-comments/SKILL.md",
    "skills/cjdoc-api-comments/references/authoring.md",
    "skills/cjdoc-api-comments/scripts/preview.py",
)
REPOSITORY_PAYLOAD = {
    "README.md": "README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "licenses/markdown-MIT.txt": "third_party/licenses/markdown-LICENSE",
    "licenses/yjson-Apache-2.0.txt": "vendor/yjson_algorithms/LICENSE",
    **{name: name for name in SCHEMA_PAYLOAD},
    **{name: name for name in API_COMMENT_SKILL_FILES},
}
