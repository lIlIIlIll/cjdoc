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

private func capturedPageBindingStateLabel(state: String, locale: String): String {
    match (state) {
        case "resolved" => label(locale, "Linked", "已关联")
        case "unavailable" => label(locale, "Not available in this audience", "当前受众不可见")
        case "ambiguous" => label(locale, "Ambiguous target", "目标不明确")
        case "conflict" => label(locale, "Conflicting markers", "标记冲突")
        case _ => label(locale, "Target not found", "未找到目标")
    }
}

private func capturedPageBindingState(binding: DocumentationPageBinding,
    visible: HashMap<String, SymbolDoc>): String {
    if (binding.targetSymbolId.isSome() && !visible.contains(binding.targetSymbolId.getOrThrow())) {
        return "unavailable"
    }
    binding.state
}

private func appendCapturedPageBindingTargetHtml(out: RenderTextBuffer,
    binding: DocumentationPageBinding, visible: HashMap<String, SymbolDoc>, prefix: String, state: String): Unit {
    if (state == "unavailable") { return }
    let target: ?SymbolDoc = match (binding.targetSymbolId) { case Some(id) => visible.get(id); case None => None }
    if (state == "resolved" && target.isSome()) {
        let symbol = target.getOrThrow()
        out.append("<a href=\"" + prefix + escapeHtml(symbolUrl(visible, symbol)) + "\"><code>" +
            escapeHtml(symbol.qualifiedName) + "</code></a>")
    } else { out.append("<code>" + escapeHtml(binding.target) + "</code>") }
    if (!binding.version.isEmpty()) {
        out.append(" <span class=\"binding-version\">" + escapeHtml(binding.version) + "</span>")
    }
}

internal func capturedPageBindingChipHtml(page: DocumentationPage, binding: DocumentationPageBinding,
    visible: HashMap<String, SymbolDoc>, locale: String): String {
    let out = RenderTextBuffer()
    let state = capturedPageBindingState(binding, visible)
    out.append("<div class=\"inline-binding\"><span class=\"binding-state\" data-state=\"" + state + "\">")
    out.append(capturedPageBindingStateLabel(state, locale) + "</span> ")
    appendCapturedPageBindingTargetHtml(out, binding, visible, pageRootPrefix(page.route), state)
    out.append("<details class=\"binding-details\"><summary>" + label(locale, "Technical details", "技术详情") + "</summary>")
    if (state != "unavailable") {
        if (!binding.selector.isEmpty()) {
            out.append("<span class=\"binding-meta\">selector: " + escapeHtml(binding.selector) + "</span>")
        }
        if (!binding.provenance.isEmpty()) {
            out.append("<span class=\"binding-meta\">source: " + escapeHtml(binding.provenance) + "</span>")
        }
    }
    out.append("<span class=\"binding-meta\">state: " + state + "; language: " + escapeHtml(binding.language) +
        "; line: " + binding.sourceLine.toString() + "</span></details></div>")
    out.toString()
}

internal func capturedPageBindingsHtml(page: DocumentationPage, documentation: DocumentationSet,
    locale: String): String {
    if (page.bindings.isEmpty()) { return "" }
    let out = RenderTextBuffer()
    let visible = RenderProjection(documentation).visibleIndex
    out.append("<section class=\"conceptual-bindings\" aria-labelledby=\"conceptual-bindings-heading\"><h2 id=\"conceptual-bindings-heading\">")
    out.append(label(locale, "API associations", "API 关联") + "</h2><p class=\"binding-scope\">")
    out.append(label(locale, "Explicit bindings from this page. Reader details stay in Technical details.",
        "本页的显式关联。技术信息见「技术详情」。") + "</p><ul>")
    for (binding in page.bindings) {
        let state = capturedPageBindingState(binding, visible)
        out.append("<li><span class=\"binding-state\" data-state=\"" + state + "\">")
        out.append(capturedPageBindingStateLabel(state, locale) + "</span> ")
        appendCapturedPageBindingTargetHtml(out, binding, visible, pageRootPrefix(page.route), state)
        out.append("</li>")
    }
    out.append("</ul></section>\n")
    out.toString()
}

internal func appendCapturedPageBindingsMarkdown(out: RenderTextBuffer,
    page: DocumentationPage, documentation: DocumentationSet, locale: String): Unit {
    if (page.bindings.isEmpty()) { return }
    out.append("\n## " + label(locale, "API associations", "API 关联") + "\n\n")
    let visible = RenderProjection(documentation).visibleIndex
    for (binding in page.bindings) {
        let target: ?SymbolDoc = match (binding.targetSymbolId) {
            case Some(id) => visible.get(id)
            case None => None
        }
        let state = if (binding.targetSymbolId.isSome() && target.isNone()) {
            "unavailable"
        } else { binding.state }
        out.append("- **" + capturedPageBindingStateLabel(state, locale) + "** ")
        if (state == "resolved" && target.isSome()) {
            let symbol = target.getOrThrow()
            let destination = pageRootPrefix(page.route) + markdownTargetPagePath(symbol, visible) +
                "#" + symbolAnchor(symbol)
            out.append("["); appendMarkdownCodeSpan(out, symbol.qualifiedName)
            out.append("](" + encodeMarkdownDestination(destination) + ")")
        } else if (state != "unavailable") { appendMarkdownCodeSpan(out, binding.target) }
        out.append(" — language: ")
        appendMarkdownCodeSpan(out, if (binding.language.isEmpty()) { "unknown" } else { binding.language })
        out.append("; line: " + binding.sourceLine.toString())
        for ((key, text) in [("version", binding.version), ("source", binding.provenance),
            ("selector", if (state == "unavailable") { "" } else { binding.selector })]) {
            if (!text.isEmpty()) {
                out.append("; " + key + ": ")
                appendMarkdownCodeSpan(out, text.replace("\r", " ").replace("\n", " ").replace("\t", " "))
            }
        }
        out.append("\n")
    }
}
