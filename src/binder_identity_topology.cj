package cjdoc

import std.collection.*
import std.sort.*

internal class IdentityTopology {
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

internal func identityTopologyForSymbols(symbols: ArrayList<SymbolDoc>): IdentityTopology {
    let ownerIndices = Array<Int64>(symbols.size, repeat: -1)
    var index: Int64 = 0
    while (index < symbols.size) {
        ownerIndices[index] = symbols[index].ownerIndex
        index++
    }
    IdentityTopology(ownerIndices)
}

internal func identityTopologyForSources(sourceDeclarations: ArrayList<SourceDeclaration>): IdentityTopology {
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
internal class IdentityGenericScope {
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

internal func identityGenericScopes(symbols: ArrayList<SymbolDoc>, topology: IdentityTopology): Array<IdentityGenericScope> {
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

internal func identityIdentifierByte(value: UInt8): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') || (value >= b'0' && value <= b'9') || value ==
        b'_' || value >= 0x80u8
}

internal func alphaNormalizedIdentitySpelling(value: String, scope: IdentityGenericScope): String {
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

internal func identityOwnerName(symbol: SymbolDoc, scope: IdentityGenericScope): String {
    if (symbol.kind == "extend") {
        alphaNormalizedIdentitySpelling(symbol.name, scope)
    } else {
        symbol.name
    }
}

internal func privateFileScope(symbol: SymbolDoc): String {
    "::file:" + percentEscapeSymbolPart(symbol.source.path)
}

// Cache the owner path including each symbol. Every owner edge is traversed
// once; constructing the cached strings is proportional to the prefixes that
// are necessarily emitted into SymbolId and qualifiedName.
internal func ensureOwnerPrefixes(symbols: ArrayList<SymbolDoc>, index: Int64, identityScopes: Array<String>,
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

internal func ownerIdentityScope(symbols: ArrayList<SymbolDoc>, index: Int64, identityScopes: Array<String>,
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

internal func identityType(typeRef: TypeRef): String {
    match (typeRef.canonical) {
        case Some(canonical) =>
            if (typeRef.state == "resolved") {
                return canonical
            }
        case None => ()
    }
    return typeRef.display
}

internal func memberIdentity(symbol: SymbolDoc, scope: IdentityGenericScope): String {
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

internal func extendIdentityName(symbols: ArrayList<SymbolDoc>, extendIndex: Int64, topology: IdentityTopology,
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

