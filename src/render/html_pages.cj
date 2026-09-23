package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en"): String {
    let out = RenderTextBuffer()
    appendPageStart(out, "${documentation.project.name} ${label(locale, "API documentation", "API 文档")}", "",
        documentation, projection, locale: locale)
    out.append("<header class=\"page-header\"><h1>${escapeHtml(documentation.project.name)} ${label(locale, "API documentation", "API 文档")}</h1>")
    out.append("<p class=\"page-lead\">${label(locale, "Browse packages and declarations to find API signatures, contracts, and examples.", "按包和声明类别查阅 API 签名、使用约定与示例。")}</p></header>\n")
    out.append("<h2 id=\"packages\">${label(locale, "API Reference", "API 参考")}</h2><ul class=\"package-index\">\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a><span class=\"meta\">${pkg.symbols.size} ${label(locale, "declarations", "个声明")}</span></li>\n")
    }
    out.append("</ul>\n")
    if (projection.visibleSymbols.isEmpty()) {
        out.append("<p class=\"empty-state\">${label(locale, "No API declarations are available for this audience.", "当前受众范围内没有可用的 API 声明。")}</p>\n")
    } else {
        appendApiOverview(out, projection, locale)
    }
    if (!documentation.diagnostics.isEmpty()) {
        var critical = false
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.severity == "error" || diagnostic.code == "CJDOC3027") { critical = true; break }
        }
        let expanded = if (critical) { " open" } else { "" }
        out.append("<details class=\"generation-metadata\"${expanded}><summary id=\"diagnostics\">${label(locale, "Generation diagnostics", "生成诊断")}</summary><ul class=\"diagnostics-list\">\n")
        for (diagnostic in documentation.diagnostics) {
            if (let Some(symbolId) <- diagnostic.symbolId) {
                if (!projection.visibleIndex.contains(symbolId)) { continue }
            }
            out.append("<li><strong>${escapeHtml(diagnostic.severity)}[${escapeHtml(diagnostic.code)}]</strong>: ${escapeHtml(diagnostic.message)}")
            match (diagnostic.source) {
                case Some(source) => out.append(" <code>${escapeHtml(source.path)}:${source.start.line}:${source.start.column}</code>")
                case None => ()
            }
            out.append("</li>\n")
        }
        out.append("</ul></details>\n")
    }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

internal func renderPackagePage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, topLevelByPackage: HashMap<String, ArrayList<SymbolDoc>>,
    pkg: ProjectedPackage, assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en"): String {
    let packageDoc = pkg.source
    let out = RenderTextBuffer()
    appendPageStart(out, "${label(locale, "Package", "包")} ${packageDoc.name}", "../",
        documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(packageDoc.moduleId, packageDoc.name)))
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li><li aria-current=\"page\">${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1>${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></h1></header>\n")
    match (topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) => appendPackageSections(out, PackageSections(symbols), index,
            assetLookup, typeLinkIndex, locale)
        case None => out.append("<p class=\"empty-state\">${label(locale, "No declarations are visible for this audience.", "此受众范围内没有直接声明。")}</p>\n")
    }
    appendPackageMetadata(out, pkg, index, locale)
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

internal func memberSectionTitle(symbol: SymbolDoc): String {
    match (symbol.kind) {
        case "constructor" => "Constructors"
        case "property" => "Properties"
        case "variable" => "Variables"
        case "function" => "Methods"
        case "enumCase" => "Enum cases"
        case "class" => "Nested classes"
        case "struct" => "Nested structs"
        case "interface" => "Nested interfaces"
        case "enum" => "Nested enums"
        case "extend" => "Nested extensions"
        case _ => "Other members"
    }
}

internal func appendMemberSection(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    owner: SymbolDoc, title: String, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    var opened = false
    match (membersByOwner.get(owner.id)) {
        case Some(members) => for (member in members) {
            if (memberSectionTitle(member) != title) { continue }
            if (!opened) { out.append("<h2 id=\"members-${member.kind}\" data-cjdoc-toc-role=\"group\">${escapeHtml(label(locale, title, match (title) { case "Constructors" => "构造器"; case "Properties" => "属性"; case "Variables" => "变量"; case "Methods" => "方法"; case "Enum cases" => "枚举项"; case "Nested classes" => "嵌套类"; case "Nested structs" => "嵌套结构体"; case "Nested interfaces" => "嵌套接口"; case "Nested enums" => "嵌套枚举"; case "Nested extensions" => "嵌套扩展"; case _ => "其他成员" }))}</h2>\n"); opened = true }
            appendSymbolArticle(out, index, member, "../", assetLookup,
                typeLinkIndex, linkTitle: isContainerDeclaration(member), locale: locale)
        }
        case None => ()
    }
}

internal func renderSymbolPage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en"): String {
    let out = RenderTextBuffer()
    appendPageStart(out, symbol.qualifiedName, "../", documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(symbol.moduleId, symbol.packageName)))
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li>")
    out.append("<li><a href=\"../${escapeHtml(packagePagePath(symbol.moduleId, symbol.packageName))}\">${label(locale, "Package", "包")} <code>${escapeHtml(symbol.packageName)}</code></a></li>")
    out.append("<li aria-current=\"page\"><code>${escapeHtml(symbol.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1 data-cjdoc-toc-role=\"api-root\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></h1>")
    appendSymbolMetadata(out, index, symbol, "../", locale: locale)
    out.append("</header>\n")
    appendDocumentationHtml(out, index, symbol, "../", assetLookup,
        typeLinkIndex, headingBase: 2, locale: locale)
    for (title in ["Constructors", "Properties", "Variables", "Methods", "Enum cases",
        "Nested classes", "Nested structs", "Nested interfaces", "Nested enums", "Nested extensions",
        "Other members"]) {
        appendMemberSection(out, index, membersByOwner, symbol, title, assetLookup,
            typeLinkIndex, locale)
    }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

