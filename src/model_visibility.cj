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

func renderableSymbolIds(documentation: DocumentationSet, audience: String): HashSet<String> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.symbols) { index[symbol.id] = symbol }
    let results = HashMap<String, Bool>()
    for (root in documentation.symbols) {
        if (results.contains(root.id)) { continue }
        let path = ArrayList<SymbolDoc>()
        var current: ?SymbolDoc = Some(root)
        var inherited = true
        while (current.isSome()) {
            let symbol = current.getOrThrow()
            match (results.get(symbol.id)) {
                case Some(value) =>
                    inherited = value
                    break
                case None => ()
            }
            path.add(symbol)
            let visible = match (audience) {
                case "external" => symbol.visibility == "public" || symbol.visibility == "protected"
                case "package" => symbol.visibility != "private"
                case "all" => true
                case _ => false
            }
            if (!visible) {
                inherited = false
                break
            }
            current = match (symbol.ownerId) {
                case Some(ownerId) => index.get(ownerId)
                case None => None
            }
        }
        var position = path.size
        while (position > 0) {
            position--
            let symbol = path[position]
            let visible = match (audience) {
                case "external" => symbol.visibility == "public" || symbol.visibility == "protected"
                case "package" => symbol.visibility != "private"
                case "all" => true
                case _ => false
            }
            inherited = inherited && visible
            results[symbol.id] = inherited
        }
    }
    let visible = HashSet<String>()
    for (symbol in documentation.symbols) {
        match (results.get(symbol.id)) {
            case Some(value) => if (value) { let _ = visible.add(symbol.id) }
            case None => ()
        }
    }
    visible
}
