package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Labels are package-scoped: identical extension targets need the same ordinal
// on every page, including when the selected declaration is outside the window.
internal func sidebarPackageLabels(projection: RenderProjection,
    moduleId: String, packageName: String): HashMap<String, String> {
    let key = routeKey(moduleId, packageName)
    match (projection.sidebarLabelsByPackage.get(key)) {
        case Some(labels) => return labels
        case None => ()
    }
    let labels = HashMap<String, String>()
    let seen = HashMap<String, Int64>()
    match (projection.topLevelByPackage.get(key)) {
        case Some(symbols) => for (symbol in symbols) {
            var name = if (symbol.kind == "extend") {
                readerSymbolName(symbol)
            } else { htmlContextLabel(symbol) }
            if (symbol.kind == "extend") {
                match (projection.membersByOwner.get(symbol.id)) {
                    case Some(members) =>
                        if (!members.isEmpty()) { name += " · " + htmlContextLabel(members[0]) }
                    case None => ()
                }
            }
            let ordinal = seen.get(name).getOrDefault({ => 0 }) + 1
            seen[name] = ordinal
            if (ordinal > 1) { name += " · #" + ordinal.toString() }
            labels[symbol.id] = name
        }
        case None => ()
    }
    projection.sidebarLabelsByPackage[key] = labels
    labels
}

private func appendSidebarSymbolIds(out: RenderTextBuffer,
    symbols: ReadOnlyList<SymbolDoc>): Unit {
    out.append("[")
    var first = true
    for (symbol in symbols) {
        if (!first) { out.append(",") }
        first = false
        out.append(escapeJsonString(symbol.id))
    }
    out.append("]")
}

// Only navigation metadata is shared. Canonical declaration pages, signatures,
// documentation and the complete package/member indexes remain ordinary HTML.
internal func renderSidebarIndexScript(projection: RenderProjection, locale: String): String {
    let out = RenderTextBuffer()
    out.append("globalThis.__CJDOC_SIDEBAR_INDEX__={\"packages\":{")
    var first = true
    for (pkg in projection.packages) {
        match (projection.topLevelByPackage.get(routeKey(pkg.source.moduleId, pkg.source.name))) {
            case Some(symbols) =>
                if (!first) { out.append(",") }
                first = false
                out.append(escapeJsonString(packagePagePath(pkg.source.moduleId, pkg.source.name)) + ":")
                appendSidebarSymbolIds(out, symbols)
            case None => ()
        }
    }
    out.append("},\"members\":{")
    first = true
    for (owner in projection.visibleSymbols) {
        if (!isTypeDeclaration(owner) && owner.kind != "extend" &&
            projection.membersByOwner.get(owner.id).isNone()) { continue }
        let entries = projection.members(owner).entries
        if (entries.isEmpty()) { continue }
        if (!first) { out.append(",") }
        first = false
        out.append(escapeJsonString(owner.id) + ":[")
        var firstMember = true
        for (entry in entries) {
            if (!firstMember) { out.append(",") }
            firstMember = false
            out.append(escapeJsonString(entry.symbol.id))
        }
        out.append("]")
    }
    out.append("},\"symbols\":{")
    first = true
    for (symbol in projection.visibleSymbols) {
        if (!first) { out.append(",") }
        first = false
        let context = htmlContextLabel(symbol)
        let name = sidebarPackageLabels(projection, symbol.moduleId, symbol.packageName)
            .get(symbol.id).getOrDefault({ => context })
        out.append(escapeJsonString(symbol.id) + ":{\"path\":" +
            escapeJsonString(symbolPagePath(symbol)) + ",\"label\":" + escapeJsonString(name) +
            ",\"context\":" + escapeJsonString(context) + ",\"kind\":" +
            escapeJsonString(htmlKindLabel(symbol.kind, locale)) + ",\"signature\":" +
            escapeJsonString(symbol.headerSpelling) + ",\"anchor\":" +
            escapeJsonString(symbolAnchor(symbol)) + "}")
    }
    out.append("}};\n")
    out.toString()
}
