package cjdoc.render

import cjdoc.model.*

internal class DocIrEncodingBudget {
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

internal func consumePositionEncoding(value: SourcePosition, path: String,
    budget: DocIrEncodingBudget, jsonDepth!: Int64 = 0): Unit {
    let _ = value
    budget.consumeObject(path, depth: jsonDepth, fields: 3)
}

internal func consumeRangeEncoding(value: SourceRange, path: String,
    budget: DocIrEncodingBudget, jsonDepth!: Int64 = 0): Unit {
    budget.consumeObject(path, depth: jsonDepth, fields: 3)
    budget.consumeString(value.path, "${path}.path")
    consumePositionEncoding(value.start, "${path}.start", budget, jsonDepth: jsonDepth + 1)
    consumePositionEncoding(value.end, "${path}.end", budget, jsonDepth: jsonDepth + 1)
}

internal func consumeTypeEncoding(value: TypeRef, path: String, depth: Int64,
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

internal func consumeMarkdownMetadataEncoding(value: MarkdownNodeMetadata, path: String,
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

internal func consumeMarkdownEncoding(value: MarkdownNode, path: String, depth: Int64,
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

internal func consumeTagEncoding(value: DocTag, path: String,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path)
    budget.consumeString(value.name, "${path}.name")
    budget.consumeString(value.subject, "${path}.subject")
    budget.consumeString(value.description, "${path}.description")
    budget.consumeString(value.referenceState, "${path}.referenceState")
    budget.consumeOptionalString(value.targetSymbolId, "${path}.targetSymbolId")
}

internal func consumeCommentEncoding(value: DocComment, path: String, jsonDepth: Int64,
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

internal func consumeSymbolEncoding(value: SymbolDoc, path: String,
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
    budget.consumeObject("${path}.sourceApiSignature")
    budget.consumeString(value.sourceApiSignature.state, "${path}.sourceApiSignature.state")
    budget.consumeCollection(value.sourceApiSignature.tokens.size,
        "${path}.sourceApiSignature.tokens")
    var signatureIndex: Int64 = 0
    for (token in value.sourceApiSignature.tokens) {
        budget.consumeString(token, "${path}.sourceApiSignature.tokens[${signatureIndex}]")
        signatureIndex++
    }
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

internal func validateDocIrEncodingBudget(documentation: DocumentationSet, limit: Int64): Unit {
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
        budget.consumeOptionalString(module.organization, "${path}.organization")
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
        budget.consumeCollection(pkg.reExports.size, "${path}.reExports")
        itemIndex = 0
        for (reExport in pkg.reExports) {
            let reExportPath = "${path}.reExports[${itemIndex}]"
            budget.consumeObject(reExportPath)
            budget.consumeString(reExport.id, "${reExportPath}.id")
            budget.consumeString(reExport.kind, "${reExportPath}.kind")
            budget.consumeOptionalString(reExport.organization, "${reExportPath}.organization")
            budget.consumeString(reExport.targetPackageName, "${reExportPath}.targetPackageName")
            budget.consumeOptionalString(reExport.targetModuleId, "${reExportPath}.targetModuleId")
            budget.consumeOptionalString(reExport.alias, "${reExportPath}.alias")
            budget.consumeString(reExport.state, "${reExportPath}.state")
            consumeRangeEncoding(reExport.source, "${reExportPath}.source", budget, jsonDepth: 3)
            budget.consumeCollection(reExport.bindings.size, "${reExportPath}.bindings")
            var bindingIndex: Int64 = 0
            for (binding in reExport.bindings) {
                let bindingPath = "${reExportPath}.bindings[${bindingIndex}]"
                budget.consumeObject(bindingPath)
                budget.consumeString(binding.exposedName, "${bindingPath}.exposedName")
                budget.consumeCollection(binding.targetSymbolIds.size,
                    "${bindingPath}.targetSymbolIds")
                var targetIndex: Int64 = 0
                for (targetId in binding.targetSymbolIds) {
                    budget.consumeString(targetId,
                        "${bindingPath}.targetSymbolIds[${targetIndex}]")
                    targetIndex++
                }
                bindingIndex++
            }
            itemIndex++
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
