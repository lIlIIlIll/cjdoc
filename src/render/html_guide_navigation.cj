package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendGuideSequence(w: HtmlWriter, pages: Array<DocumentationPage>,
    current: DocumentationPage, locale: String): Unit {
    if (current.kind != "guide") { return }
    let guides = ArrayList<DocumentationPage>()
    for (page in pages where page.kind == "guide" && capturedPageHasContent(page)) { guides.add(page) }
    if (guides.size < 2) { return }
    for (index in 0..guides.size) {
        if (guides[index].id != current.id) { continue }
        w.element("nav", [htmlClass("cj-guide-sequence"),
            htmlAttr("aria-label", label(locale, "Continue reading", "继续阅读"))]) { nav =>
            if (index > 0) { appendGuideSequenceLink(nav, guides[index - 1], current.route, locale, false) }
            if (index + 1 < guides.size) {
                appendGuideSequenceLink(nav, guides[index + 1], current.route, locale, true)
            }
        }
        w.newline()
        return
    }
}

private func appendGuideSequenceLink(w: HtmlWriter, page: DocumentationPage,
    currentRoute: String, locale: String, next: Bool): Unit {
    let direction = if (next) { "next" } else { "prev" }
    let directionText = if (next) { label(locale, "Next", "下一篇") } else { label(locale, "Previous", "上一篇") }
    w.element("a", [htmlAttr("rel", direction),
        htmlHref(documentationRouteHref(pageRootPrefix(currentRoute) + page.route))]) { link =>
        link.textElement("span", directionText)
        link.text(page.title)
    }
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
    if ((node.kind == "html_block" || node.kind == "html_inline") &&
        node.literal == "<!-- cjdoc-bind -->") {
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
internal func appendTypeGuideEntry(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, symbol: SymbolDoc, locale: String): Unit {
    if (!isTypeDeclaration(symbol) && symbol.kind != "extend") { return }
    let related = HashSet<String>()
    let _ = related.add(symbol.id)
    for (entry in projection.members(symbol).entries) { let _ = related.add(entry.symbol.id) }
    for (page in selectedDocumentationPages(documentation, locale) where page.kind == "guide") {
        for (target in page.targetSymbolIds where related.contains(target)) {
            w.element("p", [htmlClass("cj-guide-entry")]) { paragraph =>
                paragraph.text(label(locale, "Read the guide: ", "从指南开始："))
                paragraph.element("a", [htmlHref(documentationRouteHref("../" + page.route))]) { link =>
                    link.text(page.title)
                }
            }
            return
        }
    }
}
