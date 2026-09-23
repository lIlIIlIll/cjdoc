package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", docVersion!: ?String = None): String {
    let apiDocumentationLabel = label(locale, "API documentation", "API 文档")
    let startHereLabel = label(locale, "Start here", "从这里开始")
    let startHereCopy = label(locale, "Choose a module or package to begin with the generated API reference.", "选择模块或包，开始阅读生成的 API 参考。")
    let browseApiLabel = label(locale, "Browse the API index", "浏览 API 索引")
    let modulesLabel = label(locale, "Modules", "模块")
    let packagesLabel = label(locale, "Packages", "包")
    let packageCountLabel = label(locale, "packages", "个包")
    let diagnosticsLabel = label(locale, "Build status and diagnostics", "构建状态与诊断")
    let pageTitle = documentation.project.name + " " + apiDocumentationLabel
    let out = RenderTextBuffer()
    appendPageStart(out, pageTitle, "",
        documentation, projection, locale: locale)
    out.append("<header class=\"page-header\"><h1>${escapeHtml(documentation.project.name)} ${apiDocumentationLabel}</h1></header>\n")
    out.append("<section class=\"quick-start\" aria-labelledby=\"quick-start-title\"><h2 id=\"quick-start-title\">")
    out.append(startHereLabel)
    out.append("</h2><p>")
    out.append(startHereCopy)
    out.append("</p><a href=\"#packages\">")
    out.append(browseApiLabel)
    out.append("</a></section>\n")
    if (!projection.modules.isEmpty()) {
        out.append("<h2 id=\"modules\">")
        out.append(modulesLabel)
        out.append("</h2><div class=\"module-list\">\n")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<section class=\"module-record\"><h3><code>${escapeHtml(module.name)}</code> <span class=\"badge\">${escapeHtml(module.role)}</span></h3>")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">Source prefix: <code>${escapeHtml(prefix)}</code> · ${projected.packages.size} ")
            out.append(packageCountLabel)
            out.append("</p></section>\n")
        }
        out.append("</div>\n")
    }
    out.append("<h2 id=\"packages\">")
    out.append(packagesLabel)
    out.append("</h2><ul class=\"package-index\">\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a><span class=\"meta\">${pkg.symbols.size} ${label(locale, "declarations", "个声明")}</span></li>\n")
    }
    out.append("</ul>\n")
    if (projection.visibleSymbols.isEmpty()) {
        out.append("<p class=\"empty-state\">${label(locale, "No API declarations are available for this audience.", "当前受众范围内没有可用的 API 声明。")}</p>\n")
    } else {
        appendApiOverview(out, projection, locale)
    }
    if (documentation.status != "complete") {
        out.append("<details class=\"generation-metadata\" open><summary>${label(locale, "Generation status", "生成状态")}</summary><p>${escapeHtml(documentation.status)}</p></details>\n")
    }
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<details id=\"diagnostics\" class=\"build-details\"><summary>")
        out.append(diagnosticsLabel)
        out.append("</summary><ul class=\"diagnostics-list\">\n")
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

internal func appendDeclarationRow(out: RenderTextBuffer, symbol: SymbolDoc,
    rootPrefix: String): Unit {
    out.append("<article class=\"declaration-summary\" data-cjdoc-member data-member-name=\"${escapeHtml(symbol.name)}\" data-member-kind=\"${escapeHtml(symbol.kind)}\"><a class=\"declaration-row-link\" href=\"${rootPrefix}${escapeHtml(symbolPagePath(symbol))}\">")
    out.append("<div class=\"declaration-summary-head\"><code>${escapeHtml(symbol.name)}</code><span class=\"declaration-kind\">${escapeHtml(symbol.kind)}</span></div>")
    match (symbol.documentation) {
        case Some(comment) =>
            let summary = summaryPlainText(comment)
            if (!summary.isEmpty()) { out.append("<p>"); out.append(escapeHtml(summary)); out.append("</p>") }
        case None => ()
    }
    if (!symbol.headerSpelling.isEmpty()) {
        out.append("<code class=\"declaration-signature\">")
        out.append(escapeHtml(symbol.headerSpelling))
        out.append("</code>")
    }
    out.append("</a></article>\n")
}

public func renderConceptualHtmlPage(documentation: DocumentationSet, title: String, body: String,
    rootPrefix: String, source!: ?String = None, locale!: String = "en",
    docVersion!: ?String = None): String {
    let projection = RenderProjection(documentation)
    let out = RenderTextBuffer()
    let breadcrumbLabel = label(locale, "Breadcrumb", "面包屑导航")
    let apiReferenceLabel = label(locale, "API reference", "API 参考")
    let conceptsLabel = label(locale, "Concepts", "概念文档")
    let sourceLabel = label(locale, "Source", "来源")
    appendPageStart(out, title, rootPrefix, documentation, projection, locale: locale)
    out.append("<nav class=\"breadcrumbs\" aria-label=\"")
    out.append(breadcrumbLabel)
    out.append("\"><ol><li><a href=\"")
    out.append(rootPrefix)
    out.append("index.html\">")
    out.append(apiReferenceLabel)
    out.append("</a></li><li><a href=\"")
    out.append(rootPrefix)
    out.append("concepts/index.html\">")
    out.append(conceptsLabel)
    out.append("</a></li><li aria-current=\"page\">")
    out.append(escapeHtml(title))
    out.append("</li></ol></nav>")
    out.append("<header class=\"page-header\"><h1>${escapeHtml(title)}</h1>")
    match (source) {
        case Some(value) => out.append("<p class=\"page-meta\"><span class=\"page-meta-item\">")
            out.append(sourceLabel)
            out.append(": <code>")
            out.append(escapeHtml(value))
            out.append("</code></span></p>")
        case None => ()
    }
    out.append("</header>\n")
    out.append(body)
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

internal func renderPackagePage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, topLevelByPackage: HashMap<String, ArrayList<SymbolDoc>>,
    pkg: ProjectedPackage, locale!: String = "en", docVersion!: ?String = None): String {
    let packageDoc = pkg.source
    let out = RenderTextBuffer()
    appendPageStart(out, "${label(locale, "Package", "包")} ${packageDoc.name}", "../",
        documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(packageDoc.moduleId, packageDoc.name)))
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li><li aria-current=\"page\">${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1>${label(locale, "Package", "包")} <code>${escapeHtml(packageDoc.name)}</code></h1></header>\n")
    out.append("<h2 id=\"declarations\">${label(locale, "Declarations", "声明")}</h2>\n")
    var wroteDeclaration = false
    match (topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) => for (category in ["class", "struct", "interface", "enum", "typeAlias", "function", "property", "variable", "extend", "other"]) {
            var opened = false
            for (symbol in symbols) {
                let symbolCategory = match (symbol.kind) {
                    case "class" | "struct" | "interface" | "enum" | "typeAlias" |
                        "function" | "property" | "variable" | "extend" => symbol.kind
                    case _ => "other"
                }
                if (symbolCategory != category) { continue }
                if (!opened) {
                    let groupId = match (category) {
                        case "class" => "classes"
                        case "struct" => "structs"
                        case "interface" => "interfaces"
                        case "enum" => "enums"
                        case "typeAlias" => "aliases"
                        case "function" => "functions"
                        case "property" => "properties"
                        case "variable" => "variables"
                        case "extend" => "extensions"
                        case _ => "others"
                    }
                    let heading = match (category) {
                        case "class" => label(locale, "Classes", "类")
                        case "struct" => label(locale, "Structs", "结构体")
                        case "interface" => label(locale, "Interfaces", "接口")
                        case "enum" => label(locale, "Enums", "枚举")
                        case "typeAlias" => label(locale, "Type aliases", "类型别名")
                        case "function" => label(locale, "Functions", "函数")
                        case "property" => label(locale, "Properties", "属性")
                        case "variable" => label(locale, "Variables", "变量")
                        case "extend" => label(locale, "Extensions", "扩展")
                        case _ => label(locale, "Other declarations", "其他声明")
                    }
                    out.append("<section class=\"declaration-group\"><h2 id=\"${groupId}\" data-cjdoc-toc-role=\"group\">${heading}</h2><div class=\"declaration-list\">")
                    opened = true
                }
                wroteDeclaration = true
                appendDeclarationRow(out, symbol, "../")
                appendPackageDeclarationMetadata(out, symbol, locale)
            }
            if (opened) { out.append("</div></section>\n") }
        }
        case None => ()
    }
    if (!wroteDeclaration) { out.append("<p class=\"empty-state\">${label(locale, "No declarations are visible for this audience.", "此受众范围内没有直接声明。")}</p>\n") }
    appendPackageMetadata(out, pkg, index, locale)
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
    owner: SymbolDoc, title: String, locale: String): Unit {
    let sectionLabel = match (title) {
        case "Constructors" => "构造器"
        case "Properties" => "属性"
        case "Variables" => "变量"
        case "Functions" => "函数"
        case "Enum cases" => "枚举项"
        case "Nested classes" => "嵌套类"
        case "Nested structs" => "嵌套结构体"
        case "Nested interfaces" => "嵌套接口"
        case "Nested enums" => "嵌套枚举"
        case "Nested extensions" => "嵌套扩展"
        case _ => "其他成员"
    }
    let overloadLabel = label(locale, "Overloads", "重载")
    var opened = false
    match (membersByOwner.get(owner.id)) {
        case Some(members) =>
            let overloadCounts = HashMap<String, Int64>()
            for (member in members) {
                if (memberSectionTitle(member) != title) { continue }
                let count = match (overloadCounts.get(member.name)) {
                    case Some(value) => value + 1
                    case None => 1
                }
                overloadCounts[member.name] = count
            }
            var previousName = ""
            for (member in members) {
                if (memberSectionTitle(member) != title) { continue }
                if (!opened) {
                    out.append("<h2>" + escapeHtml(label(locale, title, sectionLabel)) + "</h2>\n")
                    opened = true
                }
                let count = match (overloadCounts.get(member.name)) {
                    case Some(value) => value
                    case None => 0
                }
                if (count > 1 && previousName != member.name) {
                    out.append("<p class=\"overload-group-label\"><span>" + escapeHtml(overloadLabel) + "</span> <code>" + escapeHtml(member.name) + "</code></p>\n")
                }
                previousName = member.name
                appendDeclarationRow(out, member, "../")
            }
        case None => ()
    }
}

internal func appendOwnerBreadcrumbs(out: RenderTextBuffer, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, rootPrefix: String, locale: String): Unit {
    let owners = ArrayList<SymbolDoc>()
    var current = symbol.ownerId
    while (let Some(ownerId) <- current) {
        match (findSymbol(index, ownerId)) {
            case Some(owner) => owners.add(owner); current = owner.ownerId
            case None => current = None
        }
    }
    var position = owners.size
    while (position > 0) {
        position--
        let owner = owners[position]
        out.append("<li><a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, owner))}\"><code>${escapeHtml(owner.name)}</code></a></li>")
    }
}

internal func renderSymbolPage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, membersByOwner: HashMap<String, ArrayList<SymbolDoc>>,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", docVersion!: ?String = None): String {
    let out = RenderTextBuffer()
    appendPageStart(out, symbol.qualifiedName, "../", documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(symbol.moduleId, symbol.packageName)))
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li>")
    out.append("<li><a href=\"../${escapeHtml(packagePagePath(symbol.moduleId, symbol.packageName))}\">${label(locale, "Package", "包")} <code>${escapeHtml(symbol.packageName)}</code></a></li>")
    appendOwnerBreadcrumbs(out, index, symbol, "../", locale)
    out.append("<li aria-current=\"page\"><code>${escapeHtml(symbol.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header\"><h1 data-cjdoc-toc-role=\"api-root\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\"><code>${escapeHtml(symbol.name)}</code></h1>")
    out.append("<p class=\"symbol-kind\">${escapeHtml(symbol.kind)}</p>")
    appendSymbolMetadata(out, index, symbol, "../", locale: locale)
    match (findProjectedModule(projection, symbol.moduleId)) {
        case Some(module) => match (sourceUrl(documentation.project, module, symbol.source)) {
            case Some(url) => out.append("<p class=\"source-action\"><a href=\"${escapeHtml(url)}\" rel=\"noreferrer\">${label(locale, "View source", "查看源码")}</a></p>\n")
            case None => ()
        }
        case None => ()
    }
    out.append("</header>\n")
    appendDocumentationHtml(out, index, symbol, "../", assetLookup,
        typeLinkIndex, headingBase: 4, locale: locale)
    if (isTypeDeclaration(symbol)) {
        let filterLabel = label(locale, "Filter members", "筛选成员")
        let noResultsLabel = label(locale, "No matching members.", "没有匹配的成员。")
        out.append("<section class=\"member-browser\" data-cjdoc-member-browser>")
        out.append("<div class=\"member-browser-toolbar\"><label for=\"cjdoc-member-filter\">" + filterLabel + "</label><input id=\"cjdoc-member-filter\" type=\"search\" data-cjdoc-member-filter placeholder=\"" + filterLabel + "\" autocomplete=\"off\"></div>")
        out.append("<p class=\"member-filter-status\" data-cjdoc-member-filter-status role=\"status\" hidden>" + noResultsLabel + "</p>")
    }
    for (title in ["Constructors", "Properties", "Variables", "Functions", "Enum cases",
        "Nested classes", "Nested structs", "Nested interfaces", "Nested enums", "Nested extensions",
        "Other members"]) {
        appendMemberSection(out, index, membersByOwner, symbol, title, locale)
    }
    if (isTypeDeclaration(symbol)) { out.append("</section>\n") }
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}

