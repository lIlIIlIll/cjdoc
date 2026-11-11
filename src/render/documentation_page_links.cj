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

internal func projectSearchPageBindings(page: DocumentationPage,
    visible: HashMap<String, SymbolDoc>, locale: String): ArrayList<SearchPageBinding> {
    let result = ArrayList<SearchPageBinding>()
    for (binding in page.bindings) {
        let target = CapturedPageBindingTarget(binding, visible)
        if (target.hidden) { continue }
        result.add(SearchPageBinding(binding.target, binding.selector, binding.provenance,
            binding.version, binding.sourceLine, binding.language, target.state,
            binding.targetSymbolId, target.destination("", false), target.title(locale),
            target.navigation))
    }
    result
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
    let relocated: Bool
    let originals = HashMap<String, DocumentationPage>()
    let selectedPages = HashMap<String, DocumentationPage>()
    let ambiguousSources = HashSet<String>()

    init(documentation: DocumentationSet, page: DocumentationPage,
        pages: Array<DocumentationPage>, markdown: Bool, outputPath!: ?String = None) {
        this.page = page
        this.prefix = pageRootPrefix(outputPath.getOrDefault({ => page.route }))
        this.markdown = markdown
        this.relocated = outputPath.isSome()
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
                    result[tree.literal] = if (relocated && !markdown) {
                        prefix + page.route + "#" + anchor
                    } else { "#" + if (markdown) { anchor.removePrefix("standalone--doc-") } else { anchor } }
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
    pages: Array<DocumentationPage>, markdown!: Bool = false,
    outputPath!: ?String = None): HashMap<String, String> {
    let result = HashMap<String, String>()
    CapturedPageLinkResolver(documentation, page, pages, markdown, outputPath: outputPath).collect(page.markdown, result)
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

private func appendCapturedPageBindingTargetHtml(w: HtmlWriter,
    binding: DocumentationPageBinding, target: CapturedPageBindingTarget, prefix: String, locale: String,
    compact!: Bool = false): Unit {
    if (target.hidden) { return }
    let title = target.title(locale)
    let destination = match (target.destination(prefix, false)) {
        case Some(url) => documentationLinkHref(url)
        case None => None<SafeUrl>
    }
    let spelling = match (target.symbol) {
        case Some(value) => if (compact) { htmlContextLabel(value) } else { value.qualifiedName }
        case None => binding.target
    }
    if (let Some(href) <- destination) {
        let attrs = ArrayList<HtmlAttr>([htmlHref(href)])
        if (let Some(value) <- target.navigation) {
            attrs.add(htmlAttr("data-doc-match", value.matchLevel))
        }
        if (!title.isEmpty()) { attrs.add(htmlAttr("title", title)) }
        w.open("a", attrs: attrs.toArray())
    }
    let codeAttrs = ArrayList<HtmlAttr>()
    if (destination.isNone() && !title.isEmpty()) { codeAttrs.add(htmlAttr("title", title)) }
    w.textElement("code", spelling, attrs: codeAttrs.toArray())
    if (destination.isSome()) { w.close("a") }
    if (!compact && !binding.version.isEmpty()) {
        w.text(" ")
        w.textElement("span", binding.version, attrs: [htmlClass("cj-bindings__version")])
    }
}

internal func appendCapturedPageBindingChipHtml(w: HtmlWriter, page: DocumentationPage,
    binding: DocumentationPageBinding, visible: HashMap<String, SymbolDoc>, locale: String,
    outputPath!: ?String = None): Unit {
    let target = CapturedPageBindingTarget(binding, visible)
    w.open("div", attrs: [htmlClass("cj-binding")])
    w.textElement("span", label(locale, "Related API: ", "相关 API："),
        attrs: [htmlClass("cj-bindings__label")])
    if (target.state != "resolved" || target.destination("", false).isNone()) {
        w.textElement("span", target.stateLabel(locale),
            attrs: [htmlClass("cj-bindings__state"), htmlAttr("data-state", target.state)])
        w.text(" ")
    }
    appendCapturedPageBindingTargetHtml(w, binding, target,
        pageRootPrefix(outputPath.getOrDefault({ => page.route })), locale, compact: true)
    w.open("details", attrs: [htmlClass("cj-bindings__details cj-disclosure")])
    w.textElement("summary", label(locale, "Link details", "关联详情"),
        attrs: [htmlClass("cj-disclosure__summary")])
    w.textElement("span", target.stateLabel(locale), attrs: [htmlClass("cj-bindings__meta")])
    if (!binding.version.isEmpty() && !target.hidden) {
        w.textElement("span", "version: " + binding.version, attrs: [htmlClass("cj-bindings__meta")])
    }
    if (!target.hidden) {
        if (!binding.selector.isEmpty()) {
            w.textElement("span", "selector: " + binding.selector, attrs: [htmlClass("cj-bindings__meta")])
        }
        if (!binding.provenance.isEmpty()) {
            w.textElement("span", "source: " + binding.provenance, attrs: [htmlClass("cj-bindings__meta")])
        }
    }
    w.textElement("span", "state: " + target.state + "; language: " + binding.language +
        "; line: " + binding.sourceLine.toString(), attrs: [htmlClass("cj-bindings__meta")])
    w.close("details")
    w.close("div")
}

internal func appendCapturedPageBindingsHtml(w: HtmlWriter, page: DocumentationPage,
    documentation: DocumentationSet, locale: String): Unit {
    if (page.bindings.isEmpty()) { return }
    let visible = RenderProjection(documentation).visibleIndex
    w.open("details", attrs: [htmlClass("cj-bindings cj-disclosure")])
    w.open("summary", attrs: [htmlAttr("id", "conceptual-bindings-heading"),
        htmlClass("cj-disclosure__summary")])
    w.text(label(locale, "API associations", "API 关联"))
    w.close("summary")
    w.textElement("p", label(locale, "Explicit bindings from this page. Reader details stay in Technical details.",
        "本页的显式关联。技术信息见「技术详情」。"), attrs: [htmlClass("cj-bindings__scope")])
    w.open("ul")
    for (binding in page.bindings) {
        let target = CapturedPageBindingTarget(binding, visible)
        w.open("li")
        w.textElement("span", target.stateLabel(locale),
            attrs: [htmlClass("cj-bindings__state"), htmlAttr("data-state", target.state)])
        w.text(" ")
        appendCapturedPageBindingTargetHtml(w, binding, target, pageRootPrefix(page.route), locale)
        w.close("li")
    }
    w.close("ul")
    w.close("details")
    w.newline()
}

internal func appendCapturedPageBindingsMarkdown(out: RenderTextBuffer,
    page: DocumentationPage, documentation: DocumentationSet, locale: String,
    pagePath!: ?String = None, canonicalHtml!: Bool = false): Unit {
    if (page.bindings.isEmpty()) { return }
    out.append("\n## " + label(locale, "API associations", "API 关联") + "\n\n")
    let visible = RenderProjection(documentation).visibleIndex
    for (binding in page.bindings) {
        let target = CapturedPageBindingTarget(binding, visible)
        let destination = target.destination(pageRootPrefix(pagePath.getOrDefault({ => page.route })), !canonicalHtml)
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
