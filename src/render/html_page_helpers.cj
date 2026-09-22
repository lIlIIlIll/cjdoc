package cjdoc.render

import cjdoc.model.*
import std.ast.*
import std.collection.*
import std.sort.*

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
    let documentationVersionContextLabel = label(locale, "Documentation version", "文档版本")
    let audienceContextLabel = label(locale, "Audience", "受众")
    let configurationContextLabel = label(locale, "Target configuration", "目标配置")
    let generatorContextLabel = label(locale, "Generator", "生成器")
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
    let searchSyntaxLabel = label(locale, "Filters: name:, owner:, param:, return:, package:, kind:", "筛选：name:、owner:、param:、return:、package:、kind:")
    let searchDocsLabel = label(locale, "Search docs", "搜索文档")
    let closeNavigationLabel = label(locale, "Close navigation", "关闭导航")
    let onThisPageLabel = label(locale, "On this page", "本页目录")
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self' file:; style-src 'self' file:; img-src 'self' file:; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${projectLabel} · ${escapeHtml(title)}</title><script src=\"${rootPrefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body data-cjdoc-route=\"${escapeHtml(currentRoute)}\" data-cjdoc-project=\"${projectLabel}\"")
    match (docVersion) {
        case Some(value) => out.append(" data-cjdoc-doc-version=\"${escapeHtml(value)}\"")
        case None => ()
    }
    out.append(" data-cjdoc-audience=\"${escapeHtml(documentation.configuration.audience)}\" data-cjdoc-cfg=\"${escapeHtml(documentation.configuration.cfgProfile)}\">\n")
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
    out.append("\" autocomplete=\"off\" title=\"${escapeHtml(searchSyntaxLabel)}\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"")
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
    out.append("</div></div></header>\n<div class=\"reference-context\" data-cjdoc-reference-context>")
    out.append("<span><strong>" + documentationVersionContextLabel + "</strong> " + documentVersionLabel + "</span>")
    out.append("<span><strong>" + audienceContextLabel + "</strong> " + escapeHtml(documentation.configuration.audience) + "</span>")
    out.append("<details class=\"reference-build-details\"><summary>" +
        label(locale, "Build details", "构建详情") + "</summary><div>")
    out.append("<span><strong>" + label(locale, "Library version", "库版本") + "</strong> " + label(locale, "not provided", "未提供") + "</span>")
    out.append("<span><strong>" + label(locale, "Target platform", "目标平台") + "</strong> " + label(locale, "unknown", "未知") + "</span>")
    out.append("<span><strong>" + configurationContextLabel + "</strong> " + escapeHtml(documentation.configuration.cfgProfile) + "</span>")
    out.append("<span><strong>" + generatorContextLabel + "</strong> " + escapeHtml(documentation.generator.name) + " " + escapeHtml(documentation.generator.version) + "</span>")
    out.append("</div></details></div>\n<div class=\"docs-layout\">")
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
            appendDocumentationContractsHtml(out, comment, locale)
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3>${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt><code>${escapeHtml(parameter.name)}</code></dt><dd class=\"parameter-type\"><span class=\"parameter-colon\">:</span>")
                    appendTypeRefCodeHtml(out, parameter.typeRef, typeLinkIndex, rootPrefix, locale,
                        className: "parameter-type-code")
                    match (parameter.defaultExpression) {
                        case Some(defaultExpression) => out.append(" <span class=\"parameter-default\">= <code>" + escapeHtml(defaultExpression) + "</code></span>")
                        case None => ()
                    }
                    out.append("</dd>")
                    out.append("<dd class=\"parameter-description\">")
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
                        out.append("<dt>")
                        match (tag.targetSymbolId) {
                            case Some(targetId) => match (findSymbol(index, targetId)) {
                                case Some(target) => out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(tag.subject)}</code></a>")
                                case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                            }
                            case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                        }
                        if (tag.referenceState != "resolved") {
                            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(tag.referenceState)}\">${escapeHtml(tag.referenceState)}</span>")
                        }
                        out.append("</dt><dd>")
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
                    match (parameter.defaultExpression) {
                        case Some(defaultExpression) => out.append(" <span class=\"parameter-default\">= <code>" + escapeHtml(defaultExpression) + "</code></span>")
                        case None => ()
                    }
                    out.append("</dd>")
                    out.append("<dd class=\"parameter-description\"></dd></div>\n")
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
internal class HtmlSignatureLinkSpan {
    let start: Int64
    let end: Int64
    let url: String

    init(start: Int64, end: Int64, url: String) {
        this.start = start
        this.end = end
        this.url = url
    }
}

private class HtmlSignatureSourceToken {
    let kind: String
    let value: String
    let start: Int64
    let end: Int64

    init(kind: String, value: String, start: Int64, end: Int64) {
        this.kind = kind
        this.value = value
        this.start = start
        this.end = end
    }
}

private class HtmlSignatureTypeWindow {
    let start: Int64
    let end: Int64
    let nextToken: Int64

    init(start: Int64, end: Int64, nextToken: Int64) {
        this.start = start
        this.end = end
        this.nextToken = nextToken
    }
}

private func signatureIdentifierByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'_' || value >= 0x80u8
}

private func signatureSpanBoundary(value: String, start: Int64, end: Int64): Bool {
    let firstIdentifier = !value.isEmpty() && signatureIdentifierByte(value[0])
    let lastIdentifier = !value.isEmpty() && signatureIdentifierByte(value[value.size - 1])
    if (firstIdentifier && start > 0 && signatureIdentifierByte(value[start - 1])) { return false }
    if (lastIdentifier && end < value.size && signatureIdentifierByte(value[end])) { return false }
    true
}

private func signatureLexedTokens(raw: String, expected: ReadOnlyList<String>):
    ?ArrayList<HtmlSignatureSourceToken> {
    let lineStarts = ArrayList<Int64>()
    lineStarts.add(0)
    let bytes = raw.toArray()
    var byteIndex: Int64 = 0
    while (byteIndex < bytes.size) {
        if (bytes[byteIndex] == b'\n') { lineStarts.add(byteIndex + 1) }
        byteIndex++
    }

    let result = ArrayList<HtmlSignatureSourceToken>()
    var expectedIndex: Int64 = 0
    try {
        for (token in cangjieLex(raw)) {
            if (token.kind == COMMENT || token.kind == NL || token.value.isEmpty()) { continue }
            if (expectedIndex >= expected.size) { return None }
            let descriptor = "${token.kind}:${token.value.size}:${token.value}"
            if (descriptor != expected[expectedIndex]) { return None }
            let lineIndex = Int64(token.pos.line) - 1
            let column = Int64(token.pos.column)
            if (lineIndex < 0 || lineIndex >= lineStarts.size || column < 1) { return None }
            let tokenStart = lineStarts[lineIndex] + column - 1
            let tokenEnd = tokenStart + token.value.size
            if (tokenStart < 0 || tokenEnd > raw.size ||
                raw[tokenStart..tokenEnd] != token.value) { return None }
            result.add(HtmlSignatureSourceToken("${token.kind}", token.value, tokenStart, tokenEnd))
            expectedIndex++
        }
    } catch (_: Exception) {
        return None
    }
    if (expectedIndex != expected.size) { return None }
    Some(result)
}

private func signatureTypeWindowEnd(tokens: ArrayList<HtmlSignatureSourceToken>,
    first: Int64): (Int64, Int64) {
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    var angleDepth: Int64 = 0
    var braceDepth: Int64 = 0
    var index = first
    while (index < tokens.size) {
        let value = tokens[index].value
        if (roundDepth == 0 && squareDepth == 0 && angleDepth == 0 && braceDepth == 0 &&
            (value == "=" || value == "," || value == ")" || value == "where" || value == "{")) {
            return (tokens[index].start, index + 1)
        }
        if (value == "(") {
            roundDepth++
        } else if (value == ")") {
            if (roundDepth > 0) { roundDepth-- }
        } else if (value == "[") {
            squareDepth++
        } else if (value == "]") {
            if (squareDepth > 0) { squareDepth-- }
        } else if (value == "<") {
            angleDepth++
        } else if (value == ">") {
            if (angleDepth > 0) { angleDepth-- }
        } else if (value == "{") {
            braceDepth++
        } else if (value == "}") {
            if (braceDepth > 0) { braceDepth-- }
        }
        index++
    }
    let end = if (tokens.isEmpty()) { 0 } else { tokens[tokens.size - 1].end }
    (end, index)
}

private func signatureParameterTypeWindow(tokens: ArrayList<HtmlSignatureSourceToken>,
    parameterName: String, cursor: Int64): ?HtmlSignatureTypeWindow {
    if (parameterName.isEmpty()) { return None }
    var nameIndex = cursor
    while (nameIndex < tokens.size) {
        if (tokens[nameIndex].kind == "IDENTIFIER" && tokens[nameIndex].value == parameterName) {
            break
        }
        nameIndex++
    }
    if (nameIndex >= tokens.size) { return None }

    var colonIndex = nameIndex + 1
    while (colonIndex < tokens.size) {
        let value = tokens[colonIndex].value
        if (value == ":") { break }
        if (value == "," || value == ")") { return None }
        colonIndex++
    }
    if (colonIndex + 1 >= tokens.size || tokens[colonIndex].value != ":") { return None }
    let first = colonIndex + 1
    let (end, nextToken) = signatureTypeWindowEnd(tokens, first)
    if (tokens[first].start >= end) { return None }
    Some(HtmlSignatureTypeWindow(tokens[first].start, end, nextToken))
}

private func signatureTopLevelTypeWindow(tokens: ArrayList<HtmlSignatureSourceToken>):
    ?HtmlSignatureTypeWindow {
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    var angleDepth: Int64 = 0
    var braceDepth: Int64 = 0
    var index: Int64 = 0
    while (index < tokens.size) {
        let value = tokens[index].value
        if (value == "(") {
            roundDepth++
        } else if (value == ")") {
            if (roundDepth > 0) { roundDepth-- }
        } else if (value == "[") {
            squareDepth++
        } else if (value == "]") {
            if (squareDepth > 0) { squareDepth-- }
        } else if (value == "<") {
            angleDepth++
        } else if (value == ">") {
            if (angleDepth > 0) { angleDepth-- }
        } else if (value == "{") {
            braceDepth++
        } else if (value == "}") {
            if (braceDepth > 0) { braceDepth-- }
        } else if (value == ":" && roundDepth == 0 && squareDepth == 0 &&
            angleDepth == 0 && braceDepth == 0) {
            let first = index + 1
            if (first >= tokens.size) { return None }
            let (end, nextToken) = signatureTypeWindowEnd(tokens, first)
            if (tokens[first].start >= end) { return None }
            return Some(HtmlSignatureTypeWindow(tokens[first].start, end, nextToken))
        }
        index++
    }
    None
}

private func collectSignatureTypeSpansBounded(spans: ArrayList<HtmlSignatureLinkSpan>,
    raw: String, typeRef: TypeRef, typeLinkIndex: HtmlTypeLinkIndex,
    cursor: Int64, limit: Int64): Int64 {
    if (cursor >= limit || limit > raw.size) { return cursor }
    let spelling = if (typeRef.arguments.isEmpty()) { typeRef.spelling } else {
        typeHeadSpelling(typeRef.spelling)
    }
    var nextCursor = cursor
    if (!spelling.isEmpty()) {
        var searchCursor = cursor
        while (searchCursor < limit) {
            match (raw[searchCursor..limit].indexOf(spelling)) {
                case Some(relative) =>
                    let start = searchCursor + relative
                    let end = start + spelling.size
                    if (end > limit) { break }
                    if (!signatureSpanBoundary(raw, start, end)) {
                        searchCursor = end
                        continue
                    }
                    nextCursor = end
                    match (typeLinkIndex.targetUrl(typeRef)) {
                        case Some(url) => spans.add(HtmlSignatureLinkSpan(start, end, url))
                        case None => ()
                    }
                    break
                case None => break
            }
        }
    }
    for (argument in typeRef.arguments) {
        nextCursor = collectSignatureTypeSpansBounded(spans, raw, argument,
            typeLinkIndex, nextCursor, limit)
    }
    nextCursor
}

private func signatureDeclarationNameEnd(tokens: ArrayList<HtmlSignatureSourceToken>,
    symbolName: String): Int64 {
    for (token in tokens) {
        if (token.kind == "IDENTIFIER" && token.value == symbolName) { return token.end }
    }
    0
}

internal func appendLinkedSignatureHtml(out: RenderTextBuffer, symbol: SymbolDoc,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String): Unit {
    let raw = symbol.headerSpelling
    if (raw.isEmpty() || symbol.sourceApiSignature.state != "available" ||
        symbol.sourceApiSignature.tokens.isEmpty()) {
        out.append(escapeHtml(raw))
        return
    }
    let tokens = match (signatureLexedTokens(raw, symbol.sourceApiSignature.tokens)) {
        case Some(value) => value
        case None =>
            out.append(escapeHtml(raw))
            return
    }

    let spans = ArrayList<HtmlSignatureLinkSpan>()
    var tokenCursor: Int64 = 0
    var rawCursor: Int64 = 0
    for (parameter in symbol.parameters) {
        match (signatureParameterTypeWindow(tokens, parameter.name, tokenCursor)) {
            case Some(window) =>
                rawCursor = collectSignatureTypeSpansBounded(spans, raw, parameter.typeRef,
                    typeLinkIndex, window.start, window.end)
                tokenCursor = window.nextToken
            case None =>
                out.append(escapeHtml(raw))
                return
        }
    }
    match (symbol.returnType) {
        case Some(returnType) => match (signatureTopLevelTypeWindow(tokens)) {
            case Some(window) =>
                rawCursor = collectSignatureTypeSpansBounded(spans, raw, returnType,
                    typeLinkIndex, window.start, window.end)
            case None => ()
        }
        case None => ()
    }

    var relationshipCursor = rawCursor
    if (relationshipCursor == 0) {
        relationshipCursor = signatureDeclarationNameEnd(tokens, symbol.name)
    }
    for (relationship in symbol.typeRelationships) {
        relationshipCursor = collectSignatureTypeSpansBounded(spans, raw, relationship.target,
            typeLinkIndex, relationshipCursor, raw.size)
    }
    if (spans.isEmpty()) {
        out.append(escapeHtml(raw))
        return
    }
    sort(spans, lessThan: { left, right => left.start < right.start }, stable: true)
    var position: Int64 = 0
    for (span in spans) {
        if (span.start < position) { continue }
        out.append(escapeHtml(raw[position..span.start]))
        out.append("<a class=\"type-link signature-type-link\" href=\"" +
            rootPrefix + escapeHtml(span.url) + "\">")
        out.append(escapeHtml(raw[span.start..span.end]))
        out.append("</a>")
        position = span.end
    }
    if (position < raw.size) { out.append(escapeHtml(raw[position..raw.size])) }
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

internal func appendSymbolRelationshipSection(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String): Unit {
    if (symbol.typeRelationships.isEmpty() && symbol.symbolRelationships.isEmpty()) { return }
    let headingId = "symbol-relationships-heading-" + htmlStableSlug(symbol.id)
    out.append("<section class=\"symbol-relationships\" aria-labelledby=\"" + headingId + "\">")
    out.append("<h2 id=\"" + headingId + "\">${label(locale, "Relationships", "关系")}</h2><dl class=\"relationships\">")
    for (relationship in symbol.typeRelationships) {
        if (hasResolvedSymbolRelationship(symbol, relationship.kind, relationship.target.spelling)) { continue }
        out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
        appendTypeRefCodeHtml(out, relationship.target, typeLinkIndex, rootPrefix, locale,
            className: "relationship-type")
        if (relationship.target.semantic.state != "resolved") {
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span>")
        }
        out.append("</dd>")
    }
    for (relationship in symbol.symbolRelationships) {
        out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
        var renderedState = relationship.state
        match (relationship.targetSymbolId) {
            case Some(targetId) => match (findSymbol(index, targetId)) {
                case Some(target) => out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                case None =>
                    renderedState = "unavailable"
                    out.append("<code>unavailable</code>")
            }
            case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
        }
        if (renderedState != "resolved") {
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(renderedState)}\">${escapeHtml(renderedState)}</span>")
        }
        out.append("</dd>")
    }
    out.append("</dl></section>\n")
}

internal func appendReverseTypeUsageSection(out: RenderTextBuffer, symbol: SymbolDoc,
    typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String, locale: String): Unit {
    let usages = typeLinkIndex.reverseUsages(symbol.id)
    if (usages.isEmpty()) { return }
    let heading = label(locale, "Known uses", "已知使用")
    let scope = label(locale, "Known references in this documentation set and audience.", "当前文档集和受众中的已知引用。")
    out.append("<section class=\"reverse-type-usages\" aria-labelledby=\"reverse-type-usages-heading\">")
    out.append("<h2 id=\"reverse-type-usages-heading\">" + heading + "</h2><p class=\"relation-scope\">" + scope + "</p><ol>")
    let maximum: Int64 = 40
    var shown: Int64 = 0
    for (usage in usages) {
        if (shown >= maximum) { break }
        let kindLabel = match (usage.kind) {
            case "parameter" => label(locale, "parameter", "参数")
            case "return" => label(locale, "return value", "返回值")
            case "field" => label(locale, "field/property", "字段/属性")
            case _ => escapeHtml(usage.kind)
        }
        out.append("<li><span class=\"usage-kind\">" + kindLabel + "</span> <a href=\"" + rootPrefix + escapeHtml(symbolPagePath(usage.source)) + "\"><code>" + escapeHtml(usage.source.qualifiedName) + "</code></a>")
        if (!usage.source.headerSpelling.trimAscii().isEmpty()) {
            out.append(" <code class=\"usage-signature\">" + escapeHtml(usage.source.headerSpelling) + "</code>")
        }
        out.append("</li>\n")
        shown++
    }
    if (usages.size > maximum) {
        let more = label(locale, "More references are omitted by the fixed page limit.", "受固定页面上限限制，更多引用未显示。")
        out.append("<li class=\"relation-more\">" + more + "</li>")
    }
    out.append("</ol></section>\n")
}

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex, locale!: String = "en"): Unit {
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
    out.append("<h2 class=\"signature-heading\">${label(locale, "Signature", "签名")}</h2><pre class=\"signature-block\"><code>")
    appendLinkedSignatureHtml(out, symbol, typeLinkIndex, rootPrefix)
    out.append("</code></pre>")
    out.append("<p class=\"signature-context\"><span>" + label(locale, "Source signature", "源码签名") + "</span> <span class=\"badge\" data-state=\"" + escapeHtml(symbol.sourceApiSignature.state) + "\">" + escapeHtml(symbol.sourceApiSignature.state) + "</span></p>\n")
    appendSymbolRelationshipSection(out, index, symbol, rootPrefix, typeLinkIndex, locale)
    if (symbol.ownerId.isSome() || !symbol.genericParameters.isEmpty() || !symbol.annotations.isEmpty()) {
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
        out.append("</details>")
    }
    out.append("</div>\n")
}
