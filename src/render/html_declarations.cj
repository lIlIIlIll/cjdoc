package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func packageDeclarationCategory(kind: String): String {
    match (kind) {
        case "class" | "struct" | "interface" | "enum" | "typeAlias" |
            "function" | "property" | "variable" | "extend" => kind
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
    for (category in ["class", "struct", "interface", "enum", "typeAlias", "function",
        "property", "variable", "extend", "other"]) {
        let group = match (groups.get(category)) {
            case Some(value) => value
            case None => continue
        }
        let (groupId, heading) = packageDeclarationHeading(category, locale)
        let count = label(locale, " (${group.size})", "（${group.size}）")
        out.append("<section class=\"declaration-group\"><h2 id=\"${groupId}\" data-cjdoc-toc-role=\"group\">${heading}${count}</h2><div class=\"declaration-list\">")
        for (symbol in group) {
            appendDeclarationRow(out, symbol, links, locale,
                category == "other" || kindByName[symbol.name].isEmpty())
        }
        out.append("</div></section>\n")
    }
}
