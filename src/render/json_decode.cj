package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

private func fail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR at ${path}: ${message}")
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

private func decodeCapabilities(node: JsonNode, path: String): SemanticCapabilities {
    let value = strictObject(node, path, ["sourceBinding", "ownership", "visibility",
        "canonicalTypes", "canonicalSignatures", "relationships"])
    SemanticCapabilities(boolAt(value, "sourceBinding", path), boolAt(value, "ownership", path),
        boolAt(value, "visibility", path), boolAt(value, "canonicalTypes", path),
        boolAt(value, "canonicalSignatures", path), relationships: boolAt(value, "relationships", path))
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

private func decodeTag(node: JsonNode, path: String): DocTag {
    let value = strictObject(node, path,
        ["name", "subject", "description", "referenceState", "targetSymbolId"])
    DocTag(stringAt(value, "name", path), stringAt(value, "subject", path),
        stringAt(value, "description", path),
        referenceState: stringAt(value, "referenceState", path),
        targetSymbolId: nullableStringAt(value, "targetSymbolId", path))
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

private func decodeComment(node: JsonNode, path: String): DocComment {
    let value = strictObject(node, path, ["rawText", "summary", "description", "markdown", "tags"])
    let tags = ArrayList<DocTag>()
    var index: Int64 = 0
    for (tag in arrayAt(value, "tags", path).values()) {
        tags.add(decodeTag(tag, "${path}.tags[${index}]")); index++
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

private func decodeSymbolRelationship(node: JsonNode, path: String): SymbolRelationship {
    let value = strictObject(node, path, ["kind", "targetDisplay", "state", "targetSymbolId"])
    SymbolRelationship(stringAt(value, "kind", path), stringAt(value, "targetDisplay", path),
        stringAt(value, "state", path),
        targetSymbolId: nullableStringAt(value, "targetSymbolId", path))
}

private func decodeSymbol(node: JsonNode, path: String): SymbolDoc {
    let value = strictObject(node, path, ["id", "kind", "name", "qualifiedName", "packageName",
        "ownerId", "visibility", "genericParameters", "parameters", "returnType", "annotations",
        "typeRelationships", "symbolRelationships",
        "documentation", "source", "headerSpelling", "semantic", "origin"])
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
            "${path}.symbolRelationships[${index}]")); index++
    }
    let returnNode = required(value, "returnType", path)
    let returnType: ?TypeRef = if (returnNode.isNull) { None }
        else { Some(decodeTypeRef(returnNode, "${path}.returnType", 0)) }
    let documentationNode = required(value, "documentation", path)
    let documentation: ?DocComment = if (documentationNode.isNull) { None }
        else { Some(decodeComment(documentationNode, "${path}.documentation")) }
    let semantic = strictObject(required(value, "semantic", path), "${path}.semantic",
        ["state", "provider", "canonicalSignature"])
    let origin = strictObject(required(value, "origin", path), "${path}.origin",
        ["kind", "macroSymbolId"])
    SymbolDoc(stringAt(value, "id", path), stringAt(value, "kind", path),
        stringAt(value, "name", path), stringAt(value, "qualifiedName", path),
        stringAt(value, "packageName", path), stringAt(value, "visibility", path),
        decodeRange(required(value, "source", path), "${path}.source"),
        stringAt(value, "headerSpelling", path),
        SemanticInfo(stringAt(semantic, "state", "${path}.semantic"),
            stringAt(semantic, "provider", "${path}.semantic"),
            canonicalSignature: nullableStringAt(semantic, "canonicalSignature", "${path}.semantic")),
        ownerId: nullableStringAt(value, "ownerId", path),
        genericParameters: stringsAt(value, "genericParameters", path),
        parameters: parameters.toArray(), returnType: returnType,
        annotations: stringsAt(value, "annotations", path),
        typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: documentation,
        origin: DeclarationOrigin(kind: stringAt(origin, "kind", "${path}.origin"),
            macroSymbolId: nullableStringAt(origin, "macroSymbolId", "${path}.origin")))
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

private func decodePackages(root: JsonObjectValue): Array<PackageDoc> {
    let result = ArrayList<PackageDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "packages", "$" ).values()) {
        let path = "$.packages[${index}]"
        let value = strictObject(node, path, ["name", "moduleId", "sourceFiles", "symbolIds"])
        result.add(PackageDoc(stringAt(value, "name", path), stringAt(value, "moduleId", path),
            sourceFiles: stringsAt(value, "sourceFiles", path), symbolIds: stringsAt(value, "symbolIds", path)))
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

private func decodeProviders(root: JsonObjectValue): Array<ProviderInfo> {
    let result = ArrayList<ProviderInfo>()
    var index: Int64 = 0
    for (node in arrayAt(root, "providers", "$" ).values()) {
        let path = "$.providers[${index}]"
        let value = strictObject(node, path, ["name", "version", "state", "capabilities"])
        result.add(ProviderInfo(stringAt(value, "name", path), stringAt(value, "version", path),
            stringAt(value, "state", path),
            decodeCapabilities(required(value, "capabilities", path), "${path}.capabilities")))
        index++
    }
    result.toArray()
}

private func decodeDeclarations(root: JsonObjectValue): Array<SymbolDoc> {
    let result = ArrayList<SymbolDoc>()
    var index: Int64 = 0
    for (node in arrayAt(root, "declarations", "$" ).values()) {
        result.add(decodeSymbol(node, "$.declarations[${index}]")); index++
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

private func decodeDiagnostics(root: JsonObjectValue): Array<Diagnostic> {
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
            symbolId: nullableStringAt(value, "symbolId", path)))
        index++
    }
    result.toArray()
}

public func decodeDocIr(text: String): DocumentationSet {
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 128, maxStringBytes: 8 * 1024 * 1024,
            maxBytes: 64 * 1024 * 1024)))
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "project",
        "configuration", "providers", "modules", "packages", "files", "declarations", "assets",
        "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics"])
    if (stringAt(root, "schemaVersion", "$") != DOC_IR_SCHEMA_VERSION) {
        fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}'")
    }
    let generator = strictObject(required(root, "generator", "$"), "$.generator", ["name", "version"])
    let project = strictObject(required(root, "project", "$"), "$.project", ["name", "kind"])
    let configuration = strictObject(required(root, "configuration", "$"), "$.configuration",
        ["audience", "lintProfile", "cfgProfile"])
    DocumentationSet(GeneratorInfo(stringAt(generator, "name", "$.generator"),
        stringAt(generator, "version", "$.generator")), stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"), kind: stringAt(project, "kind", "$.project")),
        ConfigurationSnapshot(audience: stringAt(configuration, "audience", "$.configuration"),
            lintProfile: stringAt(configuration, "lintProfile", "$.configuration"),
            cfgProfile: stringAt(configuration, "cfgProfile", "$.configuration")),
        providers: decodeProviders(root), modules: decodeModules(root), packages: decodePackages(root),
        files: decodeFiles(root), declarations: decodeDeclarations(root), assets: decodeAssets(root),
        orphanDocComments: decodeOrphans(root), macroInvocations: decodeMacros(root),
        unsupportedDeclarations: decodeUnsupported(root), unboundSemanticDeclarations: decodeUnbound(root),
        diagnostics: decodeDiagnostics(root))
}
