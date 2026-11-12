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
    if (comment.localizationScope != "admonitions" && !comment.localizedTexts.isEmpty()) {
        for (tag in comment.tags where tag.name == "summary") {
            if (let Some(tree) <- tag.descriptionMarkdown) { return markdownNodeText(tree).trimAscii() }
        }
        return comment.summary.trimAscii()
    }
    match (summaryParagraph(comment)) {
        case Some(paragraph) => markdownNodeText(paragraph)
        case None =>
            if (comment.markdown.children.isEmpty() && comment.markdown.literal.isEmpty()) {
                comment.summary.trimAscii()
            } else { "" }
    }
}

internal func appendSummaryHtml(w: HtmlWriter, comment: DocComment,
    symbol: SymbolDoc, assetLookup: HashMap<String, String>, rootPrefix: String,
    locale!: String = "en", fieldAnchorNamespace!: String = ""): Unit {
    if (comment.localizationScope != "admonitions" && !comment.localizedTexts.isEmpty()) {
        if (let Some(tag) <- findTag(comment, "summary")) {
            w.open("div", attrs: [htmlClass("cj-summary")])
            appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix,
                markdownHtmlContext(comment, symbol, 2, locale: locale,
                    fieldAnchorNamespace: fieldAnchorNamespace))
            w.close("div")
        }
        return
    }
    match (summaryParagraph(comment)) {
        case Some(paragraph) =>
            let context = markdownHtmlContext(comment, symbol, 2, locale: locale,
                fieldAnchorNamespace: fieldAnchorNamespace)
            w.open("div", attrs: [htmlClass("cj-summary")])
            appendMarkdownNodeHtml(w, paragraph, assetLookup, rootPrefix, context)
            w.close("div")
            w.newline()
        case None =>
            if (comment.markdown.children.isEmpty() && comment.markdown.literal.isEmpty() &&
                !comment.summary.trimAscii().isEmpty()) {
                w.element("div", [htmlClass("cj-summary")], { summary =>
                    summary.textElement("p", comment.summary.trimAscii())
                })
                w.newline()
            }
    }
}

// Stable, content-independent anchor for a documented member block, so a
// search hit can land on the matched block rather than only the member page.
internal func docBlockAnchor(symbol: SymbolDoc, block: String): String {
    symbolAnchor(symbol) + "--" + block
}

internal func appendDocumentationIntroductionHtml(w: HtmlWriter, symbol: SymbolDoc,
    rootPrefix: String, assetLookup: HashMap<String, String>, headingBase: Int64,
    locale: String, context!: ?HtmlMarkdownContext = None): Unit {
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return
    }
    let markdownContext = match (context) {
        case Some(value) => value
        case None => markdownHtmlContext(comment, symbol, headingBase, locale: locale)
    }
    appendDocumentationIntroductionBodyHtml(w, comment, rootPrefix, assetLookup, locale, markdownContext)
    appendDocumentationAdmonitionsHtml(w, comment, locale, assetLookup, rootPrefix, markdownContext)
}

private func appendDocumentationIntroductionBodyHtml(w: HtmlWriter, comment: DocComment,
    rootPrefix: String, assetLookup: HashMap<String, String>, locale: String,
    context: HtmlMarkdownContext): Unit {
    match (findTag(comment, "deprecated")) {
        case Some(tag) =>
            w.open("aside", attrs: [htmlClass("cj-note cj-note--callout")])
            w.textElement("strong", label(locale, "Deprecated.", "已弃用。"))
            w.text(" ")
            appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix, context)
            w.close("aside")
            w.newline()
        case None => ()
    }
    if (comment.localizationScope != "admonitions" && !comment.localizedTexts.isEmpty()) {
        if (let Some(tag) <- findTag(comment, "description")) {
            w.open("div", attrs: [htmlClass("cj-description")])
            appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix, context)
            w.close("div")
        }
        return
    }
    if (comment.markdown.kind == "paragraph") { return }
    let summaryIndex = topLevelParagraphIndex(comment)
    if (comment.markdown.children.isEmpty() ||
        (comment.markdown.children.size == 1 && summaryIndex == 0)) { return }
    w.open("div", attrs: [htmlClass("cj-description")])
    var childIndex: Int64 = 0
    for (child in comment.markdown.children) {
        if (childIndex != summaryIndex) {
            appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
        }
        childIndex++
    }
    w.close("div")
    w.newline()
}

internal func markdownTreeHasDescriptionContent(node: MarkdownNode,
    assets: HashMap<String, String>): Bool {
    if (node.kind == "image") {
        return !markdownNodeText(node).trimAscii().isEmpty() ||
            assetReference(assets, node.literal).isSome()
    }
    let literalContent = node.kind == "text" || node.kind == "code_span" ||
        node.kind == "code_block" || node.kind == "html_inline" || node.kind == "html_block"
    if (literalContent && !node.literal.trimAscii().isEmpty()) { return true }
    for (child in node.children) {
        if (markdownTreeHasDescriptionContent(child, assets)) { return true }
    }
    false
}

private func tagHasDescriptionContent(tag: DocTag, assets: HashMap<String, String>): Bool {
    if (!tag.description.trimAscii().isEmpty()) { return true }
    match (tag.descriptionMarkdown) {
        case Some(tree) => markdownTreeHasDescriptionContent(tree, assets)
        case None => false
    }
}

private func appendEmptyDescriptionNoticeHtml(w: HtmlWriter, locale: String): Unit {
    w.textElement("span", label(locale, "Description is empty.", "说明为空。"),
        attrs: [htmlClass("cj-note"), htmlAttr("data-documentation-state", "empty")])
}

private func appendParameterDescriptionHtml(w: HtmlWriter, parameter: ParameterDoc,
    comment: ?DocComment, locale: String, assets: HashMap<String, String>,
    rootPrefix: String, markdownContext: ?HtmlMarkdownContext): Unit {
    var tag: ?DocTag = None
    match (comment) {
        case Some(value) => tag = findTag(value, "param", subject: Some(parameter.name))
        case None => ()
    }
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-params__description")])
    if (tag.isNone() && parameter.documentation.isNone()) {
        attrs.add(htmlAttr("data-documentation-state", "missing"))
    }
    w.open("dd", attrs: attrs.toArray())
    match (tag) {
        case Some(value) =>
            if (value.translationState.isEmpty() && !tagHasDescriptionContent(value, assets)) {
                appendEmptyDescriptionNoticeHtml(w, locale)
            } else {
                appendDocumentationTagHtml(w, value, locale, assets,
                    rootPrefix, markdownContext.getOrThrow())
            }
        case None =>
            match (parameter.documentation) {
                case Some(value) =>
                    if (value.trimAscii().isEmpty()) {
                        appendEmptyDescriptionNoticeHtml(w, locale)
                    } else {
                        appendStructuredTextHtml(w, value)
                    }
                case None => w.text(label(locale,
                    "No description has been provided.", "尚未提供说明。"))
            }
    }
    w.close("dd")
}

private func appendParameterDocumentationHtml(w: HtmlWriter, symbol: SymbolDoc,
    comment: ?DocComment, typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String,
    locale: String, sectionHeading: String, assets: HashMap<String, String>,
    markdownContext: ?HtmlMarkdownContext): Unit {
    if (symbol.parameters.isEmpty()) { return }
    w.open(sectionHeading, attrs: [htmlAttr("id", docBlockAnchor(symbol, "parameters")),
        htmlClass("cj-params__title")])
    w.text(label(locale, "Parameters", "参数"))
    w.close(sectionHeading)
    w.open("dl", attrs: [htmlClass("cj-params")])
    w.newline()
    for (parameter in symbol.parameters) {
        w.open("div", attrs: [htmlClass("cj-params__row")])
        w.open("dt", attrs: [htmlClass("cj-params__term")])
        w.open("code", attrs: [htmlClass("cj-params__declaration")])
        w.textElement("span", parameter.name, attrs: [htmlClass("cj-params__name")])
        w.textElement("span", ":", attrs: [htmlClass("cj-params__colon")])
        w.text(" ")
        w.open("span", attrs: [htmlClass("cj-params__type")])
        appendTypeRefCodeHtml(w, parameter.typeRef, typeLinkIndex, rootPrefix, locale)
        match (parameter.defaultExpression) {
            case Some(defaultExpression) =>
                w.open("span", attrs: [htmlClass("cj-params__default")])
                w.text("= ")
                w.textElement("code", defaultExpression)
                w.close("span")
            case None => ()
        }
        w.close("span")
        w.close("code")
        w.close("dt")
        appendParameterDescriptionHtml(w, parameter, comment, locale, assets, rootPrefix,
            markdownContext)
        w.close("div")
        w.newline()
    }
    w.close("dl")
    w.newline()
}

private func appendReturnDocumentationHtml(w: HtmlWriter, symbol: SymbolDoc,
    comment: ?DocComment, typeLinkIndex: HtmlTypeLinkIndex, rootPrefix: String,
    locale: String, sectionHeading: String, assets: HashMap<String, String>,
    markdownContext: ?HtmlMarkdownContext): Unit {
    var showReturnType = false
    if (let Some(returnType) <- symbol.returnType) { showReturnType = !isUnitType(returnType) }
    var hasReturnDocumentation = false
    match (comment) {
        case Some(value) =>
            for (tag in value.tags) {
                if (tag.name == "return" || tag.name == "returns") { hasReturnDocumentation = true; break }
            }
        case None => ()
    }
    if (!showReturnType && !hasReturnDocumentation) { return }

    w.open(sectionHeading, attrs: [htmlAttr("id", docBlockAnchor(symbol, "return")),
        htmlClass("cj-returns__title")])
    w.text(label(locale, "Returns", "返回值"))
    w.close(sectionHeading)
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-returns")])
    if (!hasReturnDocumentation) { attrs.add(htmlAttr("data-documentation-state", "missing")) }
    w.open("div", attrs: attrs.toArray())
    if (showReturnType) {
        w.open("span", attrs: [htmlClass("cj-returns__type")])
        appendTypeRefCodeHtml(w, symbol.returnType.getOrThrow(), typeLinkIndex, rootPrefix, locale)
        w.close("span")
    }
    if (!hasReturnDocumentation) {
        w.text(" " + label(locale, "No description has been provided.", "尚未提供说明。"))
    } else {
        match (comment) {
            case Some(value) =>
                for (tag in value.tags) {
                    if (tag.name != "return" && tag.name != "returns") { continue }
                    w.open("div", attrs: [htmlClass("cj-returns__description")])
                    if (tag.translationState.isEmpty() && !tagHasDescriptionContent(tag, assets)) {
                        appendEmptyDescriptionNoticeHtml(w, locale)
                    } else {
                        appendDocumentationTagHtml(w, tag, locale, assets,
                            rootPrefix, markdownContext.getOrThrow())
                    }
                    w.close("div")
                }
            case None => ()
        }
    }
    w.close("div")
    w.newline()
}

private func appendThrowsDocumentationHtml(w: HtmlWriter, symbol: SymbolDoc,
    comment: DocComment, index: HashMap<String, SymbolDoc>, rootPrefix: String,
    locale: String, sectionHeading: String, assets: HashMap<String, String>,
    markdownContext: HtmlMarkdownContext): Unit {
    var hasThrows = false
    for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
    if (!hasThrows) { return }
    w.open(sectionHeading, attrs: [htmlAttr("id", docBlockAnchor(symbol, "throws")),
        htmlClass("cj-throws__title")])
    w.text(label(locale, "Throws", "异常"))
    w.close(sectionHeading)
    w.open("dl", attrs: [htmlClass("cj-throws")])
    w.newline()
    for (tag in comment.tags) {
        if (tag.name != "throws") { continue }
        w.open("div", attrs: [htmlClass("cj-throws__row")])
        w.open("dt", attrs: [htmlClass("cj-throws__type")])
        appendTagSubjectHtml(w, tag, index, rootPrefix)
        // Missing documentation links are not API behavior. Preserve true
        // ambiguity locally, but keep the reason readable.
        if (tag.referenceState == "ambiguous") {
            w.text(" ")
            w.textElement("span", htmlReferenceStateLabel(tag.referenceState, locale),
                attrs: [htmlClass("cj-state-note"), htmlAttr("data-state", "ambiguous")])
        }
        w.close("dt")
        w.open("dd", attrs: [htmlClass("cj-throws__description")])
        appendDocumentationTagHtml(w, tag, locale, assets, rootPrefix, markdownContext)
        w.close("dd")
        w.close("div")
        w.newline()
    }
    w.close("dl")
    w.newline()
}

private func appendSeeAlsoHtml(w: HtmlWriter, comment: DocComment,
    index: HashMap<String, SymbolDoc>, rootPrefix: String, locale: String,
    sectionHeading: String, assets: HashMap<String, String>,
    markdownContext: HtmlMarkdownContext): Unit {
    var hasSee = false
    for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
    if (!hasSee) { return }
    w.open(sectionHeading, attrs: [htmlClass("cj-see-also__title")])
    w.text(label(locale, "See also", "另请参阅"))
    w.close(sectionHeading)
    w.open("ul", attrs: [htmlClass("cj-see-also__list")])
    w.newline()
    for (tag in comment.tags) {
        if (tag.name != "see") { continue }
        w.open("li", attrs: [htmlClass("cj-see-also__item")])
        appendTagSubjectHtml(w, tag, index, rootPrefix)
        if (!tag.description.isEmpty() || !tag.translationState.isEmpty()) {
            w.text(" ")
            appendDocumentationTagHtml(w, tag, locale, assets, rootPrefix, markdownContext)
        }
        w.close("li")
        w.newline()
    }
    w.close("ul")
    w.newline()
}

private func appendTagMetadataHtml(w: HtmlWriter, comment: DocComment, locale: String,
    sectionHeading: String, assets: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext): Unit {
    for (name in ["since", "author", "version"]) {
        var opened = false
        for (tag in comment.tags) {
            if (tag.name != name) { continue }
            if (!opened) {
                w.open(sectionHeading, attrs: [htmlClass("cj-tag-meta__title")])
                w.text(label(locale, tagHeading(name),
                    match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" }))
                w.close(sectionHeading)
                w.open("ul", attrs: [htmlClass("cj-tag-meta__list")])
                w.newline()
                opened = true
            }
            w.open("li", attrs: [htmlClass("cj-tag-meta__item")])
            appendDocumentationTagHtml(w, tag, locale, assets, rootPrefix, markdownContext)
            w.close("li")
            w.newline()
        }
        if (opened) {
            w.close("ul")
            w.newline()
        }
    }
}

internal func appendDocumentationHtml(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    headingBase!: Int64 = 3, includeContracts!: Bool = true,
    includeIntroduction!: Bool = true, locale!: String = "en",
    sectionHeadingLevel!: Int64 = 3): Unit {
    let blockHeading = "h${min(6, sectionHeadingLevel)}"
    match (symbol.documentation) {
        case Some(comment) =>
            let markdownContext = markdownHtmlContext(comment, symbol, headingBase, locale: locale)
            if (includeIntroduction) {
                appendDocumentationIntroductionHtml(w, symbol, rootPrefix, assetLookup, headingBase, locale,
                    context: Some(markdownContext))
            }
            appendParameterDocumentationHtml(w, symbol, Some(comment), typeLinkIndex,
                rootPrefix, locale, blockHeading, assetLookup, Some(markdownContext))
            appendReturnDocumentationHtml(w, symbol, Some(comment), typeLinkIndex,
                rootPrefix, locale, blockHeading, assetLookup, Some(markdownContext))
            appendThrowsDocumentationHtml(w, symbol, comment, index, rootPrefix, locale,
                blockHeading, assetLookup, markdownContext)
            if (includeContracts) {
                appendDocumentationContractsHtml(w, comment, locale, symbolAnchor(symbol),
                    assetLookup: assetLookup, rootPrefix: rootPrefix,
                    markdownContext: markdownContext, headingLevel: sectionHeadingLevel)
            }
            appendDocumentationExamplesHtml(w, comment, locale,
                headingLevel: sectionHeadingLevel, symbol: Some(symbol),
                assetLookup: assetLookup,
                rootPrefix: rootPrefix, markdownContext: markdownContext)
            appendSeeAlsoHtml(w, comment, index, rootPrefix, locale, blockHeading,
                assetLookup, markdownContext)
            appendTagMetadataHtml(w, comment, locale, blockHeading, assetLookup, rootPrefix,
                markdownContext)
        case None =>
            w.textElement("p", label(locale,
                "No documentation is available for this declaration.", "此声明暂无文档。"),
                attrs: [htmlClass("cj-empty")])
            w.newline()
            appendParameterDocumentationHtml(w, symbol, None, typeLinkIndex,
                rootPrefix, locale, blockHeading, assetLookup, None)
            appendReturnDocumentationHtml(w, symbol, None, typeLinkIndex,
                rootPrefix, locale, blockHeading, assetLookup, None)
    }
}

private func appendTagSubjectHtml(w: HtmlWriter, tag: DocTag,
    index: HashMap<String, SymbolDoc>, rootPrefix: String): Unit {
    var destination: ?String = None
    var title = ""
    if (let Some(navigation) <- tag.navigation) {
        if (navigation.state == "resolved" &&
            (!navigation.symbolKey.startsWith("cjdoc:v2:") || index.contains(navigation.symbolKey))) {
            destination = navigationHref(rootPrefix, navigation.url)
        }
        if (destination.isNone()) { title = navigation.reason }
    } else if (let Some(targetId) <- tag.targetSymbolId) {
        if (let Some(target) <- index.get(targetId)) { destination = navigationHref(rootPrefix, symbolUrl(index, target)) }
    }
    if (let Some(url) <- destination) {
        w.open("a", attrs: documentationHrefAttrs(url, navigation: tag.navigation,
            cssClass: "cj-tag-subject"))
    }
    let subjectAttrs = ArrayList<HtmlAttr>()
    if (!title.isEmpty()) { subjectAttrs.add(htmlAttr("title", title)) }
    w.open("code", attrs: subjectAttrs.toArray())
    w.text(tag.subject)
    w.close("code")
    if (destination.isSome()) { w.close("a") }
}

internal func appendSymbolArticle(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    linkTitle!: Bool = false,
    locale!: String = "en"): Unit {
    let isMember = symbol.ownerId.isSome()
    let tocRole = if (isMember) { "member" } else { "api" }
    w.open("article", attrs: [htmlClass("cj-symbol-entry"), htmlAttr("id", symbolAnchor(symbol))])
    w.open("h3", attrs: [htmlClass("cj-symbol-entry__title"),
        htmlAttr("data-cjdoc-toc-role", tocRole),
        htmlAttr("data-cjdoc-toc-label", htmlTocLabel(symbol))])
    if (linkTitle) {
        w.open("a", attrs: [htmlHref(SafeUrl.siteRoute(rootPrefix + symbolUrl(index, symbol)))])
        w.textElement("code", readerQualifiedName(symbol))
        w.close("a")
    } else {
        w.textElement("code", readerQualifiedName(symbol))
    }
    w.close("h3")
    w.newline()
    appendSymbolMetadata(w, index, symbol, rootPrefix, assetLookup, typeLinkIndex, locale: locale)
    appendDocumentationHtml(w, index, symbol, rootPrefix, assetLookup,
        typeLinkIndex, headingBase: 2, locale: locale)
    appendReaderRelationships(w, index, symbol, rootPrefix, typeLinkIndex, locale,
        headingTag: "h3")
    appendReverseTypeUsages(w, index, typeLinkIndex, symbol, rootPrefix, locale)
    w.close("article")
    w.newline()
}
