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

internal func capturedConceptualEntryHtml(documentation: DocumentationSet, locale: String): String {
    var localized = documentation.languageOptions.isSome()
    for (page in documentation.pages) { if (page.language.isSome()) { localized = true; break } }
    let pages = selectedDocumentationPages(documentation, locale)
    if (pages.isEmpty()) { return "" }
    var route = pages[0].route
    for (page in pages where page.kind == "project") { route = page.route; break }
    if (!localized) {
        return "<p>" + label(locale,
            "Read the project guide before browsing the full generated API index.",
            "先阅读项目指南，再浏览完整的生成 API 索引。") + "</p><a href=\"" + escapeHtml(route) + "\">" +
            label(locale, "Open conceptual documentation", "打开概念文档") + "</a>\n"
    }
    "<p><a href=\"" + escapeHtml(route) + "\">" + label(locale, "Start with the guide", "从指南开始") + "</a></p>"
}

internal func appendCapturedPageArtifacts(artifacts: RenderArtifactCollector, documentation: DocumentationSet,
    formats: Array<String>, locale: String, version: ?String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    let assets = projectAssets(documentation, RenderProjection(documentation), pages: pages)
    let assetLookup = buildAssetLookup(assets)
    let links = HashMap<String, String>()
    for (page in pages) { links[page.source] = page.route }
    for (page in pages) {
        let prefix = pageRootPrefix(page.route)
        let sourceLinks = capturedPageSourceLinks(documentation, page, pages)
        let visible = RenderProjection(documentation).visibleIndex
        let bindingChips = HashMap<Int64, String>()
        for (binding in page.bindings) {
            bindingChips[binding.sourceLine] = capturedPageBindingChipHtml(page, binding, visible, locale)
        }
        var body = renderStandaloneMarkdownHtmlWithAssets(page.markdown, assetLookup, prefix,
            sourceLinks: sourceLinks, pageTitle: Some(page.title),
            bindingSource: page.source, bindingChips: Some(bindingChips))
        for (section in page.sections) {
            if (let Some(anchor) <- documentationSectionAnchor(page.markdown, section.anchor)) {
                // The explicit semantic id sits at the real heading position.
                body = body.replace("id=\"" + anchor + "\"", "id=\"" + anchor + "\" data-semantic-section=\"" + escapeHtml(section.id) + "\"")
            }
        }
        let state = if (page.language.isNone()) { "unknown" } else if (page.language == Some(locale)) { "complete" } else { "fallback" }
        let provenance = DocTag("description", "", "", contentLanguage: page.language, translationState: state)
        let introduction = RenderTextBuffer()
        appendContentLanguageHtml(introduction, provenance, locale)
        if (page.kind == "project") {
            introduction.append("<nav aria-label=\"" + label(locale, "Guides", "指南") + "\"><ul>")
            for (other in pages where other.id != page.id) {
                introduction.append("<li><a href=\"" + prefix + escapeHtml(other.route) + "\">" + escapeHtml(other.title) + "</a></li>")
            }
            introduction.append("</ul></nav>")
        }
        if (!page.targetSymbolIds.isEmpty()) {
            introduction.append("<nav aria-label=\"" + label(locale, "Related APIs", "相关 API") + "\"><ul>")
            let visible = RenderProjection(documentation).visibleIndex
            for (id in page.targetSymbolIds) {
                if (let Some(symbol) <- visible.get(id)) {
                    introduction.append("<li><a href=\"" + prefix + escapeHtml(symbolUrl(visible, symbol)) + "\">" + escapeHtml(symbol.qualifiedName) + "</a></li>")
                }
            }
            introduction.append("</ul></nav>")
        }
        if (formats.contains("html")) {
            artifacts.addText("html/" + page.route, "text/html; charset=utf-8",
                renderConceptualHtmlPage(documentation, page.title,
                    introduction.toString() + body + capturedPageBindingsHtml(page, documentation, locale), prefix,
                    source: Some(page.source), locale: locale, docVersion: version, pageRoute: Some(page.route)))
        }
        if (formats.contains("markdown")) {
            let markdown = RenderTextBuffer()
            let markdownLinks = capturedPageSourceLinks(documentation, page, pages, markdown: true)
            let (markdownTree, _) = capturedPageMarkdownWithoutMarkers(page.markdown, page)
            appendMarkdownNodeMarkdown(markdown, markdownTree.getOrThrow(), buildAssetLookup(assets, prefix: prefix), 1,
                capturedLinks: Some(markdownLinks))
            appendCapturedPageBindingsMarkdown(markdown, page, documentation, locale)
            artifacts.addText("markdown/" + page.route.removeSuffix(".html") + ".md", "text/markdown; charset=utf-8",
                markdown.toString() + "\n\n" + label(locale, "Content language: ", "内容语言：") + page.language.getOrDefault({ => "unknown" }) + "\n")
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

    func append(out: RenderTextBuffer, symbol: SymbolDoc, locale: String,
        headingTag!: String = "h2", headingSuffix!: String = ""): Unit {
        let pages = match (pagesBySymbol.get(symbol.id)) {
            case Some(values) => values
            case None => return
        }
        let heading = "conceptual-api-usages-heading" + headingSuffix
        out.append("<section class=\"api-usages\" aria-labelledby=\"" + escapeHtml(heading) + "\"><" + headingTag + " id=\"" + escapeHtml(heading) + "\">" + label(locale, "Related guides", "相关指南") + "</" + headingTag + "><ul>")
        for (page in pages) {
            out.append("<li><a data-guide-id=\"" + escapeHtml(page.id) + "\" href=\"../" + escapeHtml(page.route) + "\">")
            out.append(escapeHtml(page.title) + "</a></li>")
        }
        out.append("</ul></section>")
    }
}

private func capturedPageMarkdownWithoutMarkers(node: MarkdownNode,
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

