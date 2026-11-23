protected package cjdoc.binding

import std.collection.*

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

protected func renderableSymbolIds(documentation: DocumentationSet, audience: String): HashSet<String> {
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
