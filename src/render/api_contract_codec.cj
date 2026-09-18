package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*
import yjson.*

private let API_CONTRACT_MAX_INPUT: Int64 = 64 * 1024 * 1024
private let API_CONTRACT_MAX_ENTRIES: Int64 = 100000

private func appendNullableString(out: RenderTextBuffer, value: ?String): Unit {
    match (value) {
        case Some(text) => appendSearchJsonString(out, text)
        case None => out.append("null")
    }
}

private func appendNullableBool(out: RenderTextBuffer, value: ?Bool): Unit {
    match (value) {
        case Some(flag) => out.append(if (flag) { "true" } else { "false" })
        case None => out.append("null")
    }
}

private func appendStringArray(out: RenderTextBuffer, values: ReadOnlyList<String>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }
        first = false
        appendSearchJsonString(out, value)
    }
    out.append("]")
}

private func joinContractTokens(values: ReadOnlyList<String>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append(" ") }
        first = false
        out.append(value)
    }
    out.toString()
}

private func appendParameterArray(out: RenderTextBuffer,
    values: ReadOnlyList<ApiContractParameter>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"name\":")
        appendSearchJsonString(out, value.name)
        out.append(",\"type\":{\"state\":")
        appendSearchJsonString(out, value.typeState)
        out.append(",\"value\":")
        appendNullableString(out, value.`type`)
        out.append("},\"default\":{\"state\":")
        appendSearchJsonString(out, value.defaultState)
        out.append(",\"value\":")
        appendNullableString(out, value.defaultValue)
        out.append("}}")
    }
    out.append("]")
}

private func appendApiDeclaration(out: RenderTextBuffer, declaration: ApiContractDeclaration): Unit {
    out.append("{\"id\":"); appendSearchJsonString(out, declaration.id)
    out.append(",\"moduleId\":"); appendSearchJsonString(out, declaration.moduleId)
    out.append(",\"packageName\":"); appendSearchJsonString(out, declaration.packageName)
    out.append(",\"ownerId\":"); appendNullableString(out, declaration.ownerId)
    out.append(",\"kind\":"); appendSearchJsonString(out, declaration.kind)
    out.append(",\"name\":"); appendSearchJsonString(out, declaration.name)
    out.append(",\"qualifiedName\":"); appendSearchJsonString(out, declaration.qualifiedName)
    out.append(",\"visibility\":"); appendSearchJsonString(out, declaration.visibility)
    out.append(",\"sourceApiSignature\":{\"state\":")
    appendSearchJsonString(out, declaration.sourceApiSignatureState)
    out.append(",\"tokens\":"); appendStringArray(out, declaration.sourceApiSignature)
    out.append("}")
    out.append(",\"genericParameters\":"); appendStringArray(out, declaration.genericParameters)
    out.append(",\"parameters\":"); appendParameterArray(out, declaration.parameters)
    out.append(",\"return\":{\"state\":")
    appendSearchJsonString(out, declaration.returnState)
    out.append(",\"type\":"); appendNullableString(out, declaration.returnType)
    out.append("}")
    out.append(",\"relationships\":"); appendStringArray(out, declaration.relationships)
    out.append(",\"enumNonExhaustive\":"); appendNullableBool(out, declaration.enumNonExhaustive)
    out.append(",\"documentationFingerprint\":"); appendSearchJsonString(out, declaration.documentationFingerprint)
    out.append(",\"sourceFingerprint\":"); appendSearchJsonString(out, declaration.sourceFingerprint)
    out.append(",\"metadataFingerprint\":"); appendSearchJsonString(out, declaration.metadataFingerprint)
    out.append(",\"collectionState\":"); appendSearchJsonString(out, declaration.collectionState)
    out.append("}")
}

private func appendApiExposure(out: RenderTextBuffer, exposure: ApiContractExposure): Unit {
    out.append("{\"id\":"); appendSearchJsonString(out, exposure.id)
    out.append(",\"moduleId\":"); appendSearchJsonString(out, exposure.moduleId)
    out.append(",\"packageName\":"); appendSearchJsonString(out, exposure.packageName)
    out.append(",\"exposedName\":"); appendSearchJsonString(out, exposure.exposedName)
    out.append(",\"targetIds\":"); appendStringArray(out, exposure.targetIds)
    out.append(",\"state\":"); appendSearchJsonString(out, exposure.state)
    out.append("}")
}

public func encodeApiContractSnapshot(snapshot: ApiContractSnapshot): String {
    let out = RenderTextBuffer()
    out.append("{\"schemaVersion\":")
    appendSearchJsonString(out, snapshot.schemaVersion)
    out.append(",\"project\":"); appendSearchJsonString(out, snapshot.project)
    out.append(",\"audience\":"); appendSearchJsonString(out, snapshot.audience)
    out.append(",\"cfgProfile\":"); appendSearchJsonString(out, snapshot.cfgProfile)
    out.append(",\"collectionState\":"); appendSearchJsonString(out, snapshot.collectionState)
    out.append(",\"declarations\":[")
    var first = true
    for (declaration in snapshot.declarations) {
        if (!first) { out.append(",") }
        first = false
        appendApiDeclaration(out, declaration)
    }
    out.append("],\"exposures\":[")
    first = true
    for (exposure in snapshot.exposures) {
        if (!first) { out.append(",") }
        first = false
        appendApiExposure(out, exposure)
    }
    out.append("]}\n")
    out.toString()
}

private func typeState(value: TypeRef): String {
    if (value.semantic.state == "resolved") { "resolved" } else { value.semantic.state }
}

private func typeValue(value: TypeRef): ?String {
    if (value.semantic.state == "resolved") { Some(value.spelling) } else { None }
}

private func appendFingerprintPart(out: StringBuilder, label: String, value: String): Unit {
    out.append(label)
    out.append("#")
    out.append(value.toArray().size.toString())
    out.append(":")
    out.append(value)
    out.append(";")
}

private func appendOptionalFingerprintString(out: StringBuilder, label: String, value: ?String): Unit {
    match (value) {
        case Some(text) => appendFingerprintPart(out, label + ":some", text)
        case None => appendFingerprintPart(out, label + ":none", "")
    }
}

private func appendOptionalFingerprintInt(out: StringBuilder, label: String, value: ?Int64): Unit {
    match (value) {
        case Some(number) => appendFingerprintPart(out, label + ":some", number.toString())
        case None => appendFingerprintPart(out, label + ":none", "")
    }
}

private func appendOptionalFingerprintBool(out: StringBuilder, label: String, value: ?Bool): Unit {
    match (value) {
        case Some(flag) => appendFingerprintPart(out, label + ":some", if (flag) { "true" } else { "false" })
        case None => appendFingerprintPart(out, label + ":none", "")
    }
}

private func appendDocumentationMetadataFingerprint(out: StringBuilder, value: MarkdownNodeMetadata): Unit {
    appendFingerprintPart(out, "kind", value.kind)
    appendOptionalFingerprintInt(out, "headingLevel", value.headingLevel)
    appendOptionalFingerprintString(out, "listKind", value.listKind)
    appendOptionalFingerprintInt(out, "listStart", value.listStart)
    appendOptionalFingerprintString(out, "listDelimiter", value.listDelimiter)
    appendOptionalFingerprintBool(out, "listTight", value.listTight)
    appendOptionalFingerprintString(out, "taskState", value.taskState)
    appendOptionalFingerprintString(out, "codeKind", value.codeKind)
    appendOptionalFingerprintString(out, "fenceCharacter", value.fenceCharacter)
    appendOptionalFingerprintInt(out, "fenceLength", value.fenceLength)
    appendOptionalFingerprintString(out, "infoRaw", value.infoRaw)
    appendOptionalFingerprintString(out, "language", value.language)
    appendOptionalFingerprintString(out, "attributesRaw", value.attributesRaw)
    appendOptionalFingerprintBool(out, "tableHeader", value.tableHeader)
    appendOptionalFingerprintString(out, "tableAlignment", value.tableAlignment)
    appendFingerprintPart(out, "tableAlignments-count", value.tableAlignments.size.toString())
    for (alignment in value.tableAlignments) {
        appendFingerprintPart(out, "tableAlignment", alignment)
    }
}

private func appendDocumentationMarkdownFingerprint(out: StringBuilder, value: MarkdownNode): Unit {
    appendFingerprintPart(out, "node-kind", value.kind)
    appendFingerprintPart(out, "node-literal", value.literal)
    match (value.metadata) {
        case Some(metadata) =>
            appendFingerprintPart(out, "metadata", "some")
            appendDocumentationMetadataFingerprint(out, metadata)
        case None => appendFingerprintPart(out, "metadata", "none")
    }
    appendFingerprintPart(out, "children-count", value.children.size.toString())
    for (child in value.children) {
        appendDocumentationMarkdownFingerprint(out, child)
    }
}

private func documentationValue(symbol: SymbolDoc): String {
    let out = StringBuilder()
    match (symbol.documentation) {
        case Some(comment) =>
            appendFingerprintPart(out, "rawText", comment.rawText)
            appendFingerprintPart(out, "summary", comment.summary)
            appendFingerprintPart(out, "description", comment.description)
            appendDocumentationMarkdownFingerprint(out, comment.markdown)
            appendFingerprintPart(out, "tag-count", comment.tags.size.toString())
            for (tag in comment.tags) {
                appendFingerprintPart(out, "tag-name", tag.name)
                appendFingerprintPart(out, "tag-subject", tag.subject)
                appendFingerprintPart(out, "tag-description", tag.description)
                appendFingerprintPart(out, "tag-reference-state", tag.referenceState)
                appendOptionalFingerprintString(out, "tag-target", tag.targetSymbolId)
            }
        case None => appendFingerprintPart(out, "documentation", "none")
    }
    contractFingerprint(out.toString())
}

private func sourceValue(symbol: SymbolDoc): String {
    let value = if (symbol.sourceApiSignature.state == "available") {
        joinContractTokens(symbol.sourceApiSignature.tokens)
    } else { "" }
    contractFingerprint(value)
}

private func metadataValue(symbol: SymbolDoc): String {
    let out = StringBuilder()
    out.append(symbol.origin.kind)
    for (annotation in symbol.annotations) { out.append("|"); out.append(annotation.spelling) }
    contractFingerprint(out.toString())
}

private func apiDeclarationForSymbol(symbol: SymbolDoc): ApiContractDeclaration {
    let parameters = ArrayList<ApiContractParameter>()
    for (parameter in symbol.parameters) {
        let defaultState = match (parameter.defaultExpression) {
            case Some(_) => "resolved"
            case None => "unavailable"
        }
        parameters.add(ApiContractParameter(parameter.name,
            typeState: typeState(parameter.typeRef), `type`: typeValue(parameter.typeRef),
            defaultState: defaultState, defaultValue: parameter.defaultExpression))
    }
    let returnState = match (symbol.returnType) {
        case Some(value) => typeState(value)
        case None => "unavailable"
    }
    let returnValue = match (symbol.returnType) {
        case Some(value) => typeValue(value)
        case None => None<String>
    }
    let relationships = ArrayList<String>()
    for (relationship in symbol.typeRelationships) {
        relationships.add("${relationship.kind}:${relationship.target.spelling}")
    }
    for (relationship in symbol.symbolRelationships) {
        let target = match (relationship.targetSymbolId) {
            case Some(id) => id
            case None => relationship.targetDisplay
        }
        relationships.add("${relationship.kind}:${relationship.state}:${target}")
    }
    let signatureState = if (symbol.sourceApiSignature.state == "available") { "resolved" } else { "unavailable" }
    ApiContractDeclaration(symbol.id, symbol.moduleId, symbol.packageName, symbol.kind, symbol.name,
        symbol.qualifiedName, symbol.visibility, signatureState,
        sourceApiSignature: symbol.sourceApiSignature.tokens.toArray(),
        ownerId: symbol.ownerId, genericParameters: symbol.genericParameters.toArray(),
        parameters: parameters.toArray(), returnState: returnState, returnType: returnValue,
        relationships: relationships.toArray(), enumNonExhaustive: symbol.enumNonExhaustive,
        documentationFingerprint: documentationValue(symbol), sourceFingerprint: sourceValue(symbol),
        metadataFingerprint: metadataValue(symbol), collectionState: "resolved")
}

public func apiContractSnapshotForDocumentation(documentation: DocumentationSet): ApiContractSnapshot {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let declarations = ArrayList<ApiContractDeclaration>()
    for (symbol in projection.visibleSymbols) {
        if (declarations.size >= API_CONTRACT_MAX_ENTRIES) {
            throw IllegalArgumentException("API surface declaration limit exceeded")
        }
        declarations.add(apiDeclarationForSymbol(symbol))
    }
    sort(declarations, lessThan: { left, right =>
        if (left.qualifiedName != right.qualifiedName) { return left.qualifiedName < right.qualifiedName }
        if (left.kind != right.kind) { return left.kind < right.kind }
        left.id < right.id
    }, stable: true)
    let exposures = ArrayList<ApiContractExposure>()
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                exposures.add(ApiContractExposure(reExport.id, pkg.moduleId, pkg.name,
                    binding.exposedName, binding.targetSymbolIds.toArray(), state: reExport.state))
            }
        }
    }
    sort(exposures, lessThan: { left, right => left.id < right.id }, stable: true)
    let collectionState = if (documentation.status == "complete") { "resolved" }
        else if (documentation.status == "partial") { "partial" }
        else { "unavailable" }
    ApiContractSnapshot(documentation.project.name, documentation.configuration.audience,
        documentation.configuration.cfgProfile, collectionState: collectionState,
        declarations: declarations.toArray(), exposures: exposures.toArray())
}

public func renderApiContractSnapshot(documentation: DocumentationSet): String {
    encodeApiContractSnapshot(apiContractSnapshotForDocumentation(documentation))
}

private func requiredNode(object: JsonObject, key: String, path: String): JsonNode {
    match (object.get(key)) {
        case Some(value) => value
        case None => throw IllegalArgumentException("invalid API surface at ${path}: missing '${key}'")
    }
}

private func contractString(object: JsonObject, key: String, path: String): String {
    try { requiredNode(object, key, path).asString() }
    catch (_: Exception) { throw IllegalArgumentException("invalid API surface at ${path}.${key}: expected string") }
}
private func contractFingerprint(object: JsonObject, key: String, path: String): String {
    let value = contractString(object, key, path)
    if (value.size != 64) {
        throw IllegalArgumentException("invalid API surface at ${path}.${key}: expected lowercase SHA-256 fingerprint")
    }
    for (byte in value.toArray()) {
        let isHex = (byte >= b'0' && byte <= b'9') ||
            (byte >= b'a' && byte <= b'f')
        if (!isHex) {
            throw IllegalArgumentException(
                "invalid API surface at ${path}.${key}: expected lowercase SHA-256 fingerprint")
        }
    }
    value
}

private func contractNullableString(object: JsonObject, key: String, path: String): ?String {
    let node = requiredNode(object, key, path)
    if (node.isNull) { return None }
    try { Some(node.asString()) }
    catch (_: Exception) { throw IllegalArgumentException("invalid API surface at ${path}.${key}: expected string or null") }
}

private func contractStringArray(object: JsonObject, key: String, path: String): Array<String> {
    let node = try { requiredNode(object, key, path).asArray() }
        catch (_: Exception) { throw IllegalArgumentException("invalid API surface at ${path}.${key}: expected array") }
    let values = ArrayList<String>()
    var index: Int64 = 0
    for (item in jsonArrayValues(node)) {
        try { values.add(item.asString()) }
        catch (_: Exception) { throw IllegalArgumentException("invalid API surface at ${path}.${key}[${index}]") }
        index++
    }
    values.toArray()
}

private func contractNullableBool(object: JsonObject, key: String, path: String): ?Bool {
    let node = requiredNode(object, key, path)
    if (node.isNull) { return None }
    try { Some(node.asBool()) }
    catch (_: Exception) { throw IllegalArgumentException("invalid API surface at ${path}.${key}: expected boolean or null") }
}

private func decodeContractParameter(node: JsonNode, path: String): ApiContractParameter {
    let object = try { node.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}: expected parameter object")
    }
    if (object.size() != 3) { throw IllegalArgumentException("invalid API surface at ${path}: unknown parameter field") }
    let name = contractString(object, "name", path)
    let typeObject = try { requiredNode(object, "type", path).asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}.type")
    }
    let defaultObject = try { requiredNode(object, "default", path).asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}.default")
    }
    if (typeObject.size() != 2 || defaultObject.size() != 2) {
        throw IllegalArgumentException("invalid API surface at ${path}: invalid parameter evidence")
    }
    ApiContractParameter(name, typeState: contractString(typeObject, "state", path + ".type"),
        `type`: contractNullableString(typeObject, "value", path + ".type"),
        defaultState: contractString(defaultObject, "state", path + ".default"),
        defaultValue: contractNullableString(defaultObject, "value", path + ".default"))
}

private func decodeContractDeclaration(node: JsonNode, path: String): ApiContractDeclaration {
    let object = try { node.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}: expected declaration object")
    }
    let sourceObject = try { requiredNode(object, "sourceApiSignature", path).asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}.sourceApiSignature")
    }
    let returnObject = try { requiredNode(object, "return", path).asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}.return")
    }
    let parameterNodes = try { requiredNode(object, "parameters", path).asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}.parameters")
    }
    let parameters = ArrayList<ApiContractParameter>()
    var parameterIndex: Int64 = 0
    for (item in jsonArrayValues(parameterNodes)) {
        parameters.add(decodeContractParameter(item, "${path}.parameters[${parameterIndex}]"))
        parameterIndex++
    }
    if (object.size() != 18 || sourceObject.size() != 2 || returnObject.size() != 2) {
        throw IllegalArgumentException("invalid API surface at ${path}: unknown field")
    }
    ApiContractDeclaration(contractString(object, "id", path), contractString(object, "moduleId", path),
        contractString(object, "packageName", path), contractString(object, "kind", path),
        contractString(object, "name", path), contractString(object, "qualifiedName", path),
        contractString(object, "visibility", path), contractString(sourceObject, "state", "${path}.sourceApiSignature"),
        sourceApiSignature: contractStringArray(sourceObject, "tokens", "${path}.sourceApiSignature"),
        ownerId: contractNullableString(object, "ownerId", path),
        genericParameters: contractStringArray(object, "genericParameters", path), parameters: parameters.toArray(),
        returnState: contractString(returnObject, "state", "${path}.return"),
        returnType: contractNullableString(returnObject, "type", "${path}.return"),
        relationships: contractStringArray(object, "relationships", path),
        enumNonExhaustive: contractNullableBool(object, "enumNonExhaustive", path),
        documentationFingerprint: contractFingerprint(object, "documentationFingerprint", path),
        sourceFingerprint: contractFingerprint(object, "sourceFingerprint", path),
        metadataFingerprint: contractFingerprint(object, "metadataFingerprint", path),
        collectionState: contractString(object, "collectionState", path))
}

private func decodeContractExposure(node: JsonNode, path: String): ApiContractExposure {
    let object = try { node.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface at ${path}: expected exposure object")
    }
    if (object.size() != 6) { throw IllegalArgumentException("invalid API surface at ${path}: unknown field") }
    ApiContractExposure(contractString(object, "id", path), contractString(object, "moduleId", path),
        contractString(object, "packageName", path), contractString(object, "exposedName", path),
        contractStringArray(object, "targetIds", path), state: contractString(object, "state", path))
}

private func decodeLegacyContractExposure(node: JsonNode, path: String): ApiContractExposure {
    let object = try { node.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid legacy API surface at " + path + ": expected exposure object")
    }
    if (object.size() != 5) { throw IllegalArgumentException("invalid legacy API surface at " + path + ": unknown field") }
    ApiContractExposure(contractString(object, "reExportId", path),
        contractString(object, "moduleId", path), contractString(object, "packageName", path),
        contractString(object, "exposedName", path),
        contractStringArray(object, "targetSymbolIds", path), state: "unavailable")
}

public func decodeApiContractSnapshot(text: String): ApiContractSnapshot {
    if (text.toArray().size > API_CONTRACT_MAX_INPUT) {
        throw IllegalArgumentException("API surface exceeds ${API_CONTRACT_MAX_INPUT} bytes")
    }
    let parsed = try {
        JsonNode.parse(text, config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
            maxDepth: 32, maxStringBytes: API_CONTRACT_MAX_INPUT,
            maxBufferedValueBytes: API_CONTRACT_MAX_INPUT, maxInputBytes: API_CONTRACT_MAX_INPUT))
    } catch (error: Exception) {
        throw IllegalArgumentException("invalid API surface JSON: ${error.message}")
    }
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface: expected object")
    }
    let version = contractString(object, "schemaVersion", "$")
    if (version != API_SURFACE_SCHEMA_VERSION && version != API_SURFACE_LEGACY_SCHEMA_VERSION) {
        throw IllegalArgumentException("unsupported API surface schema '${version}'")
    }
    let legacy = version == API_SURFACE_LEGACY_SCHEMA_VERSION
    let expectedFields = if (legacy) { 5 } else { 7 }
    if (object.size() != expectedFields) {
        throw IllegalArgumentException("invalid API surface: unknown or missing top-level field")
    }
    let declarationsNode = try { requiredNode(object, "declarations", "$").asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface declarations")
    }
    let declarations = ArrayList<ApiContractDeclaration>()
    var index: Int64 = 0
    for (node in jsonArrayValues(declarationsNode)) {
        if (declarations.size >= API_CONTRACT_MAX_ENTRIES) {
            throw IllegalArgumentException("API surface exceeds ${API_CONTRACT_MAX_ENTRIES} declarations")
        }
        let item = try { node.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("invalid API surface declaration")
        }
        if (legacy) {
            if (item.size() != 8) {
                throw IllegalArgumentException("invalid legacy API surface declaration at $.declarations[${index}]: unknown field")
            }
            let source = try { requiredNode(item, "sourceApiSignature", "$.declarations[${index}]").asObject() }
                catch (_: Exception) { throw IllegalArgumentException("invalid legacy API surface signature") }
            if (source.size() != 2) {
                throw IllegalArgumentException(
                    "invalid legacy API surface signature at $.declarations[${index}].sourceApiSignature: unknown field")
            }
            let state = contractString(source, "state", "$.declarations[${index}].sourceApiSignature")
            if (state != "available" && state != "unavailable") {
                throw IllegalArgumentException(
                    "invalid legacy API surface signature state at $.declarations[${index}].sourceApiSignature.state")
            }
            let tokens = contractStringArray(source, "tokens", "$.declarations[${index}].sourceApiSignature")
            declarations.add(ApiContractDeclaration(contractString(item, "id", "$.declarations[${index}]"),
                contractString(item, "moduleId", "$.declarations[${index}]"),
                contractString(item, "packageName", "$.declarations[${index}]"),
                contractString(item, "kind", "$.declarations[${index}]"),
                contractString(item, "name", "$.declarations[${index}]"),
                contractString(item, "name", "$.declarations[${index}]"),
                contractString(item, "visibility", "$.declarations[${index}]"),
                if (state == "available") { "resolved" } else { "unavailable" },
                sourceApiSignature: tokens, ownerId: contractNullableString(item, "ownerId", "$.declarations[${index}]"),
                collectionState: "unavailable"))
        } else {
            declarations.add(decodeContractDeclaration(node, "$.declarations[${index}]"))
        }
        index++
    }
    let exposuresNode = try { requiredNode(object, "exposures", "$").asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid API surface exposures")
    }
    let exposures = ArrayList<ApiContractExposure>()
    index = 0
    for (node in jsonArrayValues(exposuresNode)) {
        if (legacy) {
            exposures.add(decodeLegacyContractExposure(node, "$.exposures[" + index.toString() + "]"))
        } else {
            exposures.add(decodeContractExposure(node, "$.exposures[" + index.toString() + "]"))
        }
        index++
    }
    ApiContractSnapshot(contractString(object, "project", "$") , contractString(object, "audience", "$"),
        if (legacy) { "unknown" } else { contractString(object, "cfgProfile", "$") },
        collectionState: if (legacy) { "unavailable" } else { contractString(object, "collectionState", "$") },
        declarations: declarations.toArray(), exposures: exposures.toArray(), schemaVersion: version)
}

public func encodeApiDiffReport(report: ApiDiffReport): String {
    let out = RenderTextBuffer()
    out.append("{\"schemaVersion\":"); appendSearchJsonString(out, report.schemaVersion)
    out.append(",\"baseline\":{\"project\":"); appendSearchJsonString(out, report.baseline.project)
    out.append(",\"audience\":"); appendSearchJsonString(out, report.baseline.audience)
    out.append(",\"cfgProfile\":"); appendSearchJsonString(out, report.baseline.cfgProfile)
    out.append(",\"schemaVersion\":"); appendSearchJsonString(out, report.baseline.schemaVersion)
    out.append(",\"collectionState\":"); appendSearchJsonString(out, report.baseline.collectionState)
    out.append("},\"current\":{\"project\":"); appendSearchJsonString(out, report.current.project)
    out.append(",\"audience\":"); appendSearchJsonString(out, report.current.audience)
    out.append(",\"cfgProfile\":"); appendSearchJsonString(out, report.current.cfgProfile)
    out.append(",\"schemaVersion\":"); appendSearchJsonString(out, report.current.schemaVersion)
    out.append(",\"collectionState\":"); appendSearchJsonString(out, report.current.collectionState)
    out.append("},\"comparisonState\":"); appendSearchJsonString(out, report.comparisonState)
    out.append(",\"summary\":{\"breaking\":${report.summary.breaking},\"potentiallyBreaking\":${report.summary.potentiallyBreaking},\"additive\":${report.summary.additive},\"documentationOnly\":${report.summary.documentationOnly},\"metadataOnly\":${report.summary.metadataOnly},\"unchanged\":${report.summary.unchanged}}")
    out.append(",\"entries\":[")
    var first = true
    for (entry in report.entries) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"oldId\":"); appendNullableString(out, entry.oldId)
        out.append(",\"newId\":"); appendNullableString(out, entry.newId)
        out.append(",\"kind\":"); appendSearchJsonString(out, entry.kind)
        out.append(",\"classification\":"); appendSearchJsonString(out, entry.classification)
        out.append(",\"matchState\":"); appendSearchJsonString(out, entry.matchState)
        out.append(",\"reasons\":"); appendStringArray(out, entry.reasons)
        out.append(",\"evidence\":[")
        var evidenceFirst = true
        for (evidence in entry.evidence) {
            if (!evidenceFirst) { out.append(",") }
            evidenceFirst = false
            out.append("{\"field\":"); appendSearchJsonString(out, evidence.field)
            out.append(",\"before\":"); appendNullableString(out, evidence.before)
            out.append(",\"after\":"); appendNullableString(out, evidence.after)
            out.append(",\"state\":"); appendSearchJsonString(out, evidence.state)
            out.append("}")
        }
        out.append("]}")
    }
    out.append("]}\n")
    out.toString()
}
