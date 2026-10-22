package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import yjson.*
import yjson_algorithms.*


// A domain-depth-64 TypeRef or Markdown chain adds at most two JSON container
// levels and three schema-validation frames per edge; the enclosing document
// contributes fewer than 32 frames. 512 therefore leaves more than 2x margin
// while retaining a finite parser and schema recursion budget.
internal let DOC_IR_CODEC_MAX_NESTING_DEPTH: Int64 = 512

// The schema corpus needs fewer than sixty-four evaluations per JSON object and
// regex validation also traverses each constrained string. Keep its finite budget
// separate from structural evaluation work so large real repositories remain
// valid without weakening object, array, or parser limits.
internal let DOC_IR_SCHEMA_MAX_WORK: Int64 =
    DOC_IR_MAX_SCHEMA_OBJECTS * 64 + DOC_IR_MAX_SCHEMA_ARRAY_ITEMS * 4
internal let DOC_IR_SCHEMA_MAX_REGEX_STEPS: Int64 = DOC_IR_SCHEMA_MAX_WORK * 4

internal func fail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR at ${path}: ${message}")
}


internal func jsonArrayValues(value: JsonArray): ArrayList<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (index in 0..value.size()) { result.add(value.get(index).getOrThrow()) }
    result
}

internal func compatibleSchemaText(schemaText: String): String {
    let portablePathPattern = "\"pattern\": \"^.+$\""
    let currentPattern = "\"pattern\": \"^(?![A-Za-z]:)(?!.*\\\\\\\\)(?!\\\\.{1,2}(?:/|$))(?!.*/\\\\.{1,2}(?:/|$))[^/]+(?:/[^/]+)*$\""
    schemaText.replace(currentPattern, portablePathPattern)
}

internal func validatePortablePathValue(value: String, path: String): Unit {
    if (value.isEmpty() || value.startsWith("/") || value.endsWith("/") ||
        value.contains("//") || value.contains("\\")) {
        throw IllegalArgumentException("invalid Doc IR schema at ${path}: invalid portable path")
    }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") {
            throw IllegalArgumentException("invalid Doc IR schema at ${path}: invalid portable path")
        }
    }
    let first = segments[0].toArray()
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'A' && first[0] <= b'Z') ||
        (first[0] >= b'a' && first[0] <= b'z'))) {
        throw IllegalArgumentException("invalid Doc IR schema at ${path}: invalid portable path")
    }
}

internal func validatePortablePathFields(node: JsonNode, path: String): Unit {
    match (node.kind()) {
        case JsonKind.Object =>
            let object = node.asObject()
            for (index in 0..object.size()) {
                let key = object.nameAt(index)
                let child = object.valueAt(index)
                if ((key == "sourcePrefix" || key == "repositoryPath") && child.kind() == JsonKind.String) {
                    let value = child.asString()
                    if (!value.isEmpty()) { validatePortablePathValue(value, "${path}.${key}") }
                } else if (key == "sourceFiles" && child.kind() == JsonKind.Array) {
                    var itemIndex: Int64 = 0
                    for (item in jsonArrayValues(child.asArray())) {
                        if (item.kind() == JsonKind.String) {
                            validatePortablePathValue(item.asString(), "${path}.${key}[${itemIndex}]")
                        }
                        itemIndex++
                    }
                } else if ((key == "path" || key == "sourcePath") &&
                    child.kind() == JsonKind.String) {
                    validatePortablePathValue(child.asString(), "${path}.${key}")
                }
                validatePortablePathFields(child, "${path}.${key}")
            }
        case JsonKind.Array =>
            var index: Int64 = 0
            for (item in jsonArrayValues(node.asArray())) {
                validatePortablePathFields(item, "${path}[${index}]")
                index++
            }
        case _ => ()
    }
}

internal func validateRawSchemaShape(root: JsonNode): Unit {
    let pending = ArrayList<JsonNode>()
    pending.add(root)
    var objects: Int64 = 0
    var arrayItems: Int64 = 0
    while (!pending.isEmpty()) {
        let node = pending.remove(at: pending.size - 1)
        match (node.kind()) {
            case JsonKind.Object =>
                objects++
                if (objects > DOC_IR_MAX_SCHEMA_OBJECTS) {
                    fail("$", "JSON object occurrence budget exceeded")
                }
                let object = node.asObject()
                for (index in 0..object.size()) { pending.add(object.valueAt(index)) }
            case JsonKind.Array =>
                let values = jsonArrayValues(node.asArray())
                if (values.size > DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - arrayItems) {
                    fail("$", "JSON array item occurrence budget exceeded")
                }
                arrayItems += values.size
                for (child in values) { pending.add(child) }
            case _ => ()
        }
    }
}

internal func validateDeclarativeSchema(root: JsonNode): Unit {
    let version = try {
        root.asObject().get("schemaVersion").getOrThrow().asString()
    } catch (_: Exception) {
        fail("$.schemaVersion", "expected string")
    }
    if (version != DOC_IR_SCHEMA_VERSION) {
        fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}'")
    }
    let schema = JsonSchema.parse(compatibleSchemaText(DOC_IR_SCHEMA), config: JsonSchemaConfig(
        limits: JsonSchemaLimits(maxEvaluations: DOC_IR_SCHEMA_MAX_WORK,
            maxRefResolutions: DOC_IR_SCHEMA_MAX_WORK, maxRegexSteps: DOC_IR_SCHEMA_MAX_REGEX_STEPS,
            maxErrors: 20, maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH)))
    let errors = schema.validate(root)
    if (!errors.isEmpty()) {
        let first = errors[0]
        throw IllegalArgumentException("invalid Doc IR schema at ${first.instancePath} " +
            "(${first.schemaPath}): ${first.message}")
    }
}

internal func strictObject(node: JsonNode, path: String, keys: Array<String>): JsonObject {
    let object = try { node.asObject() } catch (_: Exception) { fail(path, "expected object") }
    let allowed = HashSet<String>()
    for (key in keys) { let _ = allowed.add(key) }
    for (index in 0..object.size()) {
        let key = object.nameAt(index)
        if (!allowed.contains(key)) { fail(path, "unknown field '${key}'") }
    }
    object
}

internal func required(object: JsonObject, key: String, path: String): JsonNode {
    match (object.get(key)) {
        case Some(value) => value
        case None => fail(path, "missing required field '${key}'")
    }
}

internal func stringAt(object: JsonObject, key: String, path: String): String {
    try { required(object, key, path).asString() }
    catch (_: Exception) { fail("${path}.${key}", "expected string") }
}

internal func defaultStringAt(object: JsonObject, key: String, path: String): String {
    match (object.get(key)) {
        case None => ""
        case Some(value) =>
            try { value.asString() }
            catch (_: Exception) { fail("${path}.${key}", "expected string") }
    }
}
internal func boolAt(object: JsonObject, key: String, path: String): Bool {
    try { required(object, key, path).asBool() }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean") }
}

internal func intAt(object: JsonObject, key: String, path: String): Int64 {
    try { required(object, key, path).asInt64() }
    catch (_: Exception) { fail("${path}.${key}", "expected integer") }
}

internal func nullableStringAt(object: JsonObject, key: String, path: String): ?String {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.asString()) }
    catch (_: Exception) { fail("${path}.${key}", "expected string or null") }
}


internal func repositoryAt(node: JsonNode, path: String): RepositoryInfo {
    let value = strictObject(node, path, ["url", "revision"])
    try {
        RepositoryInfo(stringAt(value, "url", path), stringAt(value, "revision", path))
    } catch (error: IllegalArgumentException) {
        throw IllegalArgumentException("invalid Doc IR schema at ${path}: ${error.message}")
    }
}

internal func nullableRepositoryAt(object: JsonObject, key: String, path: String): ?RepositoryInfo {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    Some(repositoryAt(value, "${path}.${key}"))
}

internal func nullableBoolAt(object: JsonObject, key: String, path: String): ?Bool {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.asBool()) }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean or null") }
}

internal func arrayAt(object: JsonObject, key: String, path: String): JsonArray {
    try { required(object, key, path).asArray() }
    catch (_: Exception) { fail("${path}.${key}", "expected array") }
}

internal func stringsAt(object: JsonObject, key: String, path: String): Array<String> {
    let values = ArrayList<String>()
    var index: Int64 = 0
    for (value in jsonArrayValues(arrayAt(object, key, path))) {
        try { values.add(value.asString()) }
        catch (_: Exception) { fail("${path}.${key}[${index}]", "expected string") }
        index++
    }
    values.toArray()
}

internal func decodePosition(node: JsonNode, path: String): SourcePosition {
    let value = strictObject(node, path, ["line", "column", "byteOffset"])
    SourcePosition(intAt(value, "line", path), intAt(value, "column", path),
        intAt(value, "byteOffset", path))
}

internal func decodeRange(node: JsonNode, path: String): SourceRange {
    let value = strictObject(node, path, ["path", "start", "end"])
    SourceRange(stringAt(value, "path", path),
        decodePosition(required(value, "start", path), "${path}.start"),
        decodePosition(required(value, "end", path), "${path}.end"))
}

internal func decodeSourceApiSignature(node: JsonNode, path: String): SourceApiSignature {
    let value = strictObject(node, path, ["state", "tokens"])
    SourceApiSignature(stringAt(value, "state", path), tokens: stringsAt(value, "tokens", path))
}

internal func decodeCapabilities(node: JsonNode, path: String): SemanticCapabilities {
    let value = strictObject(node, path, ["sourceBinding", "ownership", "visibility",
        "canonicalTypes", "canonicalSignatures", "relationships", "annotations"])
    SemanticCapabilities(boolAt(value, "sourceBinding", path), boolAt(value, "ownership", path),
        boolAt(value, "visibility", path), boolAt(value, "canonicalTypes", path),
        boolAt(value, "canonicalSignatures", path), relationships: boolAt(value, "relationships", path),
        annotations: boolAt(value, "annotations", path))
}
internal func decodeTypeRef(node: JsonNode, path: String, depth: Int64): TypeRef {
    if (depth > DOC_IR_MAX_TYPE_DEPTH) {
        fail(path, "type nesting exceeds ${DOC_IR_MAX_TYPE_DEPTH}")
    }
    let value = strictObject(node, path,
        ["kind", "spelling", "nullable", "arguments", "semanticState", "semanticCanonical",
            "semanticProvider", "navigation"])
    let arguments = ArrayList<TypeRef>()
    var index: Int64 = 0
    for (argument in jsonArrayValues(arrayAt(value, "arguments", path))) {
        arguments.add(decodeTypeRef(argument, "${path}.arguments[${index}]", depth + 1))
        index++
    }
    TypeRef(stringAt(value, "kind", path), stringAt(value, "spelling", path),
        SemanticType(stringAt(value, "semanticState", path),
            canonical: nullableStringAt(value, "semanticCanonical", path),
            provider: nullableStringAt(value, "semanticProvider", path)),
        nullable: boolAt(value, "nullable", path), arguments: arguments.toArray(),
        navigation: decodeTypeNavigation(value.get("navigation"), "${path}.navigation"))
}
internal func decodeTag(node: JsonNode, path: String): DocTag {
    let value = strictObject(node, path,
        ["name", "subject", "description", "referenceState", "targetSymbolId", "directives",
            "exampleMarkdown", "contentLanguage", "translationState", "fieldId",
            "descriptionMarkdown", "navigation"])
    DocTag(stringAt(value, "name", path), stringAt(value, "subject", path),
        stringAt(value, "description", path),
        referenceState: stringAt(value, "referenceState", path),
        targetSymbolId: nullableStringAt(value, "targetSymbolId", path),
        directives: defaultStringAt(value, "directives", path),
        exampleMarkdown: decodeOptionalDocumentationMarkdown(value.get("exampleMarkdown"),
            "${path}.exampleMarkdown"),
        contentLanguage: optionalDocumentationLanguage(value.get("contentLanguage"), path),
        translationState: defaultStringAt(value, "translationState", path),
        fieldId: defaultStringAt(value, "fieldId", path),
        descriptionMarkdown: decodeOptionalDocumentationMarkdown(value.get("descriptionMarkdown"),
            "${path}.descriptionMarkdown"),
        navigation: decodeTypeNavigation(value.get("navigation"), "${path}.navigation"))
}


internal func decodeMarkdownMetadata(node: JsonNode, kind: String,
    path: String): MarkdownNodeMetadata {
    match (kind) {
        case "heading" =>
            let value = strictObject(node, path, ["level"])
            MarkdownNodeMetadata.forHeading(intAt(value, "level", path))
        case "list" =>
            let value = strictObject(node, path, ["listKind", "start", "delimiter", "tight"])
            MarkdownNodeMetadata.forList(stringAt(value, "listKind", path),
                intAt(value, "start", path), stringAt(value, "delimiter", path),
                boolAt(value, "tight", path))
        case "list_item" =>
            let value = strictObject(node, path, ["taskState"])
            MarkdownNodeMetadata.forListItem(stringAt(value, "taskState", path))
        case "code_block" =>
            let value = strictObject(node, path,
                ["codeKind", "fenceCharacter", "fenceLength", "infoRaw", "language", "attributesRaw", "codeHighlight"])
            MarkdownNodeMetadata.forCodeBlock(stringAt(value, "codeKind", path),
                nullableStringAt(value, "fenceCharacter", path), intAt(value, "fenceLength", path),
                stringAt(value, "infoRaw", path), stringAt(value, "language", path),
                stringAt(value, "attributesRaw", path),
                codeHighlight: optionalCodeHighlightAt(value, "codeHighlight", path))
        case "table" =>
            let value = strictObject(node, path, ["alignments"])
            MarkdownNodeMetadata.forTable(stringsAt(value, "alignments", path))
        case "table_row" =>
            let value = strictObject(node, path, ["header"])
            MarkdownNodeMetadata.forTableRow(boolAt(value, "header", path))
        case "table_cell" =>
            let value = strictObject(node, path, ["alignment"])
            MarkdownNodeMetadata.forTableCell(stringAt(value, "alignment", path))
        case "semantic_link" =>
            let value = strictObject(node, path, ["target", "state", "targetSymbolId", "externalUrl", "semanticNavigation"])
            MarkdownNodeMetadata.forSemanticLink(stringAt(value, "target", path), stringAt(value, "state", path),
                targetSymbolId: nullableStringAt(value, "targetSymbolId", path),
                externalUrl: nullableStringAt(value, "externalUrl", path),
                semanticNavigation: decodeTypeNavigation(value.get("semanticNavigation"), path + ".semanticNavigation"))
        case _ => fail(path, "metadata is not allowed for Markdown kind '${kind}'")
    }
}

internal func decodeMarkdown(node: JsonNode, path: String, depth: Int64): MarkdownNode {
    if (depth > DOC_IR_MAX_MARKDOWN_DEPTH) {
        fail(path, "Markdown nesting exceeds ${DOC_IR_MAX_MARKDOWN_DEPTH}")
    }
    let value = strictObject(node, path, ["kind", "literal", "source", "metadata", "children"])
    let kind = stringAt(value, "kind", path)
    let sourceNode = required(value, "source", path)
    let source: ?SourceRange = if (sourceNode.isNull) { None }
        else { Some(decodeRange(sourceNode, "${path}.source")) }
    let children = ArrayList<MarkdownNode>()
    var index: Int64 = 0
    for (child in jsonArrayValues(arrayAt(value, "children", path))) {
        children.add(decodeMarkdown(child, "${path}.children[${index}]", depth + 1))
        index++
    }
    let literal = stringAt(value, "literal", path)
    let metadataNode = required(value, "metadata", path)
    if (metadataNode.isNull) {
        MarkdownNode(kind, literal: literal, source: source, children: children.toArray())
    } else {
        MarkdownNode(kind, decodeMarkdownMetadata(metadataNode, kind, "${path}.metadata"),
            literal: literal, source: source, children: children.toArray())
    }
}
internal func decodeComment(node: JsonNode, path: String): DocComment {
    let value = strictObject(node, path, ["rawText", "summary", "description", "markdown", "tags",
        "defaultLanguage", "localizedTexts"])
    let tags = ArrayList<DocTag>()
    var index: Int64 = 0
    for (tag in jsonArrayValues(arrayAt(value, "tags", path))) {
        tags.add(decodeTag(tag, "${path}.tags[${index}]"))
        index++
    }
    DocComment(stringAt(value, "rawText", path), stringAt(value, "summary", path),
        stringAt(value, "description", path),
        decodeMarkdown(required(value, "markdown", path), "${path}.markdown", 0),
        tags: tags.toArray(),
        defaultLanguage: optionalDocumentationLanguage(value.get("defaultLanguage"), path),
        localizedTexts: decodeDocumentationTexts(value.get("localizedTexts"), path))
}
internal func decodeParameter(node: JsonNode, path: String): ParameterDoc {
    let value = strictObject(node, path, ["name", "type", "documentation", "defaultExpression"])
    ParameterDoc(stringAt(value, "name", path),
        decodeTypeRef(required(value, "type", path), "${path}.type", 0),
        documentation: nullableStringAt(value, "documentation", path),
        defaultExpression: nullableStringAt(value, "defaultExpression", path))
}

internal func decodeTypeRelationship(node: JsonNode, path: String): TypeRelationship {
    let value = strictObject(node, path, ["kind", "target"])
    TypeRelationship(stringAt(value, "kind", path),
        decodeTypeRef(required(value, "target", path), "${path}.target", 0))
}
internal func decodeSymbolRelationship(node: JsonNode, path: String): SymbolRelationship {
    let value = strictObject(node, path, ["kind", "targetDisplay", "state", "targetSymbolId"])
    SymbolRelationship(stringAt(value, "kind", path), stringAt(value, "targetDisplay", path),
        stringAt(value, "state", path),
        targetSymbolId: nullableStringAt(value, "targetSymbolId", path))
}
internal func decodeAnnotations(value: JsonObject, path: String): Array<AnnotationDoc> {
    let result = ArrayList<AnnotationDoc>()
    var index: Int64 = 0
    for (node in jsonArrayValues(arrayAt(value, "annotations", path))) {
        let annotationPath = "${path}.annotations[${index}]"
        let annotation = strictObject(node, annotationPath, ["spelling", "provenance", "provider"])
        result.add(AnnotationDoc(stringAt(annotation, "spelling", annotationPath),
            provenance: stringAt(annotation, "provenance", annotationPath),
            provider: nullableStringAt(annotation, "provider", annotationPath)))
        index++
    }
    result.toArray()
}
