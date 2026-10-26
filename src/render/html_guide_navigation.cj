package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendGuideSequence(out: RenderTextBuffer, pages: Array<DocumentationPage>,
    current: DocumentationPage, locale: String): Unit {
    if (current.kind != "guide") { return }
    let guides = ArrayList<DocumentationPage>()
    for (page in pages where page.kind == "guide" && capturedPageHasContent(page)) { guides.add(page) }
    if (guides.size < 2) { return }
    for (index in 0..guides.size) {
        if (guides[index].id != current.id) { continue }
        out.append("<nav class=\"guide-sequence\" aria-label=\"" + label(locale, "Continue reading", "继续阅读") + "\">")
        if (index > 0) { appendGuideSequenceLink(out, guides[index - 1], current.route, locale, false) }
        if (index + 1 < guides.size) { appendGuideSequenceLink(out, guides[index + 1], current.route, locale, true) }
        out.append("</nav>\n")
        return
    }
}

private func appendGuideSequenceLink(out: RenderTextBuffer, page: DocumentationPage,
    currentRoute: String, locale: String, next: Bool): Unit {
    let direction = if (next) { "next" } else { "prev" }
    let text = if (next) { label(locale, "Next", "下一篇") } else { label(locale, "Previous", "上一篇") }
    out.append("<a rel=\"${direction}\" href=\"" + pageRootPrefix(currentRoute) + escapeHtml(page.route) +
        "\"><span>" + text + "</span>" + escapeHtml(page.title) + "</a>")
}

private class GuideSectionContext {
    let markdown = HtmlMarkdownContext(2)
    let sections = ArrayList<(Int64, String, String)>()
    var chapter: ?(String, String) = None
}

private func collectGuideBindingSections(node: MarkdownNode, source: String,
    context: GuideSectionContext): Unit {
    if (node.kind == "heading") {
        let anchor = context.markdown.headingIds[context.markdown.nextHeading]
        context.markdown.nextHeading++
        context.chapter = if (node.metadata.isSome() &&
            node.metadata.getOrThrow().headingLevel != Some(1)) {
            Some((anchor, markdownNodeText(node)))
        } else { None }
    }
    if (node.kind == "html_block" && node.literal == "<!-- cjdoc-bind -->") {
        if (let Some(position) <- node.source) {
            if (position.path == source) {
                if (let Some(chapter) <- context.chapter) {
                    context.sections.add((position.start.line, chapter[0], chapter[1]))
                }
            }
        }
    }
    for (child in node.children) { collectGuideBindingSections(child, source, context) }
}

// Captured headings need no source ranges: tree order proves the chapter,
// and the preserved binding marker position proves the exact association.
internal func guideSectionTargets(page: DocumentationPage, symbolId: String): Array<(String, String)> {
    let context = GuideSectionContext()
    collectMarkdownHeadings(page.markdown, "standalone", HashMap<String, Int64>(), context.markdown)
    collectGuideBindingSections(page.markdown, page.source, context)
    let result = ArrayList<(String, String)>()
    let seen = HashSet<String>()
    for (binding in page.bindings) {
        if (binding.state != "resolved" || binding.targetSymbolId != Some(symbolId)) { continue }
        if (let Some(navigation) <- binding.navigation) {
            if (navigation.state != "resolved" || navigation.symbolKey != symbolId) { continue }
        }
        var selected: ?(Int64, String, String) = None
        for (heading in context.sections) {
            if (heading[0] == binding.sourceLine) { selected = Some(heading) }
        }
        if (let Some(heading) <- selected) {
            if (seen.add(heading[1])) { result.add((page.route + "#" + heading[1], heading[2])) }
        }
    }
    if (result.isEmpty()) { result.add((page.route, "")) }
    result.toArray()
}

// The author's first guide that actually binds this type or its members is an
// entry point; no package-name or prose-keyword inference creates a link.
internal func appendTypeGuideEntry(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, symbol: SymbolDoc, locale: String): Unit {
    if (!isTypeDeclaration(symbol) && symbol.kind != "extend") { return }
    let related = HashSet<String>()
    let _ = related.add(symbol.id)
    for (entry in projection.members(symbol).entries) { let _ = related.add(entry.symbol.id) }
    for (page in selectedDocumentationPages(documentation, locale) where page.kind == "guide") {
        for (target in page.targetSymbolIds where related.contains(target)) {
            out.append("<p class=\"api-guide-entry\">" + label(locale, "Read the guide: ", "从指南开始：") +
                "<a href=\"../" + escapeHtml(page.route) + "\">" + escapeHtml(page.title) + "</a></p>")
            return
        }
    }
}
