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

private func capturedPageFragment(original: DocumentationPage, selected: DocumentationPage,
    fragment: String): String {
    let anchor = documentationSectionAnchor(original.markdown, fragment)
    if (anchor.isNone()) { return "" }
    if (original.source == selected.source) { return anchor.getOrThrow() }
    for (section in original.sections) {
        if (documentationSectionAnchor(original.markdown, section.anchor) != anchor) { continue }
        for (target in selected.sections where target.id == section.id) {
            return documentationSectionAnchor(selected.markdown, target.anchor).getOrDefault({ => "" })
        }
    }
    ""
}

private class CapturedPageLinkResolver {
    let page: DocumentationPage
    let prefix: String
    let markdown: Bool
    let originals = HashMap<String, DocumentationPage>()
    let selectedPages = HashMap<String, DocumentationPage>()
    let ambiguousSources = HashSet<String>()

    init(documentation: DocumentationSet, page: DocumentationPage,
        pages: Array<DocumentationPage>, markdown: Bool) {
        this.page = page; this.prefix = pageRootPrefix(page.route); this.markdown = markdown
        for (original in documentation.pages) {
            for (selected in pages where original.id == selected.id) {
                if (originals.contains(original.source) &&
                    (originals[original.source].id != selected.id || original.source != selected.source)) {
                    // A source path cannot identify one of several published pages.
                    let _ = ambiguousSources.add(original.source)
                    continue
                }
                // Shared-source variants of one logical page use the explicit reading selection.
                originals[original.source] = if (original.source == selected.source) { selected } else { original }
                selectedPages[original.source] = selected
            }
        }
    }

    func collect(tree: MarkdownNode, result: HashMap<String, String>): Unit {
        if (tree.kind == "link") {
            let parts = tree.literal.split("#", 2)
            if (parts[0].isEmpty() && parts.size == 2) {
                if (let Some(anchor) <- documentationSectionAnchor(page.markdown, parts[1])) {
                    result[tree.literal] = "#" + if (markdown) { anchor.removePrefix("standalone--doc-") } else { anchor }
                }
            }
            let path = if (parts[0].isEmpty()) { "" } else { capturedSourcePath(page.source, parts[0]) }
            let target: ?DocumentationPage = if (ambiguousSources.contains(path)) { None } else { originals.get(path) }
            if (let Some(original) <- target) {
                let selected = selectedPages[path]
                var fragment = if (parts.size == 2) { capturedPageFragment(original, selected, parts[1]) } else { "" }
                if (markdown) { fragment = fragment.removePrefix("standalone--doc-") }
                result[tree.literal] = prefix +
                    if (markdown) { selected.route.removeSuffix(".html") + ".md" } else { selected.route }
                if (!fragment.isEmpty()) { result[tree.literal] += "#" + fragment }
            }
        }
        for (child in tree.children) { collect(child, result) }
    }
}

internal func capturedPageSourceLinks(documentation: DocumentationSet, page: DocumentationPage,
    pages: Array<DocumentationPage>, markdown!: Bool = false): HashMap<String, String> {
    let result = HashMap<String, String>()
    CapturedPageLinkResolver(documentation, page, pages, markdown).collect(page.markdown, result)
    result
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
