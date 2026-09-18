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
private func navigationTypeKey(value: String): String {
    value.trimAscii().replace(" ", "").replace("\t", "")
}

private func navigationTypeMatches(left: TypeRef, right: TypeRef): Bool {
    if (left.kind != right.kind || left.nullable != right.nullable ||
        left.arguments.size != right.arguments.size) { return false }
    let spellingMatches = navigationTypeKey(left.display) == navigationTypeKey(right.display)
    let canonicalMatches = match ((left.canonical, right.canonical)) {
        case (Some(leftCanonical), Some(rightCanonical)) =>
            navigationTypeKey(leftCanonical) == navigationTypeKey(rightCanonical)
        case _ => false
    }
    if (!spellingMatches && !canonicalMatches) { return false }
    var index: Int64 = 0
    while (index < left.arguments.size) {
        if (!navigationTypeMatches(left.arguments[index], right.arguments[index])) { return false }
        index++
    }
    true
}

private func navigationParameterSignaturesMatch(left: SymbolDoc, right: SymbolDoc): Bool {
    if (left.parameters.size != right.parameters.size) { return false }
    var index: Int64 = 0
    while (index < left.parameters.size) {
        if (!navigationTypeMatches(left.parameters[index].typeRef, right.parameters[index].typeRef)) {
            return false
        }
        index++
    }
    true
}

private func navigationRelationshipName(display: String): String {
    match (display.indexOf("(")) {
        case Some(index) => display[..index].trimAscii()
        case None => display.trimAscii()
    }
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
    if (head == candidate.name || head == "${candidate.packageName}.${candidate.name}") { return true }
    head.endsWith(".${candidate.name}") && candidate.packageName == owner.packageName
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

private func hasRelationship(symbol: SymbolDoc, kind: String, display: String): Bool {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind == kind && relationship.targetDisplay == display) { return true }
    }
    false
}
private func setNavigationRelationship(symbol: SymbolDoc, kind: String, display: String,
    target: NavigationTarget): Unit {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind != kind || relationship.targetDisplay != display) { continue }
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
    match (target.symbolId) {
        case Some(id) =>
            for (relationship in symbol.symbolRelationships) {
                match (relationship.targetSymbolId) {
                    case Some(existingId) => if (existingId == id) { return }
                    case None => ()
                }
            }
        case None => ()
    }
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
    kind: String, display: String, sourceId: String): Unit {
    for (target in symbols) {
        if (target.id != targetId) { continue }
        if (!hasRelationship(target, kind, display)) {
            target.symbolRelationships.add(
                SymbolRelationship(kind, display, "resolved", targetSymbolId: Some(sourceId)))
        }
        return
    }
}

private func resolveSourceTypeRelations(source: SourceSnapshot, documentation: DocumentationSet,
    idsBySourceKey: HashMap<String, String>): Unit {
    var index: Int64 = 0
    while (index < source.declarations.size && index < documentation.symbols.size) {
        let sourceDeclaration = source.declarations[index]
        let symbol = documentation.symbols[index]
        if (supportsNavigation(documentation, symbol.moduleId)) {
            for (relationship in sourceDeclaration.relationships) {
                let target = findNavigationTarget(relationship.targetSpelling, sourceDeclaration, source,
                    idsBySourceKey)
                setNavigationRelationship(symbol, relationship.kind, relationship.targetSpelling, target)
                match (target.symbolId) {
                    case Some(targetId) => match (reverseKind(relationship.kind)) {
                        case Some(reverse) => addReverseRelationship(documentation.symbols, targetId, reverse,
                            symbol.qualifiedName, symbol.id)
                        case None => ()
                    }
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

private func resolveOverrideRelations(documentation: DocumentationSet): Unit {
    for (symbol in documentation.symbols) {
        for (relationship in symbol.symbolRelationships) {
            if (relationship.kind != "override" || relationship.targetSymbolId.isSome()) { continue }
            let owner = match (ownerSymbol(documentation.symbols, symbol)) {
                case Some(value) => value
                case None => continue
            }
            let matches = ArrayList<SymbolDoc>()
            for (parent in owner.symbolRelationships) {
                if (parent.kind != "superType" && parent.kind != "extensionTarget") { continue }
                match (parent.targetSymbolId) {
                    case Some(parentId) =>
                        for (candidate in documentation.symbols) {
                            match (candidate.ownerId) {
                                case Some(ownerId) =>
                                    if (ownerId == parentId &&
                                        candidate.name == navigationRelationshipName(relationship.targetDisplay) &&
                                        navigationParameterSignaturesMatch(symbol, candidate)) { matches.add(candidate) }
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
                    symbol.qualifiedName, symbol.id)
            } else if (matches.size > 1) {
                relationship.state = "ambiguous"
                relationship.targetSymbolId = None
            }
        }
    }
}

private func resolveProviderReverseRelations(documentation: DocumentationSet): Unit {
    for (symbol in documentation.symbols) {
        for (relationship in symbol.symbolRelationships) {
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (reverseKind(relationship.kind)) {
                    case Some(reverse) => addReverseRelationship(documentation.symbols, targetId, reverse,
                        symbol.qualifiedName, symbol.id)
                    case None => ()
                }
                case None => ()
            }
        }
    }
}

internal func resolveNavigationRelations(source: SourceSnapshot, documentation: DocumentationSet,
    idsBySourceKey: HashMap<String, String>): Unit {
    resolveSourceTypeRelations(source, documentation, idsBySourceKey)
    resolveOverrideRelations(documentation)
    resolveProviderReverseRelations(documentation)
}
