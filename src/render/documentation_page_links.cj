package cjdoc.render

import cjdoc.model.*
import std.collection.*

// A frozen navigation fact does not change the binding's local-resolution state.
// All published surfaces share the same audience and ambiguity boundary.
private class CapturedPageBindingTarget {
    let state: String
    let hidden: Bool
    let symbol: ?SymbolDoc
    let navigation: ?TypeNavigation
    private let binding: DocumentationPageBinding
    private let visible: HashMap<String, SymbolDoc>

    init(binding: DocumentationPageBinding, visible: HashMap<String, SymbolDoc>) {
        this.binding = binding; this.visible = visible
        let local: ?SymbolDoc = match (binding.targetSymbolId) { case Some(id) => visible.get(id); case None => None }
        let hiddenNavigation = match (binding.navigation) {
            case Some(value) => value.symbolKey.startsWith("cjdoc:v2:") && !visible.contains(value.symbolKey)
            case None => false
        }
        hidden = binding.state == "unavailable" || (binding.targetSymbolId.isSome() && local.isNone()) || hiddenNavigation
        state = capturedPageBindingState(binding, hidden)
        symbol = if (!hidden && state == "resolved") {
            match (binding.navigation) {
                case None => local
                case Some(value) => if (value.state == "resolved" && binding.targetSymbolId == Some(value.symbolKey)) { local } else { None }
            }
        } else { None }
        navigation = if (hidden) { None } else { binding.navigation }
    }

    func destination(rootPrefix: String, markdown: Bool): ?String {
        if (hidden || state == "conflict" || state == "ambiguous") { return None }
        if (let Some(target) <- symbol) {
            if (markdown) {
                return Some(rootPrefix + markdownTargetPagePath(target, visible) + "#" + symbolAnchor(target))
            }
            return navigationHref(rootPrefix, symbolUrl(visible, target))
        }
        // Navigation, when present, is authoritative even over an old visible local id.
        if (let Some(value) <- navigation) {
            if (value.state == "resolved") {
                return navigationHref(rootPrefix + if (markdown) { "../html/" } else { "" }, value.url)
            }
        }
        None
    }

    func stateLabel(locale: String): String {
        if (hidden || state == "conflict" || state == "ambiguous") { return capturedPageBindingStateLabel(state, locale) }
        if (let Some(value) <- navigation) {
            if (value.state == "ambiguous") { return label(locale, "Ambiguous documentation target", "文档目标不明确") }
            if (value.state != "resolved") { return label(locale, "Documentation link unavailable", "暂无文档链接") }
            if (symbol.isNone() && destination("", false).isSome()) { return label(locale, "Documentation linked", "已关联文档") }
        }
        capturedPageBindingStateLabel(state, locale)
    }

    func title(locale: String): String {
        if (hidden) { return capturedPageBindingStateLabel("unavailable", locale) }
        let out = StringBuilder()
        if (!binding.version.isEmpty()) { out.append(label(locale, "Declared API version: ", "声明 API 版本：") + binding.version) }
        if (let Some(value) <- navigation) {
            if (!binding.version.isEmpty()) { out.append("; ") }
            out.append(value.matchLevel + ": " + value.reason)
            if (!value.apiIdentity.isEmpty()) { out.append("; API identity: " + value.apiIdentity) }
        }
        out.toString()
    }
}

internal func appendSearchPageBindings(out: RenderTextBuffer, page: DocumentationPage,
    visible: HashMap<String, SymbolDoc>): Unit {
    out.append(",\"bindings\":[")
    var first = true
    for (binding in page.bindings) {
        let target = CapturedPageBindingTarget(binding, visible)
        if (target.hidden) { continue }
        if (!first) { out.append(",") }; first = false
        out.append("{\"target\":" + escapeJsonString(binding.target) + ",\"selector\":" + escapeJsonString(binding.selector))
        out.append(",\"provenance\":" + escapeJsonString(binding.provenance) + ",\"version\":" + escapeJsonString(binding.version))
        out.append(",\"sourceLine\":" + binding.sourceLine.toString() + ",\"language\":" + escapeJsonString(binding.language))
        out.append(",\"state\":" + escapeJsonString(binding.state) + ",\"targetSymbolId\":" + nullableString(binding.targetSymbolId))
        out.append(",\"href\":" + nullableString(target.destination("", false)) + ",\"navigationTitle\":" + escapeJsonString(target.title("en")))
        let encoded = StringBuilder(); appendTypeNavigation(encoded, target.navigation)
        out.append(",\"navigation\":" + encoded.toString() + "}")
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

private func capturedPageBindingState(binding: DocumentationPageBinding, hidden: Bool): String {
    if (hidden && binding.state != "conflict" && binding.state != "ambiguous") { return "unavailable" }
    binding.state
}

private func appendCapturedPageBindingTargetHtml(out: RenderTextBuffer,
    binding: DocumentationPageBinding, target: CapturedPageBindingTarget, prefix: String, locale: String): Unit {
    if (target.hidden) { return }
    let title = target.title(locale)
    let destination = target.destination(prefix, false)
    if (let Some(url) <- destination) {
        out.append("<a href=\"" + escapeHtml(url) + "\"")
        if (let Some(value) <- target.navigation) { out.append(" data-doc-match=\"" + escapeHtml(value.matchLevel) + "\"") }
        if (!title.isEmpty()) { out.append(" title=\"" + escapeHtml(title) + "\"") }
        out.append(">")
    }
    let spelling = match (target.symbol) { case Some(value) => value.qualifiedName; case None => binding.target }
    out.append("<code")
    if (destination.isNone() && !title.isEmpty()) { out.append(" title=\"" + escapeHtml(title) + "\"") }
    out.append(">" + escapeHtml(spelling) + "</code>")
    if (destination.isSome()) { out.append("</a>") }
    if (!binding.version.isEmpty()) {
        out.append(" <span class=\"binding-version\">" + escapeHtml(binding.version) + "</span>")
    }
}

internal func capturedPageBindingChipHtml(page: DocumentationPage, binding: DocumentationPageBinding,
    visible: HashMap<String, SymbolDoc>, locale: String): String {
    let out = RenderTextBuffer()
    let target = CapturedPageBindingTarget(binding, visible)
    out.append("<div class=\"inline-binding\"><span class=\"binding-state\" data-state=\"" + target.state + "\">")
    out.append(target.stateLabel(locale) + "</span> ")
    appendCapturedPageBindingTargetHtml(out, binding, target, pageRootPrefix(page.route), locale)
    out.append("<details class=\"binding-details\"><summary>" + label(locale, "Technical details", "技术详情") + "</summary>")
    if (!target.hidden) {
        if (!binding.selector.isEmpty()) {
            out.append("<span class=\"binding-meta\">selector: " + escapeHtml(binding.selector) + "</span>")
        }
        if (!binding.provenance.isEmpty()) {
            out.append("<span class=\"binding-meta\">source: " + escapeHtml(binding.provenance) + "</span>")
        }
    }
    out.append("<span class=\"binding-meta\">state: " + target.state + "; language: " + escapeHtml(binding.language) +
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
        let target = CapturedPageBindingTarget(binding, visible)
        out.append("<li><span class=\"binding-state\" data-state=\"" + target.state + "\">")
        out.append(target.stateLabel(locale) + "</span> ")
        appendCapturedPageBindingTargetHtml(out, binding, target, pageRootPrefix(page.route), locale)
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
        let target = CapturedPageBindingTarget(binding, visible)
        let destination = target.destination(pageRootPrefix(page.route), true)
        out.append("- **" + target.stateLabel(locale) + "** ")
        if (!target.hidden) {
            let spelling = match (target.symbol) { case Some(value) => value.qualifiedName; case None => binding.target }
            if (destination.isSome()) { out.append("[") }
            appendMarkdownCodeSpan(out, spelling)
            if (let Some(url) <- destination) {
                out.append("](" + encodeMarkdownDestination(url))
                // Keep legacy local-link spelling stable; frozen decisions carry their own title.
                if (target.navigation.isSome()) { out.append(" " + escapeJsonString(target.title(locale))) }
                out.append(")")
            } else if (target.navigation.isSome()) {
                out.append(" — "); appendEscapedMarkdownText(out, target.title(locale))
            }
        }
        out.append(" — language: ")
        appendMarkdownCodeSpan(out, if (binding.language.isEmpty()) { "unknown" } else { binding.language })
        out.append("; line: " + binding.sourceLine.toString())
        for ((key, text) in [("version", if (target.hidden) { "" } else { binding.version }),
            ("source", if (target.hidden) { "" } else { binding.provenance }),
            ("selector", if (target.hidden) { "" } else { binding.selector })]) {
            if (!text.isEmpty()) {
                out.append("; " + key + ": ")
                appendMarkdownCodeSpan(out, text.replace("\r", " ").replace("\n", " ").replace("\t", " "))
            }
        }
        out.append("\n")
    }
}
