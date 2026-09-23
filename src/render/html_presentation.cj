package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Stable presentation order, independent of source declaration order and Doc IR encoding.
internal class PackageSection {
    let id: String
    let title: String
    let chineseTitle: String
    let symbols = ArrayList<SymbolDoc>()

    init(id: String, title: String, chineseTitle: String) {
        this.id = id
        this.title = title
        this.chineseTitle = chineseTitle
    }
}

internal class PackageSections {
    let groups = [PackageSection("classes", "Classes", "类"),
        PackageSection("structs", "Structs", "结构体"),
        PackageSection("interfaces", "Interfaces", "接口"),
        PackageSection("enums", "Enums", "枚举"),
        PackageSection("functions", "Functions", "函数"),
        PackageSection("variables", "Variables and constants", "变量与常量"),
        PackageSection("aliases", "Type aliases", "类型别名"),
        PackageSection("extensions", "Extensions", "扩展"),
        PackageSection("others", "Other declarations", "其他声明")]

    init(symbols: ArrayList<SymbolDoc>) {
        for (symbol in symbols) {
            let group: Int64 = match (symbol.kind) {
                case "class" => 0
                case "struct" => 1
                case "interface" => 2
                case "enum" => 3
                case "function" => 4
                case "variable" => 5
                case "typeAlias" => 6
                case "extend" => 7
                case _ => 8
            }
            groups[group].symbols.add(symbol)
        }
    }
}

internal func appendPackageSections(out: RenderTextBuffer, sections: PackageSections,
    index: HashMap<String, SymbolDoc>, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    out.append("<nav class=\"declaration-groups\" aria-label=\"${label(locale, "Declaration groups", "声明分组")}\"><ul>")
    for (group in sections.groups where !group.symbols.isEmpty()) {
        out.append("<li><a href=\"#${group.id}\">${label(locale, group.title, group.chineseTitle)} <span class=\"meta\">${group.symbols.size}</span></a></li>")
    }
    out.append("</ul></nav>\n")
    for (group in sections.groups where !group.symbols.isEmpty()) {
        out.append("<section class=\"declaration-group\"><h2 id=\"${group.id}\" data-cjdoc-toc-role=\"group\">${label(locale, group.title, group.chineseTitle)}</h2>\n")
        for (symbol in group.symbols) {
            if (isContainerDeclaration(symbol)) {
                out.append("<section class=\"declaration-summary\"><h3 data-cjdoc-toc-role=\"api\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\"><a href=\"../${escapeHtml(symbolPagePath(symbol))}\"><code>${escapeHtml(symbol.name)}</code></a></h3>")
                match (symbol.documentation) {
                    case Some(comment) => out.append("<p>${escapeHtml(documentationSummary(comment))}</p>")
                    case None => ()
                }
                out.append("</section>\n")
            } else {
                appendSymbolArticle(out, index, symbol, "../", assetLookup,
                    typeLinkIndex, locale: locale)
            }
        }
        out.append("</section>\n")
    }
}

internal func documentationSummary(comment: DocComment): String {
    for (child in comment.markdown.children) {
        if (child.kind == "paragraph") { return markdownNodeText(child) }
    }
    ""
}

internal func appendApiOverview(out: RenderTextBuffer, projection: RenderProjection,
    locale: String): Unit {
    let topLevel = ArrayList<SymbolDoc>()
    let packageGroups = HashMap<String, PackageSections>()
    for (pkg in projection.packages) {
        let symbols = ArrayList<SymbolDoc>()
        for (symbol in pkg.symbols where symbol.ownerId.isNone()) { symbols.add(symbol); topLevel.add(symbol) }
        packageGroups[routeKey(pkg.source.moduleId, pkg.source.name)] = PackageSections(symbols)
    }
    let sections = PackageSections(topLevel)
    out.append("<h2 id=\"api-overview\">${label(locale, "API overview", "API 概览")}</h2>\n")
    for (group in sections.groups where !group.symbols.isEmpty()) {
        out.append("<section class=\"api-overview-group\"><h3>${label(locale, group.title, group.chineseTitle)}</h3><ul class=\"api-overview-links\">")
        // Keep large projects navigable without repeating every declaration on the landing page.
        for (pkg in projection.packages) {
            var count: Int64 = 0
            for (packageGroup in packageGroups[routeKey(pkg.source.moduleId, pkg.source.name)].groups) {
                if (packageGroup.id == group.id) { count = packageGroup.symbols.size; break }
            }
            if (count == 0) { continue }
            out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}#${group.id}\"><code>${escapeHtml(pkg.source.name)}</code></a><span class=\"meta\">${count}</span></li>")
        }
        out.append("</ul></section>\n")
    }
}
