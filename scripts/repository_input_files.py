from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import tomllib
from typing import Any

try:
    from .repository_input_contracts import (
        CURRENT_GOLDEN_VERSION,
        DOC_IR_ARRAY_REFS,
        DOC_IR_CORE_DEFS,
        GOLDEN_NAMES,
        JSON_SCHEMA_DRAFT,
        LEGACY_GOLDEN_VERSIONS,
        LEGACY_SCHEMA_SHA256,
        SCHEMA_CONTRACTS,
        SCHEMA_NAMES,
    )
    from .safe_output_root import lexical_absolute, verify_directory_chain
    from .strict_json import strict_load
except ImportError:  # Direct module execution.
    from repository_input_contracts import (
        CURRENT_GOLDEN_VERSION,
        DOC_IR_ARRAY_REFS,
        DOC_IR_CORE_DEFS,
        GOLDEN_NAMES,
        JSON_SCHEMA_DRAFT,
        LEGACY_GOLDEN_VERSIONS,
        LEGACY_SCHEMA_SHA256,
        SCHEMA_CONTRACTS,
        SCHEMA_NAMES,
    )
    from safe_output_root import lexical_absolute, verify_directory_chain
    from strict_json import strict_load

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


