from __future__ import annotations

import re

COMMIT = re.compile(r"^[0-9a-f]{40}$")
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
    "docs/schema/doc-ir-v9.schema.json",
    "docs/schema/doc-ir-v11.schema.json",
    "docs/schema/doc-ir-v10.schema.json",
    "docs/schema/doc-ir-v6.schema.json",
    "docs/schema/doc-ir-v7.schema.json",
    "docs/schema/doc-ir-v8.schema.json",
    "docs/schema/diagnostics.schema.json",
    "docs/schema/cfg-matrix.schema.json",
    "docs/schema/search-index.schema.json",
    "docs/schema/symbol-index.schema.json",
    "docs/schema/navigation-index.schema.json",
    "docs/schema/api-surface.schema.json",
    "docs/schema/api-surface-v1.schema.json",
    "docs/schema/api-diff.schema.json",
    "docs/schema/documentation-coverage.schema.json",
    "docs/schema/documentation-quality.schema.json",
    "docs/schema/doctest-results.schema.json",
}
REPOSITORY_PAYLOAD = {
    "README.md": "README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "licenses/markdown-MIT.txt": "third_party/licenses/markdown-LICENSE",
    "licenses/yjson-Apache-2.0.txt": "vendor/yjson_algorithms/LICENSE",
    **{name: name for name in SCHEMA_PAYLOAD},
}

