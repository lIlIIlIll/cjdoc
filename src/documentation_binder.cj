package cjdoc

import std.collection.*
import std.sort.*

private func copyModule(source: SourceModule): ModuleDoc {
    let module = ModuleDoc(source.id, source.name, source.role, source.sourcePrefix)
    module.packageNames.add(all: source.packageNames)
    module.dependencyIds.add(all: source.dependencyIds)
    return module
}

private func copyPackage(source: SourcePackage): PackageDoc {
    let pkg = PackageDoc(source.name, source.moduleId)
    pkg.sourceFiles.add(all: source.sourceFiles)
    return pkg
}

private func typeRefFromSourceSpelling(spelling: String): TypeRef {
    TypeRef(spelling, state: if (spelling.isEmpty()) { "unavailable" } else { "partial" })
}

private func semanticFallback(source: SourceDeclaration, provider: String, state: String): SemanticDeclaration {
    let semantic = SemanticDeclaration(source.sourceKey, source.kind, source.name, source.packageName,
        source.moduleId,
        source.ownerSourceKey, source.visibility, state, provider, isContainer: source.isContainer)
    semantic.genericParameters.add(all: source.genericParameters)
    for (parameter in source.parameters) {
        semantic.parameters.add(SemanticParameter(parameter.name,
            typeRefFromSourceSpelling(parameter.typeSpelling)))
    }
    if (let Some(spelling) <- source.returnTypeSpelling) {
        semantic.returnType = Some(typeRefFromSourceSpelling(spelling))
    }
    semantic.annotations.add(all: source.annotations)
    for (relationship in source.relationships) {
        semantic.relationships.add(TypeRelationship(relationship.kind,
            typeRefFromSourceSpelling(relationship.targetSpelling)))
    }
    for (relationship in source.symbolRelationships) {
        semantic.symbolRelationships.add(SymbolRelationship(relationship.kind,
            relationship.targetDisplay, "unavailable"))
    }
    return semantic
}

private func recordContractViolation(documentation: DocumentationSet, stats: SemanticBindingStats,
    message: String, source!: ?SourceLocation = None): Unit {
    stats.contractViolations++
    documentation.diagnostics.add(Diagnostic("warning", "CJDOC1017", message, source: source))
}

private func validSemanticState(state: String): Bool {
    state == "resolved" || state == "partial" || state == "unavailable" || state == "ambiguous"
}

private func validVisibility(visibility: String): Bool {
    visibility == "public" || visibility == "protected" || visibility == "internal" ||
        visibility == "private"
}

private func sanitizeTypeRef(sourceDisplay: String, semantic: TypeRef,
    capabilities: SemanticCapabilities, documentation: DocumentationSet,
    stats: SemanticBindingStats, source: SourceLocation): TypeRef {
    if (!validSemanticState(semantic.state)) {
        recordContractViolation(documentation, stats,
            "semantic provider returned an invalid type state '${semantic.state}'", source: source)
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    if (!capabilities.canonicalTypes) {
        if (semantic.canonical.isSome() || semantic.state == "resolved") {
            recordContractViolation(documentation, stats,
                "semantic provider returned a resolved/canonical type without canonicalTypes capability",
                source: source)
        }
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    if (semantic.state == "resolved" && semantic.canonical.isNone()) {
        recordContractViolation(documentation, stats,
            "semantic provider marked a type resolved without a canonical type", source: source)
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    return TypeRef(sourceDisplay, canonical: semantic.canonical, state: semantic.state,
        kind: semantic.kind, nullable: semantic.nullable,
        arguments: semantic.arguments.toArray())
}

private func sanitizeSemantic(source: SourceDeclaration, semantic: SemanticDeclaration,
    moduleResult: ModuleSemanticResult, documentation: DocumentationSet,
    stats: SemanticBindingStats): ?SemanticDeclaration {
    if (semantic.kind != source.kind || semantic.name != source.name ||
        semantic.packageName != source.packageName || semantic.moduleId != source.moduleId ||
        semantic.isContainer != source.isContainer) {
        recordContractViolation(documentation, stats,
            "semantic declaration identity does not match its source declaration", source: source.source)
        return None
    }
    if (semantic.parameters.size != source.parameters.size) {
        recordContractViolation(documentation, stats,
            "semantic declaration parameter count does not match source", source: source.source)
        return None
    }
    var index: Int64 = 0
    while (index < source.parameters.size) {
        if (semantic.parameters[index].name != source.parameters[index].name) {
            recordContractViolation(documentation, stats,
                "semantic declaration parameter name does not match source", source: source.source)
            return None
        }
        index++
    }

    var state = semantic.state
    if (!validSemanticState(state)) {
        recordContractViolation(documentation, stats,
            "semantic provider returned an invalid declaration state '${state}'", source: source.source)
        state = "partial"
    }
    let visibility = if (moduleResult.capabilities.visibility) {
        if (validVisibility(semantic.visibility)) {
            semantic.visibility
        } else {
            recordContractViolation(documentation, stats,
                "semantic provider returned an invalid visibility '${semantic.visibility}'", source: source.source)
            source.visibility
        }
    } else {
        if (semantic.visibility != source.visibility) {
            recordContractViolation(documentation, stats,
                "semantic provider changed visibility without visibility capability", source: source.source)
        }
        source.visibility
    }

    var owner = source.ownerSourceKey
    if (moduleResult.capabilities.ownership) {
        owner = semantic.ownerSourceKey
        if (owner != source.ownerSourceKey) {
            recordContractViolation(documentation, stats,
                "semantic declaration owner does not match source ownership", source: source.source)
            owner = source.ownerSourceKey
        }
    } else if (semantic.ownerSourceKey != source.ownerSourceKey) {
        recordContractViolation(documentation, stats,
            "semantic provider changed ownership without ownership capability", source: source.source)
    }

    var canonicalSignature = semantic.canonicalSignature
    if (!moduleResult.capabilities.canonicalSignatures && canonicalSignature.isSome()) {
        recordContractViolation(documentation, stats,
            "semantic provider returned a canonical signature without canonicalSignatures capability",
            source: source.source)
        canonicalSignature = None
    }
    let sanitized = SemanticDeclaration(source.sourceKey, source.kind, source.name, source.packageName,
        source.moduleId,
        owner, visibility, state, moduleResult.provider, canonicalSignature: canonicalSignature,
        isContainer: source.isContainer)
    sanitized.genericParameters.add(all: source.genericParameters)
    index = 0
    while (index < source.parameters.size) {
        sanitized.parameters.add(SemanticParameter(source.parameters[index].name,
            sanitizeTypeRef(source.parameters[index].typeSpelling, semantic.parameters[index].typeRef,
                moduleResult.capabilities, documentation, stats, source.source)))
        index++
    }
    match (source.returnTypeSpelling) {
        case Some(display) =>
            match (semantic.returnType) {
                case Some(typeRef) => sanitized.returnType = Some(sanitizeTypeRef(display, typeRef,
                    moduleResult.capabilities, documentation, stats, source.source))
                case None =>
                    sanitized.returnType = Some(typeRefFromSourceSpelling(display))
            }
        case None =>
            if (let Some(typeRef) <- semantic.returnType) {
                sanitized.returnType = Some(sanitizeTypeRef(typeRef.display, typeRef,
                    moduleResult.capabilities, documentation, stats, source.source))
            }
    }
    sanitized.annotations.add(all: source.annotations)
    if (moduleResult.capabilities.annotations) {
        sanitized.providerAnnotations.add(all: semantic.providerAnnotations)
    } else if (!semantic.providerAnnotations.isEmpty()) {
        recordContractViolation(documentation, stats,
            "semantic provider returned annotations without annotations capability",
            source: source.source)
    }
    for (relationship in source.relationships) {
        var supplied = false
        for (candidate in semantic.relationships) {
            if (candidate.kind == relationship.kind &&
                candidate.target.display == relationship.targetSpelling) {
                supplied = true
                break
            }
        }
        if (!supplied) {
            sanitized.relationships.add(TypeRelationship(relationship.kind,
                typeRefFromSourceSpelling(relationship.targetSpelling)))
        }
    }
    for (relationship in semantic.relationships) {
        sanitized.relationships.add(TypeRelationship(relationship.kind,
            sanitizeTypeRef(relationship.target.display, relationship.target,
                moduleResult.capabilities, documentation, stats, source.source)))
    }
    for (relationship in source.symbolRelationships) {
        var supplied = false
        for (candidate in semantic.symbolRelationships) {
            if (candidate.kind == relationship.kind &&
                candidate.targetDisplay == relationship.targetDisplay) {
                supplied = true
                break
            }
        }
        if (!supplied) {
            sanitized.symbolRelationships.add(SymbolRelationship(relationship.kind,
                relationship.targetDisplay, "unavailable"))
        }
    }
    for (relationship in semantic.symbolRelationships) {
        if (!moduleResult.capabilities.symbolRelationships &&
            (relationship.state == "resolved" || relationship.targetSymbolId.isSome() ||
                relationship.targetSourceKey.isSome())) {
            recordContractViolation(documentation, stats,
                "semantic provider resolved a symbol relationship without symbolRelationships capability",
                source: source.source)
            sanitized.symbolRelationships.add(SymbolRelationship(relationship.kind,
                relationship.targetDisplay, "unavailable"))
        } else if (!validSemanticState(relationship.state) ||
            (relationship.state == "resolved" && relationship.targetSymbolId.isNone() &&
                relationship.targetSourceKey.isNone())) {
            recordContractViolation(documentation, stats,
                "semantic provider returned an invalid symbol relationship", source: source.source)
            sanitized.symbolRelationships.add(SymbolRelationship(relationship.kind,
                relationship.targetDisplay, "unavailable"))
        } else {
            sanitized.symbolRelationships.add(relationship)
        }
    }
    return Some(sanitized)
}

private func resolveSymbolRelationshipSourceKeys(symbols: ArrayList<SymbolDoc>,
    source: SourceSnapshot): Unit {
    let idsBySourceKey = HashMap<String, String>()
    var index: Int64 = 0
    while (index < source.declarations.size && index < symbols.size) {
        idsBySourceKey[source.declarations[index].sourceKey] = symbols[index].id
        index++
    }
    for (symbol in symbols) {
        for (relationship in symbol.symbolRelationships) {
            if (let Some(sourceKey) <- relationship.targetSourceKey) {
                match (idsBySourceKey.get(sourceKey)) {
                    case Some(id) => relationship.targetSymbolId = Some(id)
                    case None => relationship.state = "unavailable"; relationship.targetSymbolId = None
                }
            }
        }
    }
}

private func copySemanticToDoc(source: SourceDeclaration, semantic: SemanticDeclaration): SymbolDoc {
    let symbol = SymbolDoc(semantic.kind, semantic.name, semantic.packageName, semantic.moduleId,
        semantic.visibility,
        source.source, source.sourceSignature, isContainer: semantic.isContainer,
        semanticState: semantic.state, semanticProvider: semantic.provider,
        canonicalSignature: semantic.canonicalSignature)
    symbol.genericParameters.add(all: semantic.genericParameters)
    for (parameter in semantic.parameters) {
        symbol.parameters.add(ParameterDoc(parameter.name, parameter.typeRef))
    }
    symbol.returnType = semantic.returnType
    for (annotation in semantic.annotations) { symbol.annotations.add(DocAnnotation(annotation)) }
    for (annotation in semantic.providerAnnotations) {
        symbol.annotations.add(DocAnnotation(annotation, provenance: "provider",
            provider: Some(semantic.provider)))
    }
    symbol.relationships.add(all: semantic.relationships)
    symbol.symbolRelationships.add(all: semantic.symbolRelationships)
    symbol.documentation = source.documentation
    return symbol
}

private func ownerPath(symbols: ArrayList<SymbolDoc>, symbol: SymbolDoc): String {
    let names = ArrayList<String>()
    var owner = symbol.ownerIndex
    var rootOwner: Int64 = -1
    while (owner >= 0) {
        rootOwner = owner
        let name = if (symbols[owner].kind == "extend") {
            normalizeTypeSpelling(symbols[owner].name)
        } else {
            symbols[owner].name
        }
        names.add(name, at: 0)
        owner = symbols[owner].ownerIndex
    }
    let builder = StringBuilder()
    if (rootOwner >= 0 && symbols[rootOwner].visibility == "private") {
        builder.append("::file:")
        builder.append(percentEscapeSymbolPart(symbols[rootOwner].source.path))
    }
    for (name in names) {
        builder.append("::")
        builder.append(percentEscapeSymbolPart(name))
    }
    return builder.toString()
}

private func identityType(typeRef: TypeRef): String {
    match (typeRef.canonical) {
        case Some(canonical) =>
            if (typeRef.state == "resolved") { return canonical }
        case None => ()
    }
    return typeRef.display
}

private func memberIdentity(symbol: SymbolDoc): String {
    let builder = StringBuilder()
    builder.append(symbol.kind)
    builder.append(":")
    builder.append(symbol.name)
    builder.append("#g")
    builder.append(symbol.genericParameters.size)
    builder.append("(")
    var index: Int64 = 0
    while (index < symbol.parameters.size) {
        if (index > 0) { builder.append(",") }
        builder.append(normalizeTypeSpelling(identityType(symbol.parameters[index].typeRef)))
        index++
    }
    builder.append(")")
    return builder.toString()
}

private func extendIdentityName(symbols: ArrayList<SymbolDoc>, extendIndex: Int64): String {
    let members = ArrayList<String>()
    var index: Int64 = 0
    while (index < symbols.size) {
        if (symbols[index].ownerIndex == extendIndex &&
            (symbols[index].visibility == "public" || symbols[index].visibility == "protected")) {
            members.add(memberIdentity(symbols[index]))
        }
        index++
    }
    if (members.isEmpty()) {
        index = 0
        while (index < symbols.size) {
            if (symbols[index].ownerIndex == extendIndex) { members.add(memberIdentity(symbols[index])) }
            index++
        }
    }
    sort(members)
    let builder = StringBuilder()
    builder.append(symbols[extendIndex].name)
    builder.append("{")
    index = 0
    while (index < members.size) {
        if (index > 0) { builder.append(";") }
        builder.append(members[index])
        index++
    }
    builder.append("}")
    return builder.toString()
}

func makeSymbolId(moduleId: String, packageName: String, owner: String, kind: String, name: String,
    genericArity: Int64, parameterTypes: Array<String>): String {
    let builder = StringBuilder()
    builder.append("cjdoc:v2:")
    builder.append(percentEscapeSymbolPart(moduleId))
    builder.append("::")
    builder.append(percentEscapeSymbolPart(packageName))
    builder.append(owner)
    builder.append("::")
    builder.append(kind)
    builder.append(":")
    let identityName = if (kind == "extend") { normalizeTypeSpelling(name) } else { name }
    builder.append(percentEscapeSymbolPart(identityName))
    builder.append("#g")
    builder.append(genericArity)
    builder.append("(")
    var index: Int64 = 0
    while (index < parameterTypes.size) {
        if (index > 0) { builder.append(",") }
        builder.append(percentEscapeSymbolPart(normalizeTypeSpelling(parameterTypes[index])))
        index++
    }
    builder.append(")")
    return builder.toString()
}

private func finalizeIdentities(symbols: ArrayList<SymbolDoc>): Unit {
    var index: Int64 = 0
    while (index < symbols.size) {
        let symbol = symbols[index]
        var owner = ownerPath(symbols, symbol)
        if (owner.isEmpty() && symbol.visibility == "private") {
            owner = "::file:" + percentEscapeSymbolPart(symbol.source.path)
        }
        let types = ArrayList<String>()
        for (parameter in symbol.parameters) { types.add(identityType(parameter.typeRef)) }
        let identityName = if (symbol.kind == "extend") { extendIdentityName(symbols, index) } else { symbol.name }
        symbol.id = makeSymbolId(symbol.moduleId, symbol.packageName, owner, symbol.kind, identityName,
            symbol.genericParameters.size, types.toArray())
        let qualified = StringBuilder()
        qualified.append(symbol.packageName)
        var ownerIndex = symbol.ownerIndex
        let ownerNames = ArrayList<String>()
        while (ownerIndex >= 0) {
            ownerNames.add(symbols[ownerIndex].name, at: 0)
            ownerIndex = symbols[ownerIndex].ownerIndex
        }
        for (name in ownerNames) { qualified.append("."); qualified.append(name) }
        qualified.append(".")
        qualified.append(symbol.name)
        symbol.qualifiedName = qualified.toString()
        if (symbol.ownerIndex >= 0) { symbol.ownerId = Some(symbols[symbol.ownerIndex].id) }
        index++
    }
}

private func isConditionalDeclaration(symbol: SymbolDoc): Bool {
    for (annotation in symbol.annotations) {
        if (annotation.spelling.startsWith("@When")) { return true }
    }
    return false
}

private func getDocPackage(documentation: DocumentationSet, moduleId: String, name: String): PackageDoc {
    for (pkg in documentation.packages) {
        if (pkg.moduleId == moduleId && pkg.name == name) { return pkg }
    }
    let pkg = PackageDoc(name, moduleId)
    documentation.packages.add(pkg)
    return pkg
}

private func removeConditionalDuplicateGroups(documentation: DocumentationSet,
    conditionalDuplicateIds: HashSet<String>): Unit {
    if (conditionalDuplicateIds.isEmpty()) { return }
    var index = documentation.symbols.size - 1
    while (index >= 0) {
        if (conditionalDuplicateIds.contains(documentation.symbols[index].id)) {
            documentation.symbols.remove(at: index)
        }
        index--
    }
    for (pkg in documentation.packages) {
        index = pkg.symbolIds.size - 1
        while (index >= 0) {
            if (conditionalDuplicateIds.contains(pkg.symbolIds[index])) { pkg.symbolIds.remove(at: index) }
            index--
        }
    }
}

class DocumentationBinder {
    public func bind(source: SourceSnapshot, semanticResult: SemanticResult,
        expectedProvider!: ?String = None): DocumentationSet {
        let documentation = DocumentationSet(source.projectName)
        for (module in source.modules) { documentation.modules.add(copyModule(module)) }
        for (pkg in source.packages) { documentation.packages.add(copyPackage(pkg)) }
        documentation.sourceFileOrigins.add(all: source.sourceFileOrigins)
        documentation.orphanDocComments.add(all: source.orphanDocComments)
        documentation.macroInvocations.add(all: source.macroInvocations)
        documentation.unsupportedDeclarations.add(all: source.unsupportedDeclarations)
        documentation.diagnostics.add(all: source.diagnostics)
        documentation.diagnostics.add(all: semanticResult.diagnostics)

        let sourceIndexByKey = HashMap<String, Int64>()
        var index: Int64 = 0
        while (index < source.declarations.size) {
            sourceIndexByKey[source.declarations[index].sourceKey] = index
            index++
        }

        let knownModuleIds = HashSet<String>()
        for (module in source.modules) { let _ = knownModuleIds.add(module.id) }
        let reportedByModule = HashMap<String, ModuleSemanticResult>()
        let duplicateModuleResults = HashSet<String>()
        for (moduleResult in semanticResult.modules) {
            if (!knownModuleIds.contains(moduleResult.moduleId)) {
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                    "semantic provider returned a result for an unknown module '${moduleResult.moduleId}'"))
            } else if (reportedByModule.contains(moduleResult.moduleId)) {
                let _ = duplicateModuleResults.add(moduleResult.moduleId)
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                    "semantic provider returned duplicate results for module '${moduleResult.moduleId}'"))
            } else {
                reportedByModule[moduleResult.moduleId] = moduleResult
            }
        }

        let effectiveByModule = HashMap<String, ModuleSemanticResult>()
        let statsByModule = HashMap<String, SemanticBindingStats>()
        let semanticBySource = HashMap<String, SemanticDeclaration>()
        let ambiguousSourceKeys = HashSet<String>()
        for (module in source.modules) {
            let reported: ?ModuleSemanticResult = if (duplicateModuleResults.contains(module.id)) {
                None
            } else {
                reportedByModule.get(module.id)
            }
            let moduleResult = match (reported) {
                case Some(value) => value
                case None =>
                    let provider = match (expectedProvider) {
                        case Some(value) => value
                        case None => "unavailable"
                    }
                    let fallback = ModuleSemanticResult(module.id, provider, "unknown",
                        SemanticCapabilities(false, false, false, false, false))
                    fallback.diagnostics.add(Diagnostic("warning", "CJDOC2001",
                        "semantic result is unavailable for module '${module.name}'; AST fallback retained"))
                    fallback
            }
            effectiveByModule[module.id] = moduleResult
            let stats = SemanticBindingStats(module.id, moduleResult.provider,
                moduleResult.providerVersion, moduleResult.capabilities)
            statsByModule[module.id] = stats
            documentation.semanticBindings.add(stats)
            documentation.diagnostics.add(all: moduleResult.diagnostics)

            var bindingEnabled = moduleResult.capabilities.sourceBinding
            if (let Some(expected) <- expectedProvider) {
                if (moduleResult.provider != expected) {
                    recordContractViolation(documentation, stats,
                        "semantic provider result '${moduleResult.provider}' does not match provider '${expected}'")
                    bindingEnabled = false
                }
            }
            if (!moduleResult.capabilities.sourceBinding && !moduleResult.declarations.isEmpty()) {
                recordContractViolation(documentation, stats,
                    "semantic provider returned declarations without sourceBinding capability")
                bindingEnabled = false
            }
            for (semantic in moduleResult.declarations) {
                let original = match (sourceIndexByKey.get(semantic.sourceKey)) {
                    case Some(sourceIndex) => source.declarations[sourceIndex]
                    case None =>
                        stats.extraneous++
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                            "semantic declaration has no matching source declaration"))
                        continue
                }
                if (semantic.moduleId != module.id || original.moduleId != module.id) {
                    stats.extraneous++
                    recordContractViolation(documentation, stats,
                        "semantic declaration crossed its module transaction boundary",
                        source: original.source)
                    continue
                }
                if (semantic.provider != moduleResult.provider) {
                    recordContractViolation(documentation, stats,
                        "semantic declaration provider '${semantic.provider}' does not match result provider '${moduleResult.provider}'")
                    continue
                }
                if (!bindingEnabled) { continue }
                if (semanticBySource.contains(semantic.sourceKey)) {
                    let _ = ambiguousSourceKeys.add(semantic.sourceKey)
                } else {
                    semanticBySource[semantic.sourceKey] = semantic
                }
            }
        }

        for (declaration in source.declarations) {
            let moduleResult = effectiveByModule[declaration.moduleId]
            let stats = statsByModule[declaration.moduleId]
            let semantic = if (ambiguousSourceKeys.contains(declaration.sourceKey)) {
                stats.ambiguous++
                documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                    "ambiguous Source to semantic binding", source: declaration.source))
                semanticFallback(declaration, moduleResult.provider, "ambiguous")
            } else {
                match (semanticBySource.get(declaration.sourceKey)) {
                    case Some(found) =>
                        match (sanitizeSemantic(declaration, found, moduleResult, documentation, stats)) {
                            case Some(sanitized) => stats.matched++; sanitized
                            case None => stats.missing++;
                                semanticFallback(declaration, moduleResult.provider, "unavailable")
                        }
                    case None =>
                        stats.missing++
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                            "semantic declaration is unavailable", source: declaration.source))
                        semanticFallback(declaration, moduleResult.provider, "unavailable")
                }
            }
            let symbol = copySemanticToDoc(declaration, semantic)
            match (semantic.ownerSourceKey) {
                case Some(ownerKey) =>
                    match (sourceIndexByKey.get(ownerKey)) {
                        case Some(ownerIndex) => symbol.ownerIndex = ownerIndex
                        case None => documentation.diagnostics.add(Diagnostic("warning", "CJDOC1007",
                            "semantic owner has no matching source declaration", source: declaration.source))
                    }
                case None => ()
            }
            documentation.symbols.add(symbol)
        }

        finalizeIdentities(documentation.symbols)
        resolveSymbolRelationshipSourceKeys(documentation.symbols, source)
        let seenIds = HashSet<String>()
        let conditionalDuplicateIds = HashSet<String>()
        index = 0
        while (index < documentation.symbols.size) {
            let symbol = documentation.symbols[index]
            let pkg = getDocPackage(documentation, symbol.moduleId, symbol.packageName)
            if (!seenIds.add(symbol.id)) {
                var conditional = isConditionalDeclaration(symbol)
                if (!conditional) {
                    var previous: Int64 = 0
                    while (previous < index) {
                        if (documentation.symbols[previous].id == symbol.id &&
                            isConditionalDeclaration(documentation.symbols[previous])) {
                            conditional = true
                            break
                        }
                        previous++
                    }
                }
                if (conditional) {
                    if (conditionalDuplicateIds.add(symbol.id)) {
                        documentation.diagnostics.add(Diagnostic("warning", "CJDOC1013",
                            "conditional declaration group omitted because no cfg profile was selected",
                            source: symbol.source, symbolId: symbol.id))
                    }
                } else {
                    documentation.diagnostics.add(Diagnostic("error", "CJDOC1006",
                        "duplicate SymbolId '${symbol.id}'", source: symbol.source, symbolId: symbol.id))
                }
            }
            pkg.symbolIds.add(symbol.id)
            index++
        }
        removeConditionalDuplicateGroups(documentation, conditionalDuplicateIds)
        resolveDocumentationReferences(documentation)
        return documentation
    }
}
