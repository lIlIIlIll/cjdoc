#!/usr/bin/env python3
"""Validate the agent artifacts an actual cjdoc HTML document root deploys.

This is an integration check, not a fixture test: every assertion runs against
artifacts produced by the real renderer, so a schema that accepts the real
output and a producer that satisfies the published contract are checked
together. No network, model service, SDK or fixture project is used.

What is verified, all fail-closed:

* `navigation-index.json` and every `navigation-index-part-N.json` continuation:
  stable offsets/counts/parts, one snapshot and query identity, unique page
  identities and routes, and only root-relative routes that exist on disk.
* `llms-full.txt` and its parts against `agent-full-index.json`: byte counts and
  SHA-256 of the exact published part, contiguous unit ranges, no duplicate or
  missing unit, and only real continuation files.
* `agent/manifest.json`: the snapshot identity is recomputed from the packaged
  Doc IR plus the publication revision, every listed resource exists with its
  declared size and digest, and the Doc IR and inventory records are not
  contradicted by their own resource rows.
* Every declaration and page artifact: the strict published schema, the scope
  of the owning manifest, the identity of the declared symbol/page, the exact
  Markdown bytes it embeds, and agreement with the packaged Doc IR.
* Rejection: a copy of each real artifact with an unknown field, a removed
  required field or an unsafe path must fail the same schema check.

Usage:
    python3 scripts/test_agent_artifacts.py --binary target/release/bin/cjdoc \\
        --root target/acceptance/agent/html
"""

from __future__ import annotations

import argparse
import hashlib
import json
from io import StringIO
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

sys.dont_write_bytecode = True

SCHEMA_NAMES = {
    "navigation": "navigation-index-v2",
    "full": "agent-full-index",
    "declaration": "declaration",
    "page": "page",
    "manifest": "machine-manifest",
}
# Runtime identities use the existing documented prefixes; they are not a
# signature or an authentication claim, only a content identity.
QUERY_PREFIX = "cjdoc:query:v1:"
SNAPSHOT_PREFIX = "cjdoc:snapshot:v1:"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
SCHEMA_EXPORTS = (
    ("navigation-index", "navigation-index-v2.schema.json"),
    ("navigation-index-v1", "navigation-index.schema.json"),
    ("agent-full-index", "agent-full-index.schema.json"),
    ("declaration", "declaration.schema.json"),
    ("page", "page.schema.json"),
    ("machine-manifest", "machine-manifest.schema.json"),
    ("query-request", "query-request.schema.json"),
    ("query-result", "query-result.schema.json"),
)


class ContractError(AssertionError):
    """An artifact, or its published schema, contradicts the contract."""


def unique_keys(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def invalid_constant(value: str) -> None:
    raise ContractError(f"non-finite JSON number: {value}")


def load_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"missing regular artifact: {path.name}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys,
                           parse_constant=invalid_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ContractError(f"cannot read {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise ContractError(f"artifact is not a JSON object: {path.name}")
    return value


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def relative_artifact(value: object, label: str) -> str:
    """A canonical document-root-relative artifact path, never a URL."""
    if not isinstance(value, str) or not value:
        raise ContractError(f"{label} must be a nonempty relative path")
    if value.startswith("/") or "\\" in value or ":" in value or "?" in value or "#" in value:
        raise ContractError(f"{label} is not a normalized relative path: {value!r}")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ContractError(f"{label} contains a control character: {value!r}")
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ContractError(f"{label} is not canonical: {value!r}")
    return value


def document(root: Path, name: str) -> Path:
    relative_artifact(name, "artifact path")
    path = root / PurePosixPath(name)
    if path.is_symlink() or not path.is_file():
        raise ContractError(f"artifact is missing or unsafe: {name}")
    return path


# --------------------------------------------------------------------------
# A strict JSON Schema subset validator.
#
# The published schemas use object/array structure, `const`, `enum`, `type`,
# `required`, `additionalProperties: false`, `$ref` into embedded definitions,
# bounded lengths/counts, anchored `pattern` values, and the boolean/logical
# combinators. This evaluator implements exactly those keywords; an unknown
# keyword is a failure rather than an unverified assumption, so a schema cannot
# silently gain a constraint this check would ignore.
# --------------------------------------------------------------------------
KNOWN_KEYWORDS = frozenset({
    "$schema", "$id", "title", "description", "type", "const", "enum", "required",
    "properties", "$defs", "$ref", "additionalProperties", "items", "prefixItems",
    "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern",
    "minimum", "maximum", "anyOf", "oneOf", "allOf", "not", "if", "then", "else",
    "propertyNames", "patternProperties", "minProperties", "maxProperties",
})


def resolve(schema: dict, root: dict, pointer: str) -> dict:
    if not pointer.startswith("#"):
        raise ContractError(f"schema reference is not local: {pointer}")
    node: object = root
    if pointer != "#":
        for part in pointer[2:].split("/"):
            if not isinstance(node, dict) or part not in node:
                raise ContractError(f"unresolvable schema reference: {pointer}")
            node = node[part]
    if not isinstance(node, dict):
        raise ContractError(f"schema reference is not an object: {pointer}")
    return node


def schema_type(value: object) -> str:
    if isinstance(value, bool) or value is None:
        return "boolean" if isinstance(value, bool) else "null"
    if isinstance(value, str):
        return "string"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    raise ContractError(f"unsupported JSON value: {type(value).__name__}")


def type_matches(value: object, expected: object) -> bool:
    names = expected if isinstance(expected, list) else [expected]
    actual = schema_type(value)
    for name in names:
        if not isinstance(name, str):
            raise ContractError("schema type name must be a string")
        if name == actual:
            return True
        if name == "number" and actual == "integer":
            return True
    return False


def validate(value: object, schema: dict, root: dict, path: str) -> None:
    if not isinstance(schema, dict):
        raise ContractError(f"{path}: schema node is not an object")
    unknown = set(schema) - KNOWN_KEYWORDS
    if unknown:
        raise ContractError(f"{path}: unsupported schema keyword(s): {sorted(unknown)}")
    if "$ref" in schema:
        validate(value, resolve(schema, root, schema["$ref"]), root, path)
    if "const" in schema and value != schema["const"]:
        raise ContractError(f"{path}: expected constant {schema['const']!r}, got {value!r}")
    if "enum" in schema:
        choices = schema["enum"]
        if not isinstance(choices, list) or value not in choices:
            raise ContractError(f"{path}: {value!r} is not one of {choices!r}")
    if "type" in schema and not type_matches(value, schema["type"]):
        raise ContractError(f"{path}: expected {schema['type']!r}, got {schema_type(value)}")
    if isinstance(value, str):
        validate_string(value, schema, path)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise ContractError(f"{path}: {value} is below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            raise ContractError(f"{path}: {value} is above {schema['maximum']}")
    if isinstance(value, list):
        validate_array(value, schema, root, path)
    if isinstance(value, dict):
        validate_object(value, schema, root, path)
    for combinator in ("allOf",):
        for child in schema.get(combinator, []):
            validate(value, child, root, path)
    if "anyOf" in schema:
        matches = sum(1 for child in schema["anyOf"] if valid(value, child, root, path))
        if matches == 0:
            raise ContractError(f"{path}: matches none of anyOf")
    if "oneOf" in schema:
        matches = sum(1 for child in schema["oneOf"] if valid(value, child, root, path))
        if matches != 1:
            raise ContractError(f"{path}: matches {matches} oneOf branches")
    if "not" in schema and valid(value, schema["not"], root, path):
        raise ContractError(f"{path}: violates a negated schema")
    if "if" in schema:
        branch = "then" if valid(value, schema["if"], root, path) else "else"
        if branch in schema:
            validate(value, schema[branch], root, path)


def valid(value: object, schema: dict, root: dict, path: str) -> bool:
    try:
        validate(value, schema, root, path)
        return True
    except ContractError:
        return False


def validate_string(value: str, schema: dict, path: str) -> None:
    if "minLength" in schema and len(value) < schema["minLength"]:
        raise ContractError(f"{path}: string is shorter than {schema['minLength']}")
    if "maxLength" in schema and len(value) > schema["maxLength"]:
        raise ContractError(f"{path}: string is longer than {schema['maxLength']}")
    if "pattern" in schema:
        pattern = schema["pattern"]
        if not isinstance(pattern, str):
            raise ContractError(f"{path}: schema pattern is not a string")
        try:
            matched = re.search(pattern, value) is not None
        except re.error as error:
            raise ContractError(f"{path}: schema pattern does not compile: {error}") from error
        if not matched:
            raise ContractError(f"{path}: {value!r} does not match {pattern!r}")


def validate_array(value: list, schema: dict, root: dict, path: str) -> None:
    if "minItems" in schema and len(value) < schema["minItems"]:
        raise ContractError(f"{path}: fewer than {schema['minItems']} items")
    if "maxItems" in schema and len(value) > schema["maxItems"]:
        raise ContractError(f"{path}: more than {schema['maxItems']} items")
    if schema.get("uniqueItems") is True:
        encoded = [json.dumps(item, sort_keys=True, ensure_ascii=False) for item in value]
        if len(set(encoded)) != len(encoded):
            raise ContractError(f"{path}: items are not unique")
    prefix = schema.get("prefixItems", [])
    for index, child in enumerate(prefix[:len(value)]):
        validate(value[index], child, root, f"{path}[{index}]")
    if "items" in schema and schema["items"] is not False:
        for index in range(len(prefix), len(value)):
            validate(value[index], schema["items"], root, f"{path}[{index}]")


def validate_object(value: dict, schema: dict, root: dict, path: str) -> None:
    if "minProperties" in schema and len(value) < schema["minProperties"]:
        raise ContractError(f"{path}: too few properties")
    if "maxProperties" in schema and len(value) > schema["maxProperties"]:
        raise ContractError(f"{path}: too many properties")
    properties = schema.get("properties", {})
    for required in schema.get("required", []):
        if required not in value:
            raise ContractError(f"{path}: missing required property {required!r}")
    if "propertyNames" in schema:
        for name in value:
            validate(name, schema["propertyNames"], root, f"{path}:propertyNames")
    patterns = schema.get("patternProperties", {})
    matched: set[str] = set()
    for name, child in value.items():
        if name in properties:
            matched.add(name)
            validate(child, properties[name], root, f"{path}.{name}")
        for pattern, child_schema in patterns.items():
            if re.search(pattern, name):
                matched.add(name)
                validate(child, child_schema, root, f"{path}.{name}")
        if name in properties:
            continue
        extra = schema.get("additionalProperties", True)
        if extra is False and name not in properties:
            raise ContractError(f"{path}: unknown property {name!r}")


def check_schema(document: dict, schema: dict, label: str) -> None:
    if schema.get("additionalProperties") is not False:
        raise ContractError(f"{label} schema root must reject unknown properties")
    validate(document, schema, schema, label)


def rejected(copy: dict, schema: dict, label: str) -> bool:
    try:
        check_schema(copy, schema, label)
        return False
    except ContractError:
        return True


# --------------------------------------------------------------------------
# Artifact graph checks.
# --------------------------------------------------------------------------
def publisher_doc_ir_text(encoded: str) -> str:
    """Restore producer indentation without changing any quoted source bytes."""
    output = StringIO()
    depth = 0
    in_string = False
    escaped = False
    for character in encoded:
        if in_string:
            output.write(character)
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
        elif character in " \t\r\n":
            continue
        elif character == '"':
            in_string = True
            output.write(character)
        elif character in "{[":
            depth += 1
            output.write(character + "\n" + "  " * depth)
        elif character in "}]":
            depth -= 1
            output.write("\n" + "  " * depth + character)
        elif character == ",":
            output.write(",\n" + "  " * depth)
        elif character == ":":
            output.write(": ")
        else:
            output.write(character)
    output.write("\n")
    return output.getvalue()


def publisher_snapshot_id(encoded: str, revision: str) -> str:
    """Recompute logical identity independently of compact/indented storage."""
    configuration = '\n{"projection":"cjdoc.read/1","publicationRevision":' + json.dumps(
        revision, ensure_ascii=False) + "}"
    fingerprint = hashlib.sha256(publisher_doc_ir_text(encoded).encode("utf-8"))
    fingerprint.update(configuration.encode("utf-8"))
    return SNAPSHOT_PREFIX + fingerprint.hexdigest()


def read_text(root: Path, name: str) -> str:
    """Exact artifact text: no newline translation, so digests stay meaningful."""
    try:
        return document(root, name).read_bytes().decode("utf-8")
    except (OSError, UnicodeError) as error:
        raise ContractError(f"cannot read artifact text {name}: {error}") from error


def check_navigation(root: Path, schema: dict) -> dict:
    first = load_json(document(root, "navigation-index.json"))
    check_schema(first, schema, "navigation-index.json")
    project = first["project"]
    scope = first["scope"]
    pagination = first["pagination"]
    total, parts = pagination["total"], pagination["parts"]
    if parts > 100000 or total > 1000000:
        raise ContractError(f"navigation declares implausible bounds: {parts} parts, {total} pages")
    if pagination["pathBase"] != "document-root":
        raise ContractError("navigation path base is not the document root")
    pages: list[dict] = []
    visited = {"navigation-index.json"}
    offset = 0
    name = "navigation-index.json"
    value = first
    for part in range(parts):
        current = value["pagination"]
        if current["part"] != part or current["parts"] != parts or current["total"] != total:
            raise ContractError(f"{name}: pagination does not continue part {part} of {parts}")
        if current["offset"] != offset:
            raise ContractError(f"{name}: offset {current['offset']} does not continue {offset}")
        if value["project"] != project or value["queryId"] != first["queryId"]:
            raise ContractError(f"{name}: changed project or query identity")
        if value["scope"]["snapshotId"] != scope["snapshotId"]:
            raise ContractError(f"{name}: changed snapshot identity")
        if value["scope"] != scope:
            raise ContractError(f"{name}: changed the reading scope")
        if value["apiCollectionState"] != first["apiCollectionState"]:
            raise ContractError(f"{name}: changed API collection state")
        completeness = value["completeness"]
        if completeness["enumerationComplete"] != (parts == 1):
            raise ContractError(f"{name}: misstates enumeration completeness")
        if current["returned"] != len(value["pages"]):
            raise ContractError(f"{name}: returned count does not match its pages")
        pages.extend(value["pages"])
        offset += len(value["pages"])
        child = current["next"]
        if part + 1 == parts:
            if child is not None:
                raise ContractError(f"{name}: final part offers a continuation")
            break
        if child is None:
            raise ContractError(f"{name}: part {part} of {parts} has no continuation")
        relative_artifact(child, f"{name} next")
        if not child.endswith(".json"):
            raise ContractError(f"{name}: continuation is not a JSON artifact: {child}")
        if child in visited:
            raise ContractError(f"{name}: continuation is a loop or duplicate: {child}")
        visited.add(child)
        name = child
        value = load_json(document(root, name))
        check_schema(value, schema, name)
    if len(pages) != total:
        raise ContractError(f"navigation enumerates {len(pages)} pages, not {total}")
    ids: set[str] = set()
    hrefs: set[str] = set()
    for index, page in enumerate(pages):
        if page["id"] in ids:
            raise ContractError(f"navigation repeats page identity {page['id']!r}")
        ids.add(page["id"])
        if page["href"] in hrefs:
            raise ContractError(f"navigation repeats route {page['href']!r}")
        hrefs.add(page["href"])
        document(root, page["href"])
        state = page["summaryState"]
        summary = page["summary"]
        if state == "missing" and summary is not None:
            raise ContractError(f"page {index}: a missing summary carries text")
        if state == "complete" and summary is None:
            raise ContractError(f"page {index}: a complete summary is absent")
        if state == "budget_omitted" and summary is None:
            raise ContractError(f"page {index}: an omitted summary has no truncation marker")
    if not first["queryId"].startswith(QUERY_PREFIX) or not HEX64.fullmatch(
            first["queryId"][len(QUERY_PREFIX):]):
        raise ContractError("navigation query identity is not a content digest")
    if not first["scope"]["snapshotId"].startswith(SNAPSHOT_PREFIX):
        raise ContractError("navigation snapshot identity has the wrong prefix")
    return {"root": first, "pages": pages}


def check_full_reference(root: Path, schema: dict, manifest: dict) -> None:
    index_path = root / "agent-full-index.json"
    if manifest["fullReference"] is None:
        if index_path.exists():
            raise ContractError("a full-reference index exists although it is not enabled")
        if any(path.name.startswith("llms-full") for path in root.iterdir()):
            raise ContractError("full-reference parts exist although they are not enabled")
        return
    reference = relative_artifact(manifest["fullReference"], "fullReference")
    if reference != "agent-full-index.json":
        raise ContractError("full-reference index must be agent-full-index.json at the root")
    index = load_json(document(root, "agent-full-index.json"))
    check_schema(index, schema, "agent-full-index.json")
    if index["snapshotId"] != manifest["snapshotId"]:
        raise ContractError("full-reference index names another snapshot")
    if index["audience"] != manifest["scope"]["audience"]:
        raise ContractError("full-reference index names another audience")
    if index["language"] != manifest["scope"]["readingLanguage"]:
        raise ContractError("full-reference index names another reading language")
    if index["apiCollectionState"] != manifest["scope"]["apiCollectionState"]:
        raise ContractError("full-reference index names another API collection state")
    parts = index["parts"]
    if not parts:
        raise ContractError("full-reference index has no parts")
    units: set[str] = set()
    offset = 0
    for position, part in enumerate(parts):
        relative_artifact(part["path"], "full part path")
        if part["offset"] != offset:
            raise ContractError(f"full part {position}: unit range does not continue {offset}")
        if part["returned"] <= 0 and index["unitCount"] > 0:
            raise ContractError(f"full part {position}: a part carries no unit")
        offset += part["returned"]
        expected_next = parts[position + 1]["path"] if position + 1 < len(parts) else None
        if part["next"] != expected_next:
            raise ContractError(f"full part {position}: continuation does not name the next part")
        content = document(root, part["path"]).read_bytes()
        if len(content) != part["bytes"]:
            raise ContractError(f"full part {position}: declared byte count is wrong")
        if digest(content) != part["sha256"]:
            raise ContractError(f"full part {position}: declared digest is wrong")
        if len(content) > index["partByteLimit"]:
            raise ContractError(f"full part {position}: exceeds the declared part budget")
        if part["next"] is not None:
            document(root, part["next"])
        for omitted in part["omittedSections"]:
            relative_artifact(omitted["next"], "omitted unit reference")
            document(root, omitted["next"])
            if omitted["unitId"] in units:
                raise ContractError(f"full part {position}: repeats omitted unit {omitted['unitId']!r}")
            units.add(omitted["unitId"])
    if offset != index["unitCount"]:
        raise ContractError(f"full-reference units cover {offset}, not {index['unitCount']}")
    if index["completeness"] != {
            "enumerationComplete": True,
            "contentComplete": all(part["contentComplete"] for part in parts)}:
        raise ContractError("full-reference aggregate completeness contradicts its parts")
    published = {path.name for path in root.glob("llms-full*.txt")}
    declared = {PurePosixPath(part["path"]).name for part in parts if "/" not in part["path"]}
    if not declared.issubset(published):
        raise ContractError(f"full-reference parts are missing: {sorted(declared - published)}")


def check_manifest(root: Path, schema: dict, navigation: dict) -> dict:
    navigation_root = navigation["root"]
    manifest = load_json(document(root, "agent/manifest.json"))
    check_schema(manifest, schema, "agent/manifest.json")
    if manifest["pathBase"] != "document-root" or manifest["projection"] != "cjdoc.read/1":
        raise ContractError("manifest projection or path base is not the reading contract")
    if manifest["snapshotId"] != navigation_root["scope"]["snapshotId"]:
        raise ContractError("manifest and navigation name different snapshots")
    if manifest["scope"]["snapshotId"] != manifest["snapshotId"]:
        raise ContractError("manifest scope duplicates a different snapshot identity")
    if manifest["scope"]["audience"] != navigation_root["scope"]["audience"]:
        raise ContractError("manifest and navigation name different audiences")
    if manifest["scope"]["readingLanguage"] != navigation_root["scope"]["language"]:
        raise ContractError("manifest and navigation name different reading languages")
    if manifest["scope"]["apiCollectionState"] != navigation_root["apiCollectionState"]:
        raise ContractError("manifest and navigation name different API collection states")

    encoded = read_text(root, manifest["docIr"]["path"])
    recomputed = publisher_snapshot_id(encoded, manifest["publicationRevision"])
    if recomputed != manifest["snapshotId"]:
        raise ContractError(
            f"packaged Doc IR and publication revision produce {recomputed}, "
            f"not the advertised {manifest['snapshotId']}")
    if manifest["scope"]["publicationRevision"] != manifest["publicationRevision"]:
        raise ContractError("manifest scope and top-level publication revisions differ")

    resources: dict[str, dict] = {}
    total_bytes = 0
    for entry in manifest["resources"]:
        name = relative_artifact(entry["path"], "resource path")
        if name in resources:
            raise ContractError(f"manifest repeats resource {name!r}")
        resources[name] = entry
        content = document(root, name).read_bytes()
        if len(content) != entry["bytes"]:
            raise ContractError(f"resource {name}: declared size is wrong")
        if digest(content) != entry["sha256"]:
            raise ContractError(f"resource {name}: declared digest is wrong")
        total_bytes += len(content)
    if total_bytes > manifest["limits"]["totalArtifactBytes"]:
        raise ContractError("resources exceed the declared total budget")
    if len(resources) > manifest["limits"]["artifactCount"]:
        raise ContractError("resources exceed the declared artifact count")

    # The machine payload owns all of agent/ plus the shared root symbol index;
    # ordinary HTML/chrome resources are not part of this immutable inventory.
    published = {path.relative_to(root).as_posix() for path in (root / "agent").rglob("*")
                 if path.is_file()}
    published.add(manifest["symbolIndex"]["path"])
    expected = set(resources) | {"agent/manifest.json"}
    if any(not name.startswith("agent/") and name != manifest["symbolIndex"]["path"]
           for name in resources):
        raise ContractError("a packaged resource is outside the agent bundle")
    if published != expected:
        raise ContractError(
            "agent bundle inventory mismatch: missing=" +
            ",".join(sorted(expected - published)) +
            " unexpected=" + ",".join(sorted(published - expected)))
    for label, record in (("docIr", manifest["docIr"]), ("symbolIndex", manifest["symbolIndex"])):
        relative_artifact(record["path"], label)
        if record["path"] not in resources:
            raise ContractError(f"{label} is not listed among the packaged resources")
        if resources[record["path"]]["sha256"] != record["sha256"]:
            raise ContractError(f"{label} digest contradicts its resource row")
    inventory = read_text(root, manifest["symbolIndex"]["path"])
    if not inventory.strip() or "cjdoc.symbol-index/" not in inventory:
        raise ContractError("packaged inventory is not a versioned symbol index")

    doc_ir = load_json(root / manifest["docIr"]["path"])
    if doc_ir.get("schemaVersion") != "cjdoc.doc-ir/16":
        raise ContractError("packaged Doc IR is not the current version")
    declarations = {item["id"]: item for item in doc_ir.get("declarations", [])}
    pages = selected_documentation_pages(doc_ir.get("pages", []), manifest["scope"]["readingLanguage"])
    packages = {(item["moduleId"], item["name"]): item for item in doc_ir.get("packages", [])}
    diagnostics: dict[str, list[dict]] = {}
    for entry in doc_ir.get("diagnostics", []):
        diagnostics.setdefault(entry.get("symbolId"), []).append(entry)

    seen_kinds: set[str] = set()
    seen_ids: set[str] = set()
    for representation in manifest["representations"]:
        kind = representation["kind"]
        seen_kinds.add(kind)
        key = (kind, representation["id"])
        if key in seen_ids:
            raise ContractError(f"manifest repeats representation {key}")
        seen_ids.add(key)
        for field in ("html", "markdown", "json"):
            relative_artifact(representation[field], f"representation {field}")
            document(root, representation[field])
            # The integrity inventory is the immutable agent/ payload. HTML is
            # an existing site artifact; language/version composition may update
            # its chrome without changing the captured documentation snapshot.
            if field != "html" and representation[field] not in resources:
                raise ContractError(f"representation {field} is not among the resources")
        if kind == "symbol" and representation["id"] not in declarations:
            raise ContractError(f"representation names an absent declaration {representation['id']!r}")
        if kind == "concept" and representation["id"] not in pages:
            raise ContractError(f"representation names an absent page {representation['id']!r}")
    # A document root always maps its declarations and its project index. A
    # concept or package representation exists only when the captured model has
    # the corresponding selected content, so absence is checked, not demanded.
    for required in ("symbol", "project"):
        if required not in seen_kinds:
            raise ContractError(f"manifest has no {required} representation")
    if pages and "concept" not in seen_kinds:
        raise ContractError("manifest does not map captured conceptual pages")
    if packages and "package" not in seen_kinds:
        raise ContractError("manifest does not map packaged declarations")
    if not pages and "concept" in seen_kinds:
        raise ContractError("manifest maps conceptual pages the Doc IR does not contain")
    if not packages and "package" in seen_kinds:
        raise ContractError("manifest maps packages the Doc IR does not contain")
    return {"manifest": manifest, "docIr": doc_ir, "declarations": declarations,
            "pages": pages, "packages": packages, "diagnostics": diagnostics,
            "navigation": navigation}


def check_declaration_artifacts(root: Path, schema: dict, graph: dict) -> int:
    manifest = graph["manifest"]
    checked = 0
    for representation in manifest["representations"]:
        if representation["kind"] != "symbol":
            continue
        name = representation["json"]
        value = load_json(document(root, name))
        check_schema(value, schema, name)
        scope = value["scope"]
        for field in ("snapshotId", "audience", "cfgProfile", "readingLanguage",
                      "apiCollectionState", "publicationRevision"):
            if scope[field] != manifest["scope"][field]:
                raise ContractError(f"{name}: scope field {field} differs from the manifest")
        symbol = value["symbol"]
        if symbol["id"] != representation["id"]:
            raise ContractError(f"{name}: symbol identity differs from its representation")
        recorded = graph["declarations"][representation["id"]]
        if symbol != recorded:
            raise ContractError(f"{name}: embedded symbol differs from the packaged Doc IR")
        expected = graph["diagnostics"].get(symbol["id"], [])
        if value["diagnostics"] != expected:
            raise ContractError(f"{name}: diagnostics differ from the packaged Doc IR")
        available = recorded["documentation"] is not None
        if value["documentationState"] != ("available" if available else "missing"):
            raise ContractError(f"{name}: documentation state contradicts the packaged Doc IR")
        markdown = read_text(root, value["representations"]["markdown"])
        if value["markdown"] != markdown:
            raise ContractError(f"{name}: embedded Markdown differs from its published file")
        if value["representations"]["html"] != representation["html"] or \
                value["representations"]["json"] != name:
            raise ContractError(f"{name}: representation map differs from the manifest")
        document(root, value["representations"]["html"])
        if not value["symbolKey"]:
            raise ContractError(f"{name}: declaration has no stable symbol key")
        source = value["source"]
        if source["revisionKind"] == "recorded" and source["recordedRevision"] is None:
            raise ContractError(f"{name}: a recorded revision is absent")
        if source["revisionKind"] == "unavailable" and source["recordedRevision"] is not None:
            raise ContractError(f"{name}: an unavailable revision is advertised")
        if source["range"] != recorded["source"]:
            raise ContractError(f"{name}: source range differs from the packaged Doc IR")
        if value["exampleEvidence"]["state"] != "not_attached" or value["exampleEvidence"]["reports"]:
            raise ContractError(f"{name}: example evidence claims an attachment that does not exist")
        checked += 1
    return checked


def selected_documentation_pages(pages: list[dict], language: str) -> dict[str, dict]:
    """Prefer the requested variant, then authored default, then unknown language."""
    exact, original, unknown = {}, {}, {}
    for page in pages:
        identifier = page["id"]
        if page.get("language") == language:
            exact[identifier] = page
        if page.get("language") == page.get("defaultLanguage"):
            original[identifier] = page
        if page.get("language") is None:
            unknown[identifier] = page
    return {**unknown, **original, **exact}


def check_page_artifacts(root: Path, schema: dict, graph: dict) -> int:
    manifest = graph["manifest"]
    checked = 0
    for representation in manifest["representations"]:
        if representation["kind"] not in ("concept", "package", "project"):
            continue
        name = representation["json"]
        value = load_json(document(root, name))
        check_schema(value, schema, name)
        markdown = read_text(root, value["representations"]["markdown"])
        if value["markdown"] != markdown:
            raise ContractError(f"{name}: embedded Markdown differs from its published file")
        kind = representation["kind"]
        if value["kind"] != kind or value["id"] != representation["id"]:
            raise ContractError(f"{name}: page identity differs from its representation")
        if kind == "concept":
            if value["page"] is None or value["package"] is not None:
                raise ContractError(f"{name}: a concept must carry a page and no package")
            recorded = graph["pages"].get(representation["id"])
            if recorded is None or value["page"] != recorded:
                raise ContractError(f"{name}: page differs from the packaged Doc IR")
            if value["scope"]["documentSet"] is not None:
                raise ContractError(f"{name}: a concept claims a module document set")
            document(root, value["representations"]["html"])
        elif kind == "package":
            if value["package"] is None or value["page"] is not None:
                raise ContractError(f"{name}: a package must carry a package and no page")
            recorded = graph["packages"].get(
                (value["package"]["moduleId"], value["package"]["name"]))
            if recorded is None or value["package"] != recorded:
                raise ContractError(f"{name}: package differs from the packaged Doc IR")
            if value["scope"]["documentSet"] is None:
                raise ContractError(f"{name}: a package page has no captured document set")
        else:
            if value["page"] is not None or value["package"] is not None:
                raise ContractError(f"{name}: a project page carries page or package data")
        if "symbolId" in value:
            raise ContractError(f"{name}: a page artifact fabricates a symbol identity")
        checked += 1
    return checked


def check_navigation_representations(graph: dict) -> None:
    navigation = graph["navigation"]
    manifest = graph["manifest"]
    by_symbol = {page["symbolId"]: page for page in navigation["pages"] if page["symbolId"]}
    for representation in manifest["representations"]:
        if representation["kind"] != "symbol":
            continue
        page = by_symbol.get(representation["id"])
        if page is None:
            raise ContractError(f"declaration {representation['id']!r} is absent from navigation")
        if page["href"] != representation["html"]:
            raise ContractError(
                f"declaration {representation['id']!r} maps a different HTML route")
        if page["semanticState"] != graph["declarations"][representation["id"]]["semantic"]["state"]:
            raise ContractError(
                f"declaration {representation['id']!r} has a different semantic state")
    for page in navigation["pages"]:
        if page["kind"] == "symbol" and page["symbolId"] not in graph["declarations"]:
            raise ContractError(f"navigation names an absent declaration {page['symbolId']!r}")


def reject_mutations(root: Path, schemas: dict, graph: dict) -> int:
    """Each schema must reject an otherwise-valid artifact with a real defect."""
    manifest = graph["manifest"]
    symbol = next(item for item in manifest["representations"] if item["kind"] == "symbol")
    concept = next((item for item in manifest["representations"] if item["kind"] == "concept"),
                   None)
    cases = [
        ("navigation-index.json", "navigation", "unknown"),
        ("agent-full-index.json", "full", "unknown"),
        (manifest["docIr"]["path"], None, "unknown"),
        ("agent/manifest.json", "manifest", "unsafe"),
        ("agent/manifest.json", "manifest", "missing"),
        ("agent/manifest.json", "manifest", "unexpected-root-resource"),
        (symbol["json"], "declaration", "unknown"),
        (symbol["json"], "declaration", "unsafe"),
    ]
    if concept is not None:
        cases += [(concept["json"], "page", "unknown"), (concept["json"], "page", "missing")]
    rejected_count = 0
    for name, key, mutation in cases:
        path = root / name
        if key is None or not path.is_file():
            continue
        original = load_json(path)
        copy = json.loads(json.dumps(original))
        if mutation == "unknown":
            copy["unexpectedContractField"] = 1
        elif mutation == "missing":
            first = next(iter(copy))
            del copy[first]
        elif mutation == "unexpected-root-resource":
            copy["resources"][0]["path"] = "extra-root-payload.json"
        elif mutation == "unsafe":
            if key == "manifest":
                # The manifest's own representation list is a list of rows; the
                # resource path is the document-root-relative location a loader
                # would open, so that is where an escape must be rejected.
                copy["resources"][0]["path"] = "../../escape.json"
            else:
                copy["representations"] = {**copy["representations"],
                                           "html": "../escape.html"}
        else:
            raise ContractError(f"unknown mutation {mutation!r}")
        if key == "navigation" and mutation == "unknown":
            copy["pagination"] = {**copy["pagination"], "unexpected": True}
        schema = schemas[key]
        if not rejected(copy, schema, f"mutated {name}"):
            raise ContractError(f"{key} schema accepted an illegal {mutation} mutation of {name}")
        rejected_count += 1
    return rejected_count


def check_schema_exports(binary: Path, schema_dir: Path) -> int:
    listing = subprocess.run([str(binary), "schema", "list"], capture_output=True,
                             text=True, check=False)
    if listing.returncode != 0:
        raise ContractError(f"cjdoc schema list failed: {listing.stderr.strip()}")
    names = {line.strip() for line in listing.stdout.replace("\r", "").splitlines() if line.strip()}
    checked = 0
    for exported, published in SCHEMA_EXPORTS:
        if exported not in names:
            raise ContractError(f"schema list does not offer {exported!r}")
        emitted = subprocess.run([str(binary), "schema", exported], capture_output=True,
                                 text=True, check=False)
        if emitted.returncode != 0:
            raise ContractError(f"cjdoc schema {exported} failed: {emitted.stderr.strip()}")
        expected = (schema_dir / published).read_bytes()
        actual = emitted.stdout.replace("\r", "").encode("utf-8")
        if actual.strip() != expected.strip():
            raise ContractError(f"cjdoc schema {exported} differs from docs/schema/{published}")
        checked += 1
    if "navigation-index-v1" not in names:
        raise ContractError("schema list does not offer the frozen navigation-index-v1 contract")
    return checked


def load_schemas(schema_dir: Path) -> dict:
    schemas = {}
    for key, name in SCHEMA_NAMES.items():
        path = schema_dir / f"{name}.schema.json"
        schemas[key] = load_json(path)
        if schemas[key].get("additionalProperties") is not False:
            raise ContractError(f"{name} schema does not reject unknown properties")
    # The query contract is owned by the query module; here its published form
    # must still be a strict self-contained envelope with the same versioning the
    # CLI exports, and the result must embed the one Doc IR declaration model.
    request = load_json(schema_dir / "query-request.schema.json")
    result = load_json(schema_dir / "query-result.schema.json")
    if request.get("additionalProperties") is not False or result.get(
            "additionalProperties") is not False:
        raise ContractError("query schemas must reject unknown properties")
    if request["properties"]["schemaVersion"]["const"] != "cjdoc.query-request/1":
        raise ContractError("query-request schema version is not the published contract")
    if result["properties"]["schemaVersion"]["const"] != "cjdoc.query-result/1":
        raise ContractError("query-result schema version is not the published contract")
    if "declaration" not in result.get("$defs", {}):
        raise ContractError("query-result schema does not embed the Doc IR declaration model")
    schemas["query-request"] = request
    schemas["query-result"] = result
    return schemas


def check(binary: Path, root: Path, schema_dir: Path) -> dict:
    if not root.is_dir() or root.is_symlink():
        raise ContractError("--root must be an existing regular document root")
    schemas = load_schemas(schema_dir)
    navigation = check_navigation(root, schemas["navigation"])
    manifest = check_manifest(root, schemas["manifest"], navigation)
    check_full_reference(root, schemas["full"], manifest["manifest"])
    declarations = check_declaration_artifacts(root, schemas["declaration"], manifest)
    pages = check_page_artifacts(root, schemas["page"], manifest)
    check_navigation_representations(manifest)  # the manifest graph, not the raw document
    rejected_count = reject_mutations(root, schemas, manifest)
    exports = check_schema_exports(binary, schema_dir)
    return {"snapshotId": navigation["root"]["scope"]["snapshotId"],
            "navigationPages": len(navigation["pages"]),
            "navigationParts": navigation["root"]["pagination"]["parts"],
            "declarations": declarations, "pages": pages,
            "resources": len(manifest["manifest"]["resources"]),
            "fullReference": manifest["manifest"]["fullReference"] is not None,
            "rejectedMutations": rejected_count, "schemaExports": exports}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", type=Path, required=True,
                        help="compiled cjdoc executable whose schema exports are checked")
    parser.add_argument("--root", type=Path, required=True,
                        help="generated HTML document root that carries the agent artifacts")
    parser.add_argument("--schema-dir", type=Path,
                        default=Path(__file__).resolve().parent.parent / "docs" / "schema",
                        help="published schema directory (default: repository docs/schema)")
    args = parser.parse_args()
    report = check(args.binary.resolve(), args.root.resolve(), args.schema_dir.resolve())
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    print("agent artifacts verified: navigation, full reference, manifest, declarations, pages")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ContractError, OSError, ValueError) as error:
        print(f"agent artifact verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
