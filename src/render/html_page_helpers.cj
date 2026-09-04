package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}

internal func appendHtmlSidebar(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, rootPrefix: String, locale: String,
    currentPackagePath!: ?String = None): Unit {
    out.append("<aside class=\"docs-sidebar\" aria-label=\"${label(locale, "Documentation navigation", "文档导航")}\">")
    out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Documentation", "文档")}</p>")
    out.append("<a class=\"sidebar-link\" data-cjdoc-nav-link href=\"${rootPrefix}index.html\">${label(locale, "Overview", "总览")}</a>")
    out.append("<a class=\"sidebar-link is-current\" data-cjdoc-nav-link href=\"${rootPrefix}index.html#packages\">${label(locale, "API Reference", "API 参考")}</a></div>")
    if (!projection.modules.isEmpty()) {
        out.append("<div class=\"sidebar-section\"><p class=\"sidebar-label\">${label(locale, "Package reference", "包参考")}</p>")
        for (projected in projection.modules) {
            let module = projected.source
            out.append("<details class=\"sidebar-group\" open><summary><span>${escapeHtml(module.name)}</span><span class=\"sidebar-count\">${projected.packages.size}</span></summary><div class=\"sidebar-packages\">")
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
    locale!: String = "en", currentPackagePath!: ?String = None): Unit {
    out.append("<!doctype html>\n<html lang=\"${locale}\"><head><meta charset=\"utf-8\">")
    out.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    out.append("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'\">")
    out.append("<title>${escapeHtml(title)}</title><script src=\"${rootPrefix}theme-bootstrap.js\"></script><link rel=\"stylesheet\" href=\"${rootPrefix}style.css\">")
    out.append("<script defer src=\"${rootPrefix}search-index.js\"></script>")
    out.append("<script defer src=\"${rootPrefix}search.js\"></script></head><body>\n")
    out.append("<header class=\"site-nav\"><div class=\"site-nav-inner\">")
    out.append("<a class=\"brand\" href=\"${rootPrefix}index.html\"><span class=\"brand-mark\" aria-hidden=\"true\">cj</span><span>cjdoc<span class=\"brand-subtitle\">${label(locale, "API docs", "API 文档")}</span></span></a>")
    out.append("<div class=\"site-search\"><div class=\"search-area\"><div class=\"search-shell\"><svg width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><circle cx=\"11\" cy=\"11\" r=\"7\"></circle><path d=\"m20 20-4-4\"></path></svg><label class=\"sr-only\" for=\"cjdoc-search-input\">${label(locale, "Search API", "搜索 API")}</label>")
    out.append("<input id=\"cjdoc-search-input\" type=\"search\" placeholder=\"${label(locale, "Search docs", "搜索文档")}\" autocomplete=\"off\" role=\"combobox\" aria-autocomplete=\"list\" aria-controls=\"cjdoc-search-results\" aria-expanded=\"false\" data-cjdoc-search data-root=\"${rootPrefix}\"><kbd>Ctrl K</kbd></div>")
    out.append("<ul id=\"cjdoc-search-results\" class=\"search-results\" role=\"listbox\" data-cjdoc-results aria-live=\"polite\"></ul></div>")
    out.append("<div class=\"search-filters\"><label><span class=\"sr-only\">${label(locale, "Filter by kind", "按类别筛选")}</span><select data-cjdoc-kind aria-label=\"${label(locale, "Filter by kind", "按类别筛选")}\"><option value=\"\">${label(locale, "All kinds", "全部类别")}</option></select></label><label><span class=\"sr-only\">${label(locale, "Filter by package", "按包筛选")}</span><select data-cjdoc-package aria-label=\"${label(locale, "Filter by package", "按包筛选")}\"><option value=\"\">${label(locale, "All packages", "全部包")}</option></select></label></div></div>")
    out.append("<div class=\"top-actions\"><span class=\"version-label\" title=\"${label(locale, "Generated by cjdoc", "由 cjdoc 生成")}\">v${escapeHtml(documentation.generator.version)}</span><span class=\"top-source top-source-disabled\" aria-disabled=\"true\" title=\"${label(locale, "Repository URL is not included in this Doc IR", "此 Doc IR 未包含仓库地址")}\"><svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"currentColor\" aria-hidden=\"true\"><path d=\"M12 .7a11.3 11.3 0 0 0-3.57 22.02c.57.1.78-.25.78-.55v-2.1c-3.18.69-3.85-1.34-3.85-1.34-.52-1.32-1.27-1.67-1.27-1.67-1.04-.71.08-.7.08-.7 1.15.08 1.76 1.18 1.76 1.18 1.02 1.75 2.67 1.25 3.32.96.1-.74.4-1.25.72-1.54-2.54-.29-5.21-1.27-5.21-5.66 0-1.25.45-2.27 1.18-3.07-.12-.29-.51-1.45.11-3.03 0 0 .96-.31 3.12 1.17a10.85 10.85 0 0 1 5.68 0c2.16-1.48 3.12-1.17 3.12-1.17.62 1.58.23 2.74.11 3.03.73.8 1.18 1.82 1.18 3.07 0 4.4-2.68 5.36-5.23 5.64.41.36.77 1.07.77 2.16v3.2c0 .3.2.65.79.54A11.3 11.3 0 0 0 12 .7Z\"></path></svg><span>GitHub</span></span><button class=\"theme-toggle\" type=\"button\" data-cjdoc-theme-toggle aria-label=\"${label(locale, "Switch theme", "切换主题")}\" aria-pressed=\"false\"><svg class=\"icon-sun\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><circle cx=\"12\" cy=\"12\" r=\"4\"></circle><path d=\"M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42\"></path></svg><svg class=\"icon-moon\" width=\"17\" height=\"17\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\"><path d=\"M20.5 14.7A8.5 8.5 0 0 1 9.3 3.5 8.5 8.5 0 1 0 20.5 14.7Z\"></path></svg></button></div>")
    out.append("</div></header>\n<div class=\"docs-layout\">")
    appendHtmlSidebar(out, documentation, projection, rootPrefix, locale,
        currentPackagePath: currentPackagePath)
    out.append("<main class=\"docs-main\" data-cjdoc-content tabindex=\"-1\"><div class=\"content-column\">\n")
}

internal func appendPageEnd(out: RenderTextBuffer, documentation: DocumentationSet,
    locale!: String = "en"): Unit {
    out.append("</div></main><aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"${label(locale, "On this page", "本页目录")}\" hidden><p class=\"toc-title\">${label(locale, "On this page", "本页目录")}</p><nav><ol></ol></nav></aside></div>")
    out.append("<footer class=\"site-footer\"><div class=\"footer-inner\"><span><span class=\"footer-mark\">cjdoc</span> · ${label(locale, "Generated from Doc IR", "由 Doc IR 生成")}</span><span>${escapeHtml(documentation.generator.version)} · ${escapeHtml(documentation.schemaVersion)}</span></div></footer></body></html>\n")
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
            out.append("<h2>${label(locale, "Overview", "概览")}</h2><div class=\"description\">")
            appendMarkdownNodeHtml(out, comment.markdown, assetLookup, rootPrefix,
                markdownHtmlContext(comment, symbol, headingBase))
            out.append("</div>\n")
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

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    locale!: String = "en"): Unit {
    out.append("<div class=\"symbol-meta\"><p class=\"meta\"><span class=\"badge\">${escapeHtml(symbol.kind)}</span>")
    out.append("<span class=\"badge\">${escapeHtml(symbol.visibility)}</span>")
    out.append("<span class=\"badge\" data-state=\"${escapeHtml(symbol.semantic.state)}\">semantic: ${escapeHtml(symbol.semantic.state)}</span>")
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => out.append(" Owner: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a> ·")
            case None => out.append(" Owner: <code>${escapeHtml(ownerId)}</code> ·")
        }
        case None => ()
    }
    out.append(" <code>${escapeHtml(symbol.source.path)}:${symbol.source.start.line}:${symbol.source.start.column}</code></p>\n")
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<p class=\"meta\">Generic parameters: ")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append("<code>${escapeHtml(parameter)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.annotations.isEmpty()) {
        out.append("<p class=\"meta\">Annotations: ")
        var first = true
        for (annotation in symbol.annotations) {
            if (!first) { out.append(" ") }; first = false
            out.append("<code>${escapeHtml(annotation.spelling)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.typeRelationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
        out.append("<dl class=\"relationships\">")
        for (relationship in symbol.typeRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd><code>${escapeHtml(relationship.target.spelling)}</code> <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span></dd>")
        }
        for (relationship in symbol.symbolRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (findSymbol(index, targetId)) {
                    case Some(target) =>
                        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.state)}\">${escapeHtml(relationship.state)}</span></dd>")
        }
        out.append("</dl>\n")
    }
    out.append("</div><h2 class=\"signature-heading\">${label(locale, "Signature", "签名")}</h2><pre class=\"signature-block\"><code>${escapeHtml(symbol.headerSpelling)}</code></pre>\n")
}

internal func appendSymbolArticle(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    linkTitle!: Bool = false,
    locale!: String = "en"): Unit {
    let isMember = symbol.ownerId.isSome()
    let titleTag = if (isMember) { "h3" } else { "h2" }
    let tocRole = if (isMember) { "member" } else { "api" }
    out.append("<article class=\"symbol-entry\" id=\"${symbolAnchor(symbol)}\"><${titleTag} class=\"symbol-title\" data-cjdoc-toc-role=\"${tocRole}\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\">")
    if (linkTitle) {
        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a>")
    } else { out.append("<code>${escapeHtml(symbol.qualifiedName)}</code>") }
    out.append("</${titleTag}>\n")
    appendSymbolMetadata(out, index, symbol, rootPrefix, locale: locale)
    appendDocumentationHtml(out, index, symbol, rootPrefix, assetLookup,
        typeLinkIndex, locale: locale)
    out.append("</article>\n")
}
