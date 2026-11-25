from __future__ import annotations

import re

from .contracts import (
    DOC_IR_ARRAY_REFS,
    DOC_IR_CORE_DEFS,
    JSON_SCHEMA_DRAFT,
    SCHEMA_CONTRACTS,
    SCHEMA_OPTIONAL_PROPERTIES,
)


ARTIFACT_SCHEMAS = frozenset({
    "navigation-index-v2", "agent-full-index", "declaration", "page",
    "machine-manifest", "query-result",
})
LOOSE_PROPERTY_SCHEMAS = frozenset({"query-request"})
LOOKAROUND = re.compile(r"\(\?(?:[=!]|<[=!])")
DOC_IR_DEFINITIONS = frozenset({
    "declaration", "documentationPage", "package", "documentSetIdentity",
})
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

def local_schema(value: object, shape: object, description: str) -> dict:
    if not isinstance(shape, dict):
        raise ValueError(f"{description} schema is not an object")
    reference = shape.get("$ref")
    if reference is None:
        return shape
    if not isinstance(reference, str) or not reference.startswith("#/$defs/"):
        raise ValueError(f"{description} schema uses a non-local reference")
    return definition(value, reference[len("#/$defs/"):])

def validate_classification_definitions(value: dict, name: str) -> None:
    identifier = definition(value, "classificationId")
    title = definition(value, "classificationTitle")
    classification = definition(value, "documentationClassification")
    tag = definition(value, "documentationClassificationTag")
    group = definition(value, "documentationClassificationGroup")
    if identifier.get("type") != "string" or \
            identifier.get("minLength") != 1 or identifier.get("maxLength") != 64 or \
            identifier.get("pattern") != "^[A-Za-z0-9_-]+$":
        raise ValueError(f"{name} classification ID constraints are invalid")
    if title.get("type") != "string" or title.get("minLength") != 1 or \
            title.get("maxLength") != 256 or title.get("x-maxUtf8Bytes") != 256 or \
            not isinstance(title.get("pattern"), str) or \
            not isinstance(title.get("not"), dict) or \
            not isinstance(title["not"].get("pattern"), str):
        raise ValueError(f"{name} classification title byte limit is invalid")
    if classification.get("type") != "object" or \
            classification.get("additionalProperties") is not False or \
            classification.get("required") != ["group", "tags"] or \
            set(classification.get("properties", {})) != {"group", "tags"} or \
            classification.get("properties", {}).get("group", {}).get("anyOf") != [
                {"$ref": "#/$defs/documentationClassificationGroup"}, {"type": "null"}] or \
            classification.get("properties", {}).get("tags") != {
                "type": "array", "items": {
                    "$ref": "#/$defs/documentationClassificationTag"}}:
        raise ValueError(f"{name} classification shape is invalid")
    if tag.get("type") != "object" or tag.get("additionalProperties") is not False or \
            set(tag.get("required", [])) != {"id", "title"} or \
            set(tag.get("properties", {})) != {"id", "title"} or \
            tag.get("properties", {}).get("id") != {"$ref": "#/$defs/classificationId"} or \
            tag.get("properties", {}).get("title") != {"$ref": "#/$defs/classificationTitle"}:
        raise ValueError(f"{name} classification tag shape is invalid")
    if group.get("type") != "object" or group.get("additionalProperties") is not False or \
            set(group.get("required", [])) != {
                "id", "packageName", "ownerId", "title", "order"} or \
            set(group.get("properties", {})) != {
                "id", "packageName", "ownerId", "title", "order"} or \
            group.get("properties", {}).get("id") != {"$ref": "#/$defs/classificationId"} or \
            group.get("properties", {}).get("packageName") != {
                "type": "string", "minLength": 1} or \
            group.get("properties", {}).get("title") != {"$ref": "#/$defs/classificationTitle"} or \
            group.get("properties", {}).get("ownerId", {}).get("anyOf") != [
                {"type": "string", "minLength": 1}, {"type": "null"}] or \
            group.get("properties", {}).get("order", {}).get("anyOf") != [
                {"type": "integer", "minimum": 0, "maximum": 999999}, {"type": "null"}]:
        raise ValueError(f"{name} classification group identity/null contract is invalid")


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


def validate_embedded_doc_ir_definitions(name: str, value: dict, properties: dict,
                                         frozen_definitions: dict | None) -> None:
    definitions = value.get("$defs")
    names = set(definitions) if isinstance(definitions, dict) else set()
    missing = ARTIFACT_REQUIRED_DEFINITIONS[name] - names
    if missing:
        raise ValueError(f"{name} schema definitions are missing: {sorted(missing)}")
    embedded = set(frozen_definitions or ()) & DOC_IR_DEFINITIONS & names
    if not embedded:
        raise ValueError(f"{name} schema does not embed any current Doc IR v17 definition")
    for definition_name in embedded:
        if definitions[definition_name] != frozen_definitions[definition_name]:
            raise ValueError(
                f"{name} schema forks the current Doc IR definition: {definition_name}")
    for required in ("symbol", "page"):
        reference = properties.get(required)
        if isinstance(reference, dict) and reference.get("$ref", "").endswith("/null"):
            raise ValueError(f"{name} schema does not reference the shared Doc IR model")


def validate_navigation_index_v2_schema(value: dict, properties: dict) -> None:
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


def validate_agent_full_index_schema(value: dict) -> None:
    part = definition(value, "part")
    if "sha256" not in part.get("required", []):
        raise ValueError("agent-full-index part digest is not required")
    omitted = definition(value, "omittedSection")
    if omitted.get("properties", {}).get("reason") != {"const": "aggregate_unit_budget"}:
        raise ValueError("agent-full-index omission reason is invalid")


def validate_machine_manifest_schema(value: dict, properties: dict) -> None:
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


def validate_query_result_schema(value: dict, properties: dict) -> None:
    validate_classification_definitions(value, "query-result")
    for expected in ("querySnapshot", "queryItem", "queryIdentity", "queryRelation",
                     "queryFacets", "queryTagFacet"):
        definition(value, expected)
    result = properties.get("result")
    facets = definition(value, "queryFacets")
    facet = definition(value, "queryTagFacet")
    item = definition(value, "queryItem")
    facet_scope = facet.get("properties", {}).get("scope", {})
    expected_scope_fields = {
        "snapshotId", "sourceSnapshotId", "moduleId", "documentSet",
        "dependencyInstance", "dependencyInstanceState",
    }
    facet_properties = facet.get("properties", {})
    if not isinstance(result, dict) or result.get("additionalProperties") is not False or \
            set(result.get("required", [])) != {"items", "relations", "reports", "facets"} or \
            result.get("properties", {}).get("facets") != {"$ref": "#/$defs/queryFacets"} or \
            facets.get("additionalProperties") is not False or \
            facets.get("required") != ["tags"] or \
            set(facets.get("properties", {})) != {"tags", "commentFields"} or \
            facets.get("properties", {}).get("tags", {}).get("items") != {
                "$ref": "#/$defs/queryTagFacet"} or \
            facet.get("additionalProperties") is not False or \
            set(facet.get("required", [])) != {"scope", "id", "title", "count"} or \
            set(facet_properties) != {"scope", "id", "title", "count"} or \
            facet_properties.get("id") != {"$ref": "#/$defs/classificationId"} or \
            facet_properties.get("title") != {"$ref": "#/$defs/classificationTitle"} or \
            facet_properties.get("count") != {"type": "integer", "minimum": 1} or \
            facet_scope.get("additionalProperties") is not False or \
            set(facet_scope.get("required", [])) != expected_scope_fields or \
            set(facet_scope.get("properties", {})) != expected_scope_fields or \
            facet_scope.get("properties", {}).get("moduleId") != {
                "$ref": "#/$defs/moduleId"} or \
            facet_scope.get("properties", {}).get("documentSet") != {
                "anyOf": [{"$ref": "#/$defs/documentSetIdentity"}, {"type": "null"}]} or \
            facet_scope.get("properties", {}).get("dependencyInstance") != {
                "anyOf": [{"$ref": "#/$defs/dependencyInstance"}, {"type": "null"}]} or \
            facet_scope.get("properties", {}).get("dependencyInstanceState") != {
                "enum": ["recorded", "not_applicable", "unrecorded", "ambiguous"]}:
        raise ValueError("query-result tag facet identity contract is invalid")
    if "classification" not in item.get("required", []) or \
            item.get("properties", {}).get("classification") != {
                "$ref": "#/$defs/documentationClassification"}:
        raise ValueError("query-result item classification is not required")
    comment_page = definition(value, "queryCommentFieldFacetPage")
    comment_row = definition(value, "queryCommentFieldFacet")
    if facets["properties"]["commentFields"] != {"$ref": "#/$defs/queryCommentFieldFacetPage"} or \
            comment_page.get("additionalProperties") is not False or \
            set(comment_page.get("required", [])) != {"items", "next"} or \
            comment_page.get("properties") != {
                "items": {"type": "array", "maxItems": 100,
                          "items": {"$ref": "#/$defs/queryCommentFieldFacet"}},
                "next": {"type": ["string", "null"]}} or \
            comment_row.get("additionalProperties") is not False or \
            set(comment_row.get("required", [])) != {"scope", "id", "title", "value", "count"} or \
            set(comment_row.get("properties", {})) != {"scope", "id", "title", "value", "count"}:
        raise ValueError("query-result comment field facet contract is invalid")


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
        validate_embedded_doc_ir_definitions(name, value, properties, frozen_definitions)
    if name == "navigation-index-v2":
        validate_navigation_index_v2_schema(value, properties)
    elif name == "agent-full-index":
        validate_agent_full_index_schema(value)
    elif name == "machine-manifest":
        validate_machine_manifest_schema(value, properties)
    elif name == "query-result":
        validate_query_result_schema(value, properties)


def validate_doc_ir_collection_shapes(name: str, properties: dict) -> None:
    for property_name, definition_name in DOC_IR_ARRAY_REFS.items():
        property_schema = properties[property_name]
        if not isinstance(property_schema, dict) or \
                property_schema.get("type") != "array" or \
                property_schema.get("items") != {"$ref": f"#/$defs/{definition_name}"}:
            raise ValueError(
                f"{name} schema collection shape is invalid: {property_name}"
            )
    for property_name, definition_name in (
        ("generator", "generator"), ("project", "project"),
        ("configuration", "configuration"),
    ):
        if properties[property_name] != {"$ref": f"#/$defs/{definition_name}"}:
            raise ValueError(
                f"{name} schema object reference is invalid: {property_name}"
            )
    if properties["status"] != {"enum": ["complete", "partial"]}:
        raise ValueError(f"{name} schema status shape is invalid")
    if properties["apiCollectionState"] != {
        "enum": ["resolved", "partial", "unavailable"]
    }:
        raise ValueError(f"{name} API collection state shape is invalid")


def validate_doc_ir_provenance(name: str, value: dict, definitions: dict) -> None:
    if "repository" not in definitions:
        raise ValueError(f"{name} repository definition is missing")
    file_schema = definition(value, "file")
    provenance = definition(value, "sourceProvenance")
    provenance_fields = {
        "state", "reason", "repository", "repositoryPath", "sourceDigest",
        "normalizedDigest", "evidenceIdentity", "evidenceKind",
    }
    if "provenance" not in file_schema.get("required", []) or \
            file_schema.get("properties", {}).get("provenance") != {
                "$ref": "#/$defs/sourceProvenance"} or \
            provenance.get("type") != "object" or \
            provenance.get("additionalProperties") is not False or \
            set(provenance.get("required", [])) != provenance_fields or \
            set(provenance.get("properties", {})) != provenance_fields or \
            provenance.get("properties", {}).get("state") != {
                "$ref": "#/$defs/sourceProvenanceState"} or \
            definition(value, "sourceProvenanceState") != {
                "enum": ["verified", "declared", "unavailable", "ambiguous"]} or \
            provenance.get("properties", {}).get("reason") != {
                "$ref": "#/$defs/sourceProvenanceReason"} or \
            provenance.get("properties", {}).get("evidenceKind") != {
                "enum": ["caller_pinned_receipt", "none"]}:
        raise ValueError(f"{name} source provenance contract is invalid")
    if "evidenceKey" in definitions.get("tag", {}).get("properties", {}):
        raise ValueError(f"{name} schema contains removed tag evidence")


def validate_doc_ir_metadata(name: str, value: dict, properties: dict) -> None:
    metadata = definition(value, "documentationMetadata")
    if properties.get("metadata") != {"$ref": "#/$defs/documentationMetadata"} or \
            metadata.get("additionalProperties") is not False or \
            metadata.get("required") != ["groups", "tags", "fields"] or \
            set(metadata.get("properties", {})) != {"groups", "tags", "fields"}:
        raise ValueError(f"{name} metadata root shape is invalid")
    metadata_shapes = {
        "documentationTitle": ({"language", "title"}, {"language", "title"}),
        "documentationGroupDefinition": (
            {"moduleId", "packageName", "ownerId", "id", "title", "titles", "order"},
            {"moduleId", "packageName", "ownerId", "id", "title", "titles", "order"},
        ),
        "documentationTagDefinition": (
            {"moduleId", "id", "title", "titles"},
            {"moduleId", "id", "title", "titles"},
        ),
        "documentationFieldDefinition": (
            {"moduleId", "id", "title", "titles", "repeatable", "uses"},
            {"moduleId", "id", "title", "titles", "repeatable", "uses"},
        ),
        "documentationFieldUse": ({"symbolId", "values"}, {"symbolId", "values"}),
    }
    for definition_name, (required_fields, property_fields) in metadata_shapes.items():
        shape = definition(value, definition_name)
        if shape.get("additionalProperties") is not False or \
                set(shape.get("required", [])) != required_fields or \
                set(shape.get("properties", {})) != property_fields:
            raise ValueError(f"{name} metadata definition shape is invalid: {definition_name}")
        if shape.get("type") != "object":
            raise ValueError(f"{name} metadata definition is not an object: {definition_name}")
    title = definition(value, "documentationTitle")
    group = definition(value, "documentationGroupDefinition")
    tag = definition(value, "documentationTagDefinition")
    if title.get("properties", {}).get("language") != {"enum": ["zh-CN", "en"]} or \
            title.get("properties", {}).get("title") != {
                "$ref": "#/$defs/metadataTitleText"} or \
            group.get("properties", {}).get("moduleId") != {
                "type": "string", "minLength": 1} or \
            group.get("properties", {}).get("packageName") != {
                "type": "string", "minLength": 1} or \
            group.get("properties", {}).get("ownerId") != {
                "$ref": "#/$defs/nullableSymbolId"} or \
            group.get("properties", {}).get("order", {}).get("anyOf") != [
                {"type": "integer", "minimum": 0, "maximum": 999999},
                {"type": "null"}] or \
            tag.get("properties", {}).get("moduleId") != {
                "type": "string", "minLength": 1}:
        raise ValueError(f"{name} metadata group scope or null/order contract is invalid")
    for definition_name, shape in (("documentationGroupDefinition", group),
                                   ("documentationTagDefinition", tag)):
        id_shape = shape.get("properties", {}).get("id", {})
        if id_shape.get("type") != "string" or \
                id_shape.get("pattern") != "^[A-Za-z0-9_-]{1,64}$" or \
                shape.get("properties", {}).get("title") != {
                    "$ref": "#/$defs/metadataTitleText"} or \
                shape.get("properties", {}).get("titles", {}).get("type") != "array" or \
                shape.get("properties", {}).get("titles", {}).get("maxItems") != 2 or \
                shape.get("properties", {}).get("titles", {}).get("items") != {
                    "$ref": "#/$defs/documentationTitle"}:
            raise ValueError(
                f"{name} metadata title/id contract is invalid: {definition_name}")
    for field in ("groups", "tags"):
        if metadata.get("properties", {}).get(field, {}).get("type") != "array" or \
                metadata.get("properties", {}).get(field, {}).get("maxItems") != 2048:
            raise ValueError(f"{name} metadata definition budget is invalid: {field}")
    for field, item in (("groups", "documentationGroupDefinition"),
                        ("tags", "documentationTagDefinition")):
        if metadata.get("properties", {}).get(field, {}).get("items") != {
                "$ref": f"#/$defs/{item}"}:
            raise ValueError(f"{name} metadata collection shape is invalid: {field}")
    title_text = definition(value, "metadataTitleText")
    if title_text.get("type") != "string" or title_text.get("minLength") != 1 or \
            title_text.get("maxLength") != 256 or title_text.get("x-maxUtf8Bytes") != 256:
        raise ValueError(f"{name} metadata title byte limit is invalid")


def validate_doc_ir_markdown(name: str, definitions: dict) -> None:
    markdown_definitions = {
        "codeBlockMetadata", "headingMetadata", "listMetadata",
        "listItemMetadata", "tableMetadata", "tableRowMetadata",
        "tableCellMetadata",
    }
    if not markdown_definitions.issubset(definitions):
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


def validate_doc_ir_schema(name: str, value: dict, properties: dict) -> None:
    definitions = value.get("$defs")
    if not isinstance(definitions, dict) or not DOC_IR_CORE_DEFS.issubset(definitions):
        raise ValueError(f"{name} schema critical definitions are missing")
    validate_doc_ir_collection_shapes(name, properties)
    validate_doc_ir_provenance(name, value, definitions)
    if name in ("doc-ir", "doc-ir-v19"):
        validate_doc_ir_metadata(name, value, properties)
        validate_doc_ir_markdown(name, definitions)


def validate_source_provenance_schema(value: dict, properties: dict) -> None:
    repository = local_schema(value, properties.get("repository"), "source-provenance repository")
    files = properties.get("files")
    item = local_schema(value, files.get("items") if isinstance(files, dict) else None,
                        "source-provenance file")
    repository_properties = repository.get("properties", {})
    item_properties = item.get("properties", {})
    repository_url = repository_properties.get("url")
    repository_revision = repository_properties.get("revision")
    file_path = local_schema(value, item_properties.get("path"), "source-provenance file path")
    file_digest = item_properties.get("sha256")
    if repository.get("type") != "object" or \
            repository.get("additionalProperties") is not False or \
            set(repository.get("required", [])) != {"url", "revision"} or \
            set(repository_properties) != {"url", "revision"} or \
            not isinstance(repository_url, dict) or \
            repository_url.get("pattern") != \
                "^https://github.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$" or \
            not isinstance(repository_revision, dict) or \
            repository_revision.get("pattern") != "^[0-9a-f]{40}$" or \
            not isinstance(files, dict) or files.get("type") != "array" or \
            files.get("maxItems") != 100000 or \
            item.get("type") != "object" or \
            item.get("additionalProperties") is not False or \
            set(item.get("required", [])) != {"path", "sha256"} or \
            set(item_properties) != {"path", "sha256"} or \
            file_path.get("type") != "string" or file_path.get("minLength") != 1 or \
            file_path.get("pattern") != "^[^/]+(?:/[^/]+)*$" or \
            not isinstance(file_digest, dict) or \
            file_digest.get("pattern") != "^[0-9a-f]{64}$":
        raise ValueError("source-provenance receipt schema shape is invalid")


def validate_query_request_schema(value: dict, properties: dict, required: list) -> None:
    tags = properties.get("tags")
    tag_items = tags.get("items") if isinstance(tags, dict) else None
    if tags is not None and (
            not isinstance(tags, dict)
            or tags.get("type") != "array"
            or tags.get("minItems") != 1
            or tags.get("maxItems") != 64
            or "tags" in required
            or not isinstance(tag_items, dict)
            or tag_items.get("type") != "string"
            or tag_items.get("pattern") != "^[A-Za-z0-9_-]{1,64}$"
            or tag_items.get("minLength") != 1
            or tag_items.get("maxLength") != 64
    ):
        raise ValueError("query-request tags set predicate contract is invalid")


def validate_declaration_schema(value: dict, properties: dict) -> None:
    validate_classification_definitions(value, "declaration")
    if properties.get("classification") != {
            "$ref": "#/$defs/documentationClassification"}:
        raise ValueError("declaration classification is not required")


def validate_diagnostics_schema(properties: dict) -> None:
    if properties["diagnostics"] != {
        "type": "array", "items": {"$ref": "doc-ir.schema.json#/$defs/diagnostic"}
    }:
        raise ValueError("diagnostics schema collection shape is invalid")


def validate_cfg_matrix_schema(properties: dict) -> None:
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


def validate_search_index_schema(name: str, value: dict, properties: dict) -> None:
    validate_classification_definitions(value, name)
    entries = properties.get("entries")
    definitions = value.get("$defs")
    if not isinstance(definitions, dict):
        raise ValueError("search-index schema definitions are invalid")
    entry = definitions.get("entry")
    module = definitions.get("module")
    tag_dictionary_entry = definitions.get("tagDictionaryEntry")
    coverage = properties.get("coverage")
    scope_schema = properties.get("scope")
    search_contract = definitions.get("searchContract")
    search_contract_fields = {
        "version", "maxRequestBytes", "textPolicy", "defaultMode", "defaultProfile",
        "defaultLimit", "maxLimit", "maxFilters", "maxTags", "staticBodyTextLimit",
        "summaryDisplayLimit", "signatureDisplayLimit", "requestProperties",
        "globalFields", "searchFields", "filterFields", "filterOps", "setPredicates",
        "preciseRules", "discoveryRules",
    }
    expected_set_predicates = {
        "type": "array", "minItems": 1, "maxItems": 1,
        "items": {
            "type": "object", "additionalProperties": False,
            "required": ["field", "property", "primitive"],
            "properties": {
                "field": {"const": "tags"},
                "property": {"const": "tagIds"},
                "primitive": {"const": "all_exact"},
            },
        },
    }
    entry_required = {
        "id", "canonicalId", "snapshotId", "scope", "concept", "genericArity",
        "ownerId", "name", "qualifiedName", "kind", "packageName", "ownerName",
        "ownerQualifiedName", "symbolKey", "parameterTypes", "returnType",
        "returnCanonical", "summary", "summaryDisplay", "body", "bodyTruncated",
        "href", "exposures", "sections", "externalDocs", "bindings", "classification", "commentFields"
    }
    coverage_required = {
        "profile", "projectionId", "bodyTextLimit", "bodyComplete", "truncatedEntries"
    }
    scope_required = {
        "snapshotId", "sourceSnapshotId", "publicationRevision", "project",
        "language", "audience", "cfgProfile", "apiCollectionState"
    }
    module_required = {
        "moduleId", "moduleName", "documentSet", "dependency", "dependencyInstanceState"
    }
    root_required = {
        "schemaVersion", "profile", "contract", "projectionId", "scope", "coverage",
        "modules", "tags", "commentFields", "entries"
    }
    tags = properties.get("tags")
    if (
            not isinstance(entries, dict)
            or entries.get("type") != "array"
            or entries.get("items") != {"$ref": "#/$defs/entry"}
            or not isinstance(entry, dict)
            or entry.get("type") != "object"
            or entry.get("additionalProperties") is not False
            or set(entry.get("required", [])) != entry_required
            or set(entry.get("properties", {})) != entry_required
            or entry.get("properties", {}).get("classification") != {
                "$ref": "#/$defs/documentationClassification"}
            or not isinstance(tags, dict)
            or tags.get("type") != "array"
            or tags.get("items") != {"$ref": "#/$defs/tagDictionaryEntry"}
            or not isinstance(tag_dictionary_entry, dict)
            or tag_dictionary_entry.get("type") != "object"
            or tag_dictionary_entry.get("additionalProperties") is not False
            or tag_dictionary_entry.get("required") != ["scope", "id", "title"]
            or set(tag_dictionary_entry.get("properties", {})) != {"scope", "id", "title"}
            or tag_dictionary_entry.get("properties", {}).get("scope") != {
                "type": "integer", "minimum": 0, "maximum": 4095}
            or tag_dictionary_entry.get("properties", {}).get("id") != {
                "$ref": "#/$defs/classificationId"}
            or tag_dictionary_entry.get("properties", {}).get("title") != {
                "$ref": "#/$defs/classificationTitle"}
            or not isinstance(value.get("required"), list)
            or set(value["required"]) != root_required
            or properties.get("contract") != {"$ref": "#/$defs/searchContract"}
            or not isinstance(search_contract, dict)
            or search_contract.get("additionalProperties") is not False
            or search_contract.get("type") != "object"
            or set(search_contract.get("required", [])) != search_contract_fields
            or set(search_contract.get("properties", {})) != search_contract_fields
            or search_contract.get("properties", {}).get("version") != {
                "const": "cjdoc.search-contract/3"}
            or search_contract.get("properties", {}).get("maxTags") != {
                "type": "integer", "minimum": 1, "maximum": 64}
            or search_contract.get("properties", {}).get("setPredicates") !=
                expected_set_predicates
            or not isinstance(coverage, dict)
            or coverage.get("type") != "object"
            or set(coverage.get("required", [])) != coverage_required
            or set(coverage.get("properties", {})) != coverage_required
            or coverage.get("additionalProperties") is not False
            or not isinstance(scope_schema, dict)
            or scope_schema.get("type") != "object"
            or scope_schema.get("additionalProperties") is not False
            or set(scope_schema.get("required", [])) != scope_required
            or set(scope_schema.get("properties", {})) != scope_required
            or not isinstance(module, dict)
            or module.get("type") != "object"
            or properties.get("modules", {}).get("items") != {"$ref": "#/$defs/module"}
            or set(module.get("required", [])) != module_required
            or set(module.get("properties", {})) != module_required
            or module.get("properties", {}).get("documentSet") != {
                "anyOf": [{"$ref": "#/$defs/documentSet"}, {"type": "null"}]}
            or module.get("properties", {}).get("dependency") != {
                "anyOf": [{"$ref": "#/$defs/dependency"}, {"type": "null"}]}
            or module.get("additionalProperties") is not False
    ):
        raise ValueError("search-index schema entry shape is invalid")
    if module.get("properties", {}).get("dependencyInstanceState") != {
            "enum": ["recorded", "not_applicable", "unrecorded", "ambiguous"]}:
        raise ValueError("search-index dependency instance state contract changed")


def validate_symbol_index_schema(properties: dict) -> None:
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


def validate_navigation_index_schema(value: dict, properties: dict) -> None:
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


def validate_api_surface_schema(name: str, value: dict) -> None:
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


def validate_documentation_coverage_schema(value: dict, properties: dict) -> None:
    definitions = value.get("$defs")
    if not isinstance(definitions, dict) or not {"metric", "metrics", "group"}.issubset(definitions) or \
            properties.get("metrics") != {"$ref": "#/$defs/metrics"} or \
            properties.get("packages", {}).get("items") != {"$ref": "#/$defs/group"} or \
            properties.get("modules", {}).get("items") != {"$ref": "#/$defs/group"}:
        raise ValueError("documentation-coverage schema metrics shape is invalid")


def validate_versions_schema(value: dict, properties: dict) -> None:
    definitions = value.get("$defs")
    versions = properties["versions"]
    if (not isinstance(definitions, dict) or
            not {"safePath", "version"}.issubset(definitions) or
            versions != {"type": "array", "minItems": 1, "maxItems": 64,
                         "items": {"$ref": "#/$defs/version"}}):
        raise ValueError("versions schema manifest shape is invalid")


def validate_schema_root(name: str, value: object) -> tuple[dict, list]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} schema root must be an object")
    expected_id, _, expected_required = SCHEMA_CONTRACTS[name]
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
    return properties, required


def validate_schema_version(name: str, value: dict, properties: dict) -> None:
    _, expected_version, expected_required = SCHEMA_CONTRACTS[name]
    actual_version = properties.get("schemaVersion", {}).get("const") \
        if isinstance(properties.get("schemaVersion"), dict) else None
    if name == "machine-manifest":
        pairs = [("cjdoc.machine-manifest/1", "cjdoc.read/1"),
                 ("cjdoc.machine-manifest/2", "cjdoc.read/2"),
                 (expected_version, "cjdoc.read/3")]
        if properties["schemaVersion"] != {"enum": [version for version, _ in pairs]} or \
                properties["projection"] != {"enum": [projection for _, projection in pairs]} or \
                value.get("oneOf") != [{"properties": {"schemaVersion": {"const": version},
                                                       "projection": {"const": projection}}}
                                       for version, projection in pairs]:
            raise ValueError("machine-manifest schema must bind each version to its reading projection")
    elif actual_version != expected_version:
        raise ValueError(f"{name} schema does not declare {expected_version}")
    if name in LOOSE_PROPERTY_SCHEMAS:
        # The request schema belongs to the query contract and may add optional
        # narrowing fields; only its identity, version and mandatory operation
        # are pinned here.
        if not set(expected_required).issubset(properties):
            raise ValueError(f"{name} schema lost a required field")


def validate_graph_binding(name: str, value: dict, properties: dict) -> None:
    if name in ("doc-ir", "doc-ir-v19") and properties["documentationRevision"] != {"type": "string"}:
        raise ValueError(f"{name} schema documentation revision shape is invalid")
    if name in ("doc-ir", "doc-ir-v19", "symbol-index"):
        definitions = value.get("$defs")
        for definition_name, graph_field in (
            ("dependencyInstance", "componentModuleId"), ("documentSetIdentity", "moduleId"),
            ("documentSetIdentity", "apiVersion"), ("documentSetIdentity", "documentationRevision"),
        ):
            graph_definition = definitions.get(definition_name) if isinstance(definitions, dict) else None
            if not isinstance(graph_definition, dict) or graph_field not in graph_definition.get("required", []) or \
                    graph_definition.get("properties", {}).get(graph_field) != {"type": "string"}:
                raise ValueError(f"{name} schema graph binding field is missing: {definition_name}.{graph_field}")


def validate_schema_document(name: str, value: object,
                             frozen_definitions: dict | None = None) -> None:
    properties, required = validate_schema_root(name, value)
    validate_schema_version(name, value, properties)
    if name in ARTIFACT_SCHEMAS:
        validate_artifact_schema(name, value, properties, frozen_definitions)
    validate_graph_binding(name, value, properties)
    if name.startswith("doc-ir"):
        validate_doc_ir_schema(name, value, properties)
    elif name == "source-provenance":
        validate_source_provenance_schema(value, properties)
    elif name == "query-request":
        validate_query_request_schema(value, properties, required)
    elif name == "declaration":
        validate_declaration_schema(value, properties)
    elif name == "diagnostics":
        validate_diagnostics_schema(properties)
    elif name == "cfg-matrix":
        validate_cfg_matrix_schema(properties)
    elif name in ("search-index", "search-index-v12"):
        validate_search_index_schema(name, value, properties)
    elif name == "symbol-index":
        validate_symbol_index_schema(properties)
    elif name == "navigation-index":
        validate_navigation_index_schema(value, properties)
    elif name in ("api-surface", "api-surface-v3", "api-diff", "api-diff-v2"):
        validate_api_surface_schema(name, value)
    elif name == "documentation-coverage":
        validate_documentation_coverage_schema(value, properties)
    elif name in ("versions", "versions-v2"):
        validate_versions_schema(value, properties)
