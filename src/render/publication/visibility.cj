protected package cjdoc.render.publication

import cjdoc.model.*
import cjdoc.render.foundation.isVisibleForAudience
import cjdoc.render.codec.isDocIrContainerKind
import std.collection.*

protected func isContainerDeclaration(symbol: SymbolDoc): Bool {
    isDocIrContainerKind(symbol.kind)
}

protected func indexSymbols(documentation: DocumentationSet): HashMap<String, SymbolDoc> {
    let index = HashMap<String, SymbolDoc>()
    for (symbol in documentation.declarations) { index[symbol.id] = symbol }
    index
}

private func visibleThroughOwners(symbol: SymbolDoc, audience: String,
    index: HashMap<String, SymbolDoc>): Bool {
    var current: ?SymbolDoc = Some(symbol)
    let visited = HashSet<String>()
    while (current.isSome()) {
        let value = current.getOrThrow()
        if (!visited.add(value.id)) { return false }
        if (!isVisibleForAudience(value, audience)) { return false }
        current = match (value.ownerId) {
            case Some(ownerId) => index.get(ownerId)
            case None => None
        }
    }
    true
}

private func addVisibleOwnerId(values: HashSet<String>, ownerId: String): Unit {
    let _ = values.add(ownerId)
}

protected func visibleExtensionContainerIds(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashSet<String> {
    let audience = documentation.configuration.audience
    let ownersWithVisibleMembers = HashSet<String>()
    for (member in documentation.declarations) {
        if (!isVisibleForAudience(member, audience)) { continue }
        match (member.ownerId) {
            case Some(ownerId) => addVisibleOwnerId(ownersWithVisibleMembers, ownerId)
            case None => ()
        }
    }
    let result = HashSet<String>()
    for (extension in documentation.declarations) {
        if (extension.kind != "extend" || !ownersWithVisibleMembers.contains(extension.id)) {
            continue
        }
        for (relation in extension.symbolRelationships) {
            if (relation.kind != "extensionTarget" || relation.state != "resolved") { continue }
            match (relation.targetSymbolId) {
                case Some(targetId) => match (index.get(targetId)) {
                    case Some(target) =>
                        if (visibleThroughOwners(target, audience, index)) {
                            let _ = result.add(extension.id)
                            break
                        }
                    case None => ()
                }
                case None => ()
            }
        }
    }
    result
}

protected func renderabilityIndex(documentation: DocumentationSet,
    index: HashMap<String, SymbolDoc>): HashMap<String, Bool> {
    let results = HashMap<String, Bool>()
    let visibleExtensionContainers = visibleExtensionContainerIds(documentation, index)
    for (root in documentation.declarations) {
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
            if (!isVisibleForAudience(symbol, documentation.configuration.audience) &&
                !visibleExtensionContainers.contains(symbol.id)) {
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
            inherited = inherited &&
                (isVisibleForAudience(symbol, documentation.configuration.audience) ||
                    visibleExtensionContainers.contains(symbol.id))
            results[symbol.id] = inherited
        }
    }
    results
}

protected func isTypeDeclaration(symbol: SymbolDoc): Bool {
    symbol.kind == "class" || symbol.kind == "struct" || symbol.kind == "interface" ||
        symbol.kind == "enum" || symbol.kind == "typeAlias"
}
