package cjdoc

import std.collection.*

func retainPublicApi(documentation: DocumentationSet): Unit {
    let kept = HashSet<String>()
    for (symbol in documentation.symbols) {
        if (symbol.ownerId.isNone() && isExternallyVisible(symbol)) { let _ = kept.add(symbol.id) }
    }
    for (symbol in documentation.symbols where symbol.kind == "extend") {
        for (member in documentation.symbols) {
            if (member.ownerId == Some(symbol.id) && isExternallyVisible(member)) {
                let _ = kept.add(symbol.id)
                break
            }
        }
    }
    var changed = true
    while (changed) {
        changed = false
        for (symbol in documentation.symbols) {
            if (!kept.contains(symbol.id) && isExternallyVisible(symbol)) {
                match (symbol.ownerId) {
                    case Some(owner) =>
                        if (kept.contains(owner)) {
                            let _ = kept.add(symbol.id)
                            changed = true
                        }
                    case None => ()
                }
            }
        }
    }
    var index = documentation.symbols.size - 1
    while (index >= 0) {
        if (!kept.contains(documentation.symbols[index].id)) {
            documentation.symbols.remove(at: index)
        }
        index--
    }
    for (pkg in documentation.packages) {
        index = pkg.symbolIds.size - 1
        while (index >= 0) {
            if (!kept.contains(pkg.symbolIds[index])) { pkg.symbolIds.remove(at: index) }
            index--
        }
    }
    index = documentation.diagnostics.size - 1
    while (index >= 0) {
        if (let Some(symbolId) <- documentation.diagnostics[index].symbolId) {
            if (!kept.contains(symbolId)) { documentation.diagnostics.remove(at: index) }
        }
        index--
    }
    resolveDocumentationReferences(documentation)
}

private func visibleForAudience(symbol: SymbolDoc, audience: String): Bool {
    match (audience) {
        case "external" => symbol.visibility == "public" || symbol.visibility == "protected"
        case "package" => symbol.visibility != "private"
        case "all" => true
        case _ => false
    }
}

private func indexSymbolsById(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let result = HashMap<String, SymbolDoc>()
    for (symbol in documentation.symbols) { result[symbol.id] = symbol }
    result
}

func renderableSymbolIds(documentation: DocumentationSet, audience: String): HashSet<String> {
    let visible = HashSet<String>()
    let symbolsById = indexSymbolsById(documentation)
    for (symbol in documentation.symbols) {
        var current: ?SymbolDoc = Some(symbol)
        var renderable = true
        while (current.isSome()) {
            let currentSymbol = current.getOrThrow()
            if (!visibleForAudience(currentSymbol, audience)) {
                renderable = false
                break
            }
            current = match (currentSymbol.ownerId) {
                case Some(ownerId) => symbolsById.get(ownerId)
                case None => None
            }
        }
        if (renderable) { let _ = visible.add(symbol.id) }
    }
    visible
}
