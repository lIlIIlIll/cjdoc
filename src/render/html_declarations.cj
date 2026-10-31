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

private func appendDeclarationRow(out: RenderTextBuffer, projection: RenderProjection,
    symbol: SymbolDoc, links: HtmlTypeLinkIndex, locale: String, showKind: Bool): Unit {
    out.append("<article class=\"declaration-summary declaration-row\" data-cjdoc-member data-member-symbol-id=\"${escapeHtml(symbol.id)}\" data-member-name=\"${escapeHtml(symbol.name)}\" data-member-kind=\"${escapeHtml(symbol.kind)}\">")
    // The stretched name link owns the row; signature type links are siblings,
    // never nested anchors, and remain independently focusable above it.
    out.append("<a class=\"declaration-row-link\" href=\"../${escapeHtml(symbolPagePath(symbol))}\"><span class=\"declaration-summary-head\"><code>${escapeHtml(readerDeclarationName(symbol))}</code>")
    if (showKind) {
        out.append("<span class=\"declaration-kind\">${escapeHtml(htmlKindLabel(symbol.kind, locale))}</span>")
    }
    out.append("</span></a>")
    appendDeclarationClassificationBadges(out, projection.catalog, projection.snapshotId,
        symbol, "../", includeGroup: false)
    if (!symbol.headerSpelling.isEmpty()) {
        out.append("<code class=\"declaration-signature\">")
        appendLinkedSignatureHtml(out, symbol, links, "../")
        out.append("</code>")
    }
    match (symbol.documentation) {
        case Some(comment) =>
            let summary = summaryPlainText(comment)
            if (!summary.isEmpty()) {
                out.append("<p class=\"declaration-description\">")
                out.append(escapeHtml(summary))
                out.append("</p>")
            }
        case None => ()
    }
    out.append("</article>\n")
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

internal func appendPackageDeclarationGroups(out: RenderTextBuffer,
    projection: RenderProjection, pageModuleId: String, pagePackageName: String,
    symbols: ArrayList<SymbolDoc>, links: HtmlTypeLinkIndex, locale: String): Unit {
    let roles = partitionDeclarationGroups(symbols, projection.catalog)
    if (!hasGroupedDeclarations(roles)) {
        appendPackageDeclarationKinds(out, projection, symbols, links, locale)
        return
    }
    prepareDeclarationGroupAnchors(roles, pageModuleId, pagePackageName, None)
    out.append("<span id=\"declarations\" class=\"section-anchor-alias\" aria-hidden=\"true\"></span>")
    let aliases = HashSet<String>()
    for (role in roles) {
        for (symbol in role.symbols) {
            let (alias, _) = packageDeclarationHeading(packageDeclarationCategory(symbol.kind), locale)
            if (aliases.add(alias)) {
                out.append("<span class=\"section-anchor-alias\" id=\"" + alias + "\" aria-hidden=\"true\"></span>")
            }
        }
        out.append("<section class=\"api-declaration-group\" data-cjdoc-declaration-group=\"" +
            escapeHtml(role.id) + "\"><h2 id=\"" + escapeHtml(role.anchor) + "\">" +
            escapeHtml(declarationGroupDisplayTitle(role, locale)) +
            "<span data-cjdoc-group-count data-group-total=\"${role.symbols.size}\">" +
            label(locale, " (${role.symbols.size})", "（${role.symbols.size}）") + "</span></h2>")
        appendPackageDeclarationKinds(out, projection, role.symbols, links, locale,
            groupPrefix: role.kindPrefix)
        out.append("</section>\n")
    }
}

private func appendPackageDeclarationKinds(out: RenderTextBuffer, projection: RenderProjection,
    symbols: ArrayList<SymbolDoc>, links: HtmlTypeLinkIndex, locale: String,
    groupPrefix!: String = ""): Unit {
    let (ordered, kindByName) = packageDeclarationCategories(symbols)
    if (ordered.isEmpty()) { return }
    if (!groupPrefix.isEmpty()) {
        // A group with one visible kind needs no umbrella heading between the
        // group and its entries; the signatures keep the kind identifiable.
        let layout = declarationGroupLayout(ordered.size, 2)
        for (entry in ordered) {
            let category = entry[0]
            let group = entry[1]
            let (groupId, heading) = packageDeclarationHeading(category, locale)
            let count = label(locale, " (${group.size})", "（${group.size}）")
            if (layout.showKindHeading) {
                out.append("<section class=\"declaration-group\"><h3 id=\"${groupPrefix}${groupId}\" data-cjdoc-toc-role=\"group\">${heading}${count}</h3><div class=\"declaration-list\">")
            } else {
                // The omitted heading keeps its historical deep link on a
                // zero-height alias, so old #api-kind… URLs still resolve
                // without a second heading or TOC entry.
                out.append("<section class=\"declaration-group declaration-group-plain\"><span class=\"section-anchor-alias\" id=\"${groupPrefix}${groupId}\" aria-hidden=\"true\"></span><div class=\"declaration-list\">")
            }
            for (symbol in group) {
                appendDeclarationRow(out, projection, symbol, links, locale,
                    category == "other" || kindByName[symbol.name].isEmpty())
            }
            out.append("</div></section>\n")
        }
        return
    }
    // A single visible category needs no redundant umbrella heading above a
    // second heading for the same content; the category heading becomes the
    // section and keeps the audience-visible count.
    let singleCategory = ordered.size == 1
    if (!singleCategory) {
        out.append("<h2 id=\"declarations\">${label(locale, "Declarations", "声明")}</h2>\n")
    }
    let headingLevel = if (singleCategory) { "h2" } else { "h3" }
    for (entry in ordered) {
        let category = entry[0]
        let group = entry[1]
        let (groupId, heading) = packageDeclarationHeading(category, locale)
        // The sole group keeps the historical anchor so old deep links resolve.
        // The id lives on the heading, never on the wrapping section, so the
        // historical anchor has exactly one owner and one scroll target.
        let anchorId = if (singleCategory) { "declarations" } else { groupId }
        let count = label(locale, " (${group.size})", "（${group.size}）")
        out.append("<section class=\"declaration-group\">")
        // Merging the umbrella and category headings must not break either deep
        // link. The category anchor survives as a non-heading alias, so the TOC
        // (which only walks headings and roles) still sees one node.
        if (singleCategory) {
            out.append("<span class=\"section-anchor-alias\" id=\"${groupId}\" aria-hidden=\"true\"></span>")
        }
        out.append("<${headingLevel} id=\"${anchorId}\" data-cjdoc-toc-role=\"group\">${heading}${count}</${headingLevel}><div class=\"declaration-list\">")
        for (symbol in group) {
            appendDeclarationRow(out, projection, symbol, links, locale,
                category == "other" || kindByName[symbol.name].isEmpty())
        }
        out.append("</div></section>\n")
    }
}

