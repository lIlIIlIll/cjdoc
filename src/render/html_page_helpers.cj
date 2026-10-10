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

// Stable, content-independent anchor for a documented member block, so a
// search hit can land on the matched block rather than only the member page.
internal func docBlockAnchor(symbol: SymbolDoc, block: String): String {
    symbolAnchor(symbol) + "--" + block
}

internal func appendDocumentationIntroductionHtml(out: RenderTextBuffer, symbol: SymbolDoc,
    rootPrefix: String, assetLookup: HashMap<String, String>, headingBase: Int64,
    locale: String): Unit {
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return
    }
    match (findTag(comment, "deprecated")) {
        case Some(tag) =>
            out.append("<aside class=\"callout\"><strong>${label(locale, "Deprecated.", "已弃用。")}</strong> ")
            appendStructuredTextHtml(out, tag.description)
            out.append("</aside>\n")
        case None => ()
    }
    if (comment.markdown.kind == "paragraph") { return }
    let summaryIndex = topLevelParagraphIndex(comment)
    if (comment.markdown.children.isEmpty() ||
        (comment.markdown.children.size == 1 && summaryIndex == 0)) { return }
    out.append("<div class=\"description\">")
    let markdownContext = markdownHtmlContext(comment, symbol, headingBase)
    var childIndex: Int64 = 0
    for (child in comment.markdown.children) {
        if (childIndex != summaryIndex) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, markdownContext)
        }
        childIndex++
    }
    out.append("</div>\n")
}

internal func appendDocumentationHtml(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    headingBase!: Int64 = 3, includeContracts!: Bool = true,
    includeIntroduction!: Bool = true, locale!: String = "en",
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>()): Unit {
    if (includeIntroduction) {
        appendDocumentationIntroductionHtml(out, symbol, rootPrefix, assetLookup, headingBase, locale)
    }
    match (symbol.documentation) {
        case Some(comment) =>
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3 id=\"${docBlockAnchor(symbol, "parameters")}\">${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt class=\"parameter-declaration\"><code class=\"parameter-name\">${escapeHtml(parameter.name)}</code><span class=\"parameter-type\"><span class=\"parameter-colon\">:</span>")
                    appendTypeRefCodeHtml(out, parameter.typeRef, typeLinkIndex, rootPrefix, locale,
                        className: "parameter-type-code")
                    match (parameter.defaultExpression) {
                        case Some(defaultExpression) => out.append(" <span class=\"parameter-default\">= <code>" + escapeHtml(defaultExpression) + "</code></span>")
                        case None => ()
                    }
                    out.append("</span></dt>")
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
                    out.append("<h3 id=\"${docBlockAnchor(symbol, "return")}\">${label(locale, "Returns", "返回值")}</h3><div class=\"return-value\">")
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
                out.append("<h3 id=\"${docBlockAnchor(symbol, "throws")}\">${label(locale, "Throws", "异常")}</h3><dl class=\"throws-list\">\n")
                for (tag in comment.tags) {
                    if (tag.name == "throws") {
                        out.append("<div class=\"throws-row\"><dt>")
                        match (tag.targetSymbolId) {
                            case Some(targetId) => match (findSymbol(index, targetId)) {
                                case Some(target) => out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(tag.subject)}</code></a>")
                                case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                            }
                            case None => out.append("<code>${escapeHtml(tag.subject)}</code>")
                        }
                        // Missing documentation links are not API behavior.
                        // Preserve true ambiguity locally, but keep the reason readable.
                        if (tag.referenceState == "ambiguous") {
                            out.append(" <span class=\"reference-state-note\" data-state=\"ambiguous\">" +
                                escapeHtml(htmlReferenceStateLabel(tag.referenceState, locale)) + "</span>")
                        }
                        out.append("</dt><dd>")
                        appendStructuredTextHtml(out, tag.description)
                        out.append("</dd></div>\n")
                    }
                }
                out.append("</dl>\n")
            }
            if (includeContracts) {
                appendDocumentationContractsHtml(out, comment, locale, symbolAnchor(symbol))
            }
            appendDocumentationExamplesHtml(out, comment, locale, symbol: Some(symbol),
                exampleEvidence: exampleEvidence)
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
            out.append("<p class=\"empty-state\">${label(locale, "No documentation is available for this declaration.", "此声明暂无文档。")}</p>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h3 id=\"${docBlockAnchor(symbol, "parameters")}\">${label(locale, "Parameters", "参数")}</h3><dl class=\"parameter-list\">\n")
                for (parameter in symbol.parameters) {
                    out.append("<div class=\"parameter-row\"><dt class=\"parameter-declaration\"><code class=\"parameter-name\">${escapeHtml(parameter.name)}</code><span class=\"parameter-type\"><span class=\"parameter-colon\">:</span>")
                    appendTypeRefCodeHtml(out, parameter.typeRef, typeLinkIndex, rootPrefix, locale,
                        className: "parameter-type-code")
                    match (parameter.defaultExpression) {
                        case Some(defaultExpression) => out.append(" <span class=\"parameter-default\">= <code>" + escapeHtml(defaultExpression) + "</code></span>")
                        case None => ()
                    }
                    out.append("</span></dt><dd class=\"parameter-description\"></dd></div>\n")
                }
                out.append("</dl>\n")
            }
            match (symbol.returnType) {
                case Some(returnType) => if (!isUnitType(returnType)) {
                    out.append("<h3 id=\"${docBlockAnchor(symbol, "return")}\">${label(locale, "Returns", "返回值")}</h3><div class=\"return-value\">")
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
    locale!: String = "en",
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>()): Unit {
    let isMember = symbol.ownerId.isSome()
    let titleTag = "h3"
    let tocRole = if (isMember) { "member" } else { "api" }
    out.append("<article class=\"symbol-entry\" id=\"${symbolAnchor(symbol)}\"><${titleTag} class=\"symbol-title\" data-cjdoc-toc-role=\"${tocRole}\" data-cjdoc-toc-label=\"${escapeHtml(htmlTocLabel(symbol))}\">")
    if (linkTitle) {
        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, symbol))}\"><code>${escapeHtml(symbol.qualifiedName)}</code></a>")
    } else { out.append("<code>${escapeHtml(symbol.qualifiedName)}</code>") }
    out.append("</${titleTag}>\n")
    appendSymbolMetadata(out, index, symbol, rootPrefix, assetLookup, typeLinkIndex,
        locale: locale)
    appendDocumentationHtml(out, index, symbol, rootPrefix, assetLookup,
        typeLinkIndex, headingBase: 2, locale: locale, exampleEvidence: exampleEvidence)
    appendReaderRelationships(out, index, symbol, rootPrefix, typeLinkIndex, locale,
        headingTag: "h3")
    appendReverseTypeUsages(out, index, typeLinkIndex, symbol, rootPrefix, locale)
    out.append("</article>\n")
}
