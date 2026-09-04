package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en"): String {
    let out = RenderTextBuffer()
    appendPageStart(out, "${documentation.project.name} ${label(locale, "API documentation", "API 文档")}", "",
        documentation, projection, locale: locale)
    out.append("<header class=\"page-header\"><h1>${escapeHtml(documentation.project.name)} ${label(locale, "API documentation", "API 文档")}</h1>")
    if (locale == "zh-CN") {
        out.append("<p class=\"page-lead\">${projection.modules.size} 个模块，${projection.packages.size} 个包，${projection.visibleSymbols.size} 个可见声明</p>\n")
    } else {
        out.append("<p class=\"page-lead\">${projection.modules.size} modules, ${projection.packages.size} packages, ${projection.visibleSymbols.size} visible declarations</p>\n")
    }
    out.append("</header>\n")
    if (!projection.modules.isEmpty()) {
        out.append("<h2 id=\"modules\">${label(locale, "Modules", "模块")}</h2><div class=\"module-list\">\n")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<section class=\"module-record\"><h3><code>${escapeHtml(module.name)}</code> <span class=\"badge\">${escapeHtml(module.role)}</span></h3>")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">Source prefix: <code>${escapeHtml(prefix)}</code></p><ul class=\"package-links\">\n")
            for (pkg in projected.packages) {
                out.append("<li><a href=\"${escapeHtml(packagePagePath(module.id, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
            }
            out.append("</ul></section>\n")
        }
        out.append("</div>\n")
    }
    out.append("<h2 id=\"packages\">${label(locale, "Packages", "包")}</h2><ul class=\"package-index\">\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a></li>\n")
    }
    out.append("</ul>\n")
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<h2 id=\"diagnostics\">${label(locale, "Diagnostics", "诊断")}</h2><ul class=\"diagnostics-list\">\n")
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
        out.append("</ul>\n")
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
    if (!pkg.sourceFiles.isEmpty()) {
        out.append("<h2 id=\"sources\">${label(locale, "Sources", "源文件")}</h2><ul class=\"record-list\">\n")
        for (path in pkg.sourceFiles) { out.append("<li><code>${escapeHtml(path)}</code></li>\n") }
        out.append("</ul>\n")
    }
    if (!packageDoc.reExports.isEmpty()) {
        out.append("<h2 id=\"re-exports\">${label(locale, "Re-exports", "公开重导出")}</h2><ul class=\"record-list\">\n")
        for (reExport in packageDoc.reExports) {
            if (reExport.kind == "packageAlias") {
                out.append("<li><code>${escapeHtml(reExport.alias.getOrThrow())}</code>")
                if (reExport.state == "resolved") { out.append(" → package") }
                out.append(" <code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            if (reExport.bindings.isEmpty()) {
                out.append("<li><code>${escapeHtml(reExport.targetPackageName)}</code> <span class=\"badge\">${escapeHtml(reExport.kind)}</span> <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
                continue
            }
            for (binding in reExport.bindings) {
                out.append("<li><code>${escapeHtml(binding.exposedName)}</code> → ")
                var firstTarget = true
                for (targetId in binding.targetSymbolIds) {
                    if (!firstTarget) { out.append(", ") }; firstTarget = false
                    match (findSymbol(index, targetId)) {
                        case Some(target) => out.append("<a href=\"../${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(target.qualifiedName)}</code></a>")
                        case None => out.append("<code>${escapeHtml(targetId)}</code>")
                    }
                }
                out.append(" <span class=\"badge\">${escapeHtml(reExport.state)}</span></li>\n")
            }
        }
        out.append("</ul>\n")
    }
    out.append("<h2 id=\"declarations\">${label(locale, "Declarations", "声明")}</h2>\n")
    var wroteDeclaration = false
    match (topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) => for (symbol in symbols) {
            wroteDeclaration = true
            if (isContainerDeclaration(symbol)) {
                out.append("<section class=\"declaration-summary\"><h3 data-cjdoc-toc-role=\"api\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\"><a href=\"../${escapeHtml(symbolPagePath(symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a> <span class=\"badge\">${escapeHtml(symbol.kind)}</span></h3>")
                match (symbol.documentation) {
                    case Some(comment) => out.append("<p>${escapeHtml(markdownNodeText(comment.markdown))}</p>")
                    case None => ()
                }
                out.append("</section>\n")
            } else {
                appendSymbolArticle(out, index, symbol, "../", assetLookup,
                    typeLinkIndex, locale: locale)
            }
        }
        case None => ()
    }
    if (!wroteDeclaration) { out.append("<p class=\"empty-state\">${label(locale, "No declarations are visible for this audience.", "此受众范围内没有直接声明。")}</p>\n") }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

internal func memberSectionTitle(symbol: SymbolDoc): String {
    match (symbol.kind) {
        case "constructor" => "Constructors"
        case "property" => "Properties"
        case "variable" => "Variables"
        case "function" => "Functions"
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
            if (!opened) { out.append("<h2>${escapeHtml(label(locale, title, match (title) { case "Constructors" => "构造器"; case "Properties" => "属性"; case "Variables" => "变量"; case "Functions" => "函数"; case "Enum cases" => "枚举项"; case "Nested classes" => "嵌套类"; case "Nested structs" => "嵌套结构体"; case "Nested interfaces" => "嵌套接口"; case "Nested enums" => "嵌套枚举"; case "Nested extensions" => "嵌套扩展"; case _ => "其他成员" }))}</h2>\n"); opened = true }
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
    for (title in ["Constructors", "Properties", "Variables", "Functions", "Enum cases",
        "Nested classes", "Nested structs", "Nested interfaces", "Nested enums", "Nested extensions",
        "Other members"]) {
        appendMemberSection(out, index, membersByOwner, symbol, title, assetLookup,
            typeLinkIndex, locale)
    }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

internal func appendSearchJsonString(out: RenderTextBuffer, value: String): Unit {
    let digits = "0123456789abcdef"
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case '"' => out.append("\\\"")
            case '\\' => out.append("\\\\")
            case '\u{0008}' => out.append("\\b")
            case '\u{000c}' => out.append("\\f")
            case '\n' => out.append("\\n")
            case '\r' => out.append("\\r")
            case '\t' => out.append("\\t")
            case _ =>
                let code = UInt32(rune)
                if (code < 0x20u32) {
                    out.append("\\u")
                    out.append(digits[Int64((code >> 12) & 0xFu32)..
                        Int64((code >> 12) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 8) & 0xFu32)..
                        Int64((code >> 8) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 4) & 0xFu32)..
                        Int64((code >> 4) & 0xFu32) + 1])
                    out.append(digits[Int64(code & 0xFu32)..Int64(code & 0xFu32) + 1])
                } else { out.append(rune) }
        }
    }
    out.append("\"")
}

internal func renderSearchIndex(documentation: DocumentationSet,
    projection: RenderProjection): String {
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.search-index/4\",\n  \"entries\": [")
    var first = true
    let visible = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(visible, lessThan: { left, right => left.id < right.id }, stable: true)
    for (declaration in visible) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"canonicalId\": "); appendSearchJsonString(out, declaration.id)
        out.append(", \"exposure\": false")
        out.append(", \"name\": "); appendSearchJsonString(out, declaration.name)
        out.append(", \"qualifiedName\": "); appendSearchJsonString(out, declaration.qualifiedName)
        out.append(", \"kind\": "); appendSearchJsonString(out, declaration.kind)
        out.append(", \"packageName\": "); appendSearchJsonString(out, declaration.packageName)
        let summary = match (declaration.documentation) {
            case Some(comment) => markdownNodeText(comment.markdown)
            case None => ""
        }
        out.append(", \"summary\": "); appendSearchJsonString(out, summary)
        out.append(", \"href\": ")
        appendSearchJsonString(out,
            symbolUrl(projection.visibleIndex, declaration))
        out.append("}")
    }
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                for (targetId in binding.targetSymbolIds) {
                    match (projection.visibleIndex.get(targetId)) {
                        case Some(target) =>
                            if (!first) { out.append(",") }; first = false
                            out.append("\n    {\"id\": ")
                            appendSearchJsonString(out,
                                "${reExport.id}:${binding.exposedName}:${target.id}")
                            out.append(", \"canonicalId\": "); appendSearchJsonString(out, target.id)
                            out.append(", \"exposure\": true, \"name\": ")
                            appendSearchJsonString(out, binding.exposedName)
                            out.append(", \"qualifiedName\": ")
                            appendSearchJsonString(out, "${pkg.name}.${binding.exposedName}")
                            out.append(", \"kind\": "); appendSearchJsonString(out, target.kind)
                            out.append(", \"packageName\": "); appendSearchJsonString(out, pkg.name)
                            let summary = match (target.documentation) {
                                case Some(comment) => markdownNodeText(comment.markdown)
                                case None => ""
                            }
                            out.append(", \"summary\": "); appendSearchJsonString(out, summary)
                            out.append(", \"href\": ")
                            appendSearchJsonString(out,
                                symbolUrl(projection.visibleIndex, target))
                            out.append("}")
                        case None => ()
                    }
                }
            }
        }
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

internal func renderSearchIndexScript(searchIndex: String): String {
    let out = RenderTextBuffer()
    out.append("globalThis.__CJDOC_SEARCH_INDEX__ = ")
    out.append(searchIndex.trimAscii())
    out.append(";\n")
    out.toString()
}
