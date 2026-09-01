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
private let DOC_IR_CODEC_MAX_NESTING_DEPTH: Int64 = 512

// The schema corpus needs fewer than sixty-four evaluations per JSON object and
// four per array item. Both the typed encoding census and the raw pre-schema
// census enforce these occurrence ceilings, so this is a shared domain/schema
// upper bound rather than an unrelated validator knob.
private let DOC_IR_SCHEMA_MAX_WORK: Int64 =
    DOC_IR_MAX_SCHEMA_OBJECTS * 64 + DOC_IR_MAX_SCHEMA_ARRAY_ITEMS * 4

private func fail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR at ${path}: ${message}")
}

private class RawSchemaShape {
    let objects: Int64
    let arrayItems: Int64

    init(objects: Int64, arrayItems: Int64) {
        this.objects = objects
        this.arrayItems = arrayItems
    }
}

private func validateRawSchemaShape(root: JsonNode): RawSchemaShape {
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

private func validateDeclarativeSchema(root: JsonNode): Unit {
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

private func strictObject(node: JsonNode, path: String, keys: Array<String>): JsonObjectValue {
    let object = try { node.asObject() } catch (_: Exception) { fail(path, "expected object") }
    let allowed = HashSet<String>()
    for (key in keys) { let _ = allowed.add(key) }
    for ((key, _) in object.entries()) {
        if (!allowed.contains(key)) { fail(path, "unknown field '${key}'") }
    }
    object
}

private func required(object: JsonObjectValue, key: String, path: String): JsonNode {
    match (object.get(key)) {
        case Some(value) => value
        case None => fail(path, "missing required field '${key}'")
    }
}

private func stringAt(object: JsonObjectValue, key: String, path: String): String {
    try { required(object, key, path).string }
    catch (_: Exception) { fail("${path}.${key}", "expected string") }
}

private func boolAt(object: JsonObjectValue, key: String, path: String): Bool {
    try { required(object, key, path).bool }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean") }
}

private func intAt(object: JsonObjectValue, key: String, path: String): Int64 {
    try { required(object, key, path).int64 }
    catch (_: Exception) { fail("${path}.${key}", "expected integer") }
}

private func nullableStringAt(object: JsonObjectValue, key: String, path: String): ?String {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.string) }
    catch (_: Exception) { fail("${path}.${key}", "expected string or null") }
}

private func nullableBoolAt(object: JsonObjectValue, key: String, path: String): ?Bool {
    let value = required(object, key, path)
    if (value.isNull) { return None }
    try { Some(value.bool) }
    catch (_: Exception) { fail("${path}.${key}", "expected boolean or null") }
}

private func arrayAt(object: JsonObjectValue, key: String, path: String): JsonArrayValue {
    try { required(object, key, path).asArray() }
    catch (_: Exception) { fail("${path}.${key}", "expected array") }
}

private func stringsAt(object: JsonObjectValue, key: String, path: String): Array<String> {
    let values = ArrayList<String>()
    var index: Int64 = 0
    for (value in arrayAt(object, key, path).values()) {
        try { values.add(value.string) }
        catch (_: Exception) { fail("${path}.${key}[${index}]", "expected string") }
        index++
    }
    values.toArray()
}

private func decodePosition(node: JsonNode, path: String): SourcePosition {
    let value = strictObject(node, path, ["line", "column", "byteOffset"])
    SourcePosition(intAt(value, "line", path), intAt(value, "column", path),
        intAt(value, "byteOffset", path))
}

private func decodeRange(node: JsonNode, path: String): SourceRange {
    let value = strictObject(node, path, ["path", "start", "end"])
    SourceRange(stringAt(value, "path", path),
        decodePosition(required(value, "start", path), "${path}.start"),
        decodePosition(required(value, "end", path), "${path}.end"))
}

private func decodeSourceApiSignature(node: JsonNode, path: String): SourceApiSignature {
    let value = strictObject(node, path, ["state", "tokens"])
    SourceApiSignature(stringAt(value, "state", path), tokens: stringsAt(value, "tokens", path))
}

private func decodeCapabilities(node: JsonNode, path: String, legacy: Bool): SemanticCapabilities {
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

private func decodeSemanticType(node: JsonNode, path: String): SemanticType {
    let value = strictObject(node, path, ["state", "canonical", "provider"])
    SemanticType(stringAt(value, "state", path), canonical: nullableStringAt(value, "canonical", path),
        provider: nullableStringAt(value, "provider", path))
}

private func decodeTypeRef(node: JsonNode, path: String, depth: Int64): TypeRef {
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

private func migratedSymbolId(value: String, legacy: Bool, legacyIds: HashMap<String, String>,
    path: String): String {
    if (!legacy) { return value }
    match (legacyIds.get(value)) {
        case Some(migrated) => migrated
        case None => fail(path, "v6 SymbolId does not identify a declaration")
    }
}

private func migratedOptionalSymbolId(value: ?String, legacy: Bool,
    legacyIds: HashMap<String, String>, path: String): ?String {
    match (value) {
        case Some(id) => Some(migratedSymbolId(id, legacy, legacyIds, path))
        case None => None
    }
}

private func decodeTag(node: JsonNode, path: String, legacy: Bool,
    legacyIds: HashMap<String, String>): DocTag {
    let value = strictObject(node, path,
        ["name", "subject", "description", "referenceState", "targetSymbolId"])
    DocTag(stringAt(value, "name", path), stringAt(value, "subject", path),
        stringAt(value, "description", path),
        referenceState: stringAt(value, "referenceState", path),
        targetSymbolId: migratedOptionalSymbolId(nullableStringAt(value, "targetSymbolId", path),
            legacy, legacyIds, "${path}.targetSymbolId"))
}

private func decodeMarkdownMetadata(node: JsonNode, kind: String,
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

private func migratedAssetReference(value: String, legacy: Bool,
    assetReferences: HashMap<String, String>): String {
    if (!legacy) { return value }
    match (assetReferences.get(value)) {
        case Some(id) => id
        case None => value
    }
}

private func decodeMarkdown(node: JsonNode, path: String, depth: Int64, legacy: Bool,
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

private func decodeComment(node: JsonNode, path: String, legacyIdsRequired: Bool,
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

private func decodeParameter(node: JsonNode, path: String): ParameterDoc {
    let value = strictObject(node, path, ["name", "type", "documentation", "defaultExpression"])
    ParameterDoc(stringAt(value, "name", path),
        decodeTypeRef(required(value, "type", path), "${path}.type", 0),
        documentation: nullableStringAt(value, "documentation", path),
        defaultExpression: nullableStringAt(value, "defaultExpression", path))
}

private func decodeTypeRelationship(node: JsonNode, path: String): TypeRelationship {
    let value = strictObject(node, path, ["kind", "target"])
    TypeRelationship(stringAt(value, "kind", path),
        decodeTypeRef(required(value, "target", path), "${path}.target", 0))
}

private func decodeSymbolRelationship(node: JsonNode, path: String, legacy: Bool,
    legacyIds: HashMap<String, String>): SymbolRelationship {
    let value = strictObject(node, path, ["kind", "targetDisplay", "state", "targetSymbolId"])
    SymbolRelationship(stringAt(value, "kind", path), stringAt(value, "targetDisplay", path),
        stringAt(value, "state", path),
        targetSymbolId: migratedOptionalSymbolId(nullableStringAt(value, "targetSymbolId", path),
            legacy, legacyIds, "${path}.targetSymbolId"))
}

private class LegacyModuleIndex {
    let byPackage: HashMap<String, String>
    let ambiguousPackages: HashSet<String>

    init(byPackage: HashMap<String, String>, ambiguousPackages: HashSet<String>) {
        this.byPackage = byPackage
        this.ambiguousPackages = ambiguousPackages
    }
}

private func buildLegacyModuleIndex(modules: Array<ModuleDoc>): LegacyModuleIndex {
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

private func legacyModuleId(index: LegacyModuleIndex, packageName: String, path: String): String {
    if (index.ambiguousPackages.contains(packageName)) {
        fail(path, "v6 package '${packageName}' maps to more than one module")
    }
    match (index.byPackage.get(packageName)) {
        case Some(moduleId) => moduleId
        case None => fail(path, "v6 package '${packageName}' has no module mapping")
    }
}

private func buildLegacySymbolIds(root: JsonObjectValue,
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

private func decodeAnnotations(value: JsonObjectValue, path: String, legacy: Bool): Array<AnnotationDoc> {
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

private func decodeSymbol(node: JsonNode, path: String, legacyV6: Bool, legacy: Bool,
    modules: LegacyModuleIndex, legacyIds: HashMap<String, String>,
    assetReferences: HashMap<String, String>): SymbolDoc {
    let keys = if (legacyV6) { ["id", "kind", "name", "qualifiedName", "packageName",
        "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations",
        "typeRelationships", "symbolRelationships",
        "documentation", "source", "headerSpelling", "semantic", "origin"]
    } else if (legacy) {
        ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility",
            "genericParameters", "parameters", "returnType", "annotations", "typeRelationships",
            "symbolRelationships", "documentation", "source", "headerSpelling", "semantic", "origin"]
    } else {
        ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility",
            "genericParameters", "parameters", "returnType", "annotations", "typeRelationships",
            "symbolRelationships", "documentation", "source", "headerSpelling", "sourceApiSignature",
            "semantic", "origin", "enumNonExhaustive"]
    }
    let value = strictObject(node, path, keys)
    let parameters = ArrayList<ParameterDoc>()
    var index: Int64 = 0
    for (parameter in arrayAt(value, "parameters", path).values()) {
        parameters.add(decodeParameter(parameter, "${path}.parameters[${index}]")); index++
    }
    let typeRelationships = ArrayList<TypeRelationship>()
    index = 0
    for (relationship in arrayAt(value, "typeRelationships", path).values()) {
        typeRelationships.add(decodeTypeRelationship(relationship,
            "${path}.typeRelationships[${index}]")); index++
    }
    let symbolRelationships = ArrayList<SymbolRelationship>()
    index = 0
    for (relationship in arrayAt(value, "symbolRelationships", path).values()) {
        symbolRelationships.add(decodeSymbolRelationship(relationship,
            "${path}.symbolRelationships[${index}]", legacyV6, legacyIds)); index++
    }
    let returnNode = required(value, "returnType", path)
    let returnType: ?TypeRef = if (returnNode.isNull) { None }
        else { Some(decodeTypeRef(returnNode, "${path}.returnType", 0)) }
    let documentationNode = required(value, "documentation", path)
    let documentation: ?DocComment = if (documentationNode.isNull) { None }
        else { Some(decodeComment(documentationNode, "${path}.documentation", legacyV6,
            legacy, legacyIds, assetReferences)) }
    let semantic = strictObject(required(value, "semantic", path), "${path}.semantic",
        ["state", "provider", "canonicalSignature"])
    let origin = strictObject(required(value, "origin", path), "${path}.origin",
        ["kind", "macroSymbolId"])
    let packageName = stringAt(value, "packageName", path)
    let moduleId = if (legacyV6) { legacyModuleId(modules, packageName, path) }
        else { stringAt(value, "moduleId", path) }
    SymbolDoc(migratedSymbolId(stringAt(value, "id", path), legacyV6, legacyIds, "${path}.id"),
        stringAt(value, "kind", path),
        stringAt(value, "name", path), stringAt(value, "qualifiedName", path),
        packageName, moduleId, stringAt(value, "visibility", path),
        decodeRange(required(value, "source", path), "${path}.source"),
        stringAt(value, "headerSpelling", path),
        SemanticInfo(stringAt(semantic, "state", "${path}.semantic"),
            stringAt(semantic, "provider", "${path}.semantic"),
            canonicalSignature: nullableStringAt(semantic, "canonicalSignature", "${path}.semantic")),
        if (legacy) { None } else { nullableBoolAt(value, "enumNonExhaustive", path) },
        ownerId: migratedOptionalSymbolId(nullableStringAt(value, "ownerId", path), legacyV6,
            legacyIds, "${path}.ownerId"),
        genericParameters: stringsAt(value, "genericParameters", path),
        parameters: parameters.toArray(), returnType: returnType,
        annotations: decodeAnnotations(value, path, legacyV6),
        typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: documentation,
        origin: DeclarationOrigin(kind: stringAt(origin, "kind", "${path}.origin"),
            macroSymbolId: migratedOptionalSymbolId(nullableStringAt(origin, "macroSymbolId",
                "${path}.origin"), legacyV6, legacyIds, "${path}.origin.macroSymbolId")),
        sourceApiSignature: if (legacy) {
            SourceApiSignature("unavailable")
        } else {
            decodeSourceApiSignature(required(value, "sourceApiSignature", path),
                "${path}.sourceApiSignature")
        })
}

private func decodeModules(root: JsonObjectValue, legacy: Bool): Array<ModuleDoc> {
    let result = ArrayList<ModuleDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "modules", "$" ).values()) {
        let path = "$.modules[${index}]"
        let value = strictObject(node, path, if (legacy) {
            ["id", "name", "role", "sourcePrefix", "packageNames", "dependencyIds"]
        } else {
            ["id", "name", "role", "sourcePrefix", "organization", "packageNames", "dependencyIds"]
        })
        result.add(ModuleDoc(stringAt(value, "id", path), stringAt(value, "name", path),
            stringAt(value, "role", path), stringAt(value, "sourcePrefix", path),
            packageNames: stringsAt(value, "packageNames", path),
            dependencyIds: stringsAt(value, "dependencyIds", path),
            organization: if (legacy) { None<String> } else {
                nullableStringAt(value, "organization", path)
            }))
        index++
    }
    result.toArray()
}

private func decodePackages(root: JsonObjectValue, legacy: Bool, legacyV6: Bool,
    legacyIds: HashMap<String, String>): Array<PackageDoc> {
    let result = ArrayList<PackageDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "packages", "$" ).values()) {
        let path = "$.packages[${index}]"
        let value = strictObject(node, path, if (legacy) {
            ["name", "moduleId", "sourceFiles", "symbolIds"]
        } else {
            ["name", "moduleId", "sourceFiles", "symbolIds", "reExports"]
        })
        let ids = ArrayList<String>()
        var symbolIndex: Int64 = 0
        for (id in stringsAt(value, "symbolIds", path)) {
            ids.add(migratedSymbolId(id, legacyV6, legacyIds,
                "${path}.symbolIds[${symbolIndex}]"))
            symbolIndex++
        }
        let reExports = ArrayList<ReExportDoc>()
        if (!legacy) {
            var reExportIndex: Int64 = 0
            for (reExportNode in arrayAt(value, "reExports", path).values()) {
                let reExportPath = "${path}.reExports[${reExportIndex}]"
                let reExport = strictObject(reExportNode, reExportPath,
                    ["id", "kind", "organization", "targetPackageName", "targetModuleId",
                        "alias", "state", "source", "bindings"])
                let bindings = ArrayList<ReExportBinding>()
                var bindingIndex: Int64 = 0
                for (bindingNode in arrayAt(reExport, "bindings", reExportPath).values()) {
                    let bindingPath = "${reExportPath}.bindings[${bindingIndex}]"
                    let binding = strictObject(bindingNode, bindingPath,
                        ["exposedName", "targetSymbolIds"])
                    bindings.add(ReExportBinding(stringAt(binding, "exposedName", bindingPath),
                        targetSymbolIds: stringsAt(binding, "targetSymbolIds", bindingPath)))
                    bindingIndex++
                }
                reExports.add(ReExportDoc(stringAt(reExport, "id", reExportPath),
                    stringAt(reExport, "kind", reExportPath),
                    stringAt(reExport, "targetPackageName", reExportPath),
                    stringAt(reExport, "state", reExportPath),
                    decodeRange(required(reExport, "source", reExportPath), "${reExportPath}.source"),
                    organization: nullableStringAt(reExport, "organization", reExportPath),
                    targetModuleId: nullableStringAt(reExport, "targetModuleId", reExportPath),
                    alias: nullableStringAt(reExport, "alias", reExportPath),
                    bindings: bindings.toArray()))
                reExportIndex++
            }
        }
        result.add(PackageDoc(stringAt(value, "name", path), stringAt(value, "moduleId", path),
            sourceFiles: stringsAt(value, "sourceFiles", path), symbolIds: ids.toArray(),
            reExports: reExports.toArray()))
        index++
    }
    result.toArray()
}

private func decodeFiles(root: JsonObjectValue): Array<FileDoc> {
    let result = ArrayList<FileDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "files", "$" ).values()) {
        let path = "$.files[${index}]"
        let value = strictObject(node, path, ["path", "moduleId", "packageName"])
        result.add(FileDoc(stringAt(value, "path", path), stringAt(value, "moduleId", path),
            stringAt(value, "packageName", path)))
        index++
    }
    result.toArray()
}

// One migrated provider contributes two JSON objects (provider/capabilities),
// one providers-array item, and at least 1,290 bytes to the conservative typed
// encoding census. Account for every additional v6 global-provider copy before
// allocating it; the final typed census still charges exact strings and shape.
private let MIN_MIGRATED_PROVIDER_ENCODING_BYTES: Int64 = 1290

private func preflightLegacyProviderMigration(providerCount: Int64, moduleCount: Int64,
    rawShape: RawSchemaShape, sourceBytes: Int64): Unit {
    if (providerCount == 0) { return }
    if (moduleCount == 0) {
        fail("$.providers", "v6 global provider cannot be mapped without a module")
    }
    let additionalModules = moduleCount - 1
    if (additionalModules == 0) { return }

    let availableObjectCopies = (DOC_IR_MAX_SCHEMA_OBJECTS - rawShape.objects) / 2
    let availableArrayCopies = DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - rawShape.arrayItems
    let availableEncodingCopies =
        (DOC_IR_MAX_JSON_DOCUMENT_BYTES - sourceBytes) / MIN_MIGRATED_PROVIDER_ENCODING_BYTES
    var availableCopies = availableObjectCopies
    if (availableArrayCopies < availableCopies) { availableCopies = availableArrayCopies }
    if (availableEncodingCopies < availableCopies) { availableCopies = availableEncodingCopies }
    // Division before multiplication is the overflow-safe checked product.
    if (availableCopies < 0 || providerCount > availableCopies / additionalModules) {
        fail("$.providers", "v6 global provider migration exceeds Doc IR occurrence/encoding budget")
    }
}

private func decodeProviders(root: JsonObjectValue, modules: Array<ModuleDoc>, legacy: Bool,
    rawShape: RawSchemaShape, sourceBytes: Int64): Array<ProviderInfo> {
    let result = ArrayList<ProviderInfo>()
    let providerNodes = arrayAt(root, "providers", "$" )
    if (legacy) {
        preflightLegacyProviderMigration(providerNodes.size(), modules.size,
            rawShape, sourceBytes)
    }
    var index: Int64 = 0
    for (node in providerNodes.values()) {
        let path = "$.providers[${index}]"
        let keys = if (legacy) { ["name", "version", "state", "capabilities"] }
            else { ["name", "version", "moduleId", "state", "capabilities"] }
        let value = strictObject(node, path, keys)
        if (legacy) {
            let name = stringAt(value, "name", path)
            let version = stringAt(value, "version", path)
            let state = stringAt(value, "state", path)
            let capabilities = decodeCapabilities(required(value, "capabilities", path),
                "${path}.capabilities", true)
            for (module in modules) {
                result.add(ProviderInfo(name, version, module.id, state, capabilities))
            }
        } else {
            result.add(ProviderInfo(stringAt(value, "name", path), stringAt(value, "version", path),
                stringAt(value, "moduleId", path), stringAt(value, "state", path),
                decodeCapabilities(required(value, "capabilities", path), "${path}.capabilities", false)))
        }
        index++
    }
    result.toArray()
}

private func decodeDeclarations(root: JsonObjectValue, legacyV6: Bool, legacy: Bool,
    modules: LegacyModuleIndex, legacyIds: HashMap<String, String>,
    assetReferences: HashMap<String, String>): Array<SymbolDoc> {
    let result = ArrayList<SymbolDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "declarations", "$" ).values()) {
        result.add(decodeSymbol(node, "$.declarations[${index}]", legacyV6, legacy,
            modules, legacyIds, assetReferences)); index++
    }
    result.toArray()
}

private class DecodedAssets {
    let assets: Array<AssetDoc>
    let references: HashMap<String, String>

    init(assets: Array<AssetDoc>, references: HashMap<String, String>) {
        this.assets = assets
        this.references = references
    }
}

private func addLegacyAssetReference(references: HashMap<String, String>, reference: String,
    id: String, path: String): Unit {
    match (references.get(reference)) {
        case Some(existing) => if (existing != id) {
            fail(path, "legacy asset reference '${reference}' is ambiguous")
        }
        case None => references[reference] = id
    }
}

private func decodeAssets(root: JsonObjectValue, legacy: Bool): DecodedAssets {
    let result = ArrayList<AssetDoc>()
    let references = HashMap<String, String>()
    let oldIds = HashSet<String>()
    let sourcePaths = HashSet<String>()
    let migratedIds = HashSet<String>()
    var totalBytes: Int64 = 0
    var totalPixels: Int64 = 0
    var index: Int64 = 0
    for (node in arrayAt(root, "assets", "$" ).values()) {
        let path = "$.assets[${index}]"
        let value = strictObject(node, path, ["id", "mediaType", "sourcePath", "base64"])
        let oldId = stringAt(value, "id", path)
        let mediaType = stringAt(value, "mediaType", path)
        let sourcePath = stringAt(value, "sourcePath", path)
        let base64 = stringAt(value, "base64", path)
        if (!legacy) {
            result.add(AssetDoc(oldId, mediaType, sourcePath, base64))
            index++
            continue
        }
        if (!oldIds.add(oldId)) { fail("${path}.id", "duplicate legacy asset id") }
        if (!sourcePaths.add(sourcePath) || !safeRelativePath(sourcePath)) {
            fail("${path}.sourcePath", "duplicate or unsafe legacy asset source path")
        }
        let decoded = try {
            let _ = assetMediaExtension(mediaType)
            decodeAssetBase64(base64)
        } catch (_: Exception) {
            fail(path, "unsupported media type or invalid legacy asset base64")
        }
        let pixels = try {
            validateRasterAsset(mediaType, decoded)
        } catch (_: IllegalArgumentException) {
            fail(path, "invalid or oversized legacy image asset")
        }
        if (decoded.size > DOC_IR_MAX_TOTAL_ASSET_BYTES - totalBytes) {
            fail(path, "legacy image assets exceed the decoded-byte budget")
        }
        totalBytes += decoded.size
        if (pixels > DOC_IR_MAX_TOTAL_ASSET_PIXELS - totalPixels) {
            fail(path, "legacy image assets exceed the total-pixel budget")
        }
        totalPixels += pixels
        let id = "sha256-${docIrSha256Bytes(decoded)}"
        addLegacyAssetReference(references, oldId, id, path)
        addLegacyAssetReference(references, sourcePath, id, path)
        addLegacyAssetReference(references, "./${sourcePath}", id, path)
        if (migratedIds.add(id)) { result.add(AssetDoc(id, mediaType, sourcePath, base64)) }
        index++
    }
    DecodedAssets(result.toArray(), references)
}

private func decodeOrphans(root: JsonObjectValue): Array<OrphanDocComment> {
    let result = ArrayList<OrphanDocComment>()
    var index: Int64 = 0
    for (node in arrayAt(root, "orphanDocComments", "$" ).values()) {
        let path = "$.orphanDocComments[${index}]"
        let value = strictObject(node, path, ["rawText", "source"])
        result.add(OrphanDocComment(stringAt(value, "rawText", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

private func decodeMacros(root: JsonObjectValue): Array<MacroInvocation> {
    let result = ArrayList<MacroInvocation>()
    var index: Int64 = 0
    for (node in arrayAt(root, "macroInvocations", "$" ).values()) {
        let path = "$.macroInvocations[${index}]"
        let value = strictObject(node, path, ["name", "source"])
        result.add(MacroInvocation(stringAt(value, "name", path),
            decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

private func decodeUnsupported(root: JsonObjectValue): Array<UnsupportedDeclaration> {
    let result = ArrayList<UnsupportedDeclaration>()
    var index: Int64 = 0
    for (node in arrayAt(root, "unsupportedDeclarations", "$" ).values()) {
        let path = "$.unsupportedDeclarations[${index}]"
        let value = strictObject(node, path, ["kind", "name", "reason", "source"])
        result.add(UnsupportedDeclaration(stringAt(value, "kind", path), stringAt(value, "name", path),
            stringAt(value, "reason", path), decodeRange(required(value, "source", path), "${path}.source")))
        index++
    }
    result.toArray()
}

private func decodeUnbound(root: JsonObjectValue): Array<UnboundSemanticDeclaration> {
    let result = ArrayList<UnboundSemanticDeclaration>()
    var index: Int64 = 0
    for (node in arrayAt(root, "unboundSemanticDeclarations", "$" ).values()) {
        let path = "$.unboundSemanticDeclarations[${index}]"
        let value = strictObject(node, path, ["provider", "display", "reason"])
        result.add(UnboundSemanticDeclaration(stringAt(value, "provider", path),
            stringAt(value, "display", path), stringAt(value, "reason", path)))
        index++
    }
    result.toArray()
}

private func decodeDiagnostics(root: JsonObjectValue, legacy: Bool,
    legacyIds: HashMap<String, String>): Array<Diagnostic> {
    let result = ArrayList<Diagnostic>()
    var index: Int64 = 0
    for (node in arrayAt(root, "diagnostics", "$" ).values()) {
        let path = "$.diagnostics[${index}]"
        let value = strictObject(node, path, ["severity", "code", "message", "source", "symbolId"])
        let sourceNode = required(value, "source", path)
        result.add(Diagnostic(stringAt(value, "severity", path), stringAt(value, "code", path),
            stringAt(value, "message", path),
            source: if (sourceNode.isNull) { None }
                else { Some(decodeRange(sourceNode, "${path}.source")) },
            symbolId: migratedOptionalSymbolId(nullableStringAt(value, "symbolId", path), legacy,
                legacyIds, "${path}.symbolId")))
        index++
    }
    result.toArray()
}

public func decodeDocIr(text: String): DocumentationSet {
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH,
            maxStringBytes: DOC_IR_MAX_JSON_STRING_BYTES,
            maxBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES)))
    let rawShape = validateRawSchemaShape(parsed)
    validateDeclarativeSchema(parsed)
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "project",
        "configuration", "providers", "modules", "packages", "files", "declarations", "assets",
        "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics"])
    let version = stringAt(root, "schemaVersion", "$")
    let legacyV6 = version == DOC_IR_V6_SCHEMA_VERSION
    let legacy = legacyV6 || version == DOC_IR_V7_SCHEMA_VERSION
    if (!legacy && version != DOC_IR_SCHEMA_VERSION) {
        fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}', " +
            "'${DOC_IR_V7_SCHEMA_VERSION}', or '${DOC_IR_V6_SCHEMA_VERSION}'")
    }
    let generator = strictObject(required(root, "generator", "$"), "$.generator", ["name", "version"])
    let project = strictObject(required(root, "project", "$"), "$.project", ["name", "kind"])
    let configuration = strictObject(required(root, "configuration", "$"), "$.configuration",
        ["audience", "lintProfile", "cfgProfile"])
    let modules = decodeModules(root, legacy)
    let legacyModules = buildLegacyModuleIndex(modules)
    let legacyIds = if (legacyV6) { buildLegacySymbolIds(root, legacyModules) }
        else { HashMap<String, String>() }
    let decodedAssets = decodeAssets(root, legacy)
    let documentation = DocumentationSet(GeneratorInfo(stringAt(generator, "name", "$.generator"),
        stringAt(generator, "version", "$.generator")), stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"), kind: stringAt(project, "kind", "$.project")),
        ConfigurationSnapshot(audience: stringAt(configuration, "audience", "$.configuration"),
            lintProfile: stringAt(configuration, "lintProfile", "$.configuration"),
            cfgProfile: stringAt(configuration, "cfgProfile", "$.configuration")),
        providers: decodeProviders(root, modules, legacyV6, rawShape, text.size), modules: modules,
        packages: decodePackages(root, legacy, legacyV6, legacyIds),
        files: decodeFiles(root), declarations: decodeDeclarations(root, legacyV6, legacy,
            legacyModules, legacyIds, decodedAssets.references),
        assets: decodedAssets.assets,
        orphanDocComments: decodeOrphans(root), macroInvocations: decodeMacros(root),
        unsupportedDeclarations: decodeUnsupported(root), unboundSemanticDeclarations: decodeUnbound(root),
        diagnostics: decodeDiagnostics(root, legacyV6, legacyIds))
    validateDocumentationSet(documentation)
    documentation
}
