package cjdoc.render

import cjdoc.model.*
import std.collection.*

/** Explicit mappings are checked against headings actually present in the tree. */
public func documentationSectionAnchor(tree: MarkdownNode, anchor: String): ?String {
    let context = HtmlMarkdownContext(2)
    collectMarkdownHeadings(tree, "standalone", HashMap<String, Int64>(), context)
    if (context.headingIds.contains(anchor)) { return Some(anchor) }
    context.fragmentTargets.get("#" + anchor)
}

internal func selectedDocumentationPages(value: DocumentationSet, locale: String): Array<DocumentationPage> {
    let ids = ArrayList<String>()
    for (page in value.pages) { if (!ids.contains(page.id)) { ids.add(page.id) } }
    let result = ArrayList<DocumentationPage>()
    for (id in ids) {
        var exact: ?DocumentationPage = None
        var original: ?DocumentationPage = None
        var unknown: ?DocumentationPage = None
        for (page in value.pages where page.id == id) {
            if (page.language == Some(locale)) { exact = Some(page) }
            if (page.language == page.defaultLanguage) { original = Some(page) }
            if (page.language.isNone()) { unknown = Some(page) }
        }
        let selected = if (exact.isSome()) { exact } else if (original.isSome()) { original } else { unknown }
        if (let Some(page) <- selected) { result.add(page) }
    }
    result.toArray()
}

internal func pageRootPrefix(route: String): String {
    var prefix = ""
    for (_ in 1..route.split("/").size) { prefix += "../" }
    prefix
}

internal func appendCapturedPageMarkdownNavigation(out: RenderTextBuffer,
    documentation: DocumentationSet, locale: String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    if (pages.isEmpty()) { return }
    out.append("\n## ${label(locale, "Conceptual documentation", "概念文档")}\n\n")
    for (page in pages) {
        out.append("- [")
        appendEscapedMarkdownText(out, page.title.replace("\r", " ").replace("\n", " ").replace("\t", " "))
        out.append("](" + encodeMarkdownDestination(page.route.removeSuffix(".html") + ".md") + ")\n")
    }
}

private func capturedPageHasImage(node: MarkdownNode): Bool {
    if (node.kind == "image") { return true }
    for (child in node.children) {
        if (capturedPageHasImage(child)) { return true }
    }
    false
}

internal func capturedPageHasContent(page: DocumentationPage): Bool {
    // Empty alt text is valid for an authored image; text extraction cannot
    // distinguish it from an empty overview. Asset safety remains in rendering.
    if (!page.bindings.isEmpty() || capturedPageHasImage(page.markdown)) { return true }
    for (node in page.markdown.children) {
        if (["heading", "html_block", "html_inline"].contains(node.kind)) { continue }
        let text = markdownNodeText(node).trimAscii()
        // Legacy generator fallbacks stay in the snapshot, but are not author introductions.
        if (page.kind == "project" && text ==
            "This site contains the conceptual documentation and generated API reference.") { continue }
        if (page.kind == "package" && text == "This page describes the conceptual role of the package.") { continue }
        if (!text.isEmpty()) { return true }
    }
    false
}

internal func appendPageContentLanguage(w: HtmlWriter, page: DocumentationPage,
    locale: String): Unit {
    let state = if (page.language.isNone()) { "unknown" } else if (page.language == Some(locale)) { "complete" } else { "fallback" }
    appendContentLanguageHtml(w, DocTag("description", "", "",
        contentLanguage: page.language, translationState: state), locale)
}

private func capturedPageSectionIds(page: DocumentationPage): HashMap<String, String> {
    let result = HashMap<String, String>()
    for (section in page.sections) {
        if (let Some(anchor) <- documentationSectionAnchor(page.markdown, section.anchor)) {
            result[anchor] = section.id
        }
    }
    result
}

private func capturedPageBindingChips(page: DocumentationPage, visible: HashMap<String, SymbolDoc>,
    locale: String, outputPath: ?String): HashMap<Int64, TrustedHtml> {
    let chips = HashMap<Int64, TrustedHtml>()
    for (binding in page.bindings) {
        chips[binding.sourceLine] = TrustedHtml.capture { w =>
            appendCapturedPageBindingChipHtml(w, page, binding, visible, locale, outputPath: outputPath)
        }
    }
    chips
}

// Reuse the captured tree, highlight, assets and binding decisions when the
// same author's introduction is read at home or at its canonical guide URL.
internal func appendCapturedPageBodyHtml(w: HtmlWriter, documentation: DocumentationSet,
    page: DocumentationPage, locale: String, outputPath: String,
    assetLookup: HashMap<String, String>, afterFirstCode!: ?TrustedHtml = None): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    let relocated: ?String = if (outputPath == page.route) { None } else { Some(outputPath) }
    let links = capturedPageSourceLinks(documentation, page, pages, outputPath: relocated)
    let visible = RenderProjection(documentation).visibleIndex
    appendStandaloneMarkdownHtmlWithAssets(w, page.markdown, assetLookup,
        pageRootPrefix(outputPath), sourceLinks: links, pageTitle: Some(page.title),
        bindingSource: page.source, bindingChips: Some(capturedPageBindingChips(page, visible,
            locale, relocated)), headingBase: 1, afterFirstCode: afterFirstCode,
        sectionIds: capturedPageSectionIds(page), locale: locale)
}

private func appendPlaceholderBody(w: HtmlWriter, page: DocumentationPage, prefix: String,
    locale: String): Unit {
    let context = HtmlMarkdownContext(2)
    collectMarkdownHeadings(page.markdown, "standalone", HashMap<String, Int64>(), context)
    for (anchor in context.headingIds) {
        w.textElement("span", "", attrs: [htmlAttr("id", anchor)])
    }
    w.textElement("p", label(locale, "An author overview has not been provided.", "作者尚未提供概述。"))
    w.element("p", []) { paragraph =>
        paragraph.element("a", [htmlHref(documentationRouteHref(prefix + "index.html#packages"))]) { link =>
            link.text(label(locale, "Browse the complete API reference", "浏览完整 API 参考"))
        }
    }
}

private func appendGuideNavigation(w: HtmlWriter, documentation: DocumentationSet,
    pages: Array<DocumentationPage>, page: DocumentationPage, prefix: String, locale: String): Unit {
    if (page.kind == "project") {
        w.element("nav", [htmlClass("cj-reading-paths"),
            htmlAttr("aria-label", label(locale, "Guides", "指南"))]) { nav =>
            nav.element("ul", []) { list =>
                for (other in pages where other.kind == "guide" && capturedPageHasContent(other)) {
                    list.element("li", []) { item =>
                        item.element("a", [htmlHref(documentationRouteHref(prefix + other.route))]) { link =>
                            link.text(other.title)
                        }
                    }
                }
            }
        }
    }
    if (!page.targetSymbolIds.isEmpty()) {
        let visible = RenderProjection(documentation).visibleIndex
        w.element("nav", [htmlClass("cj-guide__related"),
            htmlAttr("aria-label", label(locale, "Related APIs", "相关 API"))]) { nav =>
            nav.element("ul", []) { list =>
                for (id in page.targetSymbolIds) {
                    if (let Some(symbol) <- visible.get(id)) {
                        list.element("li", []) { item =>
                            item.element("a", [htmlHref(documentationRouteHref(
                                prefix + symbolUrl(visible, symbol)))]) { link =>
                                link.text(symbol.qualifiedName)
                            }
                        }
                    }
                }
            }
        }
    }
    appendGuideSequence(w, pages, page, locale)
}

private func appendCapturedPageHtmlBody(w: HtmlWriter, documentation: DocumentationSet,
    pages: Array<DocumentationPage>, page: DocumentationPage, locale: String,
    assetLookup: HashMap<String, String>, prefix: String, placeholder: Bool): Unit {
    w.open("article", attrs: [htmlClass("cj-guide cj-prose")])
    if (placeholder) {
        appendPlaceholderBody(w, page, prefix, locale)
    } else {
        appendPageContentLanguage(w, page, locale)
        appendCapturedPageBodyHtml(w, documentation, page, locale, page.route, assetLookup)
    }
    w.close("article")
    w.newline()
    appendGuideNavigation(w, documentation, pages, page, prefix, locale)
    appendCapturedPageBindingsHtml(w, page, documentation, locale)
}

internal func appendCapturedPageArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, formats: Array<String>, locale: String,
    version: ?String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    let assets = projectAssets(documentation, RenderProjection(documentation), pages: pages)
    let assetLookup = buildAssetLookup(assets)
    for (page in pages) {
        let prefix = pageRootPrefix(page.route)
        let placeholder = !capturedPageHasContent(page) && ["project", "package"].contains(page.kind)
        if (formats.contains("html")) {
            let body = TrustedHtml.capture { w =>
                appendCapturedPageHtmlBody(w, documentation, pages, page, locale, assetLookup,
                    prefix, placeholder)
            }
            let title = if (placeholder && page.kind == "package") {
                label(locale, "Package ", "包 ") + page.packageName
            } else { page.title }
            artifacts.addText("html/" + page.route, "text/html; charset=utf-8",
                renderConceptualHtmlPage(documentation, title, body, prefix,
                    source: Some(page.source), locale: locale, docVersion: version,
                    pageRoute: Some(page.route), agentMarkdown: Some(agentPageMarkdownPath(page))))
        }
        if (formats.contains("markdown")) {
            let markdown = RenderTextBuffer()
            let markdownLinks = capturedPageSourceLinks(documentation, page, pages, markdown: true)
            let (markdownTree, _) = capturedPageMarkdownWithoutMarkers(page.markdown, page)
            appendMarkdownNodeMarkdown(markdown, markdownTree.getOrThrow(),
                buildAssetLookup(assets, prefix: prefix), 1, capturedLinks: Some(markdownLinks))
            appendCapturedPageBindingsMarkdown(markdown, page, documentation, locale)
            artifacts.addText("markdown/" + page.route.removeSuffix(".html") + ".md",
                "text/markdown; charset=utf-8",
                markdown.toString() + "\n\n" + label(locale, "Content language: ", "内容语言：") +
                    page.language.getOrDefault({ => "unknown" }) + "\n")
        }
    }
}

internal class CapturedApiGuideIndex {
    private let pagesBySymbol = HashMap<String, ArrayList<DocumentationPage>>()

    init(documentation: DocumentationSet, projection: RenderProjection, locale: String) {
        for (page in selectedDocumentationPages(documentation, locale)) {
            let related = HashSet<String>()
            for (id in page.targetSymbolIds) {
                let target = match (projection.visibleIndex.get(id)) {
                    case Some(value) => value
                    case None => continue
                }
                add(page, target.id, related)
                if (let Some(ownerId) <- target.ownerId) {
                    if (let Some(owner) <- projection.visibleIndex.get(ownerId)) {
                        if (owner.ownerId.isNone()) { add(page, owner.id, related) }
                    }
                }
            }
        }
    }

    private func add(page: DocumentationPage, symbolId: String, related: HashSet<String>): Unit {
        if (!related.add(symbolId)) { return }
        match (pagesBySymbol.get(symbolId)) {
            case Some(pages) => pages.add(page)
            case None => pagesBySymbol[symbolId] = ArrayList<DocumentationPage>([page])
        }
    }

    func append(w: HtmlWriter, symbol: SymbolDoc, locale: String,
        headingTag!: String = "h2", headingSuffix!: String = ""): Unit {
        let pages = match (pagesBySymbol.get(symbol.id)) {
            case Some(values) => values
            case None => return
        }
        let heading = "conceptual-api-usages-heading" + headingSuffix
        w.open("section", attrs: [htmlClass("cj-usages"), htmlAttr("aria-labelledby", heading)])
        w.open(headingTag, attrs: [htmlAttr("id", heading)])
        w.text(label(locale, "Related guides", "相关指南"))
        w.close(headingTag)
        w.open("ul")
        for (page in pages) {
            for ((route, section) in guideSectionTargets(page, symbol.id)) {
                w.element("li", []) { item =>
                    item.element("a", [htmlAttr("data-guide-id", page.id),
                        htmlHref(documentationRouteHref("../" + route))]) { link =>
                        link.text(page.title)
                        if (!section.isEmpty()) { link.text(" · " + section) }
                    }
                }
            }
        }
        w.close("ul")
        w.close("section")
    }
}

internal func capturedPageMarkdownWithoutMarkers(node: MarkdownNode,
    page: DocumentationPage): (?MarkdownNode, Bool) {
    if (["html_block", "html_inline"].contains(node.kind) && node.literal == "<!-- cjdoc-bind -->" &&
        node.source.isSome() && node.source.getOrThrow().path == page.source) {
        for (binding in page.bindings where binding.sourceLine == node.source.getOrThrow().start.line) {
            return (None, true)
        }
    }
    var children: ?ArrayList<MarkdownNode> = None
    for (index in 0..node.children.size) {
        let (filtered, childChanged) = capturedPageMarkdownWithoutMarkers(node.children[index], page)
        if (childChanged && children.isNone()) {
            let replacements = ArrayList<MarkdownNode>()
            for (previous in 0..index) { replacements.add(node.children[previous]) }
            children = Some(replacements)
        }
        if (children.isSome()) {
            if (let Some(value) <- filtered) { children.getOrThrow().add(value) }
        }
    }
    if (children.isNone()) { return (Some(node), false) }
    let filteredChildren = children.getOrThrow()
    if (node.kind == "table_row") {
        var empty = true
        for (cell in filteredChildren) { if (!cell.children.isEmpty()) { empty = false; break } }
        if (empty) { return (None, true) }
    }
    let replacement = match (node.metadata) {
        case Some(metadata) => MarkdownNode(node.kind, metadata, literal: node.literal,
            source: node.source, children: filteredChildren.toArray())
        case None => MarkdownNode(node.kind, literal: node.literal,
            source: node.source, children: filteredChildren.toArray())
    }
    (Some(replacement), true)
}
