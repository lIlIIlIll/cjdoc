package cjdoc.render

import cjdoc.model.*
import std.collection.*

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
    let overviewAttributes = if (headingBase == 2) {
        " id=\"overview\" data-cjdoc-toc-role=\"group\""
    } else { "" }
    match (symbol.documentation) {
        case Some(comment) =>
            match (findTag(comment, "deprecated")) {
                case Some(tag) =>
                    out.append("<aside class=\"callout\"><strong>${label(locale, "Deprecated.", "已弃用。")}</strong> ")
                    appendStructuredTextHtml(out, tag.description)
                    out.append("</aside>\n")
                case None => ()
            }
            out.append("<h${headingBase}${overviewAttributes}>${label(locale, "Overview", "概览")}</h${headingBase}><div class=\"description\">")
            appendMarkdownNodeHtml(out, comment.markdown, assetLookup, rootPrefix,
                markdownHtmlContext(comment, symbol, headingBase))
            out.append("</div>\n")
            appendDocumentationExamplesHtml(out, comment, locale, headingLevel: min(6, headingBase + 1))
            if (!symbol.parameters.isEmpty()) {
                out.append("<h${min(6, headingBase + 1)}>${label(locale, "Parameters", "参数")}</h${min(6, headingBase + 1)}><dl class=\"parameter-list\">\n")
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
                    out.append("<h${min(6, headingBase + 1)}>${label(locale, "Returns", "返回值")}</h${min(6, headingBase + 1)}><div class=\"return-value\">")
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
                out.append("<h${min(6, headingBase + 1)}>${label(locale, "Throws", "异常")}</h${min(6, headingBase + 1)}><dl>\n")
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
                out.append("<h${min(6, headingBase + 1)}>${label(locale, "See also", "另请参阅")}</h${min(6, headingBase + 1)}><ul>\n")
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
                    if (!opened) { out.append("<h${min(6, headingBase + 1)}>${escapeHtml(label(locale, tagHeading(name), match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" }))}</h${min(6, headingBase + 1)}><ul>\n"); opened = true }
                    out.append("<li>"); appendStructuredTextHtml(out, tag.description); out.append("</li>\n")
                }
                if (opened) { out.append("</ul>\n") }
            }
        case None =>
            out.append("<h${headingBase}${overviewAttributes}>${label(locale, "Overview", "概览")}</h${headingBase}><p class=\"empty-state\">${label(locale, "No documentation is available for this declaration.", "此声明暂无文档。")}</p>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h${min(6, headingBase + 1)}>${label(locale, "Parameters", "参数")}</h${min(6, headingBase + 1)}><dl class=\"parameter-list\">\n")
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
                    out.append("<h${min(6, headingBase + 1)}>${label(locale, "Returns", "返回值")}</h${min(6, headingBase + 1)}><div class=\"return-value\">")
                    appendTypeRefCodeHtml(out, returnType, typeLinkIndex, rootPrefix, locale,
                        className: "return-type")
                    out.append("</div>\n")
                }
                case None => ()
            }
    }
}

internal func appendSymbolArticle(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    linkTitle!: Bool = false,
    locale!: String = "en"): Unit {
    let isMember = symbol.ownerId.isSome()
    let titleTag = "h3"
    let tocRole = if (isMember) { "member" } else { "api" }
    out.append("<article class=\"symbol-entry\" id=\"${symbolAnchor(symbol)}\"><${titleTag} class=\"symbol-title\" data-cjdoc-toc-role=\"${tocRole}\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\">")
    if (linkTitle) {
        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a>")
    } else { out.append("<code>${escapeHtml(symbol.qualifiedName)}</code>") }
    out.append("</${titleTag}>\n")
    appendSymbolMetadata(out, index, symbol, rootPrefix, locale: locale)
    appendDocumentationHtml(out, index, symbol, rootPrefix, assetLookup,
        typeLinkIndex, headingBase: 4, locale: locale)
    out.append("</article>\n")
}
