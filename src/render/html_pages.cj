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
        documentation, projection, locale: locale, docVersion: docVersion)
    out.append("<header class=\"page-header\"><h1>${escapeHtml(documentation.project.name)} ${apiDocumentationLabel}</h1></header>\n")
    // One reader entry point only. The conceptual-documentation entry is merged
    // into this section by injectConceptualNavigation, so the page never stacks
    // two headings that both tell the reader to start here.
    out.append("<section class=\"quick-start\" aria-labelledby=\"quick-start-title\"><h2 id=\"quick-start-title\">")
    out.append(startHereLabel)
    out.append("</h2><p>")
    out.append(startHereCopy)
    out.append("</p><a href=\"#packages\">")
    out.append(browseApiLabel)
    out.append("</a><div class=\"conceptual-entry\" data-conceptual-entry></div></section>\n")
    if (!projection.modules.isEmpty()) {
        out.append("<h2 id=\"modules\">")
        out.append(modulesLabel)
        out.append("</h2><div class=\"module-list\">\n")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<section class=\"module-record\"><h3><code>${escapeHtml(module.name)}</code> <span class=\"badge\">${escapeHtml(htmlKindLabel(module.role, locale))}</span></h3>")
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<p class=\"meta\">${label(locale, "Source prefix", "源码目录")}: <code>${escapeHtml(prefix)}</code> · ${projected.packages.size} ")
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
        out.append("<details class=\"generation-metadata\" open><summary>${label(locale, "Generation status", "生成状态")}</summary><p>${escapeHtml(htmlStateLabel(documentation.status, locale))}</p></details>\n")
    }
    if (!documentation.diagnostics.isEmpty()) {
        out.append("<details id=\"diagnostics\" class=\"build-details\"><summary>")
        out.append(diagnosticsLabel)
        out.append("</summary><ul class=\"diagnostics-list\">\n")
        for (diagnostic in documentation.diagnostics) {
            if (let Some(symbolId) <- diagnostic.symbolId) {
                if (!projection.visibleIndex.contains(symbolId)) { continue }
            }
            out.append("<li><strong>${escapeHtml(htmlStateLabel(diagnostic.severity, locale))}[${escapeHtml(diagnostic.code)}]</strong>: ${escapeHtml(diagnostic.message)}")
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
    rootPrefix: String, locale!: String = "en"): Unit {
    out.append("<article class=\"declaration-summary\" data-cjdoc-member data-member-name=\"${escapeHtml(symbol.name)}\" data-member-kind=\"${escapeHtml(symbol.kind)}\"><a class=\"declaration-row-link\" href=\"${rootPrefix}${escapeHtml(symbolPagePath(symbol))}\">")
    out.append("<div class=\"declaration-summary-head\"><code>${escapeHtml(symbol.name)}</code><span class=\"declaration-kind\">${escapeHtml(htmlKindLabel(symbol.kind, locale))}</span></div>")
    match (symbol.documentation) {
        case Some(comment) =>
            let summary = summaryPlainText(comment)
            if (!summary.isEmpty()) { out.append("<p>"); out.append(escapeHtml(summary)); out.append("</p>") }
        case None => ()
    }
    if (!symbol.headerSpelling.isEmpty()) {
        out.append("<code class=\"declaration-signature\">")
        appendSignatureTextHtml(out, symbol)
        out.append("</code>")
    }
    out.append("</a></article>\n")
}

public func renderUtilityHtmlPage(documentation: DocumentationSet, title: String, body: String,
    rootPrefix: String, locale!: String = "en", docVersion!: ?String = None): String {
    let projection = RenderProjection(documentation)
    let out = RenderTextBuffer()
    appendPageStart(out, title, rootPrefix, documentation, projection, locale: locale,
        currentRoute: "utility", docVersion: docVersion)
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"${rootPrefix}index.html\">${label(locale, "Home", "首页")}</a></li><li aria-current=\"page\">${escapeHtml(title)}</li></ol></nav>")
    out.append("<header class=\"page-header\"><h1>${escapeHtml(title)}</h1></header>\n")
    out.append(body)
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
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
    appendPageStart(out, title, rootPrefix, documentation, projection, locale: locale,
        currentRoute: "concept", docVersion: docVersion)
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
        documentation, projection, locale: locale, docVersion: docVersion,
        currentPackagePath: Some(packagePagePath(packageDoc.moduleId, packageDoc.name)),
        currentRoute: "api")
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
                appendDeclarationRow(out, symbol, "../", locale: locale)
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

// Inline icons are deterministic local SVG; they require no external assets.
private func appendMemberActionGlyph(out: RenderTextBuffer, kind: String): Unit {
    out.append("<svg class=\"member-action-glyph\" width=\"18\" height=\"18\" " +
        "viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" " +
        "stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" " +
        "aria-hidden=\"true\" focusable=\"false\">")
    match (kind) {
        case "standalone" =>
            out.append("<path d=\"M14 4h6v6\"/><path d=\"M20 4l-9 9\"/>")
            out.append("<path d=\"M20 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h5\"/>")
        case "copy" =>
            out.append("<rect x=\"8\" y=\"8\" width=\"12\" height=\"12\" rx=\"2\"/>")
            out.append("<path d=\"M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2\"/>")
        case "source" =>
            out.append("<path d=\"m8 9-3 3 3 3\"/><path d=\"m16 9 3 3-3 3\"/>")
            out.append("<path d=\"m14 5-4 14\"/>")
        case _ => ()
    }
    out.append("</svg>")
}

internal func appendInlineMemberDetail(out: RenderTextBuffer,
    documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, entry: HtmlMemberEntry,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    rootPrefix: String, locale: String,
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>()): Unit {
    let member = entry.symbol
    let anchor = symbolAnchor(member)
    let standaloneLabel = label(locale, "Open standalone API page", "打开独立 API 页面")
    out.append("<details class=\"declaration-summary member-detail\" id=\"${escapeHtml(anchor)}\" data-cjdoc-member data-member-name=\"${escapeHtml(member.name)}\" data-member-kind=\"${escapeHtml(member.kind)}\" data-member-origin=\"${escapeHtml(entry.origin)}\">")
    out.append("<summary class=\"member-detail-summary\"><span class=\"member-summary-main\">")
    if (!member.headerSpelling.isEmpty()) {
        out.append("<code class=\"declaration-signature\">")
        appendSignatureTextHtml(out, member)
        out.append("</code>")
    } else {
        out.append("<code class=\"declaration-signature\">${escapeHtml(member.name)}</code>")
    }
    out.append("</span>")
    if (entry.origin != "declared") {
        out.append("<span class=\"declaration-kind\">" +
            escapeHtml(memberOriginLabel(entry.origin, locale)) + "</span>")
    }
    match (member.documentation) {
        case Some(comment) =>
            let summary = summaryPlainText(comment)
            if (!summary.isEmpty()) {
                out.append("<span class=\"member-summary-description\">${escapeHtml(summary)}</span>")
            }
        case None => ()
    }
    out.append("</summary><div class=\"member-detail-body\">")
    if (entry.origin != "declared") {
        match (entry.declaredBy) {
            case Some(declaredBy) =>
                out.append("<p class=\"member-origin\">" +
                    escapeHtml(memberOriginLabel(entry.origin, locale)) + " · <a href=\"" +
                    rootPrefix + escapeHtml(symbolPagePath(declaredBy)) + "\"><code>" +
                    escapeHtml(declaredBy.qualifiedName) + "</code></a></p>")
                if (entry.origin == "extension") {
                    out.append("<p class=\"extension-conditions\">" +
                        label(locale,
                            "Subject to the extension target and constraints; applicability is not inferred.",
                            "成员受扩展目标与约束限制；此处不推断对具体实例的适用性。") +
                        "</p>")
                    if (!declaredBy.headerSpelling.isEmpty()) {
                        out.append("<pre class=\"extension-signature\"><code>" +
                            escapeHtml(declaredBy.headerSpelling) + "</code></pre>")
                    }
                }
            case None => ()
        }
    }
    // Keep navigation and copy controls outside <summary>. All three share
    // the same icon-only presentation, while screen readers and hover users
    // still receive precise localized action names.
    let copyLabel = label(locale, "Copy link", "复制链接")
    let sourceLabel = label(locale, "View source code", "查看源码")
    out.append("<div class=\"member-detail-actions\" role=\"group\" aria-label=\"" +
        label(locale, "Member actions", "成员操作") + "\">")
    out.append("<a class=\"member-action member-permalink\" href=\"" +
        rootPrefix + escapeHtml(symbolPagePath(member)) + "\" aria-label=\"" +
        escapeHtml(standaloneLabel) + "\" title=\"" + escapeHtml(standaloneLabel) + "\">")
    appendMemberActionGlyph(out, "standalone")
    out.append("</a>")
    match (findProjectedModule(projection, member.moduleId)) {
        case Some(module) => match (sourceUrl(documentation.project, module, member.source)) {
            case Some(url) =>
                out.append("<a class=\"member-action member-source-link\" href=\"" +
                    escapeHtml(url) + "\" rel=\"noreferrer\" aria-label=\"" +
                    escapeHtml(sourceLabel) + "\" title=\"" + escapeHtml(sourceLabel) + "\">")
                appendMemberActionGlyph(out, "source")
                out.append("</a>")
            case None => ()
        }
        case None => ()
    }
    out.append("<button class=\"member-action member-action-copy copy-link\" type=\"button\" " +
        "data-cjdoc-copy-link=\"" + rootPrefix +
        escapeHtml(symbolReadablePagePath(member)) + "\" aria-label=\"" +
        escapeHtml(copyLabel) + "\" title=\"" + escapeHtml(copyLabel) + "\">")
    appendMemberActionGlyph(out, "copy")
    out.append("</button><span class=\"sr-only\" data-cjdoc-copy-status " +
        "role=\"status\" aria-live=\"polite\"></span></div>")
    appendDocumentationHtml(out, index, member, rootPrefix, assetLookup, typeLinkIndex,
        headingBase: 3, locale: locale, exampleEvidence: exampleEvidence)
    appendReaderRelationships(out, index, member, rootPrefix, typeLinkIndex, locale,
        headingTag: "h3")
    appendReverseTypeUsages(out, index, typeLinkIndex, member, rootPrefix, locale)
    out.append("</div></details>\n")
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
    documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, browser: HtmlMemberBrowser,
    title: String, assetLookup: HashMap<String, String>,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>()): Unit {
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
    let overloadCountLabel = label(locale, "overloads", "个重载")
    let overloadCounts = HashMap<String, Int64>()
    for (entry in browser.entries) {
        if (memberSectionTitle(entry.symbol) != title) { continue }
        let key = "${entry.groupKey}:${entry.symbol.name}"
        overloadCounts[key] = match (overloadCounts.get(key)) {
            case Some(value) => value + 1
            case None => 1
        }
    }
    var opened = false
    var activeOverloadKey = ""
    for (entry in browser.entries) {
        let member = entry.symbol
        if (memberSectionTitle(member) != title) { continue }
        if (!opened) {
            out.append("<section class=\"member-group\" data-cjdoc-member-group><h2>" +
                escapeHtml(label(locale, title, sectionLabel)) + "</h2>\n")
            opened = true
        }
        let overloadKey = "${entry.groupKey}:${member.name}"
        let count = match (overloadCounts.get(overloadKey)) {
            case Some(value) => value
            case None => 0
        }
        if (!activeOverloadKey.isEmpty() && activeOverloadKey != overloadKey) {
            out.append("</div>\n")
            activeOverloadKey = ""
        }
        if (count > 1 && activeOverloadKey.isEmpty()) {
            let groupTitleId = "overloads-" + symbolAnchor(member)
            out.append("<div class=\"member-overload-group\" role=\"group\" aria-labelledby=\"" +
                escapeHtml(groupTitleId) + "\" data-cjdoc-overload-group data-overload-total=\"" +
                count.toString() + "\">")
            out.append("<h3 class=\"overload-group-label\" id=\"" +
                escapeHtml(groupTitleId) + "\"><code>" + escapeHtml(member.name) +
                "</code><span class=\"overload-count\" data-cjdoc-overload-count>" +
                count.toString() + " " + escapeHtml(overloadCountLabel) + "</span></h3>\n")
            activeOverloadKey = overloadKey
        }
        appendInlineMemberDetail(out, documentation, projection, index, entry,
            assetLookup, typeLinkIndex, "../", locale, exampleEvidence: exampleEvidence)
    }
    if (!activeOverloadKey.isEmpty()) { out.append("</div>\n") }
    if (opened) { out.append("</section>\n") }
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
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", docVersion!: ?String = None,
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>()): String {
    let out = RenderTextBuffer()
    appendPageStart(out, symbol.qualifiedName, "../", documentation, projection, locale: locale,
        currentPackagePath: Some(packagePagePath(symbol.moduleId, symbol.packageName)),
        currentRoute: "api", docVersion: docVersion, currentSymbol: Some(symbol))
    out.append("<nav class=\"breadcrumbs\" aria-label=\"${label(locale, "Breadcrumb", "面包屑导航")}\"><ol><li><a href=\"../index.html\">${label(locale, "Home", "首页")}</a></li>")
    out.append("<li><a href=\"../${escapeHtml(packagePagePath(symbol.moduleId, symbol.packageName))}\">${label(locale, "Package", "包")} <code>${escapeHtml(symbol.packageName)}</code></a></li>")
    appendOwnerBreadcrumbs(out, index, symbol, "../", locale)
    out.append("<li aria-current=\"page\"><code>${escapeHtml(symbol.name)}</code></li></ol></nav>\n")
    out.append("<header class=\"page-header api-page-header\"><div class=\"api-title-row\"><h1 data-cjdoc-toc-role=\"api-root\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\"><code>${escapeHtml(symbol.name)}</code></h1>")
    out.append("<button class=\"copy-link\" type=\"button\" data-cjdoc-copy-link=\"../${escapeHtml(symbolReadablePagePath(symbol))}\">${label(locale, "Copy link", "复制链接")}</button></div>")
    out.append("<p class=\"symbol-kind\">${escapeHtml(htmlKindLabel(symbol.kind, locale))}</p>")
    appendSymbolMetadata(out, index, symbol, "../", assetLookup, typeLinkIndex,
        locale: locale)
    match (findProjectedModule(projection, symbol.moduleId)) {
        case Some(module) => match (sourceUrl(documentation.project, module, symbol.source)) {
            case Some(url) => out.append("<p class=\"source-action\"><a href=\"${escapeHtml(url)}\" rel=\"noreferrer\">${label(locale, "View source", "查看源码")}</a></p>\n")
            case None => ()
        }
        case None => ()
    }
    out.append("</header>\n")
    if (isTypeDeclaration(symbol)) {
        appendDocumentationIntroductionHtml(out, symbol, "../", assetLookup, 4, locale)
        match (symbol.documentation) {
            case Some(comment) => appendDocumentationContractsHtml(out, comment, locale, symbolAnchor(symbol))
            case None => ()
        }
        // Relations explain the type before readers browse its members.
        appendReaderRelationships(out, index, symbol, "../", typeLinkIndex, locale)
        let filterLabel = label(locale, "Filter members", "筛选成员")
        let originLabel = label(locale, "Origin", "来源")
        let noResultsLabel = label(locale, "No matching members.", "没有匹配的成员。")
        let browser = projection.members(symbol)
        if (!browser.entries.isEmpty()) {
            out.append("<section class=\"member-browser\" data-cjdoc-member-browser aria-label=\"${label(locale, "Members", "成员")}\">")
            out.append("<div class=\"member-browser-toolbar\"><label for=\"cjdoc-member-filter\">" +
                filterLabel + "</label><input id=\"cjdoc-member-filter\" type=\"search\" data-cjdoc-member-filter placeholder=\"" +
                filterLabel + "\" autocomplete=\"off\">")
            out.append("<label for=\"cjdoc-member-origin\">" + originLabel +
                "</label><select id=\"cjdoc-member-origin\" data-cjdoc-member-origin><option value=\"\">" +
                label(locale, "All origins", "所有来源") + "</option>")
            for (origin in ["declared", "inherited", "extension"]) {
                out.append("<option value=\"" + origin + "\">" +
                    escapeHtml(memberOriginLabel(origin, locale)) + "</option>")
            }
            out.append("</select><div class=\"member-browser-actions\"><button type=\"button\" data-cjdoc-members-expand>" +
                label(locale, "Expand all", "全部展开") + "</button><button type=\"button\" data-cjdoc-members-collapse>" +
                label(locale, "Collapse all", "全部收起") + "</button></div></div>")
            out.append("<p class=\"member-filter-status\" data-cjdoc-member-filter-status role=\"status\" hidden>" +
                noResultsLabel + "</p>")
            for (title in ["Constructors", "Properties", "Variables", "Functions", "Enum cases",
                "Nested classes", "Nested structs", "Nested interfaces", "Nested enums",
                "Nested extensions", "Other members"]) {
                appendMemberSection(out, documentation, projection, index, browser,
                    title, assetLookup, typeLinkIndex, locale, exampleEvidence: exampleEvidence)
            }
            out.append("</section>\n")
        }
    }
    appendDocumentationHtml(out, index, symbol, "../", assetLookup,
        typeLinkIndex, headingBase: 4, locale: locale, includeContracts: !isTypeDeclaration(symbol),
        includeIntroduction: !isTypeDeclaration(symbol), exampleEvidence: exampleEvidence)
    if (!isTypeDeclaration(symbol)) {
        appendReaderRelationships(out, index, symbol, "../", typeLinkIndex, locale)
    }
    appendReverseTypeUsages(out, index, typeLinkIndex, symbol, "../", locale)
    appendPageEnd(out, documentation, locale: locale)
    out.toString()
}
