package cjdoc

import std.collection.*

internal func isConditionallyOwned(source: SourceSnapshot, symbols: ArrayList<SymbolDoc>, index: Int64): Bool {
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

internal func isOmittedByIndexOrOwner(symbols: ArrayList<SymbolDoc>, index: Int64, omittedIndices: HashSet<Int64>): Bool {
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

internal func expandOmittedDescendants(symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>): Unit {
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

internal func duplicatePrunePlan(documentation: DocumentationSet, source: SourceSnapshot): HashSet<Int64> {
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

internal func getDocPackage(documentation: DocumentationSet, moduleId: String, name: String): PackageDoc {
    for (pkg in documentation.packages) {
        if (pkg.moduleId == moduleId && pkg.name == name) {
            return pkg
        }
    }
    let pkg = PackageDoc(name, moduleId)
    documentation.packages.add(pkg)
    return pkg
}

internal func survivingIdentityMaps(source: SourceSnapshot, symbols: ArrayList<SymbolDoc>, omittedIndices: HashSet<Int64>): (HashMap<String,
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

internal func recordLateRelationshipViolation(documentation: DocumentationSet, symbol: SymbolDoc, targetId: String): Unit {
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

internal class PendingProviderDiagnostic {
    let diagnostic: Diagnostic
    let binding: SemanticBindingStats
    let moduleId: String

    init(diagnostic: Diagnostic, binding: SemanticBindingStats, moduleId: String) {
        this.diagnostic = diagnostic
        this.binding = binding
        this.moduleId = moduleId
    }
}

internal func appendProviderDiagnostics(documentation: DocumentationSet, pending: ArrayList<PendingProviderDiagnostic>,
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

internal func sanitizeDanglingReferences(documentation: DocumentationSet, omittedIndices: HashSet<Int64>,
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

internal func removeOmittedSymbols(documentation: DocumentationSet, omittedIndices: HashSet<Int64>): Unit {
    var index = documentation.symbols.size - 1
    while (index >= 0) {
        if (omittedIndices.contains(index)) {
            documentation.symbols.remove(at: index)
        }
        index--
    }
}

internal func rebuildPackageSymbolIds(documentation: DocumentationSet): Unit {
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
