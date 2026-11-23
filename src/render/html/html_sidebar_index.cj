protected package cjdoc.render.html

import cjdoc.render.reading.htmlKindLabel
import cjdoc.render.publication.isTypeDeclaration
import cjdoc.render.routes.{routeKey, symbolAnchor}
import cjdoc.render.codec.{escapeJsonString, nullableString}
import cjdoc.render.foundation.RenderTextBuffer
import cjdoc.model.*
import std.collection.*
import std.sort.*

// Labels are package-scoped: identical extension targets need the same ordinal
// on every page, including when the selected declaration is outside the window.
protected func sidebarPackageLabels(projection: RenderProjection,
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

// JSON object keys are emitted in UTF-8 byte order so the shared navigation
// payload is byte-identical regardless of hash-map iteration order.
internal func byteSequenceCompare(left: String, right: String): Int64 {
    let shared = min(left.size, right.size)
    for (index in 0..shared) {
        let difference = Int64(left[index]) - Int64(right[index])
        if (difference != 0) { return difference }
    }
    left.size - right.size
}

private func sortByteOrdered(values: ArrayList<String>): Unit {
    sort(values, lessThan: { left, right => byteSequenceCompare(left, right) < 0 },
        stable: true)
}

// Only these pages actually render member summaries and therefore own the
// fragments used for their declared and contextual sidebar links.
internal func sidebarMemberEntries(projection: RenderProjection, symbol: SymbolDoc): ?ArrayList<HtmlMemberEntry> {
    if (!isTypeDeclaration(symbol) && symbol.kind != "extend") { return None }
    let entries = projection.members(symbol).entries
    if (entries.isEmpty()) { None } else { Some(entries) }
}

private func appendSidebarTypeEntry(out: RenderTextBuffer, projection: RenderProjection,
    symbol: SymbolDoc, label: String, locale: String): Unit {
    out.append("{\"label\":${escapeJsonString(label)}")
    out.append(",\"kind\":${escapeJsonString(symbol.kind)}")
    out.append(",\"kindLabel\":${escapeJsonString(htmlKindLabel(symbol.kind, locale))}")
    out.append(",\"href\":${escapeJsonString(projection.symbolFileHref(symbol.id))}")
    out.append(",\"members\":[")
    var first = true
    if (let Some(entries) <- sidebarMemberEntries(projection, symbol)) {
        for (entry in entries) {
            if (!first) { out.append(",") }
            first = false
            out.append(escapeJsonString(entry.symbol.id))
        }
    }
    out.append("]}")
}

private func appendSidebarMemberEntry(out: RenderTextBuffer, member: SymbolDoc,
    expandable: Bool, locale: String): Unit {
    out.append("{\"label\":${escapeJsonString(htmlContextLabel(member))}")
    out.append(",\"kind\":${escapeJsonString(member.kind)}")
    out.append(",\"kindLabel\":${escapeJsonString(htmlKindLabel(member.kind, locale))}")
    let owner = if (expandable) { member.ownerId } else { None<String> }
    out.append(",\"anchor\":${escapeJsonString(symbolAnchor(member))},\"ownerId\":${nullableString(owner)}}")
}

private class SidebarIndexInventory {
    let packages = ArrayList<String>()
    let packageTypes = ArrayList<ArrayList<String>>()
    let typeLabels = HashMap<String, String>()
    let members = HashMap<String, SymbolDoc>()

    private func collectMembers(projection: RenderProjection, roots: ArrayList<SymbolDoc>): Unit {
        let branch = ArrayList<SymbolDoc>()
        branch.add(all: roots)
        while (!branch.isEmpty()) {
            let owner = branch[branch.size - 1]
            branch.remove(at: branch.size - 1)
            if (let Some(entries) <- sidebarMemberEntries(projection, owner)) {
                for (entry in entries) {
                    let member = entry.symbol
                    members[member.id] = member
                    if (member.ownerId == Some(owner.id) && sidebarMemberEntries(projection, member).isSome()) {
                        typeLabels[member.id] = htmlContextLabel(member)
                        branch.add(member)
                    }
                }
            }
        }
    }

    func collect(projection: RenderProjection): Unit {
        for (pkg in projection.packages) {
            let labels = sidebarPackageLabels(projection, pkg.source.moduleId,
                pkg.source.name)
            let ids = ArrayList<String>()
            match (projection.topLevelByPackage.get(
                routeKey(pkg.source.moduleId, pkg.source.name))) {
                case Some(symbols) =>
                    for (symbol in symbols) {
                        ids.add(symbol.id)
                        typeLabels[symbol.id] = labels.get(symbol.id).getOrDefault({ => htmlContextLabel(symbol) })
                    }
                    collectMembers(projection, symbols)
                case None => ()
            }
            packages.add(projection.packageFileHref(pkg.source.moduleId, pkg.source.name))
            packageTypes.add(ids)
        }
    }
}

private func appendSidebarDeprecations(out: RenderTextBuffer, projection: RenderProjection): Unit {
    let entries = projection.deprecations().entries
    if (entries.isEmpty()) { return }
    let ids = ArrayList<String>()
    for ((id, _) in entries) { ids.add(id) }
    sortByteOrdered(ids)
    out.append(",\"deprecated\":{")
    var first = true
    for (id in ids) {
        if (!first) { out.append(",") }
        first = false
        out.append(escapeJsonString(id) + ":")
        match (entries[id]) {
            case Some(action) =>
                out.append("{\"label\":${escapeJsonString(action.name)},\"kind\":${escapeJsonString(action.kind)},")
                out.append("\"href\":${escapeJsonString(action.href)}}")
            case None => out.append("null")
        }
    }
    out.append("}")
}

/**
 * Publish only the navigation metadata the lazy sidebar tree needs. Canonical
 * declaration pages, signatures, documentation and the complete member indexes
 * remain server-rendered HTML.
 */
protected func renderSidebarIndexScript(projection: RenderProjection, locale: String): String {
    let inventory = SidebarIndexInventory()
    inventory.collect(projection)
    let out = RenderTextBuffer()
    out.append("globalThis.__CJDOC_SIDEBAR_INDEX__={\"version\":3,\"packages\":[")
    for (index in 0..inventory.packages.size) {
        if (index > 0) { out.append(",") }
        let path = inventory.packages[index]
        let pkg = projection.packages[index]
        out.append("{\"id\":${escapeJsonString(path)}")
        out.append(",\"label\":${escapeJsonString(pkg.source.name)}")
        out.append(",\"href\":${escapeJsonString(path)},\"types\":[")
        let ids = inventory.packageTypes[index]
        for (idIndex in 0..ids.size) {
            if (idIndex > 0) { out.append(",") }
            out.append(escapeJsonString(ids[idIndex]))
        }
        out.append("]}")
    }
    out.append("],\"types\":{")
    let typeIds = ArrayList<String>()
    for ((id, _) in inventory.typeLabels) { typeIds.add(id) }
    sortByteOrdered(typeIds)
    for (index in 0..typeIds.size) {
        if (index > 0) { out.append(",") }
        let id = typeIds[index]
        out.append(escapeJsonString(id) + ":")
        appendSidebarTypeEntry(out, projection, projection.visibleIndex[id],
            inventory.typeLabels[id], locale)
    }
    out.append("},\"members\":{")
    let memberIds = ArrayList<String>()
    for ((id, _) in inventory.members) { memberIds.add(id) }
    sortByteOrdered(memberIds)
    for (index in 0..memberIds.size) {
        if (index > 0) { out.append(",") }
        let id = memberIds[index]
        out.append(escapeJsonString(id) + ":")
        appendSidebarMemberEntry(out, inventory.members[id], inventory.typeLabels.contains(id), locale)
    }
    out.append("}")
    appendSidebarDeprecations(out, projection)
    out.append("};\n")
    out.toString()
}
