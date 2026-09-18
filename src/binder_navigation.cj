package cjdoc

import std.collection.*

internal class NavigationTarget {
    public let symbolId: ?String
    public let ambiguous: Bool

    init(symbolId: ?String, ambiguous!: Bool = false) {
        this.symbolId = symbolId
        this.ambiguous = ambiguous
    }
}

private func navigationHead(spelling: String): String {
    var head = spelling.trimAscii()
    match (head.indexOf("<")) {
        case Some(index) => head = head[..index].trimAscii()
        case None => ()
    }
    if (head.endsWith("?")) { head = head[..head.size - 1].trimAscii() }
    head
}

private func typeTargetCandidate(candidate: SourceDeclaration): Bool {
    candidate.kind == "class" || candidate.kind == "struct" ||
        candidate.kind == "interface" || candidate.kind == "enum"
}

private func matchesNavigationTarget(spelling: String, owner: SourceDeclaration,
    candidate: SourceDeclaration): Bool {
    if (candidate.sourceKey == owner.sourceKey || candidate.moduleId != owner.moduleId ||
        !typeTargetCandidate(candidate)) { return false }
    let head = navigationHead(spelling)
    if (!head.contains(".") && candidate.packageName != owner.packageName) { return false }
    head == candidate.name || head == "${candidate.packageName}.${candidate.name}"
}

private func navigationScore(spelling: String, owner: SourceDeclaration,
    candidate: SourceDeclaration): Int64 {
    let head = navigationHead(spelling)
    var score: Int64 = if (candidate.packageName == owner.packageName) { 4 } else { 1 }
    if (head == "${candidate.packageName}.${candidate.name}") { score += 4 }
    if (head == candidate.name) { score += 2 }
    score
}

private func unavailableNavigationTarget(ambiguous!: Bool = false): NavigationTarget {
    let noId: ?String = None
    NavigationTarget(noId, ambiguous: ambiguous)
}

private func findNavigationTarget(spelling: String, owner: SourceDeclaration,
    source: SourceSnapshot, idsBySourceKey: HashMap<String, String>): NavigationTarget {
    var bestScore: Int64 = -1
    var best = ArrayList<Int64>()
    var index: Int64 = 0
    while (index < source.declarations.size) {
        let candidate = source.declarations[index]
        if (!matchesNavigationTarget(spelling, owner, candidate)) {
            index++
            continue
        }
        let score = navigationScore(spelling, owner, candidate)
        if (score > bestScore) {
            bestScore = score
            best = ArrayList<Int64>([index])
        } else if (score == bestScore) {
            best.add(index)
        }
        index++
    }
    if (best.isEmpty()) { return unavailableNavigationTarget() }
    if (best.size > 1) { return unavailableNavigationTarget(ambiguous: true) }
    match (idsBySourceKey.get(source.declarations[best[0]].sourceKey)) {
        case Some(id) => NavigationTarget(Some(id))
        case None => unavailableNavigationTarget()
    }
}

private func supportsNavigation(documentation: DocumentationSet, moduleId: String): Bool {
    for (binding in documentation.semanticBindings) {
        if (binding.moduleId == moduleId) { return binding.capabilities.symbolRelationships }
    }
    false
}

private func targetSupportsNavigation(documentation: DocumentationSet, targetId: String,
    omittedIndices: HashSet<Int64>): Bool {
    var index: Int64 = 0
    for (target in documentation.symbols) {
        if (!omittedIndices.contains(index) && target.id == targetId) {
            return supportsNavigation(documentation, target.moduleId)
        }
        index++
    }
    false
}
private func hasReverseRelationship(symbol: SymbolDoc, kind: String, display: String,
    sourceId: String): Bool {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind == kind && relationship.targetDisplay == display &&
            relationship.targetSymbolId == Some(sourceId)) { return true }
    }
    false
}
private func setNavigationRelationship(symbol: SymbolDoc, kind: String, display: String,
    target: NavigationTarget): Unit {
    var unavailableIndex: Int64 = -1
    var found = false
    var index: Int64 = 0
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind != kind || relationship.targetDisplay != display) {
            index++
            continue
        }
        found = true
        if (relationship.state == "resolved" || relationship.targetSymbolId.isSome()) {
            // A provider-supplied identity, including a non-resolved one, is
            // authoritative. AST name matching must not redirect it.
            return
        }
        if (relationship.state == "unavailable") {
            unavailableIndex = index
        }
        index++
    }
    if (unavailableIndex >= 0) {
        let relationship = symbol.symbolRelationships[unavailableIndex]
        match (target.symbolId) {
            case Some(id) =>
                relationship.state = "resolved"
                relationship.targetSymbolId = Some(id)
            case None => if (target.ambiguous) {
                relationship.state = "ambiguous"
                relationship.targetSymbolId = None
            }
        }
        return
    }
    if (found) { return }
    match (target.symbolId) {
        case Some(id) => symbol.symbolRelationships.add(
            SymbolRelationship(kind, display, "resolved", targetSymbolId: Some(id)))
        case None => if (target.ambiguous) {
            symbol.symbolRelationships.add(SymbolRelationship(kind, display, "ambiguous"))
        }
    }
}

private func reverseKind(kind: String): ?String {
    match (kind) {
        case "superType" => Some("subType")
        case "implements" => Some("implementedBy")
        case "extensionTarget" => Some("extendedBy")
        case "override" => Some("overriddenBy")
        case _ => None
    }
}

private func addReverseRelationship(symbols: ArrayList<SymbolDoc>, targetId: String,
    kind: String, display: String, sourceId: String, documentation: DocumentationSet,
    omittedIndices: HashSet<Int64>): Unit {
    if (!targetSupportsNavigation(documentation, targetId, omittedIndices)) { return }
    var index: Int64 = 0
    for (target in symbols) {
        if (!omittedIndices.contains(index) && target.id == targetId) {
            if (!hasReverseRelationship(target, kind, display, sourceId)) {
                target.symbolRelationships.add(
                    SymbolRelationship(kind, display, "resolved", targetSymbolId: Some(sourceId)))
            }
            return
        }
        index++
    }
}

private func addResolvedReverseRelationships(documentation: DocumentationSet, symbol: SymbolDoc,
    kind: String, display: String, reverse: String, omittedIndices: HashSet<Int64>): Unit {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind != kind || relationship.targetDisplay != display ||
            relationship.state != "resolved") { continue }
        match (relationship.targetSymbolId) {
            case Some(targetId) => addReverseRelationship(documentation.symbols, targetId, reverse,
                symbol.qualifiedName, symbol.id, documentation, omittedIndices)
            case None => ()
        }
    }
}

private func resolveSourceTypeRelations(source: SourceSnapshot, documentation: DocumentationSet,
    idsBySourceKey: HashMap<String, String>, omittedIndices: HashSet<Int64>): Unit {
    var index: Int64 = 0
    while (index < source.declarations.size && index < documentation.symbols.size) {
        if (omittedIndices.contains(index)) {
            index++
            continue
        }
        let sourceDeclaration = source.declarations[index]
        let symbol = documentation.symbols[index]
        if (supportsNavigation(documentation, symbol.moduleId)) {
            for (relationship in sourceDeclaration.relationships) {
                let target = findNavigationTarget(relationship.targetSpelling, sourceDeclaration, source,
                    idsBySourceKey)
                setNavigationRelationship(symbol, relationship.kind, relationship.targetSpelling, target)
                match (reverseKind(relationship.kind)) {
                    case Some(reverse) => addResolvedReverseRelationships(documentation, symbol,
                        relationship.kind, relationship.targetSpelling, reverse, omittedIndices)
                    case None => ()
                }
            }
        }
        index++
    }
}

private func ownerSymbol(symbols: ArrayList<SymbolDoc>, symbol: SymbolDoc): ?SymbolDoc {
    match (symbol.ownerId) {
        case Some(ownerId) =>
            for (candidate in symbols) {
                if (candidate.id == ownerId) { return Some(candidate) }
            }
            None
        case None => None
    }
}

private func resolveOverrideRelations(documentation: DocumentationSet,
    omittedIndices: HashSet<Int64>): Unit {
    var symbolIndex: Int64 = 0
    while (symbolIndex < documentation.symbols.size) {
        let symbol = documentation.symbols[symbolIndex]
        if (omittedIndices.contains(symbolIndex)) {
            symbolIndex++
            continue
        }
        if (symbol.semanticProvider == "ast" || !supportsNavigation(documentation, symbol.moduleId)) {
            symbolIndex++
            continue
        }
        for (relationship in symbol.symbolRelationships) {
            if (relationship.kind != "override" || relationship.targetSymbolId.isSome()) { continue }
            let owner = match (ownerSymbol(documentation.symbols, symbol)) {
                case Some(value) => value
                case None => continue
            }
            let matches = ArrayList<SymbolDoc>()
            for (parent in owner.symbolRelationships) {
                if (parent.kind != "superType" && parent.kind != "extensionTarget") { continue }
                if (parent.state != "resolved") { continue }
                match (parent.targetSymbolId) {
                    case Some(parentId) =>
                        for (candidate in documentation.symbols) {
                            match (candidate.ownerId) {
                                case Some(ownerId) => if (ownerId == parentId &&
                                    candidate.name == relationship.targetDisplay) { matches.add(candidate) }
                                case None => ()
                            }
                        }
                    case None => ()
                }
            }
            if (matches.size == 1) {
                relationship.state = "resolved"
                relationship.targetSymbolId = Some(matches[0].id)
                addReverseRelationship(documentation.symbols, matches[0].id, "overriddenBy",
                    symbol.qualifiedName, symbol.id, documentation, omittedIndices)
            } else if (matches.size > 1) {
                relationship.state = "ambiguous"
                relationship.targetSymbolId = None
            }
        }
        symbolIndex++
    }
}

private func resolveProviderReverseRelations(documentation: DocumentationSet,
    omittedIndices: HashSet<Int64>): Unit {
    var symbolIndex: Int64 = 0
    while (symbolIndex < documentation.symbols.size) {
        let symbol = documentation.symbols[symbolIndex]
        if (omittedIndices.contains(symbolIndex)) {
            symbolIndex++
            continue
        }
        if (!supportsNavigation(documentation, symbol.moduleId)) {
            symbolIndex++
            continue
        }
        for (relationship in symbol.symbolRelationships) {
            if (relationship.state != "resolved") { continue }
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (reverseKind(relationship.kind)) {
                    case Some(reverse) => addReverseRelationship(documentation.symbols, targetId, reverse,
                        symbol.qualifiedName, symbol.id, documentation, omittedIndices)
                    case None => ()
                }
                case None => ()
            }
        }
        symbolIndex++
    }
}

internal func resolveNavigationRelations(source: SourceSnapshot, documentation: DocumentationSet,
    idsBySourceKey: HashMap<String, String>, omittedIndices: HashSet<Int64>): Unit {
    resolveSourceTypeRelations(source, documentation, idsBySourceKey, omittedIndices)
    resolveOverrideRelations(documentation, omittedIndices)
    resolveProviderReverseRelations(documentation, omittedIndices)
}
