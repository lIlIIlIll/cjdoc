package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Stable presentation order, independent of source declaration order and Doc IR encoding.
private class PackageSection {
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

private class PackageSections {
    let groups = [PackageSection("classes", "Classes", "类"),
        PackageSection("structs", "Structs", "结构体"),
        PackageSection("interfaces", "Interfaces", "接口"),
        PackageSection("enums", "Enums", "枚举"),
        PackageSection("functions", "Functions", "函数"),
        PackageSection("macros", "Macros", "宏"),
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
                case "macro" => 5
                case "variable" => 6
                case "typeAlias" => 7
                case "extend" => 8
                case _ => 9
            }
            groups[group].symbols.add(symbol)
        }
    }
}

internal func appendApiOverview(w: HtmlWriter, projection: RenderProjection,
    locale: String): Unit {
    let topLevel = ArrayList<SymbolDoc>()
    let packageGroups = HashMap<String, PackageSections>()
    for (pkg in projection.packages) {
        let symbols = ArrayList<SymbolDoc>()
        for (symbol in pkg.symbols where symbol.ownerId.isNone()) { symbols.add(symbol); topLevel.add(symbol) }
        packageGroups[routeKey(pkg.source.moduleId, pkg.source.name)] = PackageSections(symbols)
    }
    let sections = PackageSections(topLevel)
    w.textElement("h2", label(locale, "API overview", "API 概览"), attrs: [htmlAttr("id", "api-overview")])
    w.newline()
    for (group in sections.groups where !group.symbols.isEmpty()) {
        w.open("section", attrs: [htmlClass("cj-overview")])
        w.textElement("h3", label(locale, group.title, group.chineseTitle))
        w.open("ul", attrs: [htmlClass("cj-overview__links")])
        // Keep large projects navigable without repeating every declaration on the landing page.
        for (pkg in projection.packages) {
            var count: Int64 = 0
            for (packageGroup in packageGroups[routeKey(pkg.source.moduleId, pkg.source.name)].groups) {
                if (packageGroup.id == group.id) { count = packageGroup.symbols.size; break }
            }
            if (count == 0) { continue }
            let visibleCount = count
            w.element("li", []) { item =>
                let href = documentationRouteHref(packagePagePath(pkg.source.moduleId, pkg.source.name) +
                    "#" + group.id)
                item.element("a", [htmlHref(href)]) { link => link.textElement("code", pkg.source.name) }
                item.textElement("span", visibleCount.toString(), attrs: [htmlClass("cj-meta")])
            }
        }
        w.close("ul")
        w.close("section")
        w.newline()
    }
}
