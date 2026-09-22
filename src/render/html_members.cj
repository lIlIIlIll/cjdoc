package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal class HtmlMemberEntry {
    let symbol: SymbolDoc
    let origin: String
    let declaredBy: ?SymbolDoc

    init(symbol: SymbolDoc, origin: String, declaredBy: ?SymbolDoc) {
        this.symbol = symbol
        this.origin = origin
        this.declaredBy = declaredBy
    }

    prop groupKey: String { get() {
        let owner = match (declaredBy) {
            case Some(value) => value.id
            case None => ""
        }
        "${origin}:${owner}:${memberSectionTitle(symbol)}"
    } }
}

// Render only relationships explicitly present in Doc IR. A similarly named
// member on a base or extension type is not enough evidence to classify it.
internal class HtmlMemberBrowser {
    let entries = ArrayList<HtmlMemberEntry>()
    private let seen = HashSet<String>()

    init(owner: SymbolDoc, projection: RenderProjection) {
        addOwner(owner, "declared", projection)
        for (relation in owner.symbolRelationships) {
            if (relation.state != "resolved") { continue }
            let id = match (relation.targetSymbolId) {
                case Some(value) => value
                case None => continue
            }
            let target = match (projection.visibleIndex.get(id)) {
                case Some(value) => value
                case None => continue
            }
            if (relation.kind == "extendedBy" && target.kind == "extend") {
                addOwner(target, "extension", projection)
            } else if (relation.kind == "inheritedMember" ||
                relation.kind == "inherits-member") {
                let declaredBy: ?SymbolDoc = match (target.ownerId) {
                    case Some(ownerId) => projection.visibleIndex.get(ownerId)
                    case None => None
                }
                add(target, "inherited", declaredBy)
            }
        }
        sort(entries, lessThan: { left, right =>
            let leftKey = "${left.groupKey}:${left.symbol.name}:${left.symbol.headerSpelling}:${left.symbol.id}"
            let rightKey = "${right.groupKey}:${right.symbol.name}:${right.symbol.headerSpelling}:${right.symbol.id}"
            leftKey < rightKey
        }, stable: true)
    }

    private func add(symbol: SymbolDoc, origin: String, declaredBy: ?SymbolDoc): Unit {
        if (seen.add(symbol.id)) {
            entries.add(HtmlMemberEntry(symbol, origin, declaredBy))
        }
    }

    private func addOwner(owner: SymbolDoc, origin: String, projection: RenderProjection): Unit {
        match (projection.membersByOwner.get(owner.id)) {
            case Some(values) =>
                for (symbol in values) { add(symbol, origin, Some(owner)) }
            case None => ()
        }
    }
}

internal func memberOriginLabel(origin: String, locale: String): String {
    match (origin) {
        case "declared" => label(locale, "Declared", "直接声明")
        case "extension" => label(locale, "Extension", "扩展")
        case _ => label(locale, "Inherited", "继承")
    }
}
