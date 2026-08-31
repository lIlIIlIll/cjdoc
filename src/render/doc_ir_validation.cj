package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.overflow.*

private let DOC_IR_SHA256_CONSTANTS: Array<UInt32> = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

private func docIrShaRotateRight(value: UInt32, bits: UInt32): UInt32 {
    (value >> bits) | (value << (32 - bits))
}

func docIrSha256Bytes(input: Array<Byte>): String {
    let data = ArrayList<Byte>()
    data.add(all: input)
    data.add(0x80)
    while (data.size % 64 != 56) { data.add(0) }
    let bitLength = UInt64(input.size).wrappingMul(8)
    var shift: Int64 = 56
    while (shift >= 0) {
        data.add(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        shift -= 8
    }
    let state = Array<UInt32>(8, repeat: 0)
    state[0] = 0x6a09e667
    state[1] = 0xbb67ae85
    state[2] = 0x3c6ef372
    state[3] = 0xa54ff53a
    state[4] = 0x510e527f
    state[5] = 0x9b05688c
    state[6] = 0x1f83d9ab
    state[7] = 0x5be0cd19
    var chunk: Int64 = 0
    while (chunk < data.size) {
        let words = Array<UInt32>(64, repeat: 0)
        for (index in 0..16) {
            let offset = chunk + index * 4
            words[index] = (UInt32(data[offset]) << 24) |
                (UInt32(data[offset + 1]) << 16) |
                (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
        for (index in 16..64) {
            let s0 = docIrShaRotateRight(words[index - 15], 7) ^
                docIrShaRotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let s1 = docIrShaRotateRight(words[index - 2], 17) ^
                docIrShaRotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16].wrappingAdd(s0)
                .wrappingAdd(words[index - 7]).wrappingAdd(s1)
        }
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for (index in 0..64) {
            let sum1 = docIrShaRotateRight(e, 6) ^ docIrShaRotateRight(e, 11) ^
                docIrShaRotateRight(e, 25)
            let choice = (e & f) ^ ((e ^ 0xFFFFFFFF) & g)
            let temp1 = h.wrappingAdd(sum1).wrappingAdd(choice)
                .wrappingAdd(DOC_IR_SHA256_CONSTANTS[index]).wrappingAdd(words[index])
            let sum0 = docIrShaRotateRight(a, 2) ^ docIrShaRotateRight(a, 13) ^
                docIrShaRotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0.wrappingAdd(majority)
            h = g; g = f; f = e; e = d.wrappingAdd(temp1)
            d = c; c = b; b = a; a = temp1.wrappingAdd(temp2)
        }
        for (index in 0..8) {
            state[index] = state[index].wrappingAdd([a, b, c, d, e, f, g, h][index])
        }
        chunk += 64
    }
    let digits = "0123456789abcdef"
    let out = StringBuilder()
    for (word in state) {
        shift = 28
        while (shift >= 0) {
            let nibble = Int64((word >> UInt32(shift)) & 0xF)
            out.append(digits[nibble..nibble + 1])
            shift -= 4
        }
    }
    out.toString()
}

private func domainFail(path: String, message: String): Nothing {
    throw IllegalArgumentException("invalid Doc IR domain at ${path}: ${message}")
}

private class DocIrEncodingBudget {
    private let limit: Int64
    private var encodedBytes: Int64 = 0
    private var typeOccurrences: Int64 = 0
    private var typeEdges: Int64 = 0
    private var markdownOccurrences: Int64 = 0
    private var markdownEdges: Int64 = 0
    private var schemaObjects: Int64 = 0
    private var schemaArrayItems: Int64 = 0

    init(limit: Int64) {
        if (limit <= 0 || limit > DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES) {
            domainFail("$", "invalid JSON encoding budget")
        }
        this.limit = limit
    }

    func consumeBytes(amount: Int64, path: String): Unit {
        if (amount < 0 || amount > limit - encodedBytes) {
            domainFail(path, "estimated JSON encoding exceeds ${limit} bytes")
        }
        encodedBytes += amount
    }

    private func consumePrettyContainer(depth: Int64, entries: Int64,
        object: Bool, path: String): Unit {
        if (depth < 0 || depth > 256 || entries < 0) {
            domainFail(path, "invalid JSON container shape")
        }
        let rows = if (entries == 0) { 1 } else { entries }
        let childIndent = 2 * (depth + 1)
        // prettyJson adds a newline/indent after the opener and every comma,
        // another newline/indent before the closer, and one space per object
        // colon. Charge those bytes in addition to the compact representation.
        consumeBytes(rows * (1 + childIndent), path)
        consumeBytes(1 + 2 * depth, path)
        if (object) { consumeBytes(entries, path) }
    }

    func consumeObject(path: String, depth!: Int64 = 0, fields!: Int64 = 32): Unit {
        if (schemaObjects >= DOC_IR_MAX_SCHEMA_OBJECTS) {
            domainFail(path, "JSON object occurrence budget exceeded")
        }
        schemaObjects++
        consumeBytes(512, path)
        consumePrettyContainer(depth, fields, true, path)
    }

    func consumeCollection(size: Int64, path: String, depth!: Int64 = 0): Unit {
        consumeBytes(16, path)
        if (size < 0 || size > limit / 8) {
            domainFail(path, "collection exceeds JSON encoding budget")
        }
        if (size > DOC_IR_MAX_SCHEMA_ARRAY_ITEMS - schemaArrayItems) {
            domainFail(path, "JSON array item occurrence budget exceeded")
        }
        schemaArrayItems += size
        consumeBytes(size * 8, path)
        consumePrettyContainer(depth, size, false, path)
    }

    func consumeString(value: String, path: String): Unit {
        if (value.size > DOC_IR_MAX_JSON_STRING_BYTES) {
            domainFail(path, "JSON string exceeds ${DOC_IR_MAX_JSON_STRING_BYTES} UTF-8 bytes")
        }
        // Start with the original UTF-8 bytes plus quotes, then charge the exact
        // additional bytes emitted by escapeJsonString for ASCII escapes.
        consumeBytes(value.size + 2, path)
        for (rune in value.runes()) {
            match (rune) {
                case '"' | '\\' | '\u{0008}' | '\u{000c}' | '\n' | '\r' | '\t' =>
                    consumeBytes(1, path)
                case _ => if (UInt32(rune) < 0x20u32) { consumeBytes(5, path) }
            }
        }
    }

    func consumeOptionalString(value: ?String, path: String): Unit {
        match (value) {
            case Some(text) => consumeString(text, path)
            case None => consumeBytes(4, path)
        }
    }

    func consumeTypeShape(edges: Int64, path: String): Unit {
        if (typeOccurrences >= DOC_IR_MAX_TYPE_OCCURRENCES || edges < 0 ||
            edges > DOC_IR_MAX_TYPE_EDGES - typeEdges) {
            domainFail(path, "TypeRef occurrence/edge budget exceeded")
        }
        typeOccurrences++
        typeEdges += edges
    }

    func consumeMarkdownShape(edges: Int64, path: String): Unit {
        if (markdownOccurrences >= DOC_IR_MAX_MARKDOWN_OCCURRENCES || edges < 0 ||
            edges > DOC_IR_MAX_MARKDOWN_EDGES - markdownEdges) {
            domainFail(path, "Markdown occurrence/edge budget exceeded")
        }
        markdownOccurrences++
        markdownEdges += edges
    }
}

private func consumePositionEncoding(value: SourcePosition, path: String,
    budget: DocIrEncodingBudget, jsonDepth!: Int64 = 0): Unit {
    let _ = value
    budget.consumeObject(path, depth: jsonDepth, fields: 3)
}

private func consumeRangeEncoding(value: SourceRange, path: String,
    budget: DocIrEncodingBudget, jsonDepth!: Int64 = 0): Unit {
    budget.consumeObject(path, depth: jsonDepth, fields: 3)
    budget.consumeString(value.path, "${path}.path")
    consumePositionEncoding(value.start, "${path}.start", budget, jsonDepth: jsonDepth + 1)
    consumePositionEncoding(value.end, "${path}.end", budget, jsonDepth: jsonDepth + 1)
}

private func consumeTypeEncoding(value: TypeRef, path: String, depth: Int64,
    jsonDepth: Int64, budget: DocIrEncodingBudget): Unit {
    if (depth > DOC_IR_MAX_TYPE_DEPTH) {
        domainFail(path, "type nesting exceeds ${DOC_IR_MAX_TYPE_DEPTH}")
    }
    budget.consumeTypeShape(value.arguments.size, path)
    budget.consumeObject(path, depth: jsonDepth, fields: 5)
    budget.consumeString(value.kind, "${path}.kind")
    budget.consumeString(value.spelling, "${path}.spelling")
    budget.consumeCollection(value.arguments.size, "${path}.arguments", depth: jsonDepth + 1)
    budget.consumeObject("${path}.semantic", depth: jsonDepth + 1, fields: 3)
    budget.consumeString(value.semantic.state, "${path}.semantic.state")
    budget.consumeOptionalString(value.semantic.canonical, "${path}.semantic.canonical")
    budget.consumeOptionalString(value.semantic.provider, "${path}.semantic.provider")
    var index: Int64 = 0
    for (argument in value.arguments) {
        consumeTypeEncoding(argument, "${path}.arguments[${index}]", depth + 1,
            jsonDepth + 2, budget)
        index++
    }
}

private func consumeMarkdownMetadataEncoding(value: MarkdownNodeMetadata, path: String,
    jsonDepth: Int64, budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path, depth: jsonDepth, fields: 8)
    budget.consumeOptionalString(value.listKind, "${path}.listKind")
    budget.consumeOptionalString(value.listDelimiter, "${path}.delimiter")
    budget.consumeOptionalString(value.taskState, "${path}.taskState")
    budget.consumeOptionalString(value.codeKind, "${path}.codeKind")
    budget.consumeOptionalString(value.fenceCharacter, "${path}.fenceCharacter")
    budget.consumeOptionalString(value.infoRaw, "${path}.infoRaw")
    budget.consumeOptionalString(value.language, "${path}.language")
    budget.consumeOptionalString(value.attributesRaw, "${path}.attributesRaw")
    budget.consumeOptionalString(value.tableAlignment, "${path}.alignment")
    budget.consumeCollection(value.tableAlignments.size, "${path}.alignments",
        depth: jsonDepth + 1)
    var index: Int64 = 0
    for (alignment in value.tableAlignments) {
        budget.consumeString(alignment, "${path}.alignments[${index}]")
        index++
    }
}

private func consumeMarkdownEncoding(value: MarkdownNode, path: String, depth: Int64,
    jsonDepth: Int64, budget: DocIrEncodingBudget): Unit {
    if (depth > DOC_IR_MAX_MARKDOWN_DEPTH) {
        domainFail(path, "Markdown nesting exceeds ${DOC_IR_MAX_MARKDOWN_DEPTH}")
    }
    budget.consumeMarkdownShape(value.children.size, path)
    budget.consumeObject(path, depth: jsonDepth, fields: 5)
    budget.consumeString(value.kind, "${path}.kind")
    budget.consumeString(value.literal, "${path}.literal")
    match (value.source) {
        case Some(source) => consumeRangeEncoding(source, "${path}.source", budget,
            jsonDepth: jsonDepth + 1)
        case None => budget.consumeBytes(4, "${path}.source")
    }
    match (value.metadata) {
        case Some(metadata) => consumeMarkdownMetadataEncoding(metadata, "${path}.metadata",
            jsonDepth + 1, budget)
        case None => budget.consumeBytes(4, "${path}.metadata")
    }
    budget.consumeCollection(value.children.size, "${path}.children", depth: jsonDepth + 1)
    var index: Int64 = 0
    for (child in value.children) {
        consumeMarkdownEncoding(child, "${path}.children[${index}]", depth + 1,
            jsonDepth + 2, budget)
        index++
    }
}

private func consumeTagEncoding(value: DocTag, path: String,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path)
    budget.consumeString(value.name, "${path}.name")
    budget.consumeString(value.subject, "${path}.subject")
    budget.consumeString(value.description, "${path}.description")
    budget.consumeString(value.referenceState, "${path}.referenceState")
    budget.consumeOptionalString(value.targetSymbolId, "${path}.targetSymbolId")
}

private func consumeCommentEncoding(value: DocComment, path: String, jsonDepth: Int64,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path, depth: jsonDepth, fields: 5)
    budget.consumeString(value.rawText, "${path}.rawText")
    budget.consumeString(value.summary, "${path}.summary")
    budget.consumeString(value.description, "${path}.description")
    consumeMarkdownEncoding(value.markdown, "${path}.markdown", 0, jsonDepth + 1, budget)
    budget.consumeCollection(value.tags.size, "${path}.tags", depth: jsonDepth + 1)
    var index: Int64 = 0
    for (tag in value.tags) {
        consumeTagEncoding(tag, "${path}.tags[${index}]", budget)
        index++
    }
}

private func consumeSymbolEncoding(value: SymbolDoc, path: String,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path)
    for ((name, text) in [("id", value.id), ("kind", value.kind), ("name", value.name),
        ("qualifiedName", value.qualifiedName), ("packageName", value.packageName),
        ("moduleId", value.moduleId), ("visibility", value.visibility),
        ("headerSpelling", value.headerSpelling)]) {
        budget.consumeString(text, "${path}.${name}")
    }
    budget.consumeOptionalString(value.ownerId, "${path}.ownerId")
    consumeRangeEncoding(value.source, "${path}.source", budget, jsonDepth: 3)
    budget.consumeObject("${path}.semantic")
    budget.consumeString(value.semantic.state, "${path}.semantic.state")
    budget.consumeString(value.semantic.provider, "${path}.semantic.provider")
    budget.consumeOptionalString(value.semantic.canonicalSignature,
        "${path}.semantic.canonicalSignature")
    budget.consumeObject("${path}.origin")
    budget.consumeString(value.origin.kind, "${path}.origin.kind")
    budget.consumeOptionalString(value.origin.macroSymbolId, "${path}.origin.macroSymbolId")
    budget.consumeCollection(value.genericParameters.size, "${path}.genericParameters")
    var index: Int64 = 0
    for (parameter in value.genericParameters) {
        budget.consumeString(parameter, "${path}.genericParameters[${index}]")
        index++
    }
    budget.consumeCollection(value.parameters.size, "${path}.parameters")
    index = 0
    for (parameter in value.parameters) {
        let parameterPath = "${path}.parameters[${index}]"
        budget.consumeObject(parameterPath)
        budget.consumeString(parameter.name, "${parameterPath}.name")
        consumeTypeEncoding(parameter.typeRef, "${parameterPath}.type", 0, 5, budget)
        budget.consumeOptionalString(parameter.documentation, "${parameterPath}.documentation")
        budget.consumeOptionalString(parameter.defaultExpression, "${parameterPath}.defaultExpression")
        index++
    }
    match (value.returnType) {
        case Some(typeRef) => consumeTypeEncoding(typeRef, "${path}.returnType", 0, 3, budget)
        case None => budget.consumeBytes(4, "${path}.returnType")
    }
    budget.consumeCollection(value.annotations.size, "${path}.annotations")
    index = 0
    for (annotation in value.annotations) {
        let annotationPath = "${path}.annotations[${index}]"
        budget.consumeObject(annotationPath)
        budget.consumeString(annotation.spelling, "${annotationPath}.spelling")
        budget.consumeString(annotation.provenance, "${annotationPath}.provenance")
        budget.consumeOptionalString(annotation.provider, "${annotationPath}.provider")
        index++
    }
    budget.consumeCollection(value.typeRelationships.size, "${path}.typeRelationships")
    index = 0
    for (relationship in value.typeRelationships) {
        let relationshipPath = "${path}.typeRelationships[${index}]"
        budget.consumeObject(relationshipPath)
        budget.consumeString(relationship.kind, "${relationshipPath}.kind")
        consumeTypeEncoding(relationship.target, "${relationshipPath}.target", 0, 5, budget)
        index++
    }
    budget.consumeCollection(value.symbolRelationships.size, "${path}.symbolRelationships")
    index = 0
    for (relationship in value.symbolRelationships) {
        let relationshipPath = "${path}.symbolRelationships[${index}]"
        budget.consumeObject(relationshipPath)
        budget.consumeString(relationship.kind, "${relationshipPath}.kind")
        budget.consumeString(relationship.targetDisplay, "${relationshipPath}.targetDisplay")
        budget.consumeString(relationship.state, "${relationshipPath}.state")
        budget.consumeOptionalString(relationship.targetSymbolId, "${relationshipPath}.targetSymbolId")
        index++
    }
    match (value.documentation) {
        case Some(comment) => consumeCommentEncoding(comment, "${path}.documentation", 3, budget)
        case None => budget.consumeBytes(4, "${path}.documentation")
    }
}

private func validateDocIrEncodingBudget(documentation: DocumentationSet, limit: Int64): Unit {
    let budget = DocIrEncodingBudget(limit)
    budget.consumeObject("$")
    budget.consumeString(documentation.schemaVersion, "$.schemaVersion")
    budget.consumeObject("$.generator")
    budget.consumeString(documentation.generator.name, "$.generator.name")
    budget.consumeString(documentation.generator.version, "$.generator.version")
    budget.consumeString(documentation.status, "$.status")
    budget.consumeObject("$.project")
    budget.consumeString(documentation.project.name, "$.project.name")
    budget.consumeString(documentation.project.kind, "$.project.kind")
    budget.consumeObject("$.configuration")
    budget.consumeString(documentation.configuration.audience, "$.configuration.audience")
    budget.consumeString(documentation.configuration.lintProfile, "$.configuration.lintProfile")
    budget.consumeString(documentation.configuration.cfgProfile, "$.configuration.cfgProfile")

    budget.consumeCollection(documentation.providers.size, "$.providers")
    var index: Int64 = 0
    for (provider in documentation.providers) {
        let path = "$.providers[${index}]"
        budget.consumeObject(path)
        budget.consumeString(provider.name, "${path}.name")
        budget.consumeString(provider.version, "${path}.version")
        budget.consumeString(provider.moduleId, "${path}.moduleId")
        budget.consumeString(provider.state, "${path}.state")
        budget.consumeObject("${path}.capabilities")
        index++
    }
    budget.consumeCollection(documentation.modules.size, "$.modules")
    index = 0
    for (module in documentation.modules) {
        let path = "$.modules[${index}]"
        budget.consumeObject(path)
        budget.consumeString(module.id, "${path}.id")
        budget.consumeString(module.name, "${path}.name")
        budget.consumeString(module.role, "${path}.role")
        budget.consumeString(module.sourcePrefix, "${path}.sourcePrefix")
        budget.consumeCollection(module.packageNames.size, "${path}.packageNames")
        var itemIndex: Int64 = 0
        for (name in module.packageNames) {
            budget.consumeString(name, "${path}.packageNames[${itemIndex}]"); itemIndex++
        }
        budget.consumeCollection(module.dependencyIds.size, "${path}.dependencyIds")
        itemIndex = 0
        for (id in module.dependencyIds) {
            budget.consumeString(id, "${path}.dependencyIds[${itemIndex}]"); itemIndex++
        }
        index++
    }
    budget.consumeCollection(documentation.packages.size, "$.packages")
    index = 0
    for (pkg in documentation.packages) {
        let path = "$.packages[${index}]"
        budget.consumeObject(path)
        budget.consumeString(pkg.name, "${path}.name")
        budget.consumeString(pkg.moduleId, "${path}.moduleId")
        budget.consumeCollection(pkg.sourceFiles.size, "${path}.sourceFiles")
        var itemIndex: Int64 = 0
        for (file in pkg.sourceFiles) {
            budget.consumeString(file, "${path}.sourceFiles[${itemIndex}]"); itemIndex++
        }
        budget.consumeCollection(pkg.symbolIds.size, "${path}.symbolIds")
        itemIndex = 0
        for (id in pkg.symbolIds) {
            budget.consumeString(id, "${path}.symbolIds[${itemIndex}]"); itemIndex++
        }
        index++
    }
    budget.consumeCollection(documentation.files.size, "$.files")
    index = 0
    for (file in documentation.files) {
        let path = "$.files[${index}]"
        budget.consumeObject(path)
        budget.consumeString(file.path, "${path}.path")
        budget.consumeString(file.moduleId, "${path}.moduleId")
        budget.consumeString(file.packageName, "${path}.packageName")
        index++
    }
    budget.consumeCollection(documentation.declarations.size, "$.declarations")
    index = 0
    for (declaration in documentation.declarations) {
        consumeSymbolEncoding(declaration, "$.declarations[${index}]", budget); index++
    }
    budget.consumeCollection(documentation.assets.size, "$.assets")
    index = 0
    for (asset in documentation.assets) {
        let path = "$.assets[${index}]"
        budget.consumeObject(path)
        budget.consumeString(asset.id, "${path}.id")
        budget.consumeString(asset.mediaType, "${path}.mediaType")
        budget.consumeString(asset.sourcePath, "${path}.sourcePath")
        budget.consumeString(asset.base64, "${path}.base64")
        index++
    }
    budget.consumeCollection(documentation.orphanDocComments.size, "$.orphanDocComments")
    index = 0
    for (comment in documentation.orphanDocComments) {
        let path = "$.orphanDocComments[${index}]"
        budget.consumeObject(path); budget.consumeString(comment.rawText, "${path}.rawText")
        consumeRangeEncoding(comment.source, "${path}.source", budget, jsonDepth: 3); index++
    }
    budget.consumeCollection(documentation.macroInvocations.size, "$.macroInvocations")
    index = 0
    for (invocation in documentation.macroInvocations) {
        let path = "$.macroInvocations[${index}]"
        budget.consumeObject(path); budget.consumeString(invocation.name, "${path}.name")
        consumeRangeEncoding(invocation.source, "${path}.source", budget, jsonDepth: 3); index++
    }
    budget.consumeCollection(documentation.unsupportedDeclarations.size, "$.unsupportedDeclarations")
    index = 0
    for (item in documentation.unsupportedDeclarations) {
        let path = "$.unsupportedDeclarations[${index}]"
        budget.consumeObject(path); budget.consumeString(item.kind, "${path}.kind")
        budget.consumeString(item.name, "${path}.name")
        budget.consumeString(item.reason, "${path}.reason")
        consumeRangeEncoding(item.source, "${path}.source", budget, jsonDepth: 3); index++
    }
    budget.consumeCollection(documentation.unboundSemanticDeclarations.size,
        "$.unboundSemanticDeclarations")
    index = 0
    for (item in documentation.unboundSemanticDeclarations) {
        let path = "$.unboundSemanticDeclarations[${index}]"
        budget.consumeObject(path); budget.consumeString(item.provider, "${path}.provider")
        budget.consumeString(item.display, "${path}.display")
        budget.consumeString(item.reason, "${path}.reason"); index++
    }
    budget.consumeCollection(documentation.diagnostics.size, "$.diagnostics")
    index = 0
    for (diagnostic in documentation.diagnostics) {
        let path = "$.diagnostics[${index}]"
        budget.consumeObject(path); budget.consumeString(diagnostic.severity, "${path}.severity")
        budget.consumeString(diagnostic.code, "${path}.code")
        budget.consumeString(diagnostic.message, "${path}.message")
        match (diagnostic.source) {
            case Some(source) => consumeRangeEncoding(source, "${path}.source", budget,
                jsonDepth: 3)
            case None => budget.consumeBytes(4, "${path}.source")
        }
        budget.consumeOptionalString(diagnostic.symbolId, "${path}.symbolId"); index++
    }
}

protected func docIrFitsEncodedBudget(documentation: DocumentationSet, limit: Int64): Bool {
    try {
        validateDocIrEncodingBudget(documentation, limit)
        true
    } catch (_: IllegalArgumentException) {
        false
    }
}

private func compositeKey(left: String, right: String): String {
    "${left.size}:${left}${right}"
}

func symbolIdModulePrefix(moduleId: String): String {
    let out = StringBuilder()
    out.append("cjdoc:v2:")
    for (rune in moduleId.runes()) {
        match (rune) {
            case ':' => out.append("%3A")
            case '#' => out.append("%23")
            case '(' => out.append("%28")
            case ')' => out.append("%29")
            case ',' => out.append("%2C")
            case '%' => out.append("%25")
            case _ => out.append(rune)
        }
    }
    out.append("::")
    out.toString()
}

func safeRelativePath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.endsWith("/") ||
        value.contains("//") || value.contains("\\")) { return false }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    let first = segments[0].toArray()
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'A' && first[0] <= b'Z') ||
        (first[0] >= b'a' && first[0] <= b'z'))) {
        return false
    }
    true
}

private func validateRange(value: SourceRange, path: String): Unit {
    if (!safeRelativePath(value.path)) { domainFail("${path}.path", "unsafe portable path") }
    if (value.end.byteOffset < value.start.byteOffset || value.end.line < value.start.line ||
        (value.end.line == value.start.line && value.end.column < value.start.column)) {
        domainFail(path, "source range ends before it starts")
    }
}

private func validateType(value: TypeRef, path: String, depth: Int64,
    providers: HashMap<String, ProviderInfo>, moduleId: String): Unit {
    if (depth > DOC_IR_MAX_TYPE_DEPTH) {
        domainFail(path, "type nesting exceeds ${DOC_IR_MAX_TYPE_DEPTH}")
    }
    if (value.kind.isEmpty()) { domainFail("${path}.kind", "must not be empty") }
    match (value.semantic.canonical) {
        case Some(canonical) => if (canonical.trimAscii().isEmpty()) {
            domainFail("${path}.semantic.canonical", "canonical type spelling must not be empty")
        }
        case None => ()
    }
    if (value.semantic.state == "unavailable") {
        if (value.semantic.canonical.isSome() || value.semantic.provider.isSome()) {
            domainFail("${path}.semantic",
                "unavailable type semantics cannot carry canonical or provider data")
        }
    } else {
        if (value.semantic.provider.isNone()) {
            domainFail("${path}.semantic.provider",
                "non-unavailable type semantics require a provider")
        }
        if (value.semantic.state == "resolved" && value.semantic.canonical.isNone()) {
            domainFail("${path}.semantic.canonical",
                "resolved type semantics require a canonical spelling")
        }
    }
    match (value.semantic.provider) {
        case Some(provider) =>
            match (providerFor(providers, moduleId, provider)) {
                case Some(info) =>
                    if (info.state == "unavailable") {
                        domainFail("${path}.semantic.provider",
                            "unavailable provider cannot supply type semantics")
                    }
                    if (value.semantic.canonical.isSome() && !info.capabilities.canonicalTypes) {
                        domainFail("${path}.semantic", "canonical type data lacks provider capability")
                    }
                case None =>
                    domainFail("${path}.semantic.provider", "provider is not declared for the module")
            }
        case None => ()
    }
    var index: Int64 = 0
    for (argument in value.arguments) {
        validateType(argument, "${path}.arguments[${index}]", depth + 1, providers, moduleId)
        index++
    }
}

private func validMarkdownAlignment(value: String): Bool {
    value == "none" || value == "left" || value == "center" || value == "right"
}

private func markdownBlockKind(kind: String): Bool {
    match (kind) {
        case "block_quote" | "list" | "paragraph" | "heading" | "thematic_break" |
            "code_block" | "html_block" | "table" | "custom_block" => true
        case _ => false
    }
}

private func markdownInlineKind(kind: String): Bool {
    match (kind) {
        case "text" | "soft_break" | "hard_break" | "code_span" | "emphasis" |
            "strong" | "strikethrough" | "link" | "image" | "html_inline" |
            "custom_inline" => true
        case _ => false
    }
}

private func validMarkdownChild(parent: String, child: String): Bool {
    match (parent) {
        case "document" | "block_quote" | "list_item" | "custom_block" =>
            markdownBlockKind(child)
        case "list" => child == "list_item"
        case "table" => child == "table_row"
        case "table_row" => child == "table_cell"
        case "paragraph" | "heading" | "table_cell" | "emphasis" | "strong" |
            "strikethrough" | "link" | "image" | "custom_inline" =>
            markdownInlineKind(child)
        case _ => false
    }
}

private func validateMarkdownMetadata(node: MarkdownNode, path: String): Unit {
    match (node.metadata) {
        case None => ()
        case Some(value) =>
            if (value.kind != node.kind) {
                domainFail("${path}.metadata", "metadata kind does not match Markdown node kind")
            }
            match (node.kind) {
                case "heading" =>
                    let level = value.headingLevel.getOrThrow()
                    if (level < 1 || level > 6) {
                        domainFail("${path}.metadata.level", "heading level must be in 1..6")
                    }
                case "list" =>
                    let listKind = value.listKind.getOrThrow()
                    let delimiter = value.listDelimiter.getOrThrow()
                    let start = value.listStart.getOrThrow()
                    if ((listKind != "bullet" && listKind != "ordered") ||
                        start < 0 ||
                        (listKind == "bullet" && (start != 0 || delimiter != "none")) ||
                        (listKind == "ordered" && start < 1) ||
                        (listKind == "ordered" && delimiter != "period" && delimiter != "parenthesis")) {
                        domainFail("${path}.metadata", "invalid list metadata")
                    }
                    if (listKind == "ordered" && !node.children.isEmpty() &&
                        start > DOC_IR_MAX_ORDERED_LIST_NUMBER - (node.children.size - 1)) {
                        domainFail("${path}.metadata.start",
                            "ordered list numbering must remain within 1..${DOC_IR_MAX_ORDERED_LIST_NUMBER}")
                    }
                    let _ = value.listTight.getOrThrow()
                case "list_item" =>
                    let state = value.taskState.getOrThrow()
                    if (state != "notTask" && state != "checked" && state != "unchecked") {
                        domainFail("${path}.metadata.taskState", "invalid task state")
                    }
                case "code_block" =>
                    let codeKind = value.codeKind.getOrThrow()
                    let fenceLength = value.fenceLength.getOrThrow()
                    let infoRaw = value.infoRaw.getOrThrow()
                    if (infoRaw.contains("\n") || infoRaw.contains("\r")) {
                        domainFail("${path}.metadata.infoRaw", "code fence info must be a single line")
                    }
                    if (codeKind == "indented") {
                        if (value.fenceCharacter.isSome() || fenceLength != 0) {
                            domainFail("${path}.metadata", "indented code must not carry a fence")
                        }
                    } else if (codeKind == "fenced") {
                        let marker = match (value.fenceCharacter) {
                            case Some(item) => item
                            case None => domainFail("${path}.metadata.fenceCharacter",
                                "fenced code requires a marker")
                        }
                        if ((marker != "`" && marker != "~") || fenceLength < 3 ||
                            fenceLength > DOC_IR_MAX_FENCE_LENGTH) {
                            domainFail("${path}.metadata", "invalid fenced-code metadata")
                        }
                        if (marker == "`" && infoRaw.contains("`")) {
                            domainFail("${path}.metadata.infoRaw",
                                "backtick-fenced code info must not contain a backtick")
                        }
                    } else {
                        domainFail("${path}.metadata.codeKind", "invalid code block kind")
                    }
                    let _ = value.language.getOrThrow()
                    let _ = value.attributesRaw.getOrThrow()
                case "table" => for (alignment in value.tableAlignments) {
                    if (!validMarkdownAlignment(alignment)) {
                        domainFail("${path}.metadata.alignments", "invalid table alignment")
                    }
                }
                case "table_row" => let _ = value.tableHeader.getOrThrow()
                case "table_cell" => if (!validMarkdownAlignment(value.tableAlignment.getOrThrow())) {
                    domainFail("${path}.metadata.alignment", "invalid table-cell alignment")
                }
                case _ => domainFail("${path}.metadata", "metadata is not allowed for this Markdown kind")
            }
    }
}

private func validateMarkdownTable(value: MarkdownNode, path: String): Unit {
    if (value.kind != "table") { return }
    if (value.children.isEmpty()) {
        domainFail("${path}.children", "table must contain a header row")
    }
    let columnCount = value.children[0].children.size
    if (columnCount == 0) {
        domainFail("${path}.children[0].children", "table rows must contain at least one cell")
    }
    let hasMetadata = value.metadata.isSome()
    if (hasMetadata && value.metadata.getOrThrow().tableAlignments.size != columnCount) {
        domainFail("${path}.metadata.alignments", "table alignment count does not match its columns")
    }
    var rowIndex: Int64 = 0
    for (row in value.children) {
        if (row.children.size != columnCount) {
            domainFail("${path}.children[${rowIndex}].children", "table rows must have equal column counts")
        }
        match (row.metadata) {
            case Some(metadata) =>
                if (!hasMetadata || metadata.tableHeader.getOrThrow() != (rowIndex == 0)) {
                    domainFail("${path}.children[${rowIndex}].metadata.header",
                        "only the first table row may be a header")
                }
            case None => if (hasMetadata) {
                domainFail("${path}.children[${rowIndex}].metadata",
                    "closed table metadata requires row metadata")
            }
        }
        var columnIndex: Int64 = 0
        for (cell in row.children) {
            match (cell.metadata) {
                case Some(metadata) =>
                    if (!hasMetadata || metadata.tableAlignment.getOrThrow() !=
                        value.metadata.getOrThrow().tableAlignments[columnIndex]) {
                        domainFail("${path}.children[${rowIndex}].children[${columnIndex}].metadata.alignment",
                            "table-cell alignment does not match table metadata")
                    }
                case None => if (hasMetadata) {
                    domainFail("${path}.children[${rowIndex}].children[${columnIndex}].metadata",
                        "closed table metadata requires cell metadata")
                }
            }
            columnIndex++
        }
        rowIndex++
    }
}

private func validateMarkdown(value: MarkdownNode, path: String, depth: Int64): Unit {
    if (depth > DOC_IR_MAX_MARKDOWN_DEPTH) {
        domainFail(path, "Markdown nesting exceeds ${DOC_IR_MAX_MARKDOWN_DEPTH}")
    }
    match (value.kind) {
        case "document" | "block_quote" | "list" | "list_item" | "paragraph" | "heading" |
            "thematic_break" | "code_block" | "html_block" | "table" | "table_row" |
            "table_cell" | "custom_block" | "text" | "soft_break" | "hard_break" |
            "code_span" | "emphasis" | "strong" | "strikethrough" | "link" | "image" |
            "html_inline" | "custom_inline" => ()
        case _ => domainFail("${path}.kind", "unknown Markdown node kind")
    }
    validateMarkdownMetadata(value, path)
    if ((value.kind == "document" || value.kind == "block_quote" || value.kind == "list" ||
        value.kind == "list_item" || value.kind == "paragraph" || value.kind == "heading" ||
        value.kind == "thematic_break" || value.kind == "table" || value.kind == "table_row" ||
        value.kind == "table_cell" || value.kind == "emphasis" || value.kind == "strong" ||
        value.kind == "strikethrough") && !value.literal.isEmpty()) {
        domainFail("${path}.literal", "container Markdown node must not carry fallback text")
    }
    if ((value.kind == "text" || value.kind == "soft_break" || value.kind == "hard_break" ||
        value.kind == "thematic_break" || value.kind == "code_block" || value.kind == "code_span" ||
        value.kind == "html_block" || value.kind == "html_inline") && !value.children.isEmpty()) {
        domainFail("${path}.children", "leaf Markdown node must not contain children")
    }
    match (value.source) { case Some(range) => validateRange(range, "${path}.source") case None => () }
    var index: Int64 = 0
    for (child in value.children) {
        if (!validMarkdownChild(value.kind, child.kind)) {
            domainFail("${path}.children[${index}]",
                "Markdown kind '${child.kind}' is not allowed under '${value.kind}'")
        }
        validateMarkdown(child, "${path}.children[${index}]", depth + 1)
        index++
    }
    validateMarkdownTable(value, path)
}

private func validateMarkdownAssetReferences(value: MarkdownNode, path: String,
    assetIds: HashSet<String>): Unit {
    if (value.kind == "image" && value.literal.startsWith("sha256-") &&
        !assetIds.contains(value.literal)) {
        domainFail("${path}.literal", "content-addressed image does not reference a document asset")
    }
    var index: Int64 = 0
    for (child in value.children) {
        validateMarkdownAssetReferences(child, "${path}.children[${index}]", assetIds)
        index++
    }
}

private func providerFor(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): ?ProviderInfo {
    providers.get(compositeKey(moduleId, name))
}

private func providerSupportsAnnotations(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): Bool {
    match (providerFor(providers, moduleId, name)) {
        case Some(provider) => provider.capabilities.annotations
        case None => false
    }
}

private func providerSupportsRelationships(providers: HashMap<String, ProviderInfo>, moduleId: String,
    name: String): Bool {
    match (providerFor(providers, moduleId, name)) {
        case Some(provider) => provider.capabilities.relationships
        case None => false
    }
}

private func moduleColor(colors: HashMap<String, Int64>, id: String): Int64 {
    match (colors.get(id)) { case Some(value) => value case None => 0 }
}

private func validateModuleDependencyDag(modules: ReadOnlyList<ModuleDoc>,
    byId: HashMap<String, ModuleDoc>): Unit {
    // 0/absent = white, 1 = gray, 2 = black. Each node and edge is completed once.
    let colors = HashMap<String, Int64>()
    for (root in modules) {
        if (moduleColor(colors, root.id) == 2) { continue }
        let stack = ArrayList<(ModuleDoc, Int64)>()
        colors[root.id] = 1
        stack.add((root, 0))
        while (!stack.isEmpty()) {
            let (current, edge) = stack[stack.size - 1]
            if (edge >= current.dependencyIds.size) {
                colors[current.id] = 2
                stack.remove(at: stack.size - 1)
                continue
            }
            stack[stack.size - 1] = (current, edge + 1)
            let dependency = byId[current.dependencyIds[edge]]
            let color = moduleColor(colors, dependency.id)
            if (color == 1) {
                domainFail("$.modules", "dependency cycle contains '${dependency.id}'")
            }
            if (color == 0) {
                colors[dependency.id] = 1
                stack.add((dependency, 0))
            }
        }
    }
}

private func validateOwnerDag(declarations: ReadOnlyList<SymbolDoc>, byId: HashMap<String, SymbolDoc>): Unit {
    let complete = HashSet<String>()
    for (declaration in declarations) {
        if (complete.contains(declaration.id)) { continue }
        let local = HashSet<String>()
        let path = ArrayList<String>()
        var current: ?SymbolDoc = Some(declaration)
        while (current.isSome()) {
            let symbol = current.getOrThrow()
            if (complete.contains(symbol.id)) { break }
            if (!local.add(symbol.id)) {
                domainFail("$.declarations", "owner cycle contains '${symbol.id}'")
            }
            path.add(symbol.id)
            current = match (symbol.ownerId) {
                case Some(ownerId) => byId.get(ownerId)
                case None => None
            }
        }
        for (id in path) { let _ = complete.add(id) }
    }
}

protected func isDocIrContainerKind(kind: String): Bool {
    kind == "class" || kind == "struct" || kind == "interface" || kind == "enum" ||
        kind == "extend"
}

private func validSha256AssetId(value: String): Bool {
    if (!value.startsWith("sha256-") || value.size != 71) { return false }
    let bytes = value.toArray()
    var index: Int64 = 7
    while (index < bytes.size) {
        let byte = bytes[index]
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            return false
        }
        index++
    }
    true
}

public func validateDocumentationSet(documentation: DocumentationSet): Unit {
    if (documentation.schemaVersion != DOC_IR_SCHEMA_VERSION) {
        domainFail("$.schemaVersion", "typed documentation must be v8")
    }
    // This occurrence-based preflight deliberately walks shared references once
    // per encoded occurrence. It bounds all recursive validation and the later
    // JSON encoder by the work and bytes they will actually emit.
    validateDocIrEncodingBudget(documentation, DOC_IR_MAX_JSON_DOCUMENT_BYTES)
    if (documentation.status != "complete" && documentation.status != "partial") {
        domainFail("$.status", "invalid structural status")
    }
    let moduleIds = HashSet<String>()
    let modulesById = HashMap<String, ModuleDoc>()
    let modulePackageKeys = HashSet<String>()
    var index: Int64 = 0
    for (module in documentation.modules) {
        if (!module.id.startsWith("cjdoc:module:v1:") || !moduleIds.add(module.id)) {
            domainFail("$.modules[${index}].id", "empty or duplicate module id")
        }
        if (!module.sourcePrefix.isEmpty() && !safeRelativePath(module.sourcePrefix)) {
            domainFail("$.modules[${index}].sourcePrefix",
                "must be empty or a portable relative logical path")
        }
        modulesById[module.id] = module
        let packageNames = HashSet<String>()
        for (name in module.packageNames) {
            if (name.isEmpty() || !packageNames.add(name)) {
                domainFail("$.modules[${index}].packageNames", "empty or duplicate package name")
            }
            let _ = modulePackageKeys.add(compositeKey(module.id, name))
        }
        index++
    }
    index = 0
    for (module in documentation.modules) {
        let dependencies = HashSet<String>()
        for (dependencyId in module.dependencyIds) {
            if (dependencyId == module.id || !moduleIds.contains(dependencyId) ||
                !dependencies.add(dependencyId)) {
                domainFail("$.modules[${index}].dependencyIds", "invalid module dependency")
            }
        }
        index++
    }
    validateModuleDependencyDag(documentation.modules, modulesById)

    let providerKeys = HashSet<String>()
    let providersByKey = HashMap<String, ProviderInfo>()
    let providerModules = HashSet<String>()
    index = 0
    for (provider in documentation.providers) {
        let key = compositeKey(provider.moduleId, provider.name)
        if (provider.name.trimAscii().isEmpty() || provider.version.trimAscii().isEmpty() ||
            provider.name.size > DOC_IR_MAX_PROVIDER_IDENTITY_BYTES ||
            provider.version.size > DOC_IR_MAX_PROVIDER_IDENTITY_BYTES ||
            !moduleIds.contains(provider.moduleId) || !providerKeys.add(key)) {
            domainFail("$.providers[${index}]",
                "blank/oversized provider identity, unknown module, or duplicate provider/module pair")
        }
        providersByKey[key] = provider
        let _ = providerModules.add(provider.moduleId)
        index++
    }
    for (module in documentation.modules) {
        if (!providerModules.contains(module.id)) {
            domainFail("$.providers", "module '${module.id}' has no provider result")
        }
    }

    let packageKeys = HashSet<String>()
    index = 0
    for (pkg in documentation.packages) {
        let key = compositeKey(pkg.moduleId, pkg.name)
        if (!moduleIds.contains(pkg.moduleId) || !packageKeys.add(key)) {
            domainFail("$.packages[${index}]", "unknown module or duplicate module/package pair")
        }
        if (!modulePackageKeys.contains(key)) {
            domainFail("$.packages[${index}]", "package is not listed by its module")
        }
        index++
    }
    for (module in documentation.modules) {
        for (name in module.packageNames) {
            if (!packageKeys.contains(compositeKey(module.id, name))) {
                domainFail("$.modules", "module '${module.id}' lists unknown package '${name}'")
            }
        }
    }

    let filePaths = HashSet<String>()
    let fileKeys = HashSet<String>()
    index = 0
    for (file in documentation.files) {
        if (!safeRelativePath(file.path) || !filePaths.add(file.path) ||
            !packageKeys.contains(compositeKey(file.moduleId, file.packageName))) {
            domainFail("$.files[${index}]", "unsafe/duplicate path or unknown module/package")
        }
        let _ = fileKeys.add(compositeKey(compositeKey(file.moduleId, file.packageName), file.path))
        index++
    }

    let byId = HashMap<String, SymbolDoc>()
    index = 0
    for (declaration in documentation.declarations) {
        if (!declaration.id.startsWith(symbolIdModulePrefix(declaration.moduleId))) {
            domainFail("$.declarations[${index}].id", "SymbolId '${declaration.id}' does not " +
                "encode owning module '${declaration.moduleId}'")
        }
        if (byId.contains(declaration.id)) {
            domainFail("$.declarations[${index}].id", "duplicate SymbolId '${declaration.id}'")
        }
        byId[declaration.id] = declaration
        if (declaration.kind != "enum" && declaration.enumNonExhaustive.isSome()) {
            domainFail("$.declarations[${index}].enumNonExhaustive",
                "only enum declarations may carry non-exhaustive state")
        }
        if (!packageKeys.contains(compositeKey(declaration.moduleId, declaration.packageName))) {
            domainFail("$.declarations[${index}]", "unknown module/package")
        }
        if (!fileKeys.contains(compositeKey(compositeKey(declaration.moduleId,
            declaration.packageName), declaration.source.path))) {
            domainFail("$.declarations[${index}].source", "source file is not owned by declaration module/package")
        }
        validateRange(declaration.source, "$.declarations[${index}].source")
        for (parameter in declaration.parameters) {
            validateType(parameter.typeRef, "$.declarations[${index}].parameters", 0,
                providersByKey, declaration.moduleId)
        }
        match (declaration.returnType) {
            case Some(typeRef) => validateType(typeRef, "$.declarations[${index}].returnType", 0,
                providersByKey, declaration.moduleId)
            case None => ()
        }
        for (relationship in declaration.typeRelationships) {
            validateType(relationship.target, "$.declarations[${index}].typeRelationships", 0,
                providersByKey, declaration.moduleId)
        }
        var annotationIndex: Int64 = 0
        for (annotation in declaration.annotations) {
            if (annotation.provenance == "provider") {
                let provider = annotation.provider.getOrThrow()
                if (!providerSupportsAnnotations(providersByKey, declaration.moduleId, provider)) {
                    domainFail("$.declarations[${index}].annotations[${annotationIndex}]",
                        "provider annotation lacks a matching module capability")
                }
            }
            annotationIndex++
        }
        match (providerFor(providersByKey, declaration.moduleId,
            declaration.semantic.provider)) {
            case Some(provider) =>
                if (provider.state == "unavailable" &&
                    (declaration.semantic.state != "unavailable" ||
                    declaration.semantic.canonicalSignature.isSome())) {
                    domainFail("$.declarations[${index}].semantic",
                        "unavailable provider cannot supply declaration semantics or canonical data")
                }
                match (declaration.semantic.canonicalSignature) {
                case Some(canonicalSignature) =>
                    if (canonicalSignature.trimAscii().isEmpty()) {
                        domainFail("$.declarations[${index}].semantic.canonicalSignature",
                            "canonical signature must not be blank")
                    }
                    if (!provider.capabilities.canonicalSignatures) {
                        domainFail("$.declarations[${index}].semantic.canonicalSignature",
                            "canonical signature lacks provider capability")
                    }
                case None => ()
                }
            case None =>
                domainFail("$.declarations[${index}].semantic.provider",
                    "provider is not declared for the module")
        }
        match (declaration.documentation) {
            case Some(comment) =>
                if (comment.markdown.kind != "document") {
                    domainFail("$.declarations[${index}].documentation.markdown",
                        "documentation Markdown root must be a document")
                }
                validateMarkdown(comment.markdown, "$.declarations[${index}].documentation.markdown", 0)
            case None => ()
        }
        index++
    }

    index = 0
    for (declaration in documentation.declarations) {
        match (declaration.ownerId) {
            case Some(ownerId) => match (byId.get(ownerId)) {
                case Some(owner) =>
                    if (!isDocIrContainerKind(owner.kind)) {
                        domainFail("$.declarations[${index}].ownerId",
                            "owner must reference a container declaration")
                    }
                    if (owner.moduleId != declaration.moduleId ||
                        owner.packageName != declaration.packageName) {
                        domainFail("$.declarations[${index}].ownerId",
                            "owner crosses module/package boundary")
                    }
                case None => domainFail("$.declarations[${index}].ownerId", "unknown owner")
            }
            case None => ()
        }
        match (declaration.origin.macroSymbolId) {
            case Some(targetId) => if (!byId.contains(targetId)) {
                domainFail("$.declarations[${index}].origin.macroSymbolId", "unknown macro SymbolId")
            }
            case None => ()
        }
        var relationshipIndex: Int64 = 0
        for (relationship in declaration.symbolRelationships) {
            let relationshipPath =
                "$.declarations[${index}].symbolRelationships[${relationshipIndex}]"
            if ((relationship.state != "unavailable" || relationship.targetSymbolId.isSome()) &&
                !providerSupportsRelationships(providersByKey, declaration.moduleId,
                    declaration.semantic.provider)) {
                domainFail(relationshipPath,
                    "symbol relationship lacks provider relationships capability")
            }
            match (relationship.targetSymbolId) {
                case Some(targetId) => if (!byId.contains(targetId)) {
                    domainFail(relationshipPath, "unknown target SymbolId")
                }
                case None => if (relationship.state == "resolved") {
                    domainFail(relationshipPath, "resolved target is missing")
                }
            }
            relationshipIndex++
        }
        if (let Some(comment) <- declaration.documentation) {
            for (tag in comment.tags) {
                match (tag.targetSymbolId) {
                    case Some(targetId) => if (!byId.contains(targetId)) {
                        domainFail("$.declarations[${index}].documentation.tags", "unknown target SymbolId")
                    }
                    case None => if (tag.referenceState == "resolved") {
                        domainFail("$.declarations[${index}].documentation.tags", "resolved target is missing")
                    }
                }
            }
        }
        index++
    }
    validateOwnerDag(documentation.declarations, byId)

    let listedFileKeys = HashSet<String>()
    let listedSymbolIds = HashSet<String>()
    index = 0
    for (pkg in documentation.packages) {
        let sourceFiles = HashSet<String>()
        for (path in pkg.sourceFiles) {
            if (!sourceFiles.add(path) || !fileKeys.contains(compositeKey(compositeKey(pkg.moduleId,
                pkg.name), path))) {
                domainFail("$.packages[${index}].sourceFiles", "duplicate or unknown source file")
            }
            let _ = listedFileKeys.add(compositeKey(compositeKey(pkg.moduleId, pkg.name), path))
        }
        let symbolIds = HashSet<String>()
        for (id in pkg.symbolIds) {
            match (byId.get(id)) {
                case Some(symbol) => if (!symbolIds.add(id) || symbol.moduleId != pkg.moduleId ||
                    symbol.packageName != pkg.name) {
                    domainFail("$.packages[${index}].symbolIds", "duplicate or foreign symbol")
                }
                case None => domainFail("$.packages[${index}].symbolIds", "unknown symbol")
            }
            if (!listedSymbolIds.add(id)) {
                domainFail("$.packages[${index}].symbolIds", "symbol is listed more than once")
            }
        }
        index++
    }
    for (declaration in documentation.declarations) {
        if (!listedSymbolIds.contains(declaration.id)) {
            domainFail("$.packages", "declaration '${declaration.id}' is not listed")
        }
    }
    for (file in documentation.files) {
        if (!listedFileKeys.contains(compositeKey(compositeKey(file.moduleId,
            file.packageName), file.path))) {
            domainFail("$.packages", "file '${file.path}' is not listed")
        }
    }

    let assetIds = HashSet<String>()
    let assetPaths = HashSet<String>()
    let assetReferences = HashMap<String, String>()
    var totalAssetBytes: Int64 = 0
    var totalAssetPixels: Int64 = 0
    index = 0
    for (asset in documentation.assets) {
        if (!validSha256AssetId(asset.id) || !assetIds.add(asset.id) || !safeRelativePath(asset.sourcePath) ||
            !assetPaths.add(asset.sourcePath)) {
            domainFail("$.assets[${index}]", "duplicate asset id/path or unsafe source path")
        }
        for (reference in [asset.id, asset.sourcePath]) {
            match (assetReferences.get(reference)) {
                case Some(owner) => if (owner != asset.id) {
                    domainFail("$.assets[${index}]", "ambiguous asset id/sourcePath reference")
                }
                case None => assetReferences[reference] = asset.id
            }
        }
        let decoded = try {
            let _ = assetMediaExtension(asset.mediaType)
            decodeAssetBase64(asset.base64)
        } catch (_: Exception) {
            domainFail("$.assets[${index}]", "unsupported media type or invalid base64")
        }
        let pixels = try {
            validateRasterAsset(asset.mediaType, decoded)
        } catch (_: IllegalArgumentException) {
            domainFail("$.assets[${index}]", "invalid or oversized local image asset")
        }
        if (asset.id != "sha256-${docIrSha256Bytes(decoded)}") {
            domainFail("$.assets[${index}].id", "asset id does not match SHA-256 content digest")
        }
        if (decoded.size > DOC_IR_MAX_TOTAL_ASSET_BYTES - totalAssetBytes) {
            domainFail("$.assets", "decoded local assets exceed 64 MiB")
        }
        totalAssetBytes += decoded.size
        if (pixels > DOC_IR_MAX_TOTAL_ASSET_PIXELS - totalAssetPixels) {
            domainFail("$.assets", "decoded local assets exceed the total pixel budget")
        }
        totalAssetPixels += pixels
        index++
    }
    index = 0
    for (declaration in documentation.declarations) {
        if (let Some(comment) <- declaration.documentation) {
            validateMarkdownAssetReferences(comment.markdown,
                "$.declarations[${index}].documentation.markdown", assetIds)
        }
        index++
    }
    for (orphan in documentation.orphanDocComments) { validateRange(orphan.source, "$.orphanDocComments") }
    for (invocation in documentation.macroInvocations) { validateRange(invocation.source, "$.macroInvocations") }
    for (item in documentation.unsupportedDeclarations) { validateRange(item.source, "$.unsupportedDeclarations") }
    for (diagnostic in documentation.diagnostics) {
        match (diagnostic.source) { case Some(range) => validateRange(range, "$.diagnostics.source") case None => () }
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!byId.contains(symbolId)) { domainFail("$.diagnostics.symbolId", "unknown SymbolId") }
        }
    }
    var hasError = false
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error") { hasError = true; break }
    }
    var hasUnavailableSemantic = false
    for (provider in documentation.providers) {
        if (provider.state == "unavailable" || provider.state == "ambiguous") {
            hasUnavailableSemantic = true
            break
        }
    }
    if (!hasUnavailableSemantic) {
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable" ||
                declaration.semantic.state == "ambiguous") {
                hasUnavailableSemantic = true
                break
            }
        }
    }
    if (documentation.status == "complete" && (hasError || hasUnavailableSemantic ||
        !documentation.orphanDocComments.isEmpty() || !documentation.macroInvocations.isEmpty() ||
        !documentation.unsupportedDeclarations.isEmpty() ||
        !documentation.unboundSemanticDeclarations.isEmpty())) {
        domainFail("$.status", "complete status conflicts with incomplete source or semantic structure")
    }
}
