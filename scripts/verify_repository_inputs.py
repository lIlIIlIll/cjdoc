#!/usr/bin/env python3
"""Verify tracked generated inputs, third-party licenses, and vendor provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import tomllib
from typing import Any

sys.dont_write_bytecode = True

try:
    from .safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
    from .strict_json import strict_dumps, strict_load, strict_loads
    from .worktree_identity import exact_worktree_identity
except ImportError:  # Direct script execution.
    from safe_output_root import lexical_absolute, safe_regular_file, verify_directory_chain
    from strict_json import strict_dumps, strict_load, strict_loads
    from worktree_identity import exact_worktree_identity


COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MARKDOWN_COMMIT = "db4f9527944b589db8436669f1d255192388cee2"
MARKDOWN_LICENSE_SHA256 = "0d52dcdcb50af1bfd2c06821c888bdec9683830f79c78863173e3d0b12f2ac19"
YJSON_COMMIT = "bf65cbecd99ac25e7485f8db60990e94a04e57bc"
MARKDOWN_UPSTREAM = "https://github.com/lIlIIlIll/markdown.git"
YJSON_UPSTREAM = "https://github.com/lIlIIlIll/yjson.git"
LEGACY_SCHEMA_SHA256 = {
    6: "a8db4442d6587b7d93108109730b6c2840a13eb031c07632bcd59b8488033a0a",
    7: "814eae6a9145f986608795cca731874b54c6cafd05f6bbbed19053640c1b6943",
}
YJSON_LICENSE_SHA256 = "ff2bfac16f9884d002e66b1b2c75c20c626bc41ff31cdf411c5acdf224288295"
YJSON_PACKAGE_MANIFEST_SHA256 = "21919a70642bee3eeb982c831192b046c0b5a2016f5f54f42234702f412e4f36"
YJSON_UPSTREAM_NOTICE_SHA256 = "cd0e4316071e629b97fabd41411e817ea48303e44947b1437dcb1e2000f55884"
YJSON_SOURCE_SHA256 = {
    "src/lib_json_patch.cj": "32848edf1826af8b8b6816a7244ab6ffd370485f21e6ecbda0baa20fa4495492",
    "src/lib_json_pointer.cj": "972ce953184cb0e2b0c0d2b5da1589b376639f1d1d496331d435842c4d50d991",
    "src/lib_json_schema.cj": "ce169822d2d6c557ce3f62b0eed011b95469427524d8a763f4d1cf2d6c987c7c",
    "src/work_limits.cj": "52aa1b8fbd41deaa72c80028f1500fe6ff9bafbcf9f5b11d2569bbc61baaeb6c",
}
LEGACY_MIGRATION_RECEIPT_SHA256 = \
    "9e9ddc889a380f29abcf869471118e1bff92fc596055fad7cef0631a1ee5b40d"
JSON_SCHEMA_DRAFT = "https://json-schema.org/draft/2020-12/schema"

GOLDEN_NAMES = (
    "basic",
    "functions",
    "types",
    "extend",
    "source-edges",
    "unsupported",
    "workspace",
    "conditional-linux",
    "path-dependencies",
)

CURRENT_GOLDEN_VERSION = 8
LEGACY_GOLDEN_VERSIONS = (6, 7)

SCHEMA_NAMES = (
    "doc-ir",
    "doc-ir-v6",
    "doc-ir-v7",
    "doc-ir-v8",
    "diagnostics",
    "cfg-matrix",
    "search-index",
    "api-surface",
    "documentation-coverage",
)
SCHEMA_CONTRACTS = {
    "doc-ir": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/8",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v6": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/6",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v7": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json",
        "cjdoc.doc-ir/7",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "doc-ir-v8": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v8.schema.json",
        "cjdoc.doc-ir/8",
        ("schemaVersion", "generator", "status", "project", "configuration", "providers",
         "modules", "packages", "files", "declarations", "assets", "orphanDocComments",
         "macroInvocations", "unsupportedDeclarations", "unboundSemanticDeclarations",
         "diagnostics"),
    ),
    "diagnostics": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/diagnostics.schema.json",
        "cjdoc.diagnostics/2", ("schemaVersion", "diagnostics"),
    ),
    "cfg-matrix": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/cfg-matrix.schema.json",
        "cjdoc.cfg-matrix/2", ("schemaVersion", "generator", "profiles"),
    ),
    "search-index": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/search-index.schema.json",
        "cjdoc.search-index/4", ("schemaVersion", "entries"),
    ),
    "api-surface": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/api-surface.schema.json",
        "cjdoc.api-surface/1", ("schemaVersion", "project", "audience", "declarations", "exposures"),
    ),
    "documentation-coverage": (
        "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/documentation-coverage.schema.json",
        "cjdoc.documentation-coverage/1", ("schemaVersion", "audience", "symbols", "parameters"),
    ),
}
DOC_IR_CORE_DEFS = {
    "asset", "comment", "configuration", "declaration", "diagnostic", "file",
    "generator", "macroInvocation", "markdownNode", "module", "orphanComment",
    "package", "parameter", "portablePath", "position", "project", "provider",
    "semanticInfo", "sourceRange", "unsupportedDeclaration",
    "unboundSemanticDeclaration",
}
DOC_IR_ARRAY_REFS = {
    "providers": "provider",
    "modules": "module",
    "packages": "package",
    "files": "file",
    "declarations": "declaration",
    "assets": "asset",
    "orphanDocComments": "orphanComment",
    "macroInvocations": "macroInvocation",
    "unsupportedDeclarations": "unsupportedDeclaration",
    "unboundSemanticDeclarations": "unboundSemanticDeclaration",
    "diagnostics": "diagnostic",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(value: object, description: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError(f"{description} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if value in (".", "..") or path.as_posix() != value or path.is_absolute() or \
            any(part in ("", ".", "..") for part in path.parts):
        raise ValueError(f"{description} is unsafe: {value!r}")
    return path


def read_toml(path: Path) -> dict[str, Any]:
    value = tomllib.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"TOML root is not a table: {path}")
    return value


def required_repository_paths() -> tuple[str, ...]:
    paths = [
        "README.md",
        "LICENSE",
        "cjpm.toml",
        "cjpm.lock",
        "THIRD_PARTY_NOTICES.md",
        "third_party/licenses/markdown-LICENSE",
        "vendor/yjson_algorithms/LICENSE",
        "vendor/yjson_algorithms/UPSTREAM.md",
        "vendor/yjson_algorithms/cjpm.toml",
        "vendor/yjson_algorithms/vendor-manifest.toml",
        "tests/fixtures/legacy-migration-v8.json",
    ]
    paths.extend(f"docs/schema/{name}.schema.json" for name in SCHEMA_NAMES)
    for version in (*LEGACY_GOLDEN_VERSIONS, CURRENT_GOLDEN_VERSION):
        paths.extend(f"tests/fixtures/golden-v{version}/{name}.docs.json" for name in GOLDEN_NAMES)
    return tuple(paths)


def verify_golden_set(repo: Path, version: int) -> None:
    directory = repo / f"tests/fixtures/golden-v{version}"
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"v{version} golden directory must be a regular repository directory")
    expected = {f"{name}.docs.json" for name in GOLDEN_NAMES}
    actual = {path.name for path in directory.glob("*.docs.json")}
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing or unexpected:
        raise ValueError(
            f"v{version} golden set mismatch: missing=" + ",".join(missing) +
            " unexpected=" + ",".join(unexpected)
        )
    expected_version = f"cjdoc.doc-ir/{version}"
    for name in sorted(expected):
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"v{version} golden must be a regular file: {name}")
        value = strict_load(path, description=f"v{version} golden {name}")
        if not isinstance(value, dict) or value.get("schemaVersion") != expected_version:
            raise ValueError(f"v{version} golden has the wrong schemaVersion: {name}")


def validate_schema_document(name: str, value: object) -> None:
    if not isinstance(value, dict):
        raise ValueError(f"{name} schema root must be an object")
    expected_id, expected_version, expected_required = SCHEMA_CONTRACTS[name]
    if value.get("$schema") != JSON_SCHEMA_DRAFT or value.get("$id") != expected_id:
        raise ValueError(f"{name} schema draft/id contract is invalid")
    if value.get("type") != "object" or value.get("additionalProperties") is not False:
        raise ValueError(f"{name} schema root shape is invalid")
    properties = value.get("properties")
    required = value.get("required")
    if not isinstance(properties, dict) or not isinstance(required, list) or \
            any(not isinstance(item, str) for item in required) or \
            tuple(required) != expected_required or set(properties) != set(expected_required):
        raise ValueError(f"{name} schema required/property contract is invalid")
    actual_version = properties.get("schemaVersion", {}).get("const") \
        if isinstance(properties.get("schemaVersion"), dict) else None
    if actual_version != expected_version:
        raise ValueError(f"{name} schema does not declare {expected_version}")
    if name.startswith("doc-ir"):
        definitions = value.get("$defs")
        if not isinstance(definitions, dict) or not DOC_IR_CORE_DEFS.issubset(definitions):
            raise ValueError(f"{name} schema critical definitions are missing")
        for property_name, definition in DOC_IR_ARRAY_REFS.items():
            property_schema = properties[property_name]
            if not isinstance(property_schema, dict) or \
                    property_schema.get("type") != "array" or \
                    property_schema.get("items") != {"$ref": f"#/$defs/{definition}"}:
                raise ValueError(
                    f"{name} schema collection shape is invalid: {property_name}"
                )
        for property_name, definition in (
            ("generator", "generator"), ("project", "project"),
            ("configuration", "configuration"),
        ):
            if properties[property_name] != {"$ref": f"#/$defs/{definition}"}:
                raise ValueError(
                    f"{name} schema object reference is invalid: {property_name}"
                )
        if properties["status"] != {"enum": ["complete", "partial"]}:
            raise ValueError(f"{name} schema status shape is invalid")
        if name in ("doc-ir", "doc-ir-v8"):
            if not {
                "codeBlockMetadata", "headingMetadata", "listMetadata",
                "listItemMetadata", "tableMetadata", "tableRowMetadata",
                "tableCellMetadata",
            }.issubset(definitions):
                raise ValueError(f"{name} schema v8 Markdown definitions are missing")
            markdown_node = definitions["markdownNode"]
            if not isinstance(markdown_node, dict) or \
                    markdown_node.get("type") != "object" or \
                    markdown_node.get("additionalProperties") is not False or \
                    markdown_node.get("required") != [
                        "kind", "literal", "source", "metadata", "children"
                    ] or set(markdown_node.get("properties", {})) != {
                        "kind", "literal", "source", "metadata", "children"
                    }:
                raise ValueError(f"{name} schema v8 Markdown node shape is invalid")
    elif name == "diagnostics":
        if properties["diagnostics"] != {
            "type": "array", "items": {"$ref": "doc-ir.schema.json#/$defs/diagnostic"}
        }:
            raise ValueError("diagnostics schema collection shape is invalid")
    elif name == "cfg-matrix":
        profiles = properties["profiles"]
        items = profiles.get("items") if isinstance(profiles, dict) else None
        if not isinstance(profiles, dict) or profiles.get("type") != "array" or \
                profiles.get("minItems") != 1 or \
                not isinstance(items, dict) or items.get("type") != "object" or \
                items.get("additionalProperties") is not False or \
                items.get("required") != ["name", "documentation"] or \
                items.get("properties", {}).get("documentation") != {
                    "$ref": "doc-ir.schema.json"
                }:
            raise ValueError("cfg-matrix schema profile shape is invalid")
    elif name == "search-index":
        entries = properties["entries"]
        items = entries.get("items") if isinstance(entries, dict) else None
        expected_entry_fields = {
            "id", "canonicalId", "exposure", "name", "qualifiedName", "kind",
            "packageName", "summary", "href"
        }
        if not isinstance(entries, dict) or entries.get("type") != "array" or \
                not isinstance(items, dict) or \
                items.get("type") != "object" or \
                items.get("additionalProperties") is not False or \
                set(items.get("required", [])) != expected_entry_fields or \
                set(items.get("properties", {})) != expected_entry_fields:
            raise ValueError("search-index schema entry shape is invalid")
    elif name == "api-surface":
        definitions = value.get("$defs")
        if not isinstance(definitions, dict) or not {
            "declaration", "exposure", "sourceApiSignature", "symbolId", "moduleId"
        }.issubset(definitions):
            raise ValueError("api-surface schema definitions are incomplete")
    elif name == "documentation-coverage":
        definitions = value.get("$defs")
        if not isinstance(definitions, dict) or "counts" not in definitions or \
                properties.get("symbols") != {"$ref": "#/$defs/counts"} or \
                properties.get("parameters") != {"$ref": "#/$defs/counts"}:
            raise ValueError("documentation-coverage schema counts shape is invalid")


def verify_schema_set(repo: Path) -> None:
    directory = lexical_absolute(repo / "docs/schema")
    verified = verify_directory_chain(directory)
    if verified != directory:
        raise ValueError("published schema directory identity changed during verification")
    if not directory.is_dir():
        raise ValueError("published schema directory must be a regular repository directory")
    expected = {f"{name}.schema.json" for name in SCHEMA_NAMES}
    actual = {path.name for path in directory.glob("*.schema.json")}
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing or unexpected:
        raise ValueError(
            "published schema set mismatch: missing=" + ",".join(missing) +
            " unexpected=" + ",".join(unexpected)
        )
    for name in SCHEMA_NAMES:
        path = directory / f"{name}.schema.json"
        value = strict_load(path, description=f"{name} schema")
        validate_schema_document(name, value)
    for version, expected_hash in LEGACY_SCHEMA_SHA256.items():
        path = directory / f"doc-ir-v{version}.schema.json"
        if sha256(path) != expected_hash:
            raise ValueError(f"published doc-ir-v{version} schema is not byte-frozen")


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
        "upstream-notice-sha256", "files",
    }
    if set(provenance) != expected_provenance_keys:
        raise ValueError(
            "vendor manifest fields mismatch: missing=" +
            ",".join(sorted(expected_provenance_keys - set(provenance))) +
            " unexpected=" +
            ",".join(sorted(set(provenance) - expected_provenance_keys))
        )
    if provenance.get("schema-version") != "cjdoc.vendor-manifest/1":
        raise ValueError("unknown vendor manifest schema")
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

    return {
        "schemaVersion": provenance["schema-version"],
        "upstream": upstream,
        "commit": commit,
        "packagePath": provenance["package-path"],
        "packageVersion": provenance["package-version"],
        "manifestSha256": sha256(manifest_path),
        "licenseSha256": YJSON_LICENSE_SHA256,
        "packageManifestSha256": YJSON_PACKAGE_MANIFEST_SHA256,
        "upstreamNoticeSha256": YJSON_UPSTREAM_NOTICE_SHA256,
        "sourceSha256": dict(sorted(expected_files.items())),
    }


def resolve_binary(value: Path) -> Path:
    candidate = lexical_absolute(value)
    for executable in (candidate, Path(f"{candidate}.exe")):
        try:
            executable.lstat()
        except FileNotFoundError:
            continue
        return safe_regular_file(executable, description="legacy migration binary")
    raise ValueError(f"legacy migration binary does not exist: {candidate}")


def run_doc_ir_render(binary: Path, source: Path) -> bytes:
    try:
        result = subprocess.run(
            [str(binary), "render", "--input", str(source), "--format", "json", "--stdout"],
            capture_output=True, check=False, timeout=30,
        )
    except subprocess.TimeoutExpired as error:
        raise ValueError(f"Doc IR render validation timed out: {source}") from error
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode("utf-8", "replace").strip()
        raise ValueError(f"Doc IR render validation failed for {source}: {detail}")
    try:
        value = strict_loads(result.stdout, description=f"migration output for {source}")
    except ValueError as error:
        raise ValueError(f"Doc IR render emitted invalid JSON for {source}: {error}") from error
    if not isinstance(value, dict) or value.get("schemaVersion") != "cjdoc.doc-ir/8":
        raise ValueError(f"Doc IR render did not emit Doc IR v8: {source}")
    return result.stdout


def run_legacy_render(binary: Path, source: Path) -> bytes:
    return run_doc_ir_render(binary, source)


def verify_current_goldens(repo: Path, binary_value: Path) -> list[str]:
    """Exercise the repository's real yjson-backed Doc IR decoder on every v8 golden."""
    binary = resolve_binary(binary_value)
    verified: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cjdoc-current-golden-") as temporary:
        work = Path(temporary)
        for name in GOLDEN_NAMES:
            relative = f"tests/fixtures/golden-v8/{name}.docs.json"
            source = repo / relative
            output = run_doc_ir_render(binary, source)
            if output != source.read_bytes():
                raise ValueError(f"v8 golden is not an exact strict round-trip: {relative}")
            verified.append(relative)

        corrupted = strict_load(
            repo / "tests/fixtures/golden-v8/basic.docs.json",
            description="v8 corruption regression source",
        )
        if not isinstance(corrupted, dict) or "generator" not in corrupted:
            raise ValueError("v8 corruption regression source is malformed")
        del corrupted["generator"]
        corrupt_path = work / "missing-generator.docs.json"
        corrupt_path.write_text(
            strict_dumps(corrupted, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8", newline="\n",
        )
        try:
            result = subprocess.run(
                [str(binary), "render", "--input", str(corrupt_path),
                 "--format", "json", "--stdout"],
                capture_output=True, check=False, timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise ValueError("corrupt v8 Doc IR rejection timed out") from error
        if result.returncode == 0:
            raise ValueError("yjson-backed Doc IR validation accepted a missing required field")
    return verified


def semantic_digest(value: object) -> str:
    canonical = strict_dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def verify_legacy_receipts(repo: Path) -> dict[str, dict[str, dict[str, object]]]:
    path = repo / "tests/fixtures/legacy-migration-v8.json"
    if sha256(path) != LEGACY_MIGRATION_RECEIPT_SHA256:
        raise ValueError("legacy migration receipt manifest is not byte-frozen")
    value = strict_load(path, description="legacy migration receipts")
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "targetSchemaVersion", "migrations"
    } or value.get("schemaVersion") != "cjdoc.legacy-migration-receipts/1" or \
            value.get("targetSchemaVersion") != "cjdoc.doc-ir/8":
        raise ValueError("legacy migration receipt manifest schema is invalid")
    migrations = value.get("migrations")
    if not isinstance(migrations, dict) or set(migrations) != {"6", "7"}:
        raise ValueError("legacy migration receipt versions are incomplete")
    expected_names = set(GOLDEN_NAMES)
    for version in LEGACY_GOLDEN_VERSIONS:
        entries = migrations.get(str(version))
        if not isinstance(entries, dict) or set(entries) != expected_names:
            raise ValueError(f"v{version} legacy migration receipts are incomplete")
        for name, receipt in entries.items():
            if not isinstance(receipt, dict) or set(receipt) != {
                "sourceSha256", "v8SemanticSha256", "declarations", "modules",
                "diagnostics", "unsupportedDeclarations",
            }:
                raise ValueError(f"invalid v{version} migration receipt: {name}")
            if any(not isinstance(receipt[field], int) or receipt[field] < 0 for field in (
                "declarations", "modules", "diagnostics", "unsupportedDeclarations"
            )) or any(not isinstance(receipt[field], str) or not SHA256.fullmatch(receipt[field])
                      for field in ("sourceSha256", "v8SemanticSha256")):
                raise ValueError(f"invalid v{version} migration receipt values: {name}")
            source = repo / f"tests/fixtures/golden-v{version}/{name}.docs.json"
            if sha256(source) != receipt["sourceSha256"]:
                raise ValueError(f"v{version} legacy input is not byte-frozen: {name}")
    return migrations


def verify_legacy_migrations(repo: Path, binary_value: Path) -> list[str]:
    binary = resolve_binary(binary_value)
    receipts = verify_legacy_receipts(repo)
    verified: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cjdoc-legacy-migration-") as temporary:
        migrated = Path(temporary) / "migrated.docs.json"
        for version in LEGACY_GOLDEN_VERSIONS:
            for name in GOLDEN_NAMES:
                relative = f"tests/fixtures/golden-v{version}/{name}.docs.json"
                output = run_legacy_render(binary, repo / relative)
                migrated_value = strict_loads(
                    output, description=f"migrated Doc IR for {relative}"
                )
                receipt = receipts[str(version)][name]
                actual = {
                    "v8SemanticSha256": semantic_digest(migrated_value),
                    "declarations": len(migrated_value.get("declarations", [])),
                    "modules": len(migrated_value.get("modules", [])),
                    "diagnostics": len(migrated_value.get("diagnostics", [])),
                    "unsupportedDeclarations": len(
                        migrated_value.get("unsupportedDeclarations", [])
                    ),
                }
                expected = {key: receipt[key] for key in actual}
                if actual != expected:
                    raise ValueError(f"legacy migration semantic receipt mismatch: {relative}")
                migrated.write_bytes(output)
                roundtrip = run_legacy_render(binary, migrated)
                if roundtrip != output:
                    raise ValueError(f"legacy migration is not a stable v8 round-trip: {relative}")
                verified.append(relative)
    return verified


def verify_tracked(repo: Path, paths: tuple[str, ...]) -> None:
    top = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
        text=True, capture_output=True, check=False,
    )
    if top.returncode != 0 or Path(top.stdout.strip()).resolve() != repo.resolve():
        raise ValueError("repository input tracking requires the repository Git top-level")
    result = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "--error-unmatch", "--", *paths],
        text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise ValueError(f"required repository input is not tracked: {detail}")


def verify_repository_inputs(repo: Path, require_tracked: bool = False) -> dict[str, object]:
    repo = lexical_absolute(repo)
    try:
        verify_directory_chain(repo)
    except ValueError as error:
        raise ValueError(
            "repository inputs require a canonical regular repository directory"
        ) from error
    if not repo.is_dir():
        raise ValueError("repository inputs require a canonical regular repository directory")
    required = required_repository_paths()
    for relative in required:
        path = repo / relative
        if path.is_symlink():
            raise ValueError(f"required repository input must not be a symlink: {relative}")
        if not path.is_file():
            raise ValueError(f"required repository input is missing: {relative}")
    verify_schema_set(repo)
    for version in LEGACY_GOLDEN_VERSIONS:
        verify_golden_set(repo, version)
    verify_golden_set(repo, CURRENT_GOLDEN_VERSION)
    verify_legacy_receipts(repo)
    licenses = verify_third_party(repo)
    vendor = verify_vendor(repo)
    repository_identity: dict[str, object] | None = None
    if require_tracked:
        tracked = list(required)
        tracked.extend(
            f"vendor/yjson_algorithms/{relative}"
            for relative in vendor["sourceSha256"].keys()
        )
        verify_tracked(repo, tuple(dict.fromkeys(tracked)))
        repository_identity = exact_worktree_identity(repo)
    return {
        "goldens": [
            f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json"
            for name in GOLDEN_NAMES
        ],
        "legacyGoldens": [
            f"tests/fixtures/golden-v{version}/{name}.docs.json"
            for version in LEGACY_GOLDEN_VERSIONS for name in GOLDEN_NAMES
        ],
        "licenses": licenses,
        "vendor": vendor,
        "repositoryIdentity": repository_identity,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--require-tracked", action="store_true")
    parser.add_argument("--legacy-binary", type=Path)
    args = parser.parse_args()
    try:
        evidence = verify_repository_inputs(args.repo, require_tracked=args.require_tracked)
        if args.legacy_binary is not None:
            evidence["currentGoldenValidation"] = verify_current_goldens(
                args.repo.resolve(), args.legacy_binary
            )
            evidence["legacyMigrations"] = verify_legacy_migrations(
                args.repo.resolve(), args.legacy_binary
            )
    except (OSError, ValueError, tomllib.TOMLDecodeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(
        f"repository inputs verified: {len(evidence['goldens'])} v8 goldens, "
        f"{len(evidence['legacyGoldens'])} frozen v6/v7 inputs, "
        f"{len(evidence['vendor']['sourceSha256'])} vendored sources"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
