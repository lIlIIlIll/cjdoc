package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

internal func appendHtmlSidebar(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, rootPrefix: String, locale: String,
    currentPackagePath!: ?String = None, currentRoute!: String = "overview"): Unit {
    out.append("<aside id=\"cjdoc-sidebar\" class=\"docs-sidebar\" aria-label=\"${label(locale, "Documentation navigation", "文档导航")}\" tabindex=\"-1\">")
    out.append("<button class=\"sidebar-close\" type=\"button\" data-cjdoc-sidebar-close aria-label=\"${label(locale, "Close navigation", "关闭导航")}\">${label(locale, "Close", "关闭")}</button>")
    out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Documentation", "文档")}</p>")
    let overviewClass = if (currentRoute == "overview") { " is-current" } else { "" }
    let overviewCurrent = if (currentRoute == "overview") { " aria-current=\"page\"" } else { "" }
    let apiClass = if (currentRoute == "api") { " is-current" } else { "" }
    let apiCurrent = if (currentRoute == "api") { " aria-current=\"page\"" } else { "" }
    out.append("<a class=\"sidebar-link${overviewClass}\" data-cjdoc-nav-link${overviewCurrent} href=\"${rootPrefix}index.html\">${label(locale, "Overview", "总览")}</a>")
    out.append("<a class=\"sidebar-link${apiClass}\" data-cjdoc-nav-link${apiCurrent} href=\"${rootPrefix}index.html#packages\">${label(locale, "API Reference", "API 参考")}</a></div>")
    if (!projection.modules.isEmpty()) {
        out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Package reference", "包参考")}</p>")
        out.append("<label class=\"sidebar-filter-label\"><span class=\"sr-only\">${label(locale, "Filter packages", "筛选包")}</span><input class=\"sidebar-filter\" type=\"search\" placeholder=\"${label(locale, "Filter packages", "筛选包")}\" data-cjdoc-sidebar-filter></label>")
        out.append("<p class=\"sidebar-no-results\" data-cjdoc-sidebar-no-results role=\"status\" hidden>${label(locale, "No matching packages.", "没有匹配的包。")}</p>")
        for (projected in projection.modules) {
            let module = projected.source
            var isCurrentModule = false
            for (candidate in projected.packages) {
                if (currentPackagePath.isSome() && currentPackagePath.getOrThrow() ==
                    packagePagePath(candidate.source.moduleId, candidate.source.name)) { isCurrentModule = true }
            }
            let openAttribute = if (isCurrentModule) { " open" } else { "" }
            out.append("<details class=\"sidebar-group\"${openAttribute}><summary><span>${escapeHtml(module.name)}</span><span class=\"sidebar-count\">${projected.packages.size}</span></summary><div class=\"sidebar-packages\">")
            for (pkg in projected.packages) {
                let packagePath = packagePagePath(pkg.source.moduleId, pkg.source.name)
                let isCurrent = match (currentPackagePath) {
                    case Some(currentPath) => currentPath == packagePath
                    case None => false
                }
                let currentClass = if (isCurrent) { " is-current" } else { "" }
                let currentAttribute = if (isCurrent) { " aria-current=\"page\"" } else { "" }
                out.append("<a class=\"sidebar-package${currentClass}\" data-cjdoc-nav-link${currentAttribute} href=\"${rootPrefix}${escapeHtml(packagePath)}\"><span>${escapeHtml(pkg.source.name)}</span><span class=\"sidebar-package-count\">${pkg.symbols.size}</span></a>")
            }
            out.append("</div></details>")
        }
        out.append("</div>")
    }
    out.append("<p class=\"sidebar-note\">${label(locale, "Generated from", "生成自")}<code>${escapeHtml(documentation.schemaVersion)}</code></p></aside>")
}

internal func appendPageStart(out: RenderTextBuffer, title: String, rootPrefix: String,
    documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", currentPackagePath!: ?String = None,
    currentRoute!: String = "overview", docVersion!: ?String = None): Unit {
    let projectLabel = escapeHtml(documentation.project.name)
    let documentVersionLabel = match (docVersion) {
        case Some(value) => escapeHtml(value)
        case None => label(locale, "Document version not set", "未设置文档版本")
    }
    let filtersLabel = label(locale, "Filters", "筛选")
    let searchCategoriesLabel = label(locale, "Search categories", "搜索类别")
    let allLabel = label(locale, "All", "全部")
    let classesLabel = label(locale, "Classes", "类")
    let functionsLabel = label(locale, "Functions", "函数")
    let otherLabel = label(locale, "Other", "其他")
    let filterPackageLabel = label(locale, "Filter by package", "按包筛选")
    let allPackagesLabel = label(locale, "All packages", "全部包")
    let chooseThemeLabel = label(locale, "Choose theme", "切换主题")
    let themeLabel = label(locale, "Theme", "主题")
    let themeModeLabel = label(locale, "Theme mode", "主题模式")
    let systemThemeLabel = label(locale, "System", "系统")
    let lightThemeLabel = label(locale, "Light", "浅色")
    let darkThemeLabel = label(locale, "Dark", "深色")
    let paperThemeLabel = label(locale, "Paper", "纸张")
    let oceanThemeLabel = label(locale, "Ocean", "海洋")
    let forestThemeLabel = label(locale, "Forest", "森林")
    let terminalThemeLabel = label(locale, "Terminal", "终端")
    let violetThemeLabel = label(locale, "Violet", "紫罗兰")
    let openNavigationLabel = label(locale, "Open navigation", "打开导航")
    let searchApiLabel = label(locale, "Search API", "搜索 API")
    let searchDocsLabel = label(locale, "Search docs", "搜索文档")
    let closeNavigationLabel = label(locale, "Close navigation", "关闭导航")
    let onThisPageLabel = label(locale, "On this page", "本页目录")
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><script src=\"${rootPrefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body data-cjdoc-route=\"${escapeHtml(currentRoute)}\" data-cjdoc-project=\"${projectLabel}\"")
    match (docVersion) {
        case Some(value) => out.append(" data-cjdoc-doc-version=\"${escapeHtml(value)}\"")
        case None => ()
    }
    out.append(">\n")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<button class=\"nav-menu\" type=\"button\" data-cjdoc-menu aria-expanded=\"false\" aria-controls=\"cjdoc-sidebar\" aria-label=\"")
    out.append(openNavigationLabel)
    out.append("\"><svg width=\"18\" height=\"18\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" aria-hidden=\"true\"><path d=\"M4 7h16M4 12h16M4 17h16\"></path></svg></button>")
    out.append("<a class=\"brand\" href=\"${rootPrefix}index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span class=\"brand-copy\"><strong class=\"brand-project\">${projectLabel}</strong><span class=\"brand-subtitle\">${documentVersionLabel}</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><svg width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"></circle><path d=\"m20 20-4-4\"></path></svg><label class=\"sr-only\" for=\"cjdoc-search-input\">")
    out.append(searchApiLabel)
    out.append("</label>")
    out.append("<input id=\"cjdoc-search-input\" type=\"search\" placeholder=\"")
    out.append(searchDocsLabel)
    out.append("\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"")
    out.append(rootPrefix)
    out.append("\"><kbd>Ctrl K</kbd></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul><p class=\"search-status\" data-cjdoc-search-status role=\"status\" hidden></p></div>")
    out.append("<button class=\"search-filter-toggle\" type=\"button\" data-cjdoc-filter-toggle aria-expanded=\"false\" aria-controls=\"cjdoc-search-filters\">${filtersLabel}</button>")
    out.append("<div id=\"cjdoc-search-filters\" class=\"search-filters\"><div class=\"search-tabs\" role=\"tablist\" aria-label=\"")
    out.append(searchCategoriesLabel)
    out.append("\"><button type=\"button\" role=\"tab\" aria-selected=\"true\" aria-pressed=\"true\" data-cjdoc-category=\"all\">")
    out.append(allLabel)
    out.append("</button><button type=\"button\" role=\"tab\" aria-selected=\"false\" aria-pressed=\"false\" data-cjdoc-category=\"classes\">")
    out.append(classesLabel)
    out.append("</button><button type=\"button\" role=\"tab\" aria-selected=\"false\" aria-pressed=\"false\" data-cjdoc-category=\"functions\">")
    out.append(functionsLabel)
    out.append("</button><button type=\"button\" role=\"tab\" aria-selected=\"false\" aria-pressed=\"false\" data-cjdoc-category=\"other\">")
    out.append(otherLabel)
    out.append("</button></div><label><span class=\"sr-only\">")
    out.append(filterPackageLabel)
    out.append("</span><select data-cjdoc-package aria-label=\"")
    out.append(filterPackageLabel)
    out.append("\"><option value=\"\">")
    out.append(allPackagesLabel)
    out.append("</option></select></label></div>")
    out.append("<div class=\"top-actions\"><span class=\"version-label\" title=\"")
    out.append(label(locale, "Generated by cjdoc", "由 cjdoc 生成"))
    out.append("\">cjdoc ")
    out.append(escapeHtml(documentation.generator.version))
    out.append("</span><div class=\"theme-control\" data-cjdoc-theme-control><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-haspopup=\"dialog\" aria-expanded=\"false\" aria-label=\"")
    out.append(chooseThemeLabel)
    out.append("\">")
    out.append(themeLabel)
    out.append("</button><div class=\"theme-popover\" data-cjdoc-theme-popover role=\"dialog\" aria-label=\"")
    out.append(themeLabel)
    out.append("\" hidden><div class=\"theme-options\" role=\"group\" aria-label=\"")
    out.append(themeModeLabel)
    out.append("\">")
    out.append("<button type=\"button\" data-cjdoc-theme-value=\"system\">")
    out.append(systemThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"light\">")
    out.append(lightThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"dark\">")
    out.append(darkThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"paper\">")
    out.append(paperThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"ocean\">")
    out.append(oceanThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"forest\">")
    out.append(forestThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"terminal\">")
    out.append(terminalThemeLabel)
    out.append("</button><button type=\"button\" data-cjdoc-theme-value=\"violet\">")
    out.append(violetThemeLabel)
    out.append("</button></div></div></div></div>")
    out.append("</div></div></header>\n<div class=\"docs-layout\">")
    out.append("<button class=\"nav-backdrop\" type=\"button\" data-cjdoc-menu-backdrop aria-label=\"")
    out.append(closeNavigationLabel)
    out.append("\" hidden></button>")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath, currentRoute: currentRoute)
    out.append("<main class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\"><details class=\"mobile-toc\" data-cjdoc-mobile-toc hidden><summary>")
    out.append(onThisPageLabel)
    out.append("</summary><nav><ol></ol></nav></details>\n")
}

internal func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    let onThisPageLabel = label(locale, "On this page", "本页目录")
    let generatedFromLabel = label(locale, "Generated from Doc IR", "由 Doc IR 生成")
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"")
    out.append(onThisPageLabel)
    out.append("\" hidden><p class=\"toc-title\">")
    out.append(onThisPageLabel)
    out.append("</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><span><span class=\"footer-mark\">cjdoc</span> · ")
    out.append(generatedFromLabel)
    out.append("</span><span>")
    out.append(escapeHtml(documentation.generator.version))
    out.append(" · ")
    out.append(escapeHtml(documentation.schemaVersion))
    out.append("</span></div></footer></body></html>\n")
}

internal func htmlTocLabel(symbol: SymbolDoc): String {
    let header = symbol.headerSpelling.trimAscii()
    if (header.isEmpty()) { return "${symbol.kind} ${symbol.name}" }
    let visibilityPrefix = "${symbol.visibility} "
    if (header.startsWith(visibilityPrefix)) {
        return header[visibilityPrefix.size..].trimAscii()
    }
    header
}

internal func findTag(comment: DocComment, name: String, subject!: ?String = None): ?DocTag {
    for (tag in comment.tags) {
        if (tag.name == name && (subject.isNone() || tag.subject == subject.getOrThrow())) { return Some(tag) }
    }
    None
}

internal func tagHeading(name: String): String {
    match (name) {
        case "since" => "Since"
        case "author" => "Authors"
        case "version" => "Version"
        case _ => name
    }
}

internal func isUnitType(value: TypeRef): Bool {
    match (value.semantic.canonical) {
        case Some(canonical) => canonical == "Unit" || canonical == "std.core.Unit"
        case None => value.spelling.trimAscii() == "Unit"
    }
}

internal func summaryParagraph(comment: DocComment): ?MarkdownNode {
    if (comment.markdown.kind == "paragraph") { return Some(comment.markdown) }
    for (child in comment.markdown.children) {
        if (child.kind == "paragraph") { return Some(child) }
    }
    None
}

internal func topLevelParagraphIndex(comment: DocComment): Int64 {
    if (comment.markdown.kind == "paragraph") { return 0 }
    var index: Int64 = 0
    for (child in comment.markdown.children) {
        if (child.kind == "paragraph") { return index }
        index++
    }
    -1
}

internal func summaryPlainText(comment: DocComment): String {
    match (summaryParagraph(comment)) {
        case Some(paragraph) => markdownNodeText(paragraph)
        case None =>
            if (comment.markdown.children.isEmpty() && comment.markdown.literal.isEmpty()) {
                comment.summary.trimAscii()
            } else { "" }
    }
}

internal func appendSummaryHtml(out: RenderTextBuffer, comment: DocComment,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, rootPrefix: String): Unit {
    match (summaryParagraph(comment)) {
        case Some(paragraph) =>
            let context = markdownHtmlContext(comment, symbol, 2)
            out.append("<div class=\"symbol-summary\">")
            appendMarkdownNodeHtml(out, paragraph, assetLookup, rootPrefix, context)
            out.append("</div>\n")
            ()
        case None =>
            if (comment.markdown.children.isEmpty() && comment.markdown.literal.isEmpty() &&
                !comment.summary.trimAscii().isEmpty()) {
                out.append("<div class=\"symbol-summary\"><p>")
                out.append(escapeHtml(comment.summary.trimAscii()))
                out.append("</p></div>\n")
                ()
            } else { () }
    }
}

internal func appendDocumentationHtml(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    headingBase!: Int64 = 3,
    locale!: String = "en"): Unit {
    match (symbol.documentation) {
        case Some(comment) =>
            match (findTag(comment, "deprecated")) {
                case Some(tag) =>
                    out.append("<aside class=\"callout\"><strong>${label(locale, "Deprecated.", "已弃用。")}</strong> ")
                    appendStructuredTextHtml(out, tag.description)
                    out.append("</aside>\n")
                case None => ()
            }
                        let summaryIndex = topLevelParagraphIndex(comment)
            if (comment.markdown.kind != "paragraph") {
            var hasDescription = false
            var childIndex: Int64 = 0
            for (child in comment.markdown.children) {
                if (childIndex != summaryIndex) { hasDescription = true; break }
                childIndex++
            }
            if (hasDescription) {
                out.append("<h2>${label(locale, "Overview", "概览")}</h2><div class=\"description\">")
                let markdownContext = markdownHtmlContext(comment, symbol, headingBase)
                childIndex = 0
                for (child in comment.markdown.children) {
                    if (childIndex != summaryIndex) {
                        appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, markdownContext)
                    }
                    childIndex++
                }
                out.append("</div>\n")
            }
            }
            appendDocumentationExamplesHtml(out, comment, locale)
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt><code>${escapeHtml(parameter.name)}</code></dt><dd class=\"parameter-type\"><span class=\"parameter-colon\">:</span>")
                    appendTypeRefCodeHtml(out, parameter.typeRef, typeLinkIndex, rootPrefix, locale,
                        className: "parameter-type-code")
                    out.append("</dd><dd class=\"parameter-description\">")
                    match (parameter.documentation) {
                        case Some(value) => appendStructuredTextHtml(out, value)
                        case None => match (findTag(comment, "param", subject: Some(parameter.name))) {
                            case Some(tag) => appendStructuredTextHtml(out, tag.description)
                            case None => ()
                        }
                    }
                    out.append("</dd></div>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => if (!isUnitType(returnType)) {
                    out.append("<h3>${label(locale, "Returns", "返回值")}</h3><div class=\"return-value\">")
                    appendTypeRefCodeHtml(out, returnType, typeLinkIndex, rootPrefix, locale,
                        className: "return-type")
                    match (findTag(comment, "return")) {
                        case Some(tag) =>
                            out.append("<div class=\"return-description\">")
                            appendStructuredTextHtml(out, tag.description)
                            out.append("</div>")
                        case None => ()
                    }
                    out.append("</div>\n")
                }
                case None => ()
            }
            var hasThrows = false
            for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
            if (hasThrows) {
                out.append("<h3>${label(locale, "Throws", "异常")}</h3><dl>\n")
                for (tag in comment.tags) {
                    if (tag.name == "throws") {
                        out.append("<dt><code>${escapeHtml(tag.subject)}</code></dt><dd>")
                        appendStructuredTextHtml(out, tag.description)
                        out.append("</dd>\n")
                    }
                }
                out.append("</dl>\n")
            }
            var hasSee = false
            for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
            if (hasSee) {
                out.append("<h3>${label(locale, "See also", "另请参阅")}</h3><ul>\n")
                for (tag in comment.tags) {
                    if (tag.name != "see") { continue }
                    out.append("<li>")
                    match (tag.targetSymbolId) {
                        case Some(targetId) => match (findSymbol(index, targetId)) {
                            case Some(target) =>
                                out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(tag.subject)}</code></a>")
                            case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                        }
                        case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                    }
                    if (!tag.description.isEmpty()) {
                        out.append(" "); appendStructuredTextHtml(out, tag.description)
                    }
                    out.append("</li>\n")
                }
                out.append("</ul>\n")
            }
            for (name in ["since", "author", "version"]) {
                var opened = false
                for (tag in comment.tags) {
                    if (tag.name != name) { continue }
                    if (!opened) { out.append("<h3>${escapeHtml(label(locale, tagHeading(name), match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" }))}</h3><ul>\n"); opened = true }
                    out.append("<li>"); appendStructuredTextHtml(out, tag.description); out.append("</li>\n")
                }
                if (opened) { out.append("</ul>\n") }
            }
        case None =>
            out.append("<h2>${label(locale, "Overview", "概览")}</h2><p class=\"empty-state\">${label(locale, "No documentation is available for this declaration.", "此声明暂无文档。")}</p>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt><code>${escapeHtml(parameter.name)}</code></dt><dd class=\"parameter-type\"><span class=\"parameter-colon\">:</span>")
                    appendTypeRefCodeHtml(out, parameter.typeRef, typeLinkIndex, rootPrefix, locale,
                        className: "parameter-type-code")
                    out.append("</dd><dd class=\"parameter-description\"></dd></div>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => if (!isUnitType(returnType)) {
                    out.append("<h3>${label(locale, "Returns", "返回值")}</h3><div class=\"return-value\">")
                    appendTypeRefCodeHtml(out, returnType, typeLinkIndex, rootPrefix, locale,
                        className: "return-type")
                    out.append("</div>\n")
                }
                case None => ()
            }
    }
}

private func hasResolvedSymbolRelationship(symbol: SymbolDoc, kind: String, display: String): Bool {
    for (relationship in symbol.symbolRelationships) {
        if (relationship.kind == kind && relationship.targetDisplay == display &&
            relationship.state == "resolved" && relationship.targetSymbolId.isSome()) {
            return true
        }
    }
    false
}

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, locale!: String = "en"): Unit {
    out.append("<div class=\"symbol-meta\"><p class=\"symbol-kind\">${escapeHtml(symbol.kind)}")
    if (symbol.visibility != "public") {
        out.append(" <span class=\"badge\">${escapeHtml(symbol.visibility)}</span>")
    }
    if (symbol.semantic.state != "resolved") {
        out.append(" <span class=\"badge\" data-state=\"${escapeHtml(symbol.semantic.state)}\">semantic: ${escapeHtml(symbol.semantic.state)}</span>")
    }
    out.append("</p>")
    match (symbol.documentation) {
        case Some(comment) => appendSummaryHtml(out, comment, symbol, assetLookup, rootPrefix)
        case None => ()
    }
    out.append("<h2 class=\"signature-heading\">${label(locale, "Signature", "签名")}</h2><pre class=\"signature-block\"><code>${escapeHtml(symbol.headerSpelling)}</code></pre>")
    if (symbol.ownerId.isSome() || !symbol.genericParameters.isEmpty() ||
        !symbol.annotations.isEmpty() || !symbol.typeRelationships.isEmpty() ||
        !symbol.symbolRelationships.isEmpty()) {
        out.append("<details class=\"contextual-metadata\"><summary>${label(locale, "Declaration details", "声明详情")}</summary>")
        match (symbol.ownerId) {
            case Some(ownerId) => match (findSymbol(index, ownerId)) {
                case Some(owner) => out.append("<p class=\"meta\">${label(locale, "Owner", "所属")}: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a></p>")
                case None => ()
            }
            case None => ()
        }
        if (!symbol.genericParameters.isEmpty()) {
            out.append("<p class=\"meta\">${label(locale, "Generic parameters", "泛型参数")}: ")
            var first = true
            for (parameter in symbol.genericParameters) { if (!first) { out.append(", ") }; first = false; out.append("<code>${escapeHtml(parameter)}</code>") }
            out.append("</p>")
        }
        if (!symbol.annotations.isEmpty()) {
            out.append("<p class=\"meta\">${label(locale, "Annotations", "注解")}: ")
            for (annotation in symbol.annotations) { out.append("<code>${escapeHtml(annotation.spelling)}</code> ") }
            out.append("</p>")
        }
        if (!symbol.typeRelationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
            out.append("<dl class=\"relationships\">")
            for (relationship in symbol.typeRelationships) {
                if (hasResolvedSymbolRelationship(symbol, relationship.kind, relationship.target.spelling)) {
                    continue
                }
                out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd><code>${escapeHtml(relationship.target.spelling)}</code>")
                if (relationship.target.semantic.state != "resolved") {
                    out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span>")
                }
                out.append("</dd>")
            }
            for (relationship in symbol.symbolRelationships) {
                match (relationship.targetSymbolId) {
                    case Some(targetId) => if (!index.contains(targetId)) { continue }
                    case None => ()
                }
                out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
                match (relationship.targetSymbolId) {
                    case Some(targetId) => match (findSymbol(index, targetId)) {
                        case Some(target) => out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                        case None => ()
                    }
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                if (relationship.state != "resolved") {
                    out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.state)}\">${escapeHtml(relationship.state)}</span>")
                }
                out.append("</dd>")
            }
            out.append("</dl>")
        }
        out.append("</details>")
    }
    out.append("</div>\n")
}
