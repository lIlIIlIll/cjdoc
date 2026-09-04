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
// four per array item. Both the typed encoding census and the raw pre-schema
// census enforce these occurrence ceilings, so this is a shared domain/schema
// upper bound rather than an unrelated validator knob.
internal let DOC_IR_SCHEMA_MAX_WORK: Int64 =
    DOC_IR_MAX_SCHEMA_OBJECTS * 64 + DOC_IR_MAX_SCHEMA_ARRAY_ITEMS * 4

internal func fail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR at ${path}: ${message}")
}

internal class RawSchemaShape {
    let objects: Int64
    let arrayItems: Int64

    init(objects: Int64, arrayItems: Int64) {
        this.objects = objects
        this.arrayItems = arrayItems
    }
}

internal func validateRawSchemaShape(root: JsonNode): RawSchemaShape {
    let pending = ArrayList<JsonNode>()
    pending.add(root)
    var objects: Int64 = 0
    var arrayItems: Int64 = 0
    while (!pending.isEmpty()) {
        let node = pending.remove(at: pending.size - 1)
        match (node.kind()) {
            case JsObject =>
                objects++
                if (objects > DOC_IR_MAX_SCHEMA_OBJECTS) {
                    fail("$", "JSON object occurrence budget exceeded")
                }
                for ((_, child) in node.asObject().entries()) { pending.add(child) }
            case JsArray =>
                let values = node.asArray().values()
                if (values.size > DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - arrayItems) {
                    fail("$", "JSON array item occurrence budget exceeded")
                }
                arrayItems += values.size
                for (child in values) { pending.add(child) }
            case _ => ()
        }
    }
    RawSchemaShape(objects, arrayItems)
}

internal func validateDeclarativeSchema(root: JsonNode): Unit {
    let version = try {
        root.asObject().get("schemaVersion").getOrThrow().string
    } catch (_: Exception) {
        fail("$.schemaVersion", "expected string")
    }
    let schemaText = if (version == DOC_IR_SCHEMA_VERSION) { DOC_IR_SCHEMA }
        else if (version == DOC_IR_V7_SCHEMA_VERSION) { DOC_IR_V7_SCHEMA }
        else if (version == DOC_IR_V6_SCHEMA_VERSION) { DOC_IR_V6_SCHEMA }
        else {
            fail("$.schemaVersion",
                "expected '${DOC_IR_SCHEMA_VERSION}', '${DOC_IR_V7_SCHEMA_VERSION}', " +
                "or '${DOC_IR_V6_SCHEMA_VERSION}'")
        }
    let schema = JsonSchema.parse(schemaText, config: JsonSchemaConfig(
        limits: JsonSchemaLimits(maxEvaluations: DOC_IR_SCHEMA_MAX_WORK,
            maxRefResolutions: DOC_IR_SCHEMA_MAX_WORK,
            maxErrors: 20, maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH)))
    let errors = schema.validate(root)
    if (!errors.isEmpty()) {
        let first = errors[0]
        throw IllegalArgumentException("invalid Doc IR schema at ${first.jsonPath} " +
            "(${first.schemaPath}): ${first.message}")
    }
}

internal func strictObject(node: JsonNode, path: String, keys: Array<String>): JsonObjectValue {
    let object = try { node.asObject() } catch (_: Exception) { fail(path, "expected object") }
    let allowed = HashSet<String>()
    for (key in keys) { let _ = allowed.add(key) }
    for ((key, _) in object.entries()) {
        if (!allowed.contains(key)) { fail(path, "unknown field '${key}'") }
    }
    object
}

internal func required(object: JsonObjectValue, key: String, path: String): JsonNode {
    match (object.get(key)) {
        case Some(value) => value
        case None => fail(path, "missing required field '${key}'")
    }
}

internal func stringAt(object: JsonObjectValue, key: String, path: String): String {
    try { required(object, key, path).string }
    catch (_: Exception) { fail("${path}.${key}", "expected string") }
}

internal func boolAt(object: JsonObjectValue, key: String, path: String): Bool {
    try { required(object, key, path).bool }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean") }
}

internal func intAt(object: JsonObjectValue, key: String, path: String): Int64 {
    try { required(object, key, path).int64 }
    catch (_: Exception) { fail("${path}.${key}", "expected integer") }
}

internal func nullableStringAt(object: JsonObjectValue, key: String, path: String): ?String {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.string) }
    catch (_: Exception) { fail("${path}.${key}", "expected string or null") }
}

internal func nullableBoolAt(object: JsonObjectValue, key: String, path: String): ?Bool {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.bool) }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean or null") }
}

internal func arrayAt(object: JsonObjectValue, key: String, path: String): JsonArrayValue {
    try { required(object, key, path).asArray() }
    catch (_: Exception) { fail("${path}.${key}", "expected array") }
}

internal func stringsAt(object: JsonObjectValue, key: String, path: String): Array<String> {
    let values = ArrayList<String>()
    var index: Int64 = 0
    for (value in arrayAt(object, key, path).values()) {
        try { values.add(value.string) }
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

internal func decodeCapabilities(node: JsonNode, path: String, legacy: Bool): SemanticCapabilities {
    let keys = if (legacy) { ["sourceBinding", "ownership", "visibility",
        "canonicalTypes", "canonicalSignatures", "relationships"] } else {
        ["sourceBinding", "ownership", "visibility", "canonicalTypes", "canonicalSignatures",
            "relationships", "annotations"]
    }
    let value = strictObject(node, path, keys)
    SemanticCapabilities(boolAt(value, "sourceBinding", path), boolAt(value, "ownership", path),
        boolAt(value, "visibility", path), boolAt(value, "canonicalTypes", path),
        boolAt(value, "canonicalSignatures", path), relationships: boolAt(value, "relationships", path),
        annotations: if (legacy) { false } else { boolAt(value, "annotations", path) })
}

internal func decodeSemanticType(node: JsonNode, path: String): SemanticType {
    let value = strictObject(node, path, ["state", "canonical", "provider"])
    SemanticType(stringAt(value, "state", path), canonical: nullableStringAt(value, "canonical", path),
        provider: nullableStringAt(value, "provider", path))
}

internal func decodeTypeRef(node: JsonNode, path: String, depth: Int64): TypeRef {
    if (depth > DOC_IR_MAX_TYPE_DEPTH) {
        fail(path, "type nesting exceeds ${DOC_IR_MAX_TYPE_DEPTH}")
    }
    let value = strictObject(node, path, ["kind", "spelling", "nullable", "arguments", "semantic"])
    let arguments = ArrayList<TypeRef>()
    var index: Int64 = 0
    for (argument in arrayAt(value, "arguments", path).values()) {
        arguments.add(decodeTypeRef(argument, "${path}.arguments[${index}]", depth + 1))
        index++
    }
    TypeRef(stringAt(value, "kind", path), stringAt(value, "spelling", path),
        decodeSemanticType(required(value, "semantic", path), "${path}.semantic"),
        nullable: boolAt(value, "nullable", path), arguments: arguments.toArray())
}

internal func migratedSymbolId(value: String, legacy: Bool, legacyIds: HashMap<String, String>,
    path: String): String {
    if (!legacy) { return value }
    match (legacyIds.get(value)) {
        case Some(migrated) => migrated
        case None => fail(path, "v6 SymbolId does not identify a declaration")
    }
}

internal func migratedOptionalSymbolId(value: ?String, legacy: Bool,
    legacyIds: HashMap<String, String>, path: String): ?String {
    match (value) {
        case Some(id) => Some(migratedSymbolId(id, legacy, legacyIds, path))
        case None => None
    }
}

internal func decodeTag(node: JsonNode, path: String, legacy: Bool,
    legacyIds: HashMap<String, String>): DocTag {
    let value = strictObject(node, path,
        ["name", "subject", "description", "referenceState", "targetSymbolId"])
    DocTag(stringAt(value, "name", path), stringAt(value, "subject", path),
        stringAt(value, "description", path),
        referenceState: stringAt(value, "referenceState", path),
        targetSymbolId: migratedOptionalSymbolId(nullableStringAt(value, "targetSymbolId", path),
            legacy, legacyIds, "${path}.targetSymbolId"))
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
                ["codeKind", "fenceCharacter", "fenceLength", "infoRaw", "language", "attributesRaw"])
            MarkdownNodeMetadata.forCodeBlock(stringAt(value, "codeKind", path),
                nullableStringAt(value, "fenceCharacter", path), intAt(value, "fenceLength", path),
                stringAt(value, "infoRaw", path), stringAt(value, "language", path),
                stringAt(value, "attributesRaw", path))
        case "table" =>
            let value = strictObject(node, path, ["alignments"])
            MarkdownNodeMetadata.forTable(stringsAt(value, "alignments", path))
        case "table_row" =>
            let value = strictObject(node, path, ["header"])
            MarkdownNodeMetadata.forTableRow(boolAt(value, "header", path))
        case "table_cell" =>
            let value = strictObject(node, path, ["alignment"])
            MarkdownNodeMetadata.forTableCell(stringAt(value, "alignment", path))
        case _ => fail(path, "metadata is not allowed for Markdown kind '${kind}'")
    }
}

internal func migratedAssetReference(value: String, legacy: Bool,
    assetReferences: HashMap<String, String>): String {
    if (!legacy) { return value }
    match (assetReferences.get(value)) {
        case Some(id) => id
        case None => value
    }
}

internal func decodeMarkdown(node: JsonNode, path: String, depth: Int64, legacy: Bool,
    assetReferences: HashMap<String, String>): MarkdownNode {
    if (depth > DOC_IR_MAX_MARKDOWN_DEPTH) {
        fail(path, "Markdown nesting exceeds ${DOC_IR_MAX_MARKDOWN_DEPTH}")
    }
    let keys = if (legacy) { ["kind", "literal", "source", "children"] }
        else { ["kind", "literal", "source", "metadata", "children"] }
    let value = strictObject(node, path, keys)
    let kind = stringAt(value, "kind", path)
    let sourceNode = required(value, "source", path)
    let source: ?SourceRange = if (sourceNode.isNull) { None }
        else { Some(decodeRange(sourceNode, "${path}.source")) }
    let children = ArrayList<MarkdownNode>()
    var index: Int64 = 0
    for (child in arrayAt(value, "children", path).values()) {
        children.add(decodeMarkdown(child, "${path}.children[${index}]", depth + 1,
            legacy, assetReferences))
        index++
    }
    let literal = migratedAssetReference(stringAt(value, "literal", path),
        legacy && kind == "image", assetReferences)
    if (legacy) {
        return MarkdownNode(kind, literal: literal, source: source, children: children.toArray())
    }
    let metadataNode = required(value, "metadata", path)
    if (metadataNode.isNull) {
        MarkdownNode(kind, literal: literal, source: source, children: children.toArray())
    } else {
        MarkdownNode(kind, decodeMarkdownMetadata(metadataNode, kind, "${path}.metadata"),
            literal: literal, source: source, children: children.toArray())
    }
}

internal func decodeComment(node: JsonNode, path: String, legacyIdsRequired: Bool,
    legacyMarkdown: Bool, legacyIds: HashMap<String, String>,
    assetReferences: HashMap<String, String>): DocComment {
    let value = strictObject(node, path, ["rawText", "summary", "description", "markdown", "tags"])
    let tags = ArrayList<DocTag>()
    var index: Int64 = 0
    for (tag in arrayAt(value, "tags", path).values()) {
        tags.add(decodeTag(tag, "${path}.tags[${index}]", legacyIdsRequired, legacyIds)); index++
    }
    DocComment(stringAt(value, "rawText", path), stringAt(value, "summary", path),
        stringAt(value, "description", path),
        decodeMarkdown(required(value, "markdown", path), "${path}.markdown", 0,
            legacyMarkdown, assetReferences),
        tags: tags.toArray())
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

internal func decodeSymbolRelationship(node: JsonNode, path: String, legacy: Bool,
    legacyIds: HashMap<String, String>): SymbolRelationship {
    let value = strictObject(node, path, ["kind", "targetDisplay", "state", "targetSymbolId"])
    SymbolRelationship(stringAt(value, "kind", path), stringAt(value, "targetDisplay", path),
        stringAt(value, "state", path),
        targetSymbolId: migratedOptionalSymbolId(nullableStringAt(value, "targetSymbolId", path),
            legacy, legacyIds, "${path}.targetSymbolId"))
}

internal class LegacyModuleIndex {
    let byPackage: HashMap<String, String>
    let ambiguousPackages: HashSet<String>

    init(byPackage: HashMap<String, String>, ambiguousPackages: HashSet<String>) {
        this.byPackage = byPackage
        this.ambiguousPackages = ambiguousPackages
    }
}

internal func buildLegacyModuleIndex(modules: Array<ModuleDoc>): LegacyModuleIndex {
    let byPackage = HashMap<String, String>()
    let ambiguousPackages = HashSet<String>()
    for (module in modules) {
        for (packageName in module.packageNames) {
            match (byPackage.get(packageName)) {
                case Some(existing) => if (existing != module.id) {
                    let _ = ambiguousPackages.add(packageName)
                }
                case None => byPackage[packageName] = module.id
            }
        }
    }
    LegacyModuleIndex(byPackage, ambiguousPackages)
}

internal func legacyModuleId(index: LegacyModuleIndex, packageName: String, path: String): String {
    if (index.ambiguousPackages.contains(packageName)) {
        fail(path, "v6 package '${packageName}' maps to more than one module")
    }
    match (index.byPackage.get(packageName)) {
        case Some(moduleId) => moduleId
        case None => fail(path, "v6 package '${packageName}' has no module mapping")
    }
}

internal func buildLegacySymbolIds(root: JsonObjectValue,
    modules: LegacyModuleIndex): HashMap<String, String> {
    let result = HashMap<String, String>()
    let migrated = HashSet<String>()
    var index: Int64 = 0
    for (node in arrayAt(root, "declarations", "$" ).values()) {
        let path = "$.declarations[${index}]"
        let value = try { node.asObject() } catch (_: Exception) { fail(path, "expected object") }
        let oldId = stringAt(value, "id", path)
        if (!oldId.startsWith("cjdoc:v1:")) {
            fail("${path}.id", "v6 SymbolId must start with 'cjdoc:v1:'")
        }
        if (result.contains(oldId)) { fail("${path}.id", "duplicate v6 SymbolId") }
        let moduleId = legacyModuleId(modules, stringAt(value, "packageName", path), path)
        let newId = symbolIdModulePrefix(moduleId) + oldId.removePrefix("cjdoc:v1:")
        if (!migrated.add(newId)) { fail("${path}.id", "v6 SymbolIds collide after module migration") }
        result[oldId] = newId
        index++
    }
    result
}

internal func decodeAnnotations(value: JsonObjectValue, path: String, legacy: Bool): Array<AnnotationDoc> {
    let result = ArrayList<AnnotationDoc>()
    var index: Int64 = 0
    for (node in arrayAt(value, "annotations", path).values()) {
        if (legacy) {
            try { result.add(AnnotationDoc(node.string)) }
            catch (_: Exception) { fail("${path}.annotations[${index}]", "expected string") }
        } else {
            let annotationPath = "${path}.annotations[${index}]"
            let annotation = strictObject(node, annotationPath, ["spelling", "provenance", "provider"])
            result.add(AnnotationDoc(stringAt(annotation, "spelling", annotationPath),
                provenance: stringAt(annotation, "provenance", annotationPath),
                provider: nullableStringAt(annotation, "provider", annotationPath)))
        }
        index++
    }
    result.toArray()
}

