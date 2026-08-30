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
    TypeRef(spelling, state: if (spelling.isEmpty()) {
        "unavailable"
    } else {
        "partial"
    })
}

private func semanticFallback(source: SourceDeclaration, provider: String, state: String): SemanticDeclaration {
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

private func recordContractViolation(documentation: DocumentationSet, stats: SemanticBindingStats, message: String,
    source!: ?SourceLocation = None): Unit {
    stats.contractViolations++
    documentation.diagnostics.add(Diagnostic("warning", "CJDOC2017", message, source: source))
}

private func validSemanticState(state: String): Bool {
    state == "resolved" || state == "partial" || state == "unavailable" || state == "ambiguous"
}

private func validVisibility(visibility: String): Bool {
    visibility == "public" || visibility == "protected" || visibility == "internal" || visibility == "private"
}

private func sanitizeTypeRef(sourceDisplay: String, semantic: TypeRef, capabilities: SemanticCapabilities,
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

private func sanitizeSemantic(source: SourceDeclaration, semantic: SemanticDeclaration,
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

private func resolveSymbolRelationshipSourceKeys(symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>,
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

private func copySemanticToDoc(source: SourceDeclaration, semantic: SemanticDeclaration): SymbolDoc {
    let symbol = SymbolDoc(semantic.kind, semantic.name, semantic.packageName, semantic.moduleId, semantic.visibility,
        source.source, source.sourceSignature, isContainer: semantic.isContainer, semanticState: semantic.state,
        semanticProvider: semantic.provider, canonicalSignature: semantic.canonicalSignature,
        enumNonExhaustive: semantic.enumNonExhaustive)
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

private class IdentityTopology {
    let ownerIndices: Array<Int64>
    let membersByOwner = HashMap<Int64, ArrayList<Int64>>()

    init(ownerIndices: Array<Int64>) {
        this.ownerIndices = ownerIndices
        var index: Int64 = 0
        while (index < ownerIndices.size) {
            let owner = ownerIndices[index]
            if (owner >= 0) {
                match (membersByOwner.get(owner)) {
                    case Some(members) => members.add(index)
                    case None => membersByOwner[owner] = ArrayList<Int64>([index])
                }
            }
            index++
        }
    }

    func apply(symbols: ArrayList<SymbolDoc>): Unit {
        var index: Int64 = 0
        while (index < symbols.size && index < ownerIndices.size) {
            symbols[index].ownerIndex = ownerIndices[index]
            index++
        }
    }
}

private func identityTopologyForSymbols(symbols: ArrayList<SymbolDoc>): IdentityTopology {
    let ownerIndices = Array<Int64>(symbols.size, repeat: -1)
    var index: Int64 = 0
    while (index < symbols.size) {
        ownerIndices[index] = symbols[index].ownerIndex
        index++
    }
    IdentityTopology(ownerIndices)
}

private func identityTopologyForSources(sourceDeclarations: ArrayList<SourceDeclaration>): IdentityTopology {
    let sourceIndexByKey = HashMap<String, Int64>()
    var index: Int64 = 0
    while (index < sourceDeclarations.size) {
        sourceIndexByKey[sourceDeclarations[index].sourceKey] = index
        index++
    }
    let ownerIndices = Array<Int64>(sourceDeclarations.size, repeat: -1)
    index = 0
    while (index < sourceDeclarations.size) {
        if (let Some(ownerKey) <- sourceDeclarations[index].ownerSourceKey) {
            match (sourceIndexByKey.get(ownerKey)) {
                case Some(ownerIndex) => ownerIndices[index] = ownerIndex
                case None => ()
            }
        }
        index++
    }
    IdentityTopology(ownerIndices)
}

// Generic names are source spelling, not declaration identity. A persistent
// lexical scope assigns each binding a position across the owner chain, so
// renames are stable while permutations such as <X, Y>(X, Y) and
// <Y, X>(X, Y) remain distinct.
private class IdentityGenericScope {
    private let parent: ?IdentityGenericScope
    private let parameters: ArrayList<String>
    private let basePosition: Int64
    let totalPositions: Int64

    init(parent: ?IdentityGenericScope, parameters: Array<String>) {
        this.parent = parent
        this.parameters = ArrayList<String>(parameters)
        this.basePosition = match (parent) {
            case Some(value) => value.totalPositions
            case None => 0
        }
        this.totalPositions = basePosition + parameters.size
    }

    func binding(name: String): ?String {
        var index: Int64 = 0
        while (index < parameters.size) {
            if (parameters[index] == name) {
                return Some("@g${basePosition + index}")
            }
            index++
        }
        match (parent) {
            case Some(value) => value.binding(name)
            case None => None
        }
    }
}

private func identityGenericScopes(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology): Array<IdentityGenericScope> {
    let root = IdentityGenericScope(None, [])
    let scopes = Array<IdentityGenericScope>(symbols.size, repeat: root)
    let computed = Array<Bool>(symbols.size, repeat: false)
    let visiting = Array<Int64>(symbols.size, repeat: -1)
    var index: Int64 = 0
    while (index < symbols.size) {
        if (computed[index]) {
            index++;
            continue
        }
        let chain = ArrayList<Int64>()
        var current = index
        while (current >= 0 && current < symbols.size && !computed[current] && visiting[current] != index) {
            visiting[current] = index
            chain.add(current)
            current = topology.ownerIndices[current]
        }
        var scope = if (current >= 0 && current < symbols.size && computed[current]) {
            scopes[current]
        } else {
            root
        }
        var cursor = chain.size
        while (cursor > 0) {
            cursor--
            let currentIndex = chain[cursor]
            if (!symbols[currentIndex].genericParameters.isEmpty()) {
                scope = IdentityGenericScope(Some(scope), symbols[currentIndex].genericParameters.toArray())
            }
            scopes[currentIndex] = scope
            computed[currentIndex] = true
        }
        index++
    }
    scopes
}

private func identityIdentifierByte(value: UInt8): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') || (value >= b'0' && value <= b'9') || value ==
        b'_' || value >= 0x80u8
}

private func alphaNormalizedIdentitySpelling(value: String, scope: IdentityGenericScope): String {
    let normalized = normalizeTypeSpelling(value)
    let bytes = normalized.toArray()
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < bytes.size) {
        if (!identityIdentifierByte(bytes[index])) {
            builder.append(normalized[index..index + 1])
            index++
            continue
        }
        let start = index
        while (index < bytes.size && identityIdentifierByte(bytes[index])) {
            index++
        }
        let token = String.fromUtf8(bytes[start..index])
        let qualified = start > 0 && (bytes[start - 1] == b'.' || bytes[start - 1] == b':')
        if (!qualified) {
            match (scope.binding(token)) {
                case Some(binding) => builder.append(binding)
                case None => builder.append(token)
            }
        } else {
            builder.append(token)
        }
    }
    builder.toString()
}

private func identityOwnerName(symbol: SymbolDoc, scope: IdentityGenericScope): String {
    if (symbol.kind == "extend") {
        alphaNormalizedIdentitySpelling(symbol.name, scope)
    } else {
        symbol.name
    }
}

private func privateFileScope(symbol: SymbolDoc): String {
    "::file:" + percentEscapeSymbolPart(symbol.source.path)
}

// Cache the owner path including each symbol. Every owner edge is traversed
// once; constructing the cached strings is proportional to the prefixes that
// are necessarily emitted into SymbolId and qualifiedName.
private func ensureOwnerPrefixes(symbols: ArrayList<SymbolDoc>, index: Int64, identityScopes: Array<String>,
    qualifiedSuffixes: Array<String>, computed: Array<Bool>, visiting: Array<Int64>,
    genericScopes: Array<IdentityGenericScope>, extensionBlockDiscriminators: Array<String>): Unit {
    if (index < 0 || index >= symbols.size || computed[index]) {
        return
    }
    let chain = ArrayList<Int64>()
    var current = index
    while (current >= 0 && current < symbols.size && !computed[current]) {
        if (visiting[current] == index) {
            break
        }
        visiting[current] = index
        chain.add(current)
        current = symbols[current].ownerIndex
    }
    var identityPrefix = if (current >= 0 && current < symbols.size && computed[current]) {
        identityScopes[current]
    } else {
        ""
    }
    var qualifiedSuffix = if (current >= 0 && current < symbols.size && computed[current]) {
        qualifiedSuffixes[current]
    } else {
        ""
    }
    var cursor = chain.size
    while (cursor > 0) {
        cursor--
        let currentIndex = chain[cursor]
        let symbol = symbols[currentIndex]
        let hasOwner = symbol.ownerIndex >= 0 && symbol.ownerIndex < symbols.size
        let identity = StringBuilder()
        if (hasOwner) {
            identity.append(identityPrefix)
            if (symbol.visibility == "private" && symbols[symbol.ownerIndex].kind == "extend") {
                identity.append(extensionBlockDiscriminators[symbol.ownerIndex])
            }
        } else if (symbol.visibility == "private") {
            identity.append(privateFileScope(symbol))
        }
        identity.append("::")
        identity.append(percentEscapeSymbolPart(identityOwnerName(symbol, genericScopes[currentIndex])))
        identityScopes[currentIndex] = identity.toString()

        let qualified = StringBuilder()
        if (hasOwner) {
            qualified.append(qualifiedSuffix)
        }
        qualified.append(".")
        qualified.append(symbol.name)
        qualifiedSuffixes[currentIndex] = qualified.toString()
        computed[currentIndex] = true
        identityPrefix = identityScopes[currentIndex]
        qualifiedSuffix = qualifiedSuffixes[currentIndex]
    }
}

private func ownerIdentityScope(symbols: ArrayList<SymbolDoc>, index: Int64, identityScopes: Array<String>,
    extensionBlockDiscriminators: Array<String>): String {
    let symbol = symbols[index]
    if (symbol.ownerIndex >= 0 && symbol.ownerIndex < symbols.size) {
        let builder = StringBuilder()
        builder.append(identityScopes[symbol.ownerIndex])
        if (symbol.visibility == "private" && symbols[symbol.ownerIndex].kind == "extend") {
            builder.append(extensionBlockDiscriminators[symbol.ownerIndex])
        }
        return builder.toString()
    }
    if (symbol.visibility == "private") {
        return privateFileScope(symbol)
    }
    ""
}

private func identityType(typeRef: TypeRef): String {
    match (typeRef.canonical) {
        case Some(canonical) =>
            if (typeRef.state == "resolved") {
                return canonical
            }
        case None => ()
    }
    return typeRef.display
}

private func memberIdentity(symbol: SymbolDoc, scope: IdentityGenericScope): String {
    let builder = StringBuilder()
    builder.append(symbol.kind)
    builder.append(":")
    builder.append(symbol.name)
    builder.append("#g")
    builder.append(symbol.genericParameters.size)
    builder.append("(")
    var index: Int64 = 0
    while (index < symbol.parameters.size) {
        if (index > 0) {
            builder.append(",")
        }
        builder.append(alphaNormalizedIdentitySpelling(identityType(symbol.parameters[index].typeRef), scope))
        index++
    }
    builder.append(")")
    return builder.toString()
}

private func extendIdentityName(symbols: ArrayList<SymbolDoc>, extendIndex: Int64, topology: IdentityTopology,
    genericScopes: Array<IdentityGenericScope>): String {
    let members = ArrayList<String>()
    let directMembers = match (topology.membersByOwner.get(extendIndex)) {
        case Some(value) => value
        case None => ArrayList<Int64>()
    }
    var hasVisibleMember = false
    for (memberIndex in directMembers) {
        let visibility = symbols[memberIndex].visibility
        if (visibility == "public" || visibility == "protected") {
            hasVisibleMember = true
            break
        }
    }
    for (memberIndex in directMembers) {
        let visibility = symbols[memberIndex].visibility
        if (!hasVisibleMember || visibility == "public" || visibility == "protected") {
            members.add(memberIdentity(symbols[memberIndex], genericScopes[memberIndex]))
        }
    }
    sort(members)
    let builder = StringBuilder()
    builder.append(alphaNormalizedIdentitySpelling(symbols[extendIndex].name, genericScopes[extendIndex]))
    builder.append("{")
    var index: Int64 = 0
    while (index < members.size) {
        if (index > 0) {
            builder.append(";")
        }
        builder.append(members[index])
        index++
    }
    builder.append("}")
    return builder.toString()
}

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

private class ExtensionIdentityPlan {
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
private func extensionIdentityPlan(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology,
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

private func finalizeIdentities(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology): Unit {
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

private func finalizeIdentities(symbols: ArrayList<SymbolDoc>): Unit {
    finalizeIdentities(symbols, identityTopologyForSymbols(symbols))
}

// Mirror sanitizeTypeRef's identity basis: provider spelling is never source
// truth. Only a resolved canonical type can replace the source spelling in a
// SymbolId; partial/unavailable/ambiguous provider spellings retain source
// overload identity.
private func copySemanticIdentityToDoc(source: SourceDeclaration, semantic: SemanticDeclaration): SymbolDoc {
    let symbol = SymbolDoc(source.kind, source.name, source.packageName, source.moduleId, semantic.visibility,
        source.source, source.sourceSignature, isContainer: source.isContainer, semanticState: semantic.state,
        semanticProvider: semantic.provider, canonicalSignature: semantic.canonicalSignature,
        enumNonExhaustive: source.enumNonExhaustive)
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

private func identityProjection(sourceDeclarations: ArrayList<SourceDeclaration>,
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

private func isConditionallyOwned(source: SourceSnapshot, symbols: ArrayList<SymbolDoc>, index: Int64): Bool {
    var current = index
    var remaining = symbols.size + 1
    while (current >= 0 && current < source.declarations.size && current < symbols.size && remaining > 0) {
        for (annotation in source.declarations[current].annotations) {
            if (isExactWhenAnnotation(annotation)) {
                return true
            }
        }
        current = symbols[current].ownerIndex
        remaining--
    }
    return false
}

private func isOmittedByIndexOrOwner(symbols: ArrayList<SymbolDoc>, index: Int64, omittedIndices: HashSet<Int64>): Bool {
    var current = index
    var remaining = symbols.size + 1
    while (current >= 0 && current < symbols.size && remaining > 0) {
        if (omittedIndices.contains(current)) {
            return true
        }
        current = symbols[current].ownerIndex
        remaining--
    }
    false
}

private func expandOmittedDescendants(symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>): Unit {
    let childrenByOwner = HashMap<Int64, ArrayList<Int64>>()
    var index: Int64 = 0
    while (index < symbols.size) {
        let owner = symbols[index].ownerIndex
        if (owner >= 0) {
            match (childrenByOwner.get(owner)) {
                case Some(children) => children.add(index)
                case None => childrenByOwner[owner] = ArrayList<Int64>([index])
            }
        }
        index++
    }
    let queue = ArrayList<Int64>()
    index = 0
    while (index < symbols.size) {
        if (omittedIndices.contains(index)) {
            queue.add(index)
        }
        index++
    }
    var cursor: Int64 = 0
    while (cursor < queue.size) {
        match (childrenByOwner.get(queue[cursor])) {
            case Some(children) => for (child in children) {
                if (omittedIndices.add(child)) {
                    queue.add(child)
                }
            }
            case None => ()
        }
        cursor++
    }
}

private func duplicatePrunePlan(documentation: DocumentationSet, source: SourceSnapshot): HashSet<Int64> {
    let groups = HashMap<String, ArrayList<Int64>>()
    let duplicateIds = ArrayList<String>()
    var index: Int64 = 0
    while (index < documentation.symbols.size) {
        let id = documentation.symbols[index].id
        match (groups.get(id)) {
            case Some(indices) =>
                indices.add(index)
                if (indices.size == 2) {
                    duplicateIds.add(id)
                }
            case None => groups[id] = ArrayList<Int64>([index])
        }
        index++
    }

    let omittedIndices = HashSet<Int64>()
    for (id in duplicateIds) {
        let indices = groups[id]
        var hasSurvivingCandidate = false
        for (candidate in indices) {
            if (!isOmittedByIndexOrOwner(documentation.symbols, candidate, omittedIndices)) {
                hasSurvivingCandidate = true
                break
            }
        }
        if (!hasSurvivingCandidate) {
            continue
        }
        var conditional = false
        for (candidate in indices) {
            if (!isOmittedByIndexOrOwner(documentation.symbols, candidate, omittedIndices) && isConditionallyOwned(
                source, documentation.symbols, candidate)) {
                conditional = true
                break
            }
        }
        if (conditional) {
            for (candidate in indices) {
                let _ = omittedIndices.add(candidate)
            }
            documentation
                .diagnostics
                .add(
                    Diagnostic("warning", "CJDOC1013",
                        "conditional declaration group omitted because no cfg profile was selected",
                        source: documentation.symbols[indices[1]].source))
            continue
        }

        var kept = false
        for (candidate in indices) {
            if (isOmittedByIndexOrOwner(documentation.symbols, candidate, omittedIndices)) {
                continue
            }
            if (!kept) {
                kept = true
            } else {
                let _ = omittedIndices.add(candidate)
                let symbol = documentation.symbols[candidate]
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("error", "CJDOC1006", "duplicate SymbolId '${symbol.id}'", source: symbol.source,
                            symbolId: symbol.id))
            }
        }
    }
    expandOmittedDescendants(documentation.symbols, omittedIndices)
    omittedIndices
}

private func getDocPackage(documentation: DocumentationSet, moduleId: String, name: String): PackageDoc {
    for (pkg in documentation.packages) {
        if (pkg.moduleId == moduleId && pkg.name == name) {
            return pkg
        }
    }
    let pkg = PackageDoc(name, moduleId)
    documentation.packages.add(pkg)
    return pkg
}

private func survivingIdentityMaps(source: SourceSnapshot, symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>): (HashMap<String,
    String>, HashSet<String>, HashMap<String, String>) {
    let idsBySourceKey = HashMap<String, String>()
    let survivingIds = HashSet<String>()
    let moduleBySymbolId = HashMap<String, String>()
    var index: Int64 = 0
    while (index < source.declarations.size && index < symbols.size) {
        if (!omittedIndices.contains(index)) {
            idsBySourceKey[source.declarations[index].sourceKey] = symbols[index].id
            let _ = survivingIds.add(symbols[index].id)
            moduleBySymbolId[symbols[index].id] = symbols[index].moduleId
        }
        index++
    }
    (idsBySourceKey, survivingIds, moduleBySymbolId)
}

private func recordLateRelationshipViolation(documentation: DocumentationSet, symbol: SymbolDoc, targetId: String): Unit {
    for (binding in documentation.semanticBindings) {
        if (binding.moduleId == symbol.moduleId && binding.provider == symbol.semanticProvider) {
            binding.contractViolations++
            break
        }
    }
    documentation
        .diagnostics
        .add(
            Diagnostic("warning", "CJDOC2017",
                "semantic provider returned an unknown relationship target SymbolId '${targetId}'; " +
                    "relationship downgraded to unavailable", source: symbol.source, symbolId: symbol.id))
}

private class PendingProviderDiagnostic {
    let diagnostic: Diagnostic
    let binding: SemanticBindingStats
    let moduleId: String

    init(diagnostic: Diagnostic, binding: SemanticBindingStats, moduleId: String) {
        this.diagnostic = diagnostic
        this.binding = binding
        this.moduleId = moduleId
    }
}

private func appendProviderDiagnostics(documentation: DocumentationSet, pending: ArrayList<PendingProviderDiagnostic>,
    moduleBySymbolId: HashMap<String, String>): Unit {
    for (entry in pending) {
        let diagnostic = entry.diagnostic
        if (let Some(symbolId) <- diagnostic.symbolId) {
            let belongsToModule = match (moduleBySymbolId.get(symbolId)) {
                case Some(moduleId) => moduleId == entry.moduleId
                case None => false
            }
            if (!belongsToModule) {
                documentation
                    .diagnostics
                    .add(Diagnostic(diagnostic.severity, diagnostic.code, diagnostic.message, source: diagnostic.source))
                recordContractViolation(documentation, entry.binding,
                    "semantic provider diagnostic referenced an unknown or cross-module " + "SymbolId '${symbolId}'; " +
                        "diagnostic retained without a symbol identity", source: diagnostic.source)
                continue
            }
        }
        documentation.diagnostics.add(diagnostic)
    }
}

private func sanitizeDanglingReferences(documentation: DocumentationSet, omittedIndices: HashSet<Int64>,
    survivingIds: HashSet<String>): Unit {
    var index: Int64 = 0
    while (index < documentation.symbols.size) {
        if (!omittedIndices.contains(index)) {
            let symbol = documentation.symbols[index]
            for (relationship in symbol.symbolRelationships) {
                if (relationship.targetSourceKey.isSome()) {
                    continue
                }
                if (let Some(targetId) <- relationship.targetSymbolId) {
                    if (!survivingIds.contains(targetId)) {
                        relationship.state = "unavailable"
                        relationship.targetSymbolId = None
                        recordLateRelationshipViolation(documentation, symbol, targetId)
                    }
                }
            }
        }
        index++
    }

    index = 0
    while (index < documentation.diagnostics.size) {
        let diagnostic = documentation.diagnostics[index]
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!survivingIds.contains(symbolId)) {
                documentation.diagnostics.remove(at: index)
                documentation
                    .diagnostics
                    .add(Diagnostic(diagnostic.severity, diagnostic.code, diagnostic.message, source: diagnostic.source),
                        at: index)
            }
        }
        index++
    }
}

private func removeOmittedSymbols(documentation: DocumentationSet, omittedIndices: HashSet<Int64>): Unit {
    var index = documentation.symbols.size - 1
    while (index >= 0) {
        if (omittedIndices.contains(index)) {
            documentation.symbols.remove(at: index)
        }
        index--
    }
}

private func rebuildPackageSymbolIds(documentation: DocumentationSet): Unit {
    for (pkg in documentation.packages) {
        var index = pkg.symbolIds.size - 1
        while (index >= 0) {
            pkg.symbolIds.remove(at: index);
            index--
        }
    }
    for (symbol in documentation.symbols) {
        getDocPackage(documentation, symbol.moduleId, symbol.packageName).symbolIds.add(symbol.id)
    }
}

class DocumentationBinder {
    public func bind(source: SourceSnapshot, semanticResult: SemanticResult, expectedProvider!: ?String = None): DocumentationSet {
        let documentation = DocumentationSet(source.projectName)
        for (module in source.modules) {
            documentation.modules.add(copyModule(module))
        }
        for (pkg in source.packages) {
            documentation.packages.add(copyPackage(pkg))
        }
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
        for (module in source.modules) {
            let _ = knownModuleIds.add(module.id)
        }
        let reportedByModule = HashMap<String, ModuleSemanticResult>()
        let duplicateModuleResults = HashSet<String>()
        for (moduleResult in semanticResult.modules) {
            if (!knownModuleIds.contains(moduleResult.moduleId)) {
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007",
                            "semantic provider returned a result for an unknown module '${moduleResult.moduleId}'"))
            } else if (reportedByModule.contains(moduleResult.moduleId)) {
                let _ = duplicateModuleResults.add(moduleResult.moduleId)
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007",
                            "semantic provider returned duplicate results for module '${moduleResult.moduleId}'"))
            } else {
                reportedByModule[moduleResult.moduleId] = moduleResult
            }
        }

        let effectiveByModule = HashMap<String, ModuleSemanticResult>()
        let statsByModule = HashMap<String, SemanticBindingStats>()
        let semanticBySource = HashMap<String, SemanticDeclaration>()
        let ambiguousSourceKeys = HashSet<String>()
        let pendingProviderDiagnostics = ArrayList<PendingProviderDiagnostic>()
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
                    fallback
                        .diagnostics
                        .add(
                            Diagnostic("warning", "CJDOC2001",
                                "semantic result is unavailable for module '${module.name}'; AST fallback retained"))
                    fallback
            }
            effectiveByModule[module.id] = moduleResult
            let stats = SemanticBindingStats(module.id, moduleResult.provider, moduleResult.providerVersion,
                moduleResult.capabilities)
            statsByModule[module.id] = stats
            documentation.semanticBindings.add(stats)
            for (diagnostic in moduleResult.diagnostics) {
                pendingProviderDiagnostics.add(PendingProviderDiagnostic(diagnostic, stats, module.id))
            }

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
                        documentation
                            .diagnostics
                            .add(
                                Diagnostic("warning", "CJDOC1007",
                                    "semantic declaration has no matching source declaration"))
                        continue
                }
                if (semantic.moduleId != module.id || original.moduleId != module.id) {
                    stats.extraneous++
                    recordContractViolation(documentation, stats,
                        "semantic declaration crossed its module transaction boundary", source: original.source)
                    continue
                }
                if (semantic.provider != moduleResult.provider) {
                    recordContractViolation(documentation, stats,
                        "semantic declaration provider '${semantic.provider}' does not match result provider '${moduleResult.provider}'")
                    continue
                }
                if (!bindingEnabled) {
                    continue
                }
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
                documentation
                    .diagnostics
                    .add(
                        Diagnostic("warning", "CJDOC1007", "ambiguous Source to semantic binding",
                            source: declaration.source))
                semanticFallback(declaration, moduleResult.provider, "ambiguous")
            } else {
                match (semanticBySource.get(declaration.sourceKey)) {
                    case Some(found) => match (sanitizeSemantic(declaration, found, moduleResult, documentation, stats)) {
                        case Some(sanitized) =>
                            stats.matched++;
                            sanitized
                        case None =>
                            stats.missing++;
                            semanticFallback(declaration, moduleResult.provider, "unavailable")
                    }
                    case None =>
                        stats.missing++
                        documentation
                            .diagnostics
                            .add(
                                Diagnostic("warning", "CJDOC1007", "semantic declaration is unavailable",
                                    source: declaration.source))
                        semanticFallback(declaration, moduleResult.provider, "unavailable")
                }
            }
            let symbol = copySemanticToDoc(declaration, semantic)
            match (semantic.ownerSourceKey) {
                case Some(ownerKey) => match (sourceIndexByKey.get(ownerKey)) {
                    case Some(ownerIndex) => symbol.ownerIndex = ownerIndex
                    case None => documentation
                        .diagnostics
                        .add(
                            Diagnostic("warning", "CJDOC1007", "semantic owner has no matching source declaration",
                                source: declaration.source))
                }
                case None => ()
            }
            documentation.symbols.add(symbol)
        }

        finalizeIdentities(documentation.symbols)
        let omittedIndices = duplicatePrunePlan(documentation, source)
        let (idsBySourceKey, survivingIds, moduleBySymbolId) = survivingIdentityMaps(source, documentation.symbols,
            omittedIndices)
        resolveSymbolRelationshipSourceKeys(documentation.symbols, omittedIndices, idsBySourceKey)
        sanitizeDanglingReferences(documentation, omittedIndices, survivingIds)
        appendProviderDiagnostics(documentation, pendingProviderDiagnostics, moduleBySymbolId)
        removeOmittedSymbols(documentation, omittedIndices)
        rebuildPackageSymbolIds(documentation)
        resolveDocumentationReferences(documentation)
        return documentation
    }
}
