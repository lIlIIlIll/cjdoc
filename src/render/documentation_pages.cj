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

internal func capturedPageHasContent(page: DocumentationPage): Bool {
    if (!page.bindings.isEmpty()) { return true }
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

internal func appendPageContentLanguage(out: RenderTextBuffer, page: DocumentationPage,
    locale: String): Unit {
    let state = if (page.language.isNone()) { "unknown" } else if (page.language == Some(locale)) { "complete" } else { "fallback" }
    appendContentLanguageHtml(out, DocTag("description", "", "",
        contentLanguage: page.language, translationState: state), locale)
}

// Reuse the captured tree, highlight, assets and binding decisions when the
// same author's introduction is read at home or at its canonical guide URL.
internal func capturedPageBodyHtml(documentation: DocumentationSet, page: DocumentationPage,
    locale: String, outputPath: String, assetLookup: HashMap<String, String>,
    afterFirstCode!: String = ""): String {
    let pages = selectedDocumentationPages(documentation, locale)
    let relocated: ?String = if (outputPath == page.route) { None } else { Some(outputPath) }
    let links = capturedPageSourceLinks(documentation, page, pages, outputPath: relocated)
    let visible = RenderProjection(documentation).visibleIndex
    let chips = HashMap<Int64, String>()
    for (binding in page.bindings) {
        chips[binding.sourceLine] = capturedPageBindingChipHtml(page, binding, visible, locale,
            outputPath: relocated)
    }
    var body = renderStandaloneMarkdownHtmlWithAssets(page.markdown, assetLookup,
        pageRootPrefix(outputPath), sourceLinks: links, pageTitle: Some(page.title),
        bindingSource: page.source, bindingChips: Some(chips), headingBase: 1, afterFirstCode: afterFirstCode)
    for (section in page.sections) {
        if (let Some(anchor) <- documentationSectionAnchor(page.markdown, section.anchor)) {
            body = body.replace("id=\"" + anchor + "\"", "id=\"" + anchor +
                "\" data-semantic-section=\"" + escapeHtml(section.id) + "\"")
        }
    }
    body
}

internal func appendCapturedPageArtifacts(artifacts: RenderArtifactCollector, documentation: DocumentationSet,
    formats: Array<String>, locale: String, version: ?String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    let assets = projectAssets(documentation, RenderProjection(documentation), pages: pages)
    let assetLookup = buildAssetLookup(assets)
    for (page in pages) {
        let prefix = pageRootPrefix(page.route)
        let body = RenderTextBuffer()
        body.append("<article class=\"guide-content prose\">")
        let placeholder = !capturedPageHasContent(page) && ["project", "package"].contains(page.kind)
        if (placeholder) {
            let context = HtmlMarkdownContext(2)
            collectMarkdownHeadings(page.markdown, "standalone", HashMap<String, Int64>(), context)
            for (anchor in context.headingIds) { body.append("<span id=\"" + escapeHtml(anchor) + "\"></span>") }
            body.append("<p>" + label(locale, "An author overview has not been provided.", "作者尚未提供概述。") +
                "</p><p><a href=\"" + prefix + "index.html#packages\">" +
                label(locale, "Browse the complete API reference", "浏览完整 API 参考") + "</a></p>")
        } else {
            appendPageContentLanguage(body, page, locale)
            body.append(capturedPageBodyHtml(documentation, page, locale, page.route, assetLookup))
        }
        body.append("</article>\n")
        let navigation = RenderTextBuffer()
        if (page.kind == "project") {
            navigation.append("<nav class=\"reading-paths\" aria-label=\"" + label(locale, "Guides", "指南") + "\"><ul>")
            for (other in pages where other.kind == "guide" && capturedPageHasContent(other)) {
                navigation.append("<li><a href=\"" + prefix + escapeHtml(other.route) + "\">" + escapeHtml(other.title) + "</a></li>")
            }
            navigation.append("</ul></nav>")
        }
        if (!page.targetSymbolIds.isEmpty()) {
            navigation.append("<nav class=\"guide-related-api\" aria-label=\"" + label(locale, "Related APIs", "相关 API") + "\"><ul>")
            let visible = RenderProjection(documentation).visibleIndex
            for (id in page.targetSymbolIds) {
                if (let Some(symbol) <- visible.get(id)) {
                    navigation.append("<li><a href=\"" + prefix + escapeHtml(symbolUrl(visible, symbol)) + "\">" + escapeHtml(symbol.qualifiedName) + "</a></li>")
                }
            }
            navigation.append("</ul></nav>")
        }
        appendGuideSequence(navigation, pages, page, locale)
        if (formats.contains("html")) {
            artifacts.addText("html/" + page.route, "text/html; charset=utf-8",
                renderConceptualHtmlPage(documentation,
                    if (placeholder && page.kind == "package") { label(locale, "Package ", "包 ") + page.packageName } else { page.title },
                    body.toString() + navigation.toString() + capturedPageBindingsHtml(page, documentation, locale), prefix,
                    source: Some(page.source), locale: locale, docVersion: version, pageRoute: Some(page.route),
                    agentMarkdown: Some(agentPageMarkdownPath(page))))
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
            for ((route, section) in guideSectionTargets(page, symbol.id)) {
                out.append("<li><a data-guide-id=\"" + escapeHtml(page.id) + "\" href=\"../" + escapeHtml(route) + "\">")
                out.append(escapeHtml(page.title))
                if (!section.isEmpty()) { out.append(" · " + escapeHtml(section)) }
                out.append("</a></li>")
            }
        }
        out.append("</ul></section>")
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
