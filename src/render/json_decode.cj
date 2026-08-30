package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import yjson.*
import yjson_algorithms.*

private func fail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR at ${path}: ${message}")
}

private func validateDeclarativeSchema(root: JsonNode): Unit {
    let version = try {
        root.asObject().get("schemaVersion").getOrThrow().string
    } catch (_: Exception) {
        fail("$.schemaVersion", "expected string")
    }
    let schemaText = if (version == DOC_IR_SCHEMA_VERSION) { DOC_IR_SCHEMA }
        else if (version == DOC_IR_V6_SCHEMA_VERSION) { DOC_IR_V6_SCHEMA }
        else {
            fail("$.schemaVersion",
                "expected '${DOC_IR_SCHEMA_VERSION}' or '${DOC_IR_V6_SCHEMA_VERSION}'")
        }
    let schema = JsonSchema.parse(schemaText, config: JsonSchemaConfig(
        limits: JsonSchemaLimits(maxEvaluations: 5000000, maxRefResolutions: 500000,
            maxErrors: 20, maxDepth: 128)))
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

private func stringListContains(values: ReadOnlyList<String>, expected: String): Bool {
    for (value in values) { if (value == expected) { return true } }
    false
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
    if (depth > 64) { fail(path, "type nesting exceeds 64") }
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

private func decodeMarkdown(node: JsonNode, path: String, depth: Int64): MarkdownNode {
    if (depth > 64) { fail(path, "Markdown nesting exceeds 64") }
    let value = strictObject(node, path, ["kind", "literal", "source", "children"])
    let sourceNode = required(value, "source", path)
    let source: ?SourceRange = if (sourceNode.isNull) { None }
        else { Some(decodeRange(sourceNode, "${path}.source")) }
    let children = ArrayList<MarkdownNode>()
    var index: Int64 = 0
    for (child in arrayAt(value, "children", path).values()) {
        children.add(decodeMarkdown(child, "${path}.children[${index}]", depth + 1))
        index++
    }
    MarkdownNode(stringAt(value, "kind", path), literal: stringAt(value, "literal", path),
        source: source, children: children.toArray())
}

private func decodeComment(node: JsonNode, path: String, legacy: Bool,
    legacyIds: HashMap<String, String>): DocComment {
    let value = strictObject(node, path, ["rawText", "summary", "description", "markdown", "tags"])
    let tags = ArrayList<DocTag>()
    var index: Int64 = 0
    for (tag in arrayAt(value, "tags", path).values()) {
        tags.add(decodeTag(tag, "${path}.tags[${index}]", legacy, legacyIds)); index++
    }
    DocComment(stringAt(value, "rawText", path), stringAt(value, "summary", path),
        stringAt(value, "description", path),
        decodeMarkdown(required(value, "markdown", path), "${path}.markdown", 0),
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

private func legacyModuleId(modules: Array<ModuleDoc>, packageName: String, path: String): String {
    var found: ?String = None
    for (module in modules) {
        if (!stringListContains(module.packageNames, packageName)) { continue }
        if (found.isSome()) {
            fail(path, "v6 package '${packageName}' maps to more than one module")
        }
        found = Some(module.id)
    }
    match (found) {
        case Some(moduleId) => moduleId
        case None => fail(path, "v6 package '${packageName}' has no module mapping")
    }
}

private func buildLegacySymbolIds(root: JsonObjectValue,
    modules: Array<ModuleDoc>): HashMap<String, String> {
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

private func decodeSymbol(node: JsonNode, path: String, legacy: Bool,
    modules: Array<ModuleDoc>, legacyIds: HashMap<String, String>): SymbolDoc {
    let keys = if (legacy) { ["id", "kind", "name", "qualifiedName", "packageName",
        "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations",
        "typeRelationships", "symbolRelationships",
        "documentation", "source", "headerSpelling", "semantic", "origin"] } else {
        ["id", "kind", "name", "qualifiedName", "packageName", "moduleId", "ownerId", "visibility",
            "genericParameters", "parameters", "returnType", "annotations", "typeRelationships",
            "symbolRelationships", "documentation", "source", "headerSpelling", "semantic", "origin"]
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
            "${path}.symbolRelationships[${index}]", legacy, legacyIds)); index++
    }
    let returnNode = required(value, "returnType", path)
    let returnType: ?TypeRef = if (returnNode.isNull) { None }
        else { Some(decodeTypeRef(returnNode, "${path}.returnType", 0)) }
    let documentationNode = required(value, "documentation", path)
    let documentation: ?DocComment = if (documentationNode.isNull) { None }
        else { Some(decodeComment(documentationNode, "${path}.documentation", legacy, legacyIds)) }
    let semantic = strictObject(required(value, "semantic", path), "${path}.semantic",
        ["state", "provider", "canonicalSignature"])
    let origin = strictObject(required(value, "origin", path), "${path}.origin",
        ["kind", "macroSymbolId"])
    let packageName = stringAt(value, "packageName", path)
    let moduleId = if (legacy) { legacyModuleId(modules, packageName, path) }
        else { stringAt(value, "moduleId", path) }
    SymbolDoc(migratedSymbolId(stringAt(value, "id", path), legacy, legacyIds, "${path}.id"),
        stringAt(value, "kind", path),
        stringAt(value, "name", path), stringAt(value, "qualifiedName", path),
        packageName, moduleId, stringAt(value, "visibility", path),
        decodeRange(required(value, "source", path), "${path}.source"),
        stringAt(value, "headerSpelling", path),
        SemanticInfo(stringAt(semantic, "state", "${path}.semantic"),
            stringAt(semantic, "provider", "${path}.semantic"),
            canonicalSignature: nullableStringAt(semantic, "canonicalSignature", "${path}.semantic")),
        ownerId: migratedOptionalSymbolId(nullableStringAt(value, "ownerId", path), legacy,
            legacyIds, "${path}.ownerId"),
        genericParameters: stringsAt(value, "genericParameters", path),
        parameters: parameters.toArray(), returnType: returnType,
        annotations: decodeAnnotations(value, path, legacy),
        typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: documentation,
        origin: DeclarationOrigin(kind: stringAt(origin, "kind", "${path}.origin"),
            macroSymbolId: migratedOptionalSymbolId(nullableStringAt(origin, "macroSymbolId",
                "${path}.origin"), legacy, legacyIds, "${path}.origin.macroSymbolId")))
}

private func decodeModules(root: JsonObjectValue): Array<ModuleDoc> {
    let result = ArrayList<ModuleDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "modules", "$" ).values()) {
        let path = "$.modules[${index}]"
        let value = strictObject(node, path,
            ["id", "name", "role", "sourcePrefix", "packageNames", "dependencyIds"])
        result.add(ModuleDoc(stringAt(value, "id", path), stringAt(value, "name", path),
            stringAt(value, "role", path), stringAt(value, "sourcePrefix", path),
            packageNames: stringsAt(value, "packageNames", path),
            dependencyIds: stringsAt(value, "dependencyIds", path)))
        index++
    }
    result.toArray()
}

private func decodePackages(root: JsonObjectValue, legacy: Bool,
    legacyIds: HashMap<String, String>): Array<PackageDoc> {
    let result = ArrayList<PackageDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "packages", "$" ).values()) {
        let path = "$.packages[${index}]"
        let value = strictObject(node, path, ["name", "moduleId", "sourceFiles", "symbolIds"])
        let ids = ArrayList<String>()
        var symbolIndex: Int64 = 0
        for (id in stringsAt(value, "symbolIds", path)) {
            ids.add(migratedSymbolId(id, legacy, legacyIds,
                "${path}.symbolIds[${symbolIndex}]"))
            symbolIndex++
        }
        result.add(PackageDoc(stringAt(value, "name", path), stringAt(value, "moduleId", path),
            sourceFiles: stringsAt(value, "sourceFiles", path), symbolIds: ids.toArray()))
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

private func decodeProviders(root: JsonObjectValue, modules: Array<ModuleDoc>, legacy: Bool): Array<ProviderInfo> {
    let result = ArrayList<ProviderInfo>()
    var index: Int64 = 0
    for (node in arrayAt(root, "providers", "$" ).values()) {
        let path = "$.providers[${index}]"
        let keys = if (legacy) { ["name", "version", "state", "capabilities"] }
            else { ["name", "version", "moduleId", "state", "capabilities"] }
        let value = strictObject(node, path, keys)
        if (legacy) {
            for (module in modules) {
                result.add(ProviderInfo(stringAt(value, "name", path), stringAt(value, "version", path),
                    module.id, stringAt(value, "state", path),
                    decodeCapabilities(required(value, "capabilities", path), "${path}.capabilities", true)))
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

private func decodeDeclarations(root: JsonObjectValue, legacy: Bool,
    modules: Array<ModuleDoc>, legacyIds: HashMap<String, String>): Array<SymbolDoc> {
    let result = ArrayList<SymbolDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "declarations", "$" ).values()) {
        result.add(decodeSymbol(node, "$.declarations[${index}]", legacy, modules, legacyIds)); index++
    }
    result.toArray()
}

private func decodeAssets(root: JsonObjectValue): Array<AssetDoc> {
    let result = ArrayList<AssetDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "assets", "$" ).values()) {
        let path = "$.assets[${index}]"
        let value = strictObject(node, path, ["id", "mediaType", "sourcePath", "base64"])
        result.add(AssetDoc(stringAt(value, "id", path), stringAt(value, "mediaType", path),
            stringAt(value, "sourcePath", path), stringAt(value, "base64", path)))
        index++
    }
    result.toArray()
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
        limits: JsonReadLimits(maxDepth: 128, maxStringBytes: 8 * 1024 * 1024,
            maxBytes: 64 * 1024 * 1024)))
    validateDeclarativeSchema(parsed)
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "project",
        "configuration", "providers", "modules", "packages", "files", "declarations", "assets",
        "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics"])
    let version = stringAt(root, "schemaVersion", "$")
    let legacy = if (version == DOC_IR_SCHEMA_VERSION) { false }
        else if (version == DOC_IR_V6_SCHEMA_VERSION) { true }
        else { fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}' or '${DOC_IR_V6_SCHEMA_VERSION}'") }
    let generator = strictObject(required(root, "generator", "$"), "$.generator", ["name", "version"])
    let project = strictObject(required(root, "project", "$"), "$.project", ["name", "kind"])
    let configuration = strictObject(required(root, "configuration", "$"), "$.configuration",
        ["audience", "lintProfile", "cfgProfile"])
    let modules = decodeModules(root)
    let legacyIds = if (legacy) { buildLegacySymbolIds(root, modules) }
        else { HashMap<String, String>() }
    let documentation = DocumentationSet(GeneratorInfo(stringAt(generator, "name", "$.generator"),
        stringAt(generator, "version", "$.generator")), stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"), kind: stringAt(project, "kind", "$.project")),
        ConfigurationSnapshot(audience: stringAt(configuration, "audience", "$.configuration"),
            lintProfile: stringAt(configuration, "lintProfile", "$.configuration"),
            cfgProfile: stringAt(configuration, "cfgProfile", "$.configuration")),
        providers: decodeProviders(root, modules, legacy), modules: modules,
        packages: decodePackages(root, legacy, legacyIds),
        files: decodeFiles(root), declarations: decodeDeclarations(root, legacy, modules, legacyIds),
        assets: decodeAssets(root),
        orphanDocComments: decodeOrphans(root), macroInvocations: decodeMacros(root),
        unsupportedDeclarations: decodeUnsupported(root), unboundSemanticDeclarations: decodeUnbound(root),
        diagnostics: decodeDiagnostics(root, legacy, legacyIds))
    validateDocumentationSet(documentation)
    documentation
}
