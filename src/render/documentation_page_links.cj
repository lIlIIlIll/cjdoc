package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendSearchPageBindings(out: RenderTextBuffer, page: DocumentationPage): Unit {
    out.append(",\"bindings\":[")
    var first = true
    for (binding in page.bindings where binding.state != "unavailable") {
        if (!first) { out.append(",") }; first = false
        out.append("{\"target\":${escapeJsonString(binding.target)},\"selector\":${escapeJsonString(binding.selector)},\"provenance\":${escapeJsonString(binding.provenance)},\"version\":${escapeJsonString(binding.version)},")
        out.append("\"sourceLine\":${binding.sourceLine},\"language\":${escapeJsonString(binding.language)},\"state\":${escapeJsonString(binding.state)},\"targetSymbolId\":${nullableString(binding.targetSymbolId)}}")
    }
    out.append("]")
}

private func capturedSourcePath(source: String, destination: String): String {
    if (destination.startsWith("/") || destination.contains(":")) { return "" }
    let parts = ArrayList<String>()
    let parent = source.split("/")
    for (index in 0..parent.size - 1) { parts.add(parent[index]) }
    for (part in destination.split("/")) {
        if (part == "." || part.isEmpty()) { continue }
        if (part == "..") {
            if (parts.isEmpty()) { return "" }
            parts.remove(at: parts.size - 1)
        } else { parts.add(part) }
    }
    let out = RenderTextBuffer()
    for (part in parts) { if (out.size > 0) { out.append("/") }; out.append(part) }
    out.toString()
}

internal func capturedPageSourceLinks(documentation: DocumentationSet, page: DocumentationPage,
    pages: Array<DocumentationPage>, markdown!: Bool = false): HashMap<String, String> {
    let links = HashMap<String, String>()
    let prefix = pageRootPrefix(page.route)
    for (original in documentation.pages) {
        for (selected in pages where original.id == selected.id) {
            let destination = prefix + if (markdown) { selected.route.removeSuffix(".html") + ".md" } else { selected.route }
            links[original.source] = destination
        }
    }
    let result = HashMap<String, String>()
    capturedPageLinkNodes(page.markdown, page.source, links, result)
    result
}

private func capturedPageLinkNodes(tree: MarkdownNode, source: String, routes: HashMap<String, String>,
    result: HashMap<String, String>): Unit {
    if (tree.kind == "link") {
        let parts = tree.literal.split("#", 2)
        let path = capturedSourcePath(source, parts[0])
        if (let Some(route) <- routes.get(path)) {
            // A source fragment is preserved only within the same captured page.
            // Translated headings need the explicit language-section mapping.
            result[tree.literal] = route + if (parts.size == 2 && path == source) { "#" + parts[1] } else { "" }
        }
    }
    for (child in tree.children) { capturedPageLinkNodes(child, source, routes, result) }
}

internal func capturedMarkdownLinks(tree: MarkdownNode, links: HashMap<String, String>): MarkdownNode {
    let children = ArrayList<MarkdownNode>()
    for (child in tree.children) { children.add(capturedMarkdownLinks(child, links)) }
    let literal = if (tree.kind == "link") { links.get(tree.literal).getOrDefault({ => tree.literal }) } else { tree.literal }
    match (tree.metadata) {
        case Some(metadata) => MarkdownNode(tree.kind, metadata, literal: literal, source: tree.source, children: children.toArray())
        case None => MarkdownNode(tree.kind, literal: literal, source: tree.source, children: children.toArray())
    }
}

internal func capturedPageBindingsHtml(page: DocumentationPage, documentation: DocumentationSet,
    locale: String): String {
    let out = RenderTextBuffer()
    let visible = RenderProjection(documentation).visibleIndex
    for (binding in page.bindings) {
        out.append("<div class=\"inline-binding\"><span class=\"binding-state\" data-state=\"" + binding.state + "\">")
        let state = match (binding.state) {
            case "resolved" => label(locale, "Linked", "已关联")
            case "unavailable" => label(locale, "Not available in this audience", "当前受众不可见")
            case "ambiguous" => label(locale, "Ambiguous target", "目标不明确")
            case "conflict" => label(locale, "Conflicting markers", "标记冲突")
            case _ => label(locale, "Target not found", "未找到目标")
        }
        out.append(state + "</span> ")
        let target: ?SymbolDoc = match (binding.targetSymbolId) { case Some(id) => visible.get(id); case None => None }
        if (let Some(symbol) <- target) {
            out.append("<a href=\"" + pageRootPrefix(page.route) + escapeHtml(symbolUrl(visible, symbol)) + "\"><code>" + escapeHtml(symbol.qualifiedName) + "</code></a>")
        } else if (binding.state != "unavailable") { out.append("<code>" + escapeHtml(binding.target) + "</code>") }
        if (!binding.version.isEmpty()) { out.append(" <span class=\"binding-version\">" + escapeHtml(binding.version) + "</span>") }
        out.append("<details class=\"binding-details\"><summary>" + label(locale, "Technical details", "技术详情") + "</summary>")
        if (binding.state != "unavailable") { out.append("<span class=\"binding-meta\">selector: " + escapeHtml(binding.selector) + "</span>") }
        out.append("<span class=\"binding-meta\">source: " + escapeHtml(binding.provenance) + "; line: " + binding.sourceLine.toString() + "</span></details></div>")
    }
    out.toString()
}
