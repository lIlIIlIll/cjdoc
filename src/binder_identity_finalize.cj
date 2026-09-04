package cjdoc

import std.collection.*

func makeSymbolId(moduleId: String, packageName: String, owner: String, kind: String, name: String, genericArity: Int64,
    parameterTypes: Array<String>): String {
    let builder = StringBuilder()
    builder.append("cjdoc:v2:")
    builder.append(percentEscapeSymbolPart(moduleId))
    builder.append("::")
    builder.append(percentEscapeSymbolPart(packageName))
    builder.append(owner)
    builder.append("::")
    builder.append(kind)
    builder.append(":")
    let identityName = if (kind == "extend") {
        normalizeTypeSpelling(name)
    } else {
        name
    }
    builder.append(percentEscapeSymbolPart(identityName))
    builder.append("#g")
    builder.append(genericArity)
    builder.append("(")
    var index: Int64 = 0
    while (index < parameterTypes.size) {
        if (index > 0) {
            builder.append(",")
        }
        builder.append(percentEscapeSymbolPart(normalizeTypeSpelling(parameterTypes[index])))
        index++
    }
    builder.append(")")
    return builder.toString()
}

internal class ExtensionIdentityPlan {
    let baseNames: Array<String>
    let blockDiscriminators: Array<String>
    let ownerNeedsDiscriminator: Array<Bool>

    init(baseNames: Array<String>, blockDiscriminators: Array<String>, ownerNeedsDiscriminator: Array<Bool>) {
        this.baseNames = baseNames
        this.blockDiscriminators = blockDiscriminators
        this.ownerNeedsDiscriminator = ownerNeedsDiscriminator
    }
}

// A block discriminator is based on logical file identity, the block's
// semantic member identity, and source-order ordinal among equivalent blocks
// in that file. It deliberately excludes source coordinates, so inserting
// blank lines does not perturb SymbolIds.
internal func extensionIdentityPlan(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology,
    genericScopes: Array<IdentityGenericScope>, semanticIdentityScopes: Array<String>,
    emptyBlockDiscriminators: Array<String>): ExtensionIdentityPlan {
    let baseNames = Array<String>(symbols.size, repeat: "")
    let equivalenceKeys = Array<String>(symbols.size, repeat: "")
    let blockDiscriminators = Array<String>(symbols.size, repeat: "")
    let ownerNeedsDiscriminator = Array<Bool>(symbols.size, repeat: false)
    let counts = HashMap<String, Int64>()
    var index: Int64 = 0
    while (index < symbols.size) {
        let symbol = symbols[index]
        if (symbol.kind == "extend") {
            let baseName = extendIdentityName(symbols, index, topology, genericScopes)
            baseNames[index] = baseName
            let owner = ownerIdentityScope(symbols, index, semanticIdentityScopes, emptyBlockDiscriminators)
            let key = makeSymbolId(symbol.moduleId, symbol.packageName, owner, symbol.kind, baseName,
                symbol.genericParameters.size, [])
            equivalenceKeys[index] = key
            counts[key] = match (counts.get(key)) {
                case Some(value) => value + 1
                case None => 1
            }
        }
        index++
    }

    let ordinals = HashMap<String, Int64>()
    index = 0
    while (index < symbols.size) {
        let symbol = symbols[index]
        if (symbol.kind == "extend") {
            let key = equivalenceKeys[index]
            ownerNeedsDiscriminator[index] = counts[key] > 1
            let ordinalKey = "${key.size}:${key}${symbol.source.path}"
            let ordinal = match (ordinals.get(ordinalKey)) {
                case Some(value) => value
                case None => 0
            }
            ordinals[ordinalKey] = ordinal + 1
            let discriminator = StringBuilder()
            discriminator.append("::extension-block:")
            discriminator.append(percentEscapeSymbolPart(symbol.source.path))
            discriminator.append(":")
            discriminator.append(percentEscapeSymbolPart(baseNames[index]))
            discriminator.append("#")
            discriminator.append(ordinal)
            blockDiscriminators[index] = discriminator.toString()
        }
        index++
    }
    ExtensionIdentityPlan(baseNames, blockDiscriminators, ownerNeedsDiscriminator)
}

internal func finalizeIdentities(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology): Unit {
    topology.apply(symbols)
    let genericScopes = identityGenericScopes(symbols, topology)
    let emptyBlockDiscriminators = Array<String>(symbols.size, repeat: "")
    let semanticIdentityScopes = Array<String>(symbols.size, repeat: "")
    let semanticQualifiedSuffixes = Array<String>(symbols.size, repeat: "")
    let semanticComputed = Array<Bool>(symbols.size, repeat: false)
    let semanticVisiting = Array<Int64>(symbols.size, repeat: -1)
    var index: Int64 = 0
    while (index < symbols.size) {
        ensureOwnerPrefixes(symbols, index, semanticIdentityScopes, semanticQualifiedSuffixes, semanticComputed,
            semanticVisiting, genericScopes, emptyBlockDiscriminators)
        index++
    }
    let extensionPlan = extensionIdentityPlan(symbols, topology, genericScopes, semanticIdentityScopes,
        emptyBlockDiscriminators)

    let identityScopes = Array<String>(symbols.size, repeat: "")
    let qualifiedSuffixes = Array<String>(symbols.size, repeat: "")
    let computed = Array<Bool>(symbols.size, repeat: false)
    let visiting = Array<Int64>(symbols.size, repeat: -1)
    index = 0
    while (index < symbols.size) {
        ensureOwnerPrefixes(symbols, index, identityScopes, qualifiedSuffixes, computed, visiting, genericScopes,
            extensionPlan.blockDiscriminators)
        index++
    }
    index = 0
    while (index < symbols.size) {
        let symbol = symbols[index]
        let owner = ownerIdentityScope(symbols, index, identityScopes, extensionPlan.blockDiscriminators)
        let types = ArrayList<String>()
        for (parameter in symbol.parameters) {
            types.add(alphaNormalizedIdentitySpelling(identityType(parameter.typeRef), genericScopes[index]))
        }
        let identityName = if (symbol.kind == "extend") {
            if (extensionPlan.ownerNeedsDiscriminator[index]) {
                extensionPlan.baseNames[index] + extensionPlan.blockDiscriminators[index]
            } else {
                extensionPlan.baseNames[index]
            }
        } else {
            symbol.name
        }
        symbol.id = makeSymbolId(symbol.moduleId, symbol.packageName, owner, symbol.kind, identityName,
            symbol.genericParameters.size, types.toArray())
        let qualified = StringBuilder()
        qualified.append(symbol.packageName)
        if (symbol.ownerIndex >= 0 && symbol.ownerIndex < symbols.size) {
            qualified.append(qualifiedSuffixes[symbol.ownerIndex])
        }
        qualified.append(".")
        qualified.append(symbol.name)
        symbol.qualifiedName = qualified.toString()
        index++
    }
    index = 0
    while (index < symbols.size) {
        let owner = symbols[index].ownerIndex
        if (owner >= 0 && owner < symbols.size) {
            symbols[index].ownerId = Some(symbols[owner].id)
        }
        index++
    }
}

internal func finalizeIdentities(symbols: ArrayList<SymbolDoc>): Unit {
    finalizeIdentities(symbols, identityTopologyForSymbols(symbols))
}

// Mirror sanitizeTypeRef's identity basis: provider spelling is never source
// truth. Only a resolved canonical type can replace the source spelling in a
// SymbolId; partial/unavailable/ambiguous provider spellings retain source
// overload identity.
internal func copySemanticIdentityToDoc(source: SourceDeclaration, semantic: SemanticDeclaration): SymbolDoc {
    let symbol = SymbolDoc(source.kind, source.name, source.packageName, source.moduleId, semantic.visibility,
        source.source, source.sourceSignature, isContainer: source.isContainer, semanticState: semantic.state,
        semanticProvider: semantic.provider, canonicalSignature: semantic.canonicalSignature,
        enumNonExhaustive: source.enumNonExhaustive,
        sourceApiSignatureTokens: source.sourceApiSignatureTokens.toArray())
    symbol.genericParameters.add(all: source.genericParameters)
    var index: Int64 = 0
    while (index < source.parameters.size) {
        let sourceParameter = source.parameters[index]
        let typeRef = if (index < semantic.parameters.size) {
            let provided = semantic.parameters[index].typeRef
            TypeRef(sourceParameter.typeSpelling, canonical: provided.canonical, state: provided.state,
                kind: provided.kind, nullable: provided.nullable)
        } else {
            typeRefFromSourceSpelling(sourceParameter.typeSpelling)
        }
        symbol
            .parameters
            .add(ParameterDoc(sourceParameter.name, typeRef, defaultExpression: sourceParameter.defaultExpression))
        index++
    }
    symbol
}

internal func identityProjection(sourceDeclarations: ArrayList<SourceDeclaration>,
    semanticBySource: HashMap<String, SemanticDeclaration>, provider: String, useProviderSemantics: Bool,
    topology: IdentityTopology): ArrayList<SymbolDoc> {
    let projected = ArrayList<SymbolDoc>()
    for (source in sourceDeclarations) {
        let semantic = if (useProviderSemantics) {
            match (semanticBySource.get(source.sourceKey)) {
                case Some(value) => value
                case None => semanticFallback(source, provider, "unavailable")
            }
        } else {
            semanticFallback(source, provider, "unavailable")
        }
        projected.add(copySemanticIdentityToDoc(source, semantic))
    }
    finalizeIdentities(projected, topology)
    projected
}

// A provider must not collapse distinct source identities into one SymbolId.
// The public adapter calls this while its module result is still staged, so a
// collision discards the entire provider batch and retains the source-spelling
// AST fallback (including overloads).
func providerIntroducesSymbolIdConflict(sourceDeclarations: ArrayList<SourceDeclaration>,
    semantics: ArrayList<SemanticDeclaration>, provider: String): Bool {
    let semanticBySource = HashMap<String, SemanticDeclaration>()
    for (semantic in semantics) {
        semanticBySource[semantic.sourceKey] = semantic
    }
    let topology = identityTopologyForSources(sourceDeclarations)
    let projected = identityProjection(sourceDeclarations, semanticBySource, provider, true, topology)
    let sourceFallback = identityProjection(sourceDeclarations, HashMap<String, SemanticDeclaration>(), provider, false,
        topology)
    let sourceIdentityByProjectedId = HashMap<String, String>()
    var index: Int64 = 0
    while (index < projected.size && index < sourceFallback.size) {
        match (sourceIdentityByProjectedId.get(projected[index].id)) {
            case Some(firstSourceIdentity) =>
                if (firstSourceIdentity != sourceFallback[index].id) {
                    return true
                }
            case None => sourceIdentityByProjectedId[projected[index].id] = sourceFallback[index].id
        }
        index++
    }
    false
}
