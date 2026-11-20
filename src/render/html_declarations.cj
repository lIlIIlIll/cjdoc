package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func packageDeclarationCategory(kind: String): String {
    match (kind) {
        case "class" | "struct" | "interface" | "enum" | "typeAlias" |
            "function" | "macro" | "property" | "variable" | "extend" => kind
        case _ => "other"
    }
}

internal func packageDeclarationHeading(category: String, locale: String): (String, String) {
    match (category) {
        case "class" => ("classes", label(locale, "Classes", "类"))
        case "struct" => ("structs", label(locale, "Structs", "结构体"))
        case "interface" => ("interfaces", label(locale, "Interfaces", "接口"))
        case "enum" => ("enums", label(locale, "Enums", "枚举"))
        case "typeAlias" => ("aliases", label(locale, "Type aliases", "类型别名"))
        case "function" => ("functions", label(locale, "Functions", "函数"))
        case "macro" => ("macros", label(locale, "Macros", "宏"))
        case "property" => ("properties", label(locale, "Properties", "属性"))
        case "variable" => ("variables", label(locale, "Variables", "变量"))
        case "extend" => ("extensions", label(locale, "Extensions", "扩展"))
        case _ => ("others", label(locale, "Other declarations", "其他声明"))
    }
}

private func declarationRowSummary(symbol: SymbolDoc): String {
    match (symbol.documentation) {
        case Some(comment) => summaryPlainText(comment)
        case None => ""
    }
}

// Display-only soft-break opportunities at the label's own generated lists: the
// generic parameter list and the parameter list, plus the separators inside
// them. The text stays byte-identical (copy, identity and signatures never pass
// through here), nested parentheses in default expressions get no breaks, and
// an empty list is never split.
internal func appendSoftWrappedLabel(w: HtmlWriter, value: String): Unit {
    var start = 0
    var index = 0
    var depth = 0
    while (index < value.size) {
        let byte = value[index]
        var breakAfter = false
        if ((byte == b'(' || byte == b'<') && depth == 0) {
            if (index + 1 < value.size) {
                let next = value[index + 1]
                breakAfter = next != b')' && next != b'>'
            }
            depth = 1
        } else if (byte == b'(' || byte == b'<') {
            depth++
        } else if (byte == b')' || byte == b'>') {
            if (depth > 0) { depth-- }
        } else if (byte == b',' && depth == 1 && index + 1 < value.size && value[index + 1] == b' ') {
            index++
            breakAfter = true
        }
        if (breakAfter) {
            w.text(value[start..index + 1])
            w.void("wbr")
            start = index + 1
        }
        index++
    }
    if (start < value.size) { w.text(value[start..]) }
}

// A compact row: name links to the declaration page and the one-paragraph
// summary replaces the old row-level signature. The name is the navigation
// label shared with the sidebar, so overloads and repeated extensions stay
// distinguishable without a signature column. The row itself is the outline
// target, so a table of contents entry points at the visible declaration rather
// than at the source header or a table ordinal.
private func appendDeclarationRow(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, locale: String, rootPrefix: String, showKind: Bool): Unit {
    let name = sidebarPackageLabels(projection, symbol.moduleId, symbol.packageName)
        .get(symbol.id).getOrDefault({ => readerDeclarationName(symbol) })
    // Attribute order keeps the historical row prefix these pages have always
    // published; the row anchor and outline role follow the member metadata.
    w.open("tr", attrs: [htmlClass("cj-decl-table__row"),
        htmlFlag("data-cjdoc-member"),
        htmlAttr("data-member-symbol-id", symbol.id),
        htmlAttr("data-member-name", symbol.name),
        htmlAttr("data-member-kind", symbol.kind),
        htmlAttr("id", symbolAnchor(symbol)),
        htmlAttr("data-cjdoc-toc-role", "entry")])
    w.element("td", [htmlClass("cj-decl-table__name")]) { cell =>
        cell.element("a", [htmlClass("cj-decl-table__link"),
            htmlHref(SafeUrl.siteRoute(projection.publicSymbolHref(rootPrefix, symbol.id))),
            htmlFlag("data-cjdoc-api-link")]) { link =>
            link.open("code")
            appendSoftWrappedLabel(link, name)
            link.close("code")
        }
        // The kind appears once per section; a merged author-group heading
        // (or a hidden kind heading) no longer states it, so the row then
        // carries the small label itself instead of a whole column.
        if (showKind) {
            cell.textElement("span", htmlKindLabel(symbol.kind, locale), attrs: [
                htmlClass("cj-kind cj-decl-table__kind"), htmlAttr("data-kind", symbol.kind)])
        }
        appendDeprecationBadgeFor(cell, projection, symbol, locale)
        appendDeclarationClassificationBadges(cell, projection.catalog, projection.snapshotId,
            symbol, rootPrefix, includeGroup: false)
    }
    w.element("td", [htmlClass("cj-decl-table__summary")]) { cell =>
        cell.text(declarationRowSummary(symbol))
        if (let Some(action) <- projection.deprecations().action(symbol.id)) {
            // The migration action owns a line of its own instead of trailing
            // the summary text or sharing the name cell.
            cell.element("div", [htmlClass("cj-decl-table__replacement")]) { line =>
                appendReplacementLink(line, action, projection, rootPrefix, locale)
            }
        }
    }
    w.close("tr")
    w.newline()
}

private let PACKAGE_DECLARATION_CATEGORY_ORDER = ["class", "struct", "interface", "enum",
    "typeAlias", "function", "macro", "property", "variable", "extend", "other"]

/**
 * Partition `symbols` by the published declaration category, in the fixed
 * reading order. The result comes from the audience/cfg projection only, so a
 * hidden member can never create a category or inflate a count.
 */
internal func packageDeclarationCategories(symbols: ArrayList<SymbolDoc>):
    (ArrayList<(String, ArrayList<SymbolDoc>)>, HashMap<String, String>) {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    let kindByName = HashMap<String, String>()
    for (symbol in symbols) {
        let category = packageDeclarationCategory(symbol.kind)
        match (groups.get(category)) {
            case Some(group) => group.add(symbol)
            case None => groups[category] = ArrayList<SymbolDoc>([symbol])
        }
        match (kindByName.get(symbol.name)) {
            case Some(kind) => if (kind != symbol.kind) { kindByName[symbol.name] = "" }
            case None => kindByName[symbol.name] = symbol.kind
        }
    }
    let ordered = ArrayList<(String, ArrayList<SymbolDoc>)>()
    for (category in PACKAGE_DECLARATION_CATEGORY_ORDER) {
        match (groups.get(category)) {
            case Some(group) => ordered.add((category, group))
            case None => continue
        }
    }
    (ordered, kindByName)
}

// `showKind` mirrors the rendered section above the table: when a visible kind
// heading already says "Functions", the column would repeat it on every row.
private func appendDeclarationTable(w: HtmlWriter, projection: RenderProjection,
    symbols: ArrayList<SymbolDoc>, locale: String, rootPrefix: String,
    showKind: Bool): Unit {
    w.open("table", attrs: [htmlClass("cj-decl-table")])
    w.open("thead", attrs: [htmlClass("cj-sr-only")])
    w.open("tr")
    for (column in [label(locale, "Name", "名称"), label(locale, "Summary", "摘要")]) {
        w.textElement("th", column, attrs: [htmlAttr("scope", "col")])
    }
    w.close("tr")
    w.close("thead")
    w.open("tbody")
    for (symbol in symbols) {
        appendDeclarationRow(w, projection, symbol, locale, rootPrefix, showKind)
    }
    w.close("tbody")
    w.close("table")
    w.newline()
}

internal func appendPackageDeclarationGroups(w: HtmlWriter,
    projection: RenderProjection, pageModuleId: String, pagePackageName: String,
    symbols: ArrayList<SymbolDoc>, locale: String, rootPrefix!: String = ""): Unit {
    let roles = partitionDeclarationGroups(symbols, projection.catalog)
    if (!hasGroupedDeclarations(roles)) {
        appendPackageDeclarationKinds(w, projection, symbols, locale, rootPrefix)
        return
    }
    prepareDeclarationGroupAnchors(roles, pageModuleId, pagePackageName, None)
    w.textElement("span", "", attrs: [htmlAttr("id", "declarations"),
        htmlClass("cj-anchor-alias"), htmlAttr("aria-hidden", "true")])
    let aliases = HashSet<String>()
    for (role in roles) {
        for (symbol in role.symbols) {
            let (alias, _) = packageDeclarationHeading(packageDeclarationCategory(symbol.kind), locale)
            if (aliases.add(alias)) {
                w.textElement("span", "", attrs: [htmlClass("cj-anchor-alias"),
                    htmlAttr("id", alias), htmlAttr("aria-hidden", "true")])
            }
        }
        w.open("section", attrs: [htmlClass("cj-api-group"),
            htmlAttr("data-cjdoc-declaration-group", role.id)])
        w.open("h2", attrs: [htmlAttr("id", role.anchor),
            htmlAttr("data-cjdoc-toc-role", "group")])
        w.text(declarationGroupDisplayTitle(role, locale))
        w.textElement("span", label(locale, " (${role.symbols.size})", "（${role.symbols.size}）"),
            attrs: [htmlFlag("data-cjdoc-group-count"), htmlAttr("data-group-total", role.symbols.size.toString())])
        w.close("h2")
        appendPackageDeclarationKinds(w, projection, role.symbols, locale, rootPrefix,
            groupPrefix: role.kindPrefix)
        w.close("section")
        w.newline()
    }
}

private func appendKindHeading(w: HtmlWriter, headingTag: String, anchorId: String,
    heading: String, count: String): Unit {
    w.open(headingTag, attrs: [htmlAttr("id", anchorId), htmlAttr("data-cjdoc-toc-role", "group")])
    w.text(heading + count)
    w.close(headingTag)
}

private func appendGroupedKindSection(w: HtmlWriter, projection: RenderProjection,
    category: String, group: ArrayList<SymbolDoc>,
    locale: String, groupPrefix: String, showKindHeading: Bool, rootPrefix: String): Unit {
    let (groupId, heading) = packageDeclarationHeading(category, locale)
    let count = label(locale, " (${group.size})", "（${group.size}）")
    if (showKindHeading) {
        w.open("section", attrs: [htmlClass("cj-decl-group")])
        appendKindHeading(w, "h3", groupPrefix + groupId, heading, count)
    } else {
        // The omitted heading keeps its historical deep link on a zero-height
        // alias, so old #api-kind… URLs still resolve without a second heading
        // or TOC entry.
        w.open("section", attrs: [htmlClass("cj-decl-group cj-decl-group--plain")])
        w.textElement("span", "", attrs: [htmlClass("cj-anchor-alias"),
            htmlAttr("id", groupPrefix + groupId), htmlAttr("aria-hidden", "true")])
    }
    // A merged kind heading no longer names the kind above the table, and the
    // generic "Other declarations" heading never names the concrete kind, so
    // those rows carry the small label instead.
    appendDeclarationTable(w, projection, group, locale, rootPrefix,
        !showKindHeading || category == "other")
    w.close("section")
    w.newline()
}

private func appendPackageDeclarationKinds(w: HtmlWriter, projection: RenderProjection,
    symbols: ArrayList<SymbolDoc>, locale: String, rootPrefix: String,
    groupPrefix!: String = ""): Unit {
    let (ordered, _) = packageDeclarationCategories(symbols)
    if (ordered.isEmpty()) { return }
    if (!groupPrefix.isEmpty()) {
        // A group with one visible kind needs no umbrella heading between the
        // group and its entries; the table rows keep the kind identifiable.
        let layout = declarationGroupLayout(ordered.size, 2)
        for (entry in ordered) {
            appendGroupedKindSection(w, projection, entry[0], entry[1], locale,
                groupPrefix, layout.showKindHeading, rootPrefix)
        }
        return
    }
    // A single visible category needs no redundant umbrella heading above a
    // second heading for the same content; the category heading becomes the
    // section and keeps the audience-visible count.
    let singleCategory = ordered.size == 1
    if (!singleCategory) {
        w.textElement("h2", label(locale, "Declarations", "声明"), attrs: [htmlAttr("id", "declarations")])
        w.newline()
    }
    let headingTag = if (singleCategory) { "h2" } else { "h3" }
    for (entry in ordered) {
        let category = entry[0]
        let group = entry[1]
        let (groupId, heading) = packageDeclarationHeading(category, locale)
        // The sole group keeps the historical anchor so old deep links resolve.
        // The id lives on the heading, never on the wrapping section, so the
        // historical anchor has exactly one owner and one scroll target.
        let anchorId = if (singleCategory) { "declarations" } else { groupId }
        let count = label(locale, " (${group.size})", "（${group.size}）")
        w.open("section", attrs: [htmlClass("cj-decl-group")])
        // Merging the umbrella and category headings must not break either deep
        // link. The category anchor survives as a non-heading alias, so the TOC
        // (which only walks headings and roles) still sees one node.
        if (singleCategory) {
            w.textElement("span", "", attrs: [htmlClass("cj-anchor-alias"),
                htmlAttr("id", groupId), htmlAttr("aria-hidden", "true")])
        }
        w.open(headingTag, attrs: [htmlAttr("id", anchorId),
            htmlAttr("data-cjdoc-toc-role", "group")])
        w.text(heading + count)
        w.close(headingTag)
        // "Other declarations" is not a concrete kind, so its rows keep one.
        appendDeclarationTable(w, projection, group, locale, rootPrefix, category == "other")
        w.close("section")
        w.newline()
    }
}
