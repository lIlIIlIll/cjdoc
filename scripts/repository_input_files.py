from __future__ import annotations

import hashlib
from pathlib import Path, PurePosixPath
import re
import tomllib
from typing import Any

try:
    from .repository_input_contracts import (
        CURRENT_GOLDEN_VERSION,
        DOC_IR_ARRAY_REFS,
        DOC_IR_CORE_DEFS,
        GOLDEN_NAMES,
        JSON_SCHEMA_DRAFT,
        SCHEMA_CONTRACTS,
        SCHEMA_OPTIONAL_PROPERTIES,
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
        SCHEMA_CONTRACTS,
        SCHEMA_OPTIONAL_PROPERTIES,
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
    try:
        from .showcase_inputs import source_inputs
    except ImportError:
        from showcase_inputs import source_inputs
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
        "cjdoc.toml",
        "site/showcase-baseline.json",
        "scripts/requirements-showcase.txt",
    ]
    paths.extend(source_inputs())
    paths.extend(f"docs/schema/{name}.schema.json" for name in SCHEMA_NAMES)
    paths.extend(
        f"tests/fixtures/golden-v{CURRENT_GOLDEN_VERSION}/{name}.docs.json"
        for name in GOLDEN_NAMES
    )
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


ARTIFACT_SCHEMAS = frozenset({
    "navigation-index-v2", "agent-full-index", "declaration", "page",
    "machine-manifest", "query-result",
})
LOOSE_PROPERTY_SCHEMAS = frozenset({"query-request"})
LOOKAROUND = re.compile(r"\(\?(?:[=!]|<[=!])")
DOC_IR_DEFINITIONS = frozenset({"declaration", "documentationPage", "package", "documentSetIdentity"})
ARTIFACT_REQUIRED_DEFINITIONS = {
    "declaration": {"declaration", "diagnostic", "sourceRange"},
    "page": {"documentationPage", "package", "documentSetIdentity"},
    "machine-manifest": {"documentSetIdentity", "representation", "resource", "report", "limits"},
}


def definition(value: object, name: str) -> dict:
    definitions = value.get("$defs") if isinstance(value, dict) else None
    found = definitions.get(name) if isinstance(definitions, dict) else None
    if not isinstance(found, dict):
        raise ValueError(f"schema definition is missing or not an object: {name}")
    return found


def schema_refs(value: object) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "$ref" and isinstance(child, str):
                found.append(child)
            else:
                found.extend(schema_refs(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(schema_refs(child))
    return found


def schema_patterns(value: object) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "pattern" and isinstance(child, str):
                found.append(child)
            else:
                found.extend(schema_patterns(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(schema_patterns(child))
    return found


def validate_artifact_schema(name: str, value: dict, properties: dict,
                             frozen_definitions: dict | None) -> None:
    """Validate the artifact schemas that consumers actually validate natively."""
    for reference in schema_refs(value):
        if not reference.startswith("#/$defs/"):
            raise ValueError(f"{name} schema is not self-contained: external reference {reference}")
        definition(value, reference[len("#/$defs/"):])
    for pattern in schema_patterns(value):
        if LOOKAROUND.search(pattern):
            raise ValueError(
                f"{name} schema uses lookaround, which the native linear matcher rejects: {pattern}")
    if name in ARTIFACT_REQUIRED_DEFINITIONS:
        definitions = value.get("$defs")
        names = set(definitions) if isinstance(definitions, dict) else set()
        missing = ARTIFACT_REQUIRED_DEFINITIONS[name] - names
        if missing:
            raise ValueError(f"{name} schema definitions are missing: {sorted(missing)}")
        embedded = set(frozen_definitions or ()) & DOC_IR_DEFINITIONS & names
        if not embedded:
            raise ValueError(f"{name} schema does not embed any frozen Doc IR v16 definition")
        for definition_name in embedded:
            if definitions[definition_name] != frozen_definitions[definition_name]:
                raise ValueError(
                    f"{name} schema forks the frozen Doc IR definition: {definition_name}")
        for required in ("symbol", "page"):
            reference = properties.get(required)
            if isinstance(reference, dict) and reference.get("$ref", "").endswith("/null"):
                raise ValueError(f"{name} schema does not reference the shared Doc IR model")
    if name == "navigation-index-v2":
        scope = definition(value, "scope")
        if set(scope.get("required", [])) != {
                "snapshotId", "audience", "language", "order", "includeValidation"}:
            raise ValueError("navigation-index-v2 scope shape is invalid")
        page = definition(value, "page")
        summary_state = page.get("properties", {}).get("summaryState", {})
        if summary_state != {"enum": ["complete", "missing", "budget_omitted"]}:
            raise ValueError("navigation-index-v2 page summaryState shape is invalid")
        pagination = properties.get("pagination", {})
        if pagination.get("properties", {}).get("pathBase") != {"const": "document-root"}:
            raise ValueError("navigation-index-v2 pagination root contract is invalid")
        if pagination.get("properties", {}).get("next", {}).get("anyOf") != [
                {"$ref": "#/$defs/safePath"}, {"type": "null"}]:
            raise ValueError("navigation-index-v2 continuation shape is invalid")
    elif name == "agent-full-index":
        part = definition(value, "part")
        if "sha256" not in part.get("required", []):
            raise ValueError("agent-full-index part digest is not required")
        omitted = definition(value, "omittedSection")
        if omitted.get("properties", {}).get("reason") != {"const": "aggregate_unit_budget"}:
            raise ValueError("agent-full-index omission reason is invalid")
    elif name == "machine-manifest":
        if properties.get("docIr", {}).get("$ref") != "#/$defs/docIrResource":
            raise ValueError("machine-manifest Doc IR reference is invalid")
        if properties.get("symbolIndex", {}).get("$ref") != "#/$defs/symbolIndexResource":
            raise ValueError("machine-manifest inventory reference is invalid")
        doc_ir = definition(value, "docIrResource")
        if doc_ir.get("properties", {}).get("path") != {"const": "agent/docs.json"}:
            raise ValueError("machine-manifest Doc IR path is invalid")
        inventory = definition(value, "symbolIndexResource")
        if inventory.get("properties", {}).get("path") != {"const": "symbol-index.json"}:
            raise ValueError("machine-manifest inventory path is invalid")
        report = definition(value, "report")
        if report.get("properties", {}).get("kind") != {"enum": ["validation", "api-diff"]} or \
                set(report.get("required", [])) != {
                    "kind", "path", "sha256", "snapshotId",
                    "baselineSnapshotId", "currentSnapshotId"}:
            raise ValueError("machine-manifest report row shape is invalid")
        if properties.get("fullReference", {}).get("anyOf") != [
                {"const": "agent-full-index.json"}, {"type": "null"}]:
            raise ValueError("machine-manifest full-reference shape is invalid")
    elif name == "query-result":
        for expected in ("querySnapshot", "queryItem", "queryIdentity", "queryRelation"):
            definition(value, expected)
        if "declaration" not in value.get("$defs", {}):
            raise ValueError("query-result schema does not embed the Doc IR declaration model")


def validate_schema_document(name: str, value: object,
                             frozen_definitions: dict | None = None) -> None:
    if not isinstance(value, dict):
        raise ValueError(f"{name} schema root must be an object")
    expected_id, expected_version, expected_required = SCHEMA_CONTRACTS[name]
    if value.get("$schema") != JSON_SCHEMA_DRAFT or value.get("$id") != expected_id:
        raise ValueError(f"{name} schema draft/id contract is invalid")
    if value.get("type") != "object" or value.get("additionalProperties") is not False:
        raise ValueError(f"{name} schema root shape is invalid")
    properties = value.get("properties")
    required = value.get("required")
    expected_properties = set(expected_required) | set(SCHEMA_OPTIONAL_PROPERTIES.get(name, ()))
    if not isinstance(properties, dict) or not isinstance(required, list) or \
            any(not isinstance(item, str) for item in required) or \
            tuple(required) != expected_required or (
                name not in LOOSE_PROPERTY_SCHEMAS and set(properties) != expected_properties):
        raise ValueError(f"{name} schema required/property contract is invalid")
    actual_version = properties.get("schemaVersion", {}).get("const") \
        if isinstance(properties.get("schemaVersion"), dict) else None
    if actual_version != expected_version:
        raise ValueError(f"{name} schema does not declare {expected_version}")
    if name in LOOSE_PROPERTY_SCHEMAS:
        # The request schema belongs to the query contract and may add optional
        # narrowing fields; only its identity, version and mandatory operation
        # are pinned here.
        if not set(expected_required).issubset(properties):
            raise ValueError(f"{name} schema lost a required field")
    if name in ARTIFACT_SCHEMAS:
        validate_artifact_schema(name, value, properties, frozen_definitions)
    if name in ("doc-ir", "doc-ir-v16") and properties["documentationRevision"] != {"type": "string"}:
        raise ValueError(f"{name} schema documentation revision shape is invalid")
    if name in ("doc-ir", "doc-ir-v16", "symbol-index"):
        definitions = value.get("$defs")
        for definition_name, graph_field in (
            ("dependencyInstance", "componentModuleId"), ("documentSetIdentity", "moduleId"),
            ("documentSetIdentity", "apiVersion"), ("documentSetIdentity", "documentationRevision"),
        ):
            definition = definitions.get(definition_name) if isinstance(definitions, dict) else None
            if not isinstance(definition, dict) or graph_field not in definition.get("required", []) or \
                    definition.get("properties", {}).get(graph_field) != {"type": "string"}:
                raise ValueError(f"{name} schema graph binding field is missing: {definition_name}.{graph_field}")
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
        if properties["apiCollectionState"] != {
            "enum": ["resolved", "partial", "unavailable"]
        }:
            raise ValueError(f"{name} API collection state shape is invalid")
        if "repository" not in definitions:
            raise ValueError(f"{name} repository definition is missing")
        if "evidenceKey" in definitions.get("tag", {}).get("properties", {}):
            raise ValueError(f"{name} schema contains removed tag evidence")
        if name in ("doc-ir", "doc-ir-v16"):
            if not {
                "codeBlockMetadata", "headingMetadata", "listMetadata",
                "listItemMetadata", "tableMetadata", "tableRowMetadata",
                "tableCellMetadata",
            }.issubset(definitions):
                raise ValueError(f"{name} schema Markdown definitions are missing")
            markdown_node = definitions["markdownNode"]
            if not isinstance(markdown_node, dict) or \
                    markdown_node.get("type") != "object" or \
                    markdown_node.get("additionalProperties") is not False or \
                    markdown_node.get("required") != [
                        "kind", "literal", "source", "metadata", "children"
                    ] or set(markdown_node.get("properties", {})) != {
                        "kind", "literal", "source", "metadata", "children"
                    }:
                raise ValueError(f"{name} schema Markdown node shape is invalid")
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
    elif name in ("search-index", "search-index-v9"):
        entries = properties["entries"]
        items = entries.get("items") if isinstance(entries, dict) else None
        expected_required_fields = {
            "id", "canonicalId", "exposure", "name", "qualifiedName", "kind",
            "packageName", "summary", "href"
        }
        expected_property_fields = expected_required_fields | {
            "moduleId", "moduleName", "ownerName", "parameterTypes", "returnType", "returnCanonical", "bindings", "externalDocs", "body", "sections", "fields"
        }
        if (
                not isinstance(entries, dict)
                or entries.get("type") != "array"
                or not isinstance(items, dict)
                or items.get("type") != "object"
                or items.get("additionalProperties") is not False
                or set(items.get("required", [])) != expected_required_fields
                or set(items.get("properties", {})) != expected_property_fields
        ):
            raise ValueError("search-index schema entry shape is invalid")
    elif name == "symbol-index":
        entries = properties["entries"]
        items = entries.get("items") if isinstance(entries, dict) else None
        expected_entry_fields = {
            "id", "canonicalId", "name", "qualifiedName", "kind", "moduleId",
            "packageName", "ownerId", "visibility", "semanticState", "summary",
            "source", "href", "relations", "references", "identity", "documentSetId", "symbolKey", "typeNavigations"
        }
        if not isinstance(entries, dict) or entries.get("type") != "array" or \
                not isinstance(items, dict) or items.get("type") != "object" or \
                items.get("additionalProperties") is not False or \
                set(items.get("required", [])) != expected_entry_fields or \
                set(items.get("properties", {})) != expected_entry_fields | {"sourceHeader"} or \
                items.get("properties", {}).get("sourceHeader") != {"type": "string"}:
            raise ValueError("symbol-index schema entry shape is invalid")
    elif name == "navigation-index":
        definitions = value.get("$defs")
        pages = properties["pages"]
        page = definitions.get("page") if isinstance(definitions, dict) else None
        expected_page_fields = {
            "id", "kind", "title", "href", "summary", "symbolId", "moduleId",
            "packageName", "semanticState"
        }
        if (not isinstance(definitions, dict) or
                not {"project", "page", "safePath"}.issubset(definitions) or
                not isinstance(pages, dict) or
                pages != {"type": "array", "maxItems": 100000,
                          "items": {"$ref": "#/$defs/page"}} or
                not isinstance(page, dict) or page.get("type") != "object" or
                page.get("additionalProperties") is not False or
                set(page.get("required", [])) != expected_page_fields or
                set(page.get("properties", {})) != expected_page_fields):
            raise ValueError("navigation-index schema page shape is invalid")
    elif name in ("api-surface", "api-surface-v3", "api-diff", "api-diff-v2"):
        definitions = value.get("$defs")
        if not isinstance(definitions, dict):
            raise ValueError(f"{name} schema definitions are missing")
        required = {
            "declaration", "exposure", "sourceApiSignature", "fingerprint"
        } if name in ("api-surface", "api-surface-v3") else {
            "identity", "summary", "evidence", "entry", "nullableString"
        }
        if not required.issubset(definitions):
            raise ValueError(f"{name} schema definitions are incomplete")
    elif name == "documentation-coverage":
        definitions = value.get("$defs")
        if not isinstance(definitions, dict) or not {"metric", "metrics", "group"}.issubset(definitions) or \
                properties.get("metrics") != {"$ref": "#/$defs/metrics"} or \
                properties.get("packages", {}).get("items") != {"$ref": "#/$defs/group"} or \
                properties.get("modules", {}).get("items") != {"$ref": "#/$defs/group"}:
            raise ValueError("documentation-coverage schema metrics shape is invalid")
    elif name in ("versions", "versions-v2"):
        definitions = value.get("$defs")
        versions = properties["versions"]
        if (not isinstance(definitions, dict) or
                not {"safePath", "version"}.issubset(definitions) or
                versions != {"type": "array", "minItems": 1, "maxItems": 64,
                             "items": {"$ref": "#/$defs/version"}}):
            raise ValueError("versions schema manifest shape is invalid")
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
    # Artifact schemas must embed the same Doc IR v16 definitions rather than a
    # forked model, so the frozen document is loaded once and compared.
    frozen_definitions = strict_load(
        directory / "doc-ir-v16.schema.json", description="doc-ir-v16 schema")
    if not isinstance(frozen_definitions, dict) or not isinstance(
            frozen_definitions.get("$defs"), dict):
        raise ValueError("doc-ir-v16 schema definitions are missing")
    frozen_definitions = frozen_definitions["$defs"]
    for name in SCHEMA_NAMES:
        path = directory / f"{name}.schema.json"
        value = strict_load(path, description=f"{name} schema")
        validate_schema_document(name, value, frozen_definitions)
