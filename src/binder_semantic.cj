package cjdoc

import std.collection.*


internal func copyModule(source: SourceModule): ModuleDoc {
    let module = ModuleDoc(source.id, source.name, source.role, source.sourcePrefix,
        organization: source.organization)
    module.packageNames.add(all: source.packageNames)
    module.dependencyIds.add(all: source.dependencyIds)
    return module
}

internal func copyPackage(source: SourcePackage): PackageDoc {
    let pkg = PackageDoc(source.name, source.moduleId)
    pkg.sourceFiles.add(all: source.sourceFiles)
    return pkg
}

internal func typeRefFromSourceSpelling(spelling: String): TypeRef {
    TypeRef(spelling, state: if (spelling.isEmpty()) {
        "unavailable"
    } else {
        "partial"
    })
}

internal func semanticFallback(source: SourceDeclaration, provider: String, state: String): SemanticDeclaration {
    let semantic = SemanticDeclaration(source.sourceKey, source.kind, source.name, source.packageName, source.moduleId,
        source.ownerSourceKey, source.visibility, state, provider, isContainer: source.isContainer,
        enumNonExhaustive: source.enumNonExhaustive)
    semantic.genericParameters.add(all: source.genericParameters)
    for (parameter in source.parameters) {
        semantic.parameters.add(SemanticParameter(parameter.name, typeRefFromSourceSpelling(parameter.typeSpelling)))
    }
    if (let Some(spelling) <- source.returnTypeSpelling) {
        semantic.returnType = Some(typeRefFromSourceSpelling(spelling))
    }
    semantic.annotations.add(all: source.annotations)
    for (relationship in source.relationships) {
        semantic
            .relationships
            .add(TypeRelationship(relationship.kind, typeRefFromSourceSpelling(relationship.targetSpelling)))
    }
    for (relationship in source.symbolRelationships) {
        semantic
            .symbolRelationships
            .add(SymbolRelationship(relationship.kind, relationship.targetDisplay, "unavailable"))
    }
    return semantic
}

internal func recordContractViolation(documentation: DocumentationSet, stats: SemanticBindingStats, message: String,
    source!: ?SourceLocation = None): Unit {
    stats.contractViolations++
    documentation.diagnostics.add(Diagnostic("warning", "CJDOC2017", message, source: source))
}

internal func validSemanticState(state: String): Bool {
    state == "resolved" || state == "partial" || state == "unavailable" || state == "ambiguous"
}

internal func validVisibility(visibility: String): Bool {
    visibility == "public" || visibility == "protected" || visibility == "internal" || visibility == "private"
}

internal func sanitizeTypeRef(sourceDisplay: String, semantic: TypeRef, capabilities: SemanticCapabilities,
    documentation: DocumentationSet, stats: SemanticBindingStats, source: SourceLocation): TypeRef {
    if (!validSemanticState(semantic.state)) {
        recordContractViolation(documentation, stats,
            "semantic provider returned an invalid type state '${semantic.state}'", source: source)
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    if (!capabilities.canonicalTypes) {
        if (semantic.canonical.isSome() || semantic.state == "resolved") {
            recordContractViolation(documentation, stats,
                "semantic provider returned a resolved/canonical type without canonicalTypes capability", source: source)
        }
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    if (let Some(canonical) <- semantic.canonical) {
        if (canonical.trimAscii().isEmpty()) {
            recordContractViolation(documentation, stats, "semantic provider returned an empty canonical type spelling",
                source: source)
            return typeRefFromSourceSpelling(sourceDisplay)
        }
    }
    if (semantic.state == "resolved" && semantic.canonical.isNone()) {
        recordContractViolation(documentation, stats,
            "semantic provider marked a type resolved without a canonical type", source: source)
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    if (semantic.state == "unavailable" && semantic.canonical.isSome()) {
        recordContractViolation(documentation, stats,
            "semantic provider attached a canonical spelling to an unavailable type", source: source)
        return typeRefFromSourceSpelling(sourceDisplay)
    }
    let arguments = ArrayList<TypeRef>()
    for (argument in semantic.arguments) {
        arguments.add(sanitizeTypeRef(argument.display, argument, capabilities, documentation, stats, source))
    }
    return TypeRef(sourceDisplay, canonical: semantic.canonical, state: semantic.state, kind: semantic.kind,
        nullable: semantic.nullable, arguments: arguments.toArray())
}

internal func sanitizeSemantic(source: SourceDeclaration, semantic: SemanticDeclaration,
    moduleResult: ModuleSemanticResult, documentation: DocumentationSet, stats: SemanticBindingStats): ?SemanticDeclaration {
    if (semantic.kind != source.kind || semantic.name != source.name || semantic.packageName != source.packageName ||
        semantic.moduleId != source.moduleId || semantic.isContainer != source.isContainer ||
        semantic.enumNonExhaustive != source.enumNonExhaustive) {
        recordContractViolation(documentation, stats,
            "semantic declaration identity does not match its source declaration", source: source.source)
        return None
    }
    if (semantic.parameters.size != source.parameters.size) {
        recordContractViolation(documentation, stats, "semantic declaration parameter count does not match source",
            source: source.source)
        return None
    }
    var index: Int64 = 0
    while (index < source.parameters.size) {
        if (semantic.parameters[index].name != source.parameters[index].name) {
            recordContractViolation(documentation, stats, "semantic declaration parameter name does not match source",
                source: source.source)
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
            recordContractViolation(documentation, stats, "semantic declaration owner does not match source ownership",
                source: source.source)
            owner = source.ownerSourceKey
        }
    } else if (semantic.ownerSourceKey != source.ownerSourceKey) {
        recordContractViolation(documentation, stats, "semantic provider changed ownership without ownership capability",
            source: source.source)
    }

    var canonicalSignature = semantic.canonicalSignature
    if (!moduleResult.capabilities.canonicalSignatures && canonicalSignature.isSome()) {
        recordContractViolation(documentation, stats,
            "semantic provider returned a canonical signature without canonicalSignatures capability",
            source: source.source)
        canonicalSignature = None
    }
    if (moduleResult.capabilities.canonicalSignatures && canonicalSignature.isSome() &&
        canonicalSignature.getOrThrow().trimAscii().isEmpty()) {
        recordContractViolation(documentation, stats, "semantic provider returned an empty canonical signature",
            source: source.source)
        canonicalSignature = None
    }
    let sanitized = SemanticDeclaration(source.sourceKey, source.kind, source.name, source.packageName, source.moduleId,
        owner, visibility, state, moduleResult.provider, canonicalSignature: canonicalSignature,
        isContainer: source.isContainer, enumNonExhaustive: source.enumNonExhaustive)
    sanitized.genericParameters.add(all: source.genericParameters)
    index = 0
    while (index < source.parameters.size) {
        sanitized
            .parameters
            .add(
                SemanticParameter(source.parameters[index].name,
                    sanitizeTypeRef(source.parameters[index].typeSpelling, semantic.parameters[index].typeRef,
                        moduleResult.capabilities, documentation, stats, source.source)))
        index++
    }
    match (source.returnTypeSpelling) {
        case Some(display) => match (semantic.returnType) {
            case Some(typeRef) => sanitized.returnType = Some(
                sanitizeTypeRef(display, typeRef, moduleResult.capabilities, documentation, stats, source.source))
            case None => sanitized.returnType = Some(typeRefFromSourceSpelling(display))
        }
        case None =>
            if (let Some(typeRef) <- semantic.returnType) {
                sanitized.returnType = Some(
                    sanitizeTypeRef(typeRef.display, typeRef, moduleResult.capabilities, documentation, stats,
                        source.source))
            }
    }
    sanitized.annotations.add(all: source.annotations)
    if (moduleResult.capabilities.annotations) {
        sanitized.providerAnnotations.add(all: semantic.providerAnnotations)
    } else if (!semantic.providerAnnotations.isEmpty()) {
        recordContractViolation(documentation, stats,
            "semantic provider returned annotations without annotations capability", source: source.source)
    }
    for (relationship in source.relationships) {
        var supplied = false
        for (candidate in semantic.relationships) {
            if (candidate.kind == relationship.kind && candidate.target.display == relationship.targetSpelling) {
                supplied = true
                break
            }
        }
        if (!supplied) {
            sanitized
                .relationships
                .add(TypeRelationship(relationship.kind, typeRefFromSourceSpelling(relationship.targetSpelling)))
        }
    }
    for (relationship in semantic.relationships) {
        sanitized
            .relationships
            .add(
                TypeRelationship(relationship.kind,
                    sanitizeTypeRef(relationship.target.display, relationship.target, moduleResult.capabilities,
                        documentation, stats, source.source)))
    }
    for (relationship in source.symbolRelationships) {
        var supplied = false
        for (candidate in semantic.symbolRelationships) {
            if (candidate.kind == relationship.kind && candidate.targetDisplay == relationship.targetDisplay) {
                supplied = true
                break
            }
        }
        if (!supplied) {
            sanitized
                .symbolRelationships
                .add(SymbolRelationship(relationship.kind, relationship.targetDisplay, "unavailable"))
        }
    }
    for (relationship in semantic.symbolRelationships) {
        if (!moduleResult.capabilities.symbolRelationships && (relationship.state == "resolved" ||
            relationship.targetSymbolId.isSome() || relationship.targetSourceKey.isSome())) {
            recordContractViolation(documentation, stats,
                "semantic provider resolved a symbol relationship without symbolRelationships capability",
                source: source.source)
            sanitized
                .symbolRelationships
                .add(SymbolRelationship(relationship.kind, relationship.targetDisplay, "unavailable"))
        } else if (!validSemanticState(relationship.state) || (relationship.state == "resolved" &&
            relationship.targetSymbolId.isNone() && relationship.targetSourceKey.isNone())) {
            recordContractViolation(documentation, stats, "semantic provider returned an invalid symbol relationship",
                source: source.source)
            sanitized
                .symbolRelationships
                .add(SymbolRelationship(relationship.kind, relationship.targetDisplay, "unavailable"))
        } else {
            sanitized.symbolRelationships.add(relationship)
        }
    }
    return Some(sanitized)
}

internal func resolveSymbolRelationshipSourceKeys(symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>,
    idsBySourceKey: HashMap<String, String>): Unit {
    var index: Int64 = 0
    while (index < symbols.size) {
        if (omittedIndices.contains(index)) {
            index++;
            continue
        }
        let symbol = symbols[index]
        for (relationship in symbol.symbolRelationships) {
            if (let Some(sourceKey) <- relationship.targetSourceKey) {
                match (idsBySourceKey.get(sourceKey)) {
                    case Some(id) => relationship.targetSymbolId = Some(id)
                    case None =>
                        relationship.state = "unavailable"
                        relationship.targetSymbolId = None
                }
            }
        }
        index++
    }
}

internal func copySemanticToDoc(source: SourceDeclaration, semantic: SemanticDeclaration): SymbolDoc {
    let symbol = SymbolDoc(semantic.kind, semantic.name, semantic.packageName, semantic.moduleId, semantic.visibility,
        source.source, source.sourceSignature, isContainer: semantic.isContainer, semanticState: semantic.state,
        semanticProvider: semantic.provider, canonicalSignature: semantic.canonicalSignature,
        enumNonExhaustive: semantic.enumNonExhaustive,
        sourceApiSignatureTokens: source.sourceApiSignatureTokens.toArray())
    symbol.genericParameters.add(all: semantic.genericParameters)
    var parameterIndex: Int64 = 0
    for (parameter in semantic.parameters) {
        let defaultExpression: ?String = if (parameterIndex < source.parameters.size) {
            source.parameters[parameterIndex].defaultExpression
        } else {
            None
        }
        symbol.parameters.add(ParameterDoc(parameter.name, parameter.typeRef, defaultExpression: defaultExpression))
        parameterIndex++
    }
    symbol.returnType = semantic.returnType
    for (annotation in semantic.annotations) {
        symbol.annotations.add(DocAnnotation(annotation))
    }
    for (annotation in semantic.providerAnnotations) {
        symbol.annotations.add(DocAnnotation(annotation, provenance: "provider", provider: Some(semantic.provider)))
    }
    symbol.relationships.add(all: semantic.relationships)
    symbol.symbolRelationships.add(all: semantic.symbolRelationships)
    symbol.documentation = source.documentation
    return symbol
}
