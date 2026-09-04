from __future__ import annotations

from pathlib import Path
from typing import Any

try:
    from .repository_input_contracts import (
        COMMIT,
        MARKDOWN_COMMIT,
        MARKDOWN_LICENSE_SHA256,
        MARKDOWN_UPSTREAM,
        SHA256,
        YJSON_COMMIT,
        YJSON_LICENSE_SHA256,
        YJSON_PACKAGE_MANIFEST_SHA256,
        YJSON_SOURCE_SHA256,
        YJSON_UPSTREAM,
        YJSON_UPSTREAM_NOTICE_SHA256,
        YJSON_VENDOR_PATCHES,
    )
    from .repository_input_files import read_toml, safe_relative, sha256
except ImportError:  # Direct module execution.
    from repository_input_contracts import (
        COMMIT,
        MARKDOWN_COMMIT,
        MARKDOWN_LICENSE_SHA256,
        MARKDOWN_UPSTREAM,
        SHA256,
        YJSON_COMMIT,
        YJSON_LICENSE_SHA256,
        YJSON_PACKAGE_MANIFEST_SHA256,
        YJSON_SOURCE_SHA256,
        YJSON_UPSTREAM,
        YJSON_UPSTREAM_NOTICE_SHA256,
        YJSON_VENDOR_PATCHES,
    )
    from repository_input_files import read_toml, safe_relative, sha256

def verify_third_party(repo: Path) -> dict[str, str]:
    markdown_license = repo / "third_party/licenses/markdown-LICENSE"
    actual_markdown_license = sha256(markdown_license)
    if actual_markdown_license != MARKDOWN_LICENSE_SHA256:
        raise ValueError("markdown license does not match the pinned dependency")

    notice_path = repo / "THIRD_PARTY_NOTICES.md"
    notice = notice_path.read_text(encoding="utf-8")
    for required in (
        MARKDOWN_COMMIT,
        YJSON_COMMIT,
        "third_party/licenses/markdown-LICENSE",
        "licenses/markdown-MIT.txt",
        "vendor/yjson_algorithms/LICENSE",
        "licenses/yjson-Apache-2.0.txt",
        "vendor/yjson_algorithms/vendor-manifest.toml",
    ):
        if required not in notice:
            raise ValueError(f"third-party notices omit {required!r}")
    return {
        "THIRD_PARTY_NOTICES.md": sha256(notice_path),
        "third_party/licenses/markdown-LICENSE": actual_markdown_license,
    }


def verify_vendor(repo: Path) -> dict[str, object]:
    root_manifest = read_toml(repo / "cjpm.toml")
    dependencies = root_manifest.get("dependencies")
    if not isinstance(dependencies, dict):
        raise ValueError("root dependencies must be a TOML table")
    if set(dependencies) != {"markdown", "yjson", "yjson_algorithms"}:
        raise ValueError("root dependency inventory does not match audited provenance")
    markdown = dependencies.get("markdown")
    yjson = dependencies.get("yjson")
    vendored = dependencies.get("yjson_algorithms")
    if not isinstance(markdown, dict) or not isinstance(yjson, dict) or \
            not isinstance(vendored, dict):
        raise ValueError("root third-party dependencies are missing")
    for name, dependency, upstream, commit in (
        ("markdown", markdown, MARKDOWN_UPSTREAM, MARKDOWN_COMMIT),
        ("yjson", yjson, YJSON_UPSTREAM, YJSON_COMMIT),
    ):
        if dependency != {"git": upstream, "commitId": commit, "output-type": "static"}:
            raise ValueError(f"root {name} dependency does not match audited provenance")
    if vendored != {"path": "vendor/yjson_algorithms", "output-type": "static"}:
        raise ValueError("yjson_algorithms must use the audited vendor path")

    lock = read_toml(repo / "cjpm.lock")
    locked = lock.get("requires")
    if not isinstance(locked, dict):
        raise ValueError("cjpm.lock requires must be a TOML table")
    if set(locked) != {"markdown", "yjson"}:
        raise ValueError("cjpm.lock dependency inventory does not match audited provenance")
    for name, dependency in (("markdown", markdown), ("yjson", yjson)):
        entry = locked.get(name)
        if entry != dependency:
            raise ValueError(f"cjpm.lock does not match audited dependency {name}")

    vendor_root = repo / "vendor/yjson_algorithms"
    if vendor_root.is_symlink() or not vendor_root.is_dir():
        raise ValueError("vendored dependency root must be a regular repository directory")
    manifest_path = vendor_root / "vendor-manifest.toml"
    provenance = read_toml(manifest_path)
    expected_provenance_keys = {
        "schema-version", "upstream", "commit", "package-path", "package-name",
        "package-version", "license-spdx", "license-file", "license-sha256",
        "package-manifest-file", "package-manifest-sha256", "upstream-notice-file",
        "upstream-notice-sha256", "patches", "files",
    }
    if set(provenance) != expected_provenance_keys:
        raise ValueError(
            "vendor manifest fields mismatch: missing=" +
            ",".join(sorted(expected_provenance_keys - set(provenance))) +
            " unexpected=" +
            ",".join(sorted(set(provenance) - expected_provenance_keys))
        )
    if provenance.get("schema-version") != "cjdoc.vendor-manifest/2":
        raise ValueError("unknown vendor manifest schema")
    if provenance.get("patches") != list(YJSON_VENDOR_PATCHES):
        raise ValueError("vendor local patch inventory does not match the audited patch")
    upstream = provenance.get("upstream")
    commit = provenance.get("commit")
    if upstream != yjson.get("git"):
        raise ValueError("vendor upstream does not match the root yjson dependency")
    if not isinstance(commit, str) or not COMMIT.fullmatch(commit):
        raise ValueError("vendor commit must be a lowercase 40-hex commit")
    if commit != yjson.get("commitId") or commit != YJSON_COMMIT:
        raise ValueError("vendor commit does not match the pinned yjson dependency")
    if provenance.get("package-path") != "packages/yjson_algorithms":
        raise ValueError("unexpected vendored upstream package path")
    if provenance.get("license-spdx") != "Apache-2.0":
        raise ValueError("vendored algorithms must retain Apache-2.0")

    package_manifest_relative = safe_relative(
        provenance.get("package-manifest-file"), "vendor package-manifest-file"
    )
    if package_manifest_relative.as_posix() != "cjpm.toml":
        raise ValueError("vendored package manifest must be cjpm.toml")
    package_manifest_path = vendor_root.joinpath(*package_manifest_relative.parts)
    expected_package_manifest_hash = provenance.get("package-manifest-sha256")
    if expected_package_manifest_hash != YJSON_PACKAGE_MANIFEST_SHA256 or \
            sha256(package_manifest_path) != YJSON_PACKAGE_MANIFEST_SHA256:
        raise ValueError("vendored package manifest does not match the audited manifest")
    package_manifest = read_toml(package_manifest_path)
    if set(package_manifest) != {"package", "dependencies"}:
        raise ValueError("vendored package manifest contains unexpected build configuration")
    package = package_manifest.get("package")
    vendor_dependencies = package_manifest.get("dependencies")
    if not isinstance(package, dict) or not isinstance(vendor_dependencies, dict):
        raise ValueError("vendored package manifest is incomplete")
    expected_package = {
        "cjc-version": "1.1.0",
        "name": "yjson_algorithms",
        "organization": "",
        "description": "Vendored yjson JSON Schema algorithms",
        "version": "2.0.1",
        "output-type": "static",
        "compile-option": "-O2",
    }
    if package != expected_package:
        raise ValueError("vendored package manifest contains unaudited package/build settings")
    if package.get("name") != provenance.get("package-name") or \
            package.get("version") != provenance.get("package-version"):
        raise ValueError("vendored package identity does not match provenance")
    if set(vendor_dependencies) != {"yjson"}:
        raise ValueError("vendored package manifest contains unexpected dependencies")
    vendor_yjson = vendor_dependencies.get("yjson")
    if vendor_yjson != {"git": upstream, "commitId": commit, "output-type": "static"}:
        raise ValueError("vendored package yjson dependency does not match provenance")

    license_relative = safe_relative(provenance.get("license-file"), "vendor license-file")
    license_path = vendor_root.joinpath(*license_relative.parts)
    expected_license = provenance.get("license-sha256")
    if license_relative.as_posix() != "LICENSE" or expected_license != YJSON_LICENSE_SHA256 or \
            sha256(license_path) != YJSON_LICENSE_SHA256:
        raise ValueError("vendor license does not match the audited dependency license")

    notice_relative = safe_relative(
        provenance.get("upstream-notice-file"), "vendor upstream-notice-file"
    )
    notice_path = vendor_root.joinpath(*notice_relative.parts)
    expected_notice_hash = provenance.get("upstream-notice-sha256")
    if notice_relative.as_posix() != "UPSTREAM.md" or \
            expected_notice_hash != YJSON_UPSTREAM_NOTICE_SHA256 or \
            sha256(notice_path) != YJSON_UPSTREAM_NOTICE_SHA256:
        raise ValueError("vendor upstream notice does not match the audited notice")

    raw_files = provenance.get("files")
    if not isinstance(raw_files, list) or not raw_files:
        raise ValueError("vendor manifest must list source files")
    expected_files: dict[str, str] = {}
    for entry in raw_files:
        if not isinstance(entry, dict):
            raise ValueError("vendor file entry must be a TOML table")
        relative = safe_relative(entry.get("path"), "vendor source path")
        relative_text = relative.as_posix()
        if not relative_text.startswith("src/") or not relative_text.endswith(".cj"):
            raise ValueError(f"vendor source path is outside src/: {relative_text}")
        expected_hash = entry.get("sha256")
        if not isinstance(expected_hash, str) or not SHA256.fullmatch(expected_hash):
            raise ValueError(f"invalid vendor source hash: {relative_text}")
        if relative_text in expected_files:
            raise ValueError(f"duplicate vendor source path: {relative_text}")
        expected_files[relative_text] = expected_hash

    if expected_files != YJSON_SOURCE_SHA256:
        raise ValueError("vendor source inventory does not match the audited exact inventory")

    expected_inventory = {
        "LICENSE", "UPSTREAM.md", "cjpm.toml", "vendor-manifest.toml",
        *YJSON_SOURCE_SHA256,
    }
    actual_files: set[str] = set()
    for path in vendor_root.rglob("*"):
        relative = path.relative_to(vendor_root).as_posix()
        if path.is_symlink():
            raise ValueError(f"vendor inventory must not contain symlinks: {relative}")
        if path.is_file():
            actual_files.add(relative)
        elif not path.is_dir():
            raise ValueError(f"vendor inventory contains a non-file entry: {relative}")
    if actual_files != expected_inventory:
        raise ValueError(
            "vendor inventory mismatch: missing=" +
            ",".join(sorted(expected_inventory - actual_files)) +
            " unexpected=" + ",".join(sorted(actual_files - expected_inventory))
        )
    for relative, expected_hash in expected_files.items():
        if sha256(vendor_root / relative) != expected_hash:
            raise ValueError(f"vendor source hash mismatch: {relative}")

    upstream_notice = notice_path.read_text(encoding="utf-8")
    notice_values = (
        upstream.removesuffix(".git"),
        commit,
        provenance["package-path"],
        str(provenance["package-version"]),
        "Apache-2.0",
        *(value for pair in sorted(expected_files.items()) for value in pair),
    )
    for value in notice_values:
        if value not in upstream_notice:
            raise ValueError(f"vendor upstream notice omits {value!r}")
    for patch in YJSON_VENDOR_PATCHES:
        for value in (patch["path"], patch["reason"]):
            if value not in upstream_notice:
                raise ValueError(f"vendor upstream notice omits local patch detail {value!r}")

    return {
        "schemaVersion": provenance["schema-version"],
        "upstream": upstream,
        "commit": commit,
        "packagePath": provenance["package-path"],
        "packageVersion": provenance["package-version"],
        "patches": list(YJSON_VENDOR_PATCHES),
        "manifestSha256": sha256(manifest_path),
        "licenseSha256": YJSON_LICENSE_SHA256,
        "packageManifestSha256": YJSON_PACKAGE_MANIFEST_SHA256,
        "upstreamNoticeSha256": YJSON_UPSTREAM_NOTICE_SHA256,
        "sourceSha256": dict(sorted(expected_files.items())),
    }
