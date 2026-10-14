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

internal func capturedConceptualEntryHtml(documentation: DocumentationSet, locale: String): String {
    var localized = documentation.languageOptions.isSome()
    for (page in documentation.pages) { if (page.language.isSome()) { localized = true; break } }
    if (!localized) { return "" }
    let pages = selectedDocumentationPages(documentation, locale)
    if (pages.isEmpty()) { return "" }
    var route = pages[0].route
    for (page in pages where page.kind == "project") { route = page.route; break }
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
        var body = renderStandaloneMarkdownHtmlWithAssets(page.markdown, assetLookup, prefix,
            sourceLinks: sourceLinks, pageTitle: Some(page.title))
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
        introduction.append(capturedPageBindingsHtml(page, documentation, locale))
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
                renderConceptualHtmlPage(documentation, page.title, introduction.toString() + body, prefix,
                    source: Some(page.source), locale: locale, docVersion: version))
        }
        if (formats.contains("markdown")) {
            let markdown = RenderTextBuffer()
            let markdownLinks = capturedPageSourceLinks(documentation, page, pages, markdown: true)
            appendMarkdownNodeMarkdown(markdown, page.markdown, buildAssetLookup(assets, prefix: prefix), 1,
                capturedLinks: Some(markdownLinks))
            appendCapturedPageBindingsMarkdown(markdown, page, documentation, locale)
            artifacts.addText("markdown/" + page.route.removeSuffix(".html") + ".md", "text/markdown; charset=utf-8",
                markdown.toString() + "\n\n" + label(locale, "Content language: ", "内容语言：") + page.language.getOrDefault({ => "unknown" }) + "\n")
        }
    }
}

internal func capturedApiGuideLinks(documentation: DocumentationSet, symbol: SymbolDoc, locale: String): String {
    let out = RenderTextBuffer()
    var opened = false
    let visible = RenderProjection(documentation).visibleIndex
    for (page in selectedDocumentationPages(documentation, locale)) {
        var related = page.targetSymbolIds.toArray().contains(symbol.id)
        if (!related && symbol.ownerId.isNone()) {
            for (target in page.targetSymbolIds) {
                if (let Some(member) <- visible.get(target)) { if (member.ownerId == Some(symbol.id)) { related = true } }
            }
        }
        if (!related) { continue }
        if (!opened) { out.append("<section class=\"api-usages\"><h2>" + label(locale, "Related guides", "相关指南") + "</h2><ul>"); opened = true }
        out.append("<li><a data-guide-id=\"" + escapeHtml(page.id) + "\" href=\"../" + escapeHtml(page.route) + "\">")
        out.append(escapeHtml(page.title) + "</a></li>")
    }
    if (opened) { out.append("</ul></section>") }
    out.toString()
}
