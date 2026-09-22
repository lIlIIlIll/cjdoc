package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
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
                out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--overview\">${label(locale, "Overview", "概览")}</h${headingBase}><div class=\"description\">")
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
            appendDocumentationExamplesHtml(out, comment, locale, headingBase: headingBase, anchor: symbolAnchor(symbol))
            appendDocumentationContractsHtml(out, comment, locale, headingBase: headingBase, anchor: symbolAnchor(symbol))
            if (!symbol.parameters.isEmpty()) {
                out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--parameters\">${label(locale, "Parameters", "参数")}</h${headingBase}><dl class=\"parameter-list\">\n")
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
                    out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--returns\">${label(locale, "Returns", "返回值")}</h${headingBase}><div class=\"return-value\">")
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
                out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--throws\">${label(locale, "Throws", "异常")}</h${headingBase}><dl>\n")
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
                out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--see-also\">${label(locale, "See also", "另请参阅")}</h${headingBase}><ul>\n")
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
                    if (!opened) { out.append("<h${headingBase}>${escapeHtml(label(locale, tagHeading(name), match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" }))}</h${headingBase}><ul>\n"); opened = true }
                    out.append("<li>"); appendStructuredTextHtml(out, tag.description); out.append("</li>\n")
                }
                if (opened) { out.append("</ul>\n") }
            }
        case None =>
            out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--overview\">${label(locale, "Overview", "概览")}</h${headingBase}><p class=\"empty-state\">${label(locale, "No documentation is available for this declaration.", "此声明暂无文档。")}</p>\n")
            if (!symbol.parameters.isEmpty()) {
                out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--parameters\">${label(locale, "Parameters", "参数")}</h${headingBase}><dl class=\"parameter-list\">\n")
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
                    out.append("<h${headingBase} id=\"${symbolAnchor(symbol)}--returns\">${label(locale, "Returns", "返回值")}</h${headingBase}><div class=\"return-value\">")
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

internal func appendSymbolRelationshipSection(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String, headingBase!: Int64 = 2): Unit {
    if (symbol.typeRelationships.isEmpty() && symbol.symbolRelationships.isEmpty()) { return }
    let relationId = symbolAnchor(symbol) + "--relationships"
    out.append("<section class=\"symbol-relationships\" aria-labelledby=\"${relationId}\">")
    out.append("<h${headingBase} id=\"${relationId}\">${label(locale, "Relationships", "关系")}</h${headingBase}><dl class=\"relationships\">")
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
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex, locale!: String = "en",
    headingBase!: Int64 = 2): Unit {
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
    out.append("<h${headingBase} class=\"signature-heading\">${label(locale, "Signature", "签名")}</h${headingBase}><pre class=\"signature-block\"><code>")
    appendLinkedSignatureHtml(out, symbol, typeLinkIndex, rootPrefix)
    out.append("</code></pre>")
    if (symbol.sourceApiSignature.state != "available") { out.append("<p class=\"signature-context\">" + label(locale, "Source signature mapping unavailable; unresolved references remain plain text.", "源码签名映射不可用；未解析的引用保留为文本。") + "</p>") }
    appendSymbolRelationshipSection(out, index, symbol, rootPrefix, typeLinkIndex, locale, headingBase: headingBase)
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
