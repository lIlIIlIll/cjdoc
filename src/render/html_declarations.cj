package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func packageDeclarationCategory(kind: String): String {
    match (kind) {
        case "class" | "struct" | "interface" | "enum" | "typeAlias" |
            "function" | "macro" | "property" | "variable" | "extend" => kind
        case _ => "other"
    }
}

private func packageDeclarationHeading(category: String, locale: String): (String, String) {
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

private func appendDeclarationRow(out: RenderTextBuffer, symbol: SymbolDoc,
    links: HtmlTypeLinkIndex, locale: String, showKind: Bool): Unit {
    out.append("<article class=\"declaration-summary declaration-row\" data-cjdoc-member data-member-name=\"${escapeHtml(symbol.name)}\" data-member-kind=\"${escapeHtml(symbol.kind)}\">")
    // The stretched name link owns the row; signature type links are siblings,
    // never nested anchors, and remain independently focusable above it.
    out.append("<a class=\"declaration-row-link\" href=\"../${escapeHtml(symbolPagePath(symbol))}\"><span class=\"declaration-summary-head\"><code>${escapeHtml(readerDeclarationName(symbol))}</code>")
    if (showKind) {
        out.append("<span class=\"declaration-kind\">${escapeHtml(htmlKindLabel(symbol.kind, locale))}</span>")
    }
    out.append("</span></a>")
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

internal func appendPackageDeclarationGroups(out: RenderTextBuffer,
    symbols: ArrayList<SymbolDoc>, links: HtmlTypeLinkIndex, locale: String): Unit {
    let roles = declarationGroups(symbols)
    if (!hasDeclarationGroups(roles)) {
        appendPackageDeclarationKinds(out, symbols, links, locale)
        return
    }
    out.append("<span id=\"declarations\" class=\"section-anchor-alias\" aria-hidden=\"true\"></span>")
    let aliases = HashSet<String>()
    for (role in roles) {
        for (symbol in role.symbols) {
            let (alias, _) = packageDeclarationHeading(packageDeclarationCategory(symbol.kind), locale)
            if (aliases.add(alias)) {
                out.append("<span class=\"section-anchor-alias\" id=\"" + alias + "\" aria-hidden=\"true\"></span>")
            }
        }
        let anchor = if (role.key.isEmpty()) { "api-ungrouped" } else { "api-group-" + role.key }
        out.append("<section class=\"api-declaration-group\" data-cjdoc-declaration-group=\"" +
            escapeHtml(role.key) + "\"><h2 id=\"" + anchor + "\">" +
            escapeHtml(declarationGroupTitle(role, locale)) +
            label(locale, " (${role.symbols.size})", "（${role.symbols.size}）") + "</h2>")
        appendPackageDeclarationKinds(out, role.symbols, links, locale,
            groupPrefix: "api-kind-${role.key.size}-${role.key}-")
        out.append("</section>\n")
    }
}

private func appendPackageDeclarationKinds(out: RenderTextBuffer,
    symbols: ArrayList<SymbolDoc>, links: HtmlTypeLinkIndex, locale: String,
    groupPrefix!: String = ""): Unit {
    // Only the audience/cfg projection reaches this function. Hidden members
    // cannot affect counts or introduce a same-name kind badge.
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
    for (category in ["class", "struct", "interface", "enum", "typeAlias", "function", "macro",
        "property", "variable", "extend", "other"]) {
        match (groups.get(category)) {
            case Some(group) => ordered.add((category, group))
            case None => continue
        }
    }
    // A single visible category needs no redundant umbrella heading above a
    // second heading for the same content; the category heading becomes the
    // section and keeps the audience-visible count.
    let singleCategory = ordered.size == 1
    if (!singleCategory && groupPrefix.isEmpty()) {
        out.append("<h2 id=\"declarations\">${label(locale, "Declarations", "声明")}</h2>\n")
    }
    let headingLevel = if (!groupPrefix.isEmpty()) { "h3" }
        else if (singleCategory) { "h2" } else { "h3" }
    for (entry in ordered) {
        let category = entry[0]
        let group = entry[1]
        let (groupId, heading) = packageDeclarationHeading(category, locale)
        // The sole group keeps the historical anchor so old deep links resolve.
        // The id lives on the heading, never on the wrapping section, so the
        // historical anchor has exactly one owner and one scroll target.
        let anchorId = if (!groupPrefix.isEmpty()) { groupPrefix + groupId }
            else if (singleCategory) { "declarations" } else { groupId }
        let count = label(locale, " (${group.size})", "（${group.size}）")
        out.append("<section class=\"declaration-group\">")
        // Merging the umbrella and category headings must not break either deep
        // link. The category anchor survives as a non-heading alias, so the TOC
        // (which only walks headings and roles) still sees one node.
        if (singleCategory && groupPrefix.isEmpty()) {
            out.append("<span class=\"section-anchor-alias\" id=\"${groupId}\" aria-hidden=\"true\"></span>")
        }
        out.append("<${headingLevel} id=\"${anchorId}\" data-cjdoc-toc-role=\"group\">${heading}${count}</${headingLevel}><div class=\"declaration-list\">")
        for (symbol in group) {
            appendDeclarationRow(out, symbol, links, locale,
                category == "other" || kindByName[symbol.name].isEmpty())
        }
        out.append("</div></section>\n")
    }
}
