package cjdoc.render

import cjdoc.model.*
import std.collection.*

// Block/inline dispatch for captured Markdown. Every branch writes through the
// shared HtmlWriter, so author text can only reach the page escaped.

internal func appendMarkdownNodeHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    tableHeader!: Bool = false, tightListItem!: Bool = false): Unit {
    match (node.kind) {
        case "document" | "custom_block" | "custom_inline" =>
            appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
        case "paragraph" => appendParagraphHtml(w, node, assetLookup, rootPrefix, context)
        case "heading" => appendMarkdownHeadingHtml(w, node, assetLookup, rootPrefix, context)
        case "text" => w.text(node.literal)
        case "soft_break" => w.newline()
        case "hard_break" =>
            w.void("br")
            w.newline()
        case "emphasis" => appendInlineContainerHtml(w, "em", node, assetLookup, rootPrefix, context)
        case "strong" => appendInlineContainerHtml(w, "strong", node, assetLookup, rootPrefix, context)
        case "strikethrough" =>
            appendInlineContainerHtml(w, "del", node, assetLookup, rootPrefix, context)
        case "code_span" => w.textElement("code", node.literal)
        case "code_block" => appendMarkdownCodeBlockHtml(w, node)
        case "thematic_break" =>
            w.void("hr")
            w.newline()
        case "admonition" => appendAdmonitionHtml(w, node, assetLookup, rootPrefix, context)
        case "block_quote" =>
            appendBlockContainerHtml(w, "blockquote", node, assetLookup, rootPrefix, context)
        case "list" => appendMarkdownListHtml(w, node, assetLookup, rootPrefix, context)
        case "list_item" =>
            appendListItemHtml(w, node, assetLookup, rootPrefix, context, tightListItem)
        case "link" => appendMarkdownLinkHtml(w, node, assetLookup, rootPrefix, context)
        case "semantic_link" => appendSemanticLinkHtml(w, node, assetLookup, rootPrefix, context)
        case "image" => appendMarkdownImageHtml(w, node, assetLookup, rootPrefix)
        case "table" => appendMarkdownTableHtml(w, node, assetLookup, rootPrefix, context)
        case "table_row" => appendTableRowHtml(w, node, assetLookup, rootPrefix, context)
        case "table_cell" =>
            appendTableCellHtml(w, node, assetLookup, rootPrefix, context, tableHeader)
        case "html_block" => appendRawHtmlBlock(w, node, context)
        case "html_inline" => appendRawHtmlInline(w, node, context)
        case _ => w.text(markdownNodeText(node))
    }
}

private func appendParagraphHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    w.open("p")
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close("p")
    w.newline()
}

private func appendInlineContainerHtml(w: HtmlWriter, tag: String, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    w.open(tag)
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close(tag)
}

private func appendBlockContainerHtml(w: HtmlWriter, tag: String, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    w.open(tag)
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close(tag)
    w.newline()
}

private func appendMarkdownHeadingHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let tag = "h${markdownHeadingLevel(node, context.headingBase)}"
    let id = context.headingIds[context.nextHeading]
    context.nextHeading++
    w.open(tag, attrs: anchorAttrs(id, context))
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close(tag)
    w.newline()
}

// A fenced block keeps the author's language, highlight metadata and fenced
// attributes; only the surrounding structure and class vocabulary changed.
private func appendMarkdownCodeBlockHtml(w: HtmlWriter, node: MarkdownNode): Unit {
    var language = ""
    var attributesRaw = ""
    var highlight: ?CodeHighlight = None
    if (let Some(metadata) <- node.metadata) {
        if (metadata.kind == "code_block") {
            language = normalizeCodeLanguage(metadata.language.getOrThrow())
            attributesRaw = metadata.attributesRaw.getOrThrow()
            highlight = metadata.codeHighlight
        }
    }
    appendCodeBlockHtml(w, node.literal,
        codeBlockAttrs(node.literal, language, attributesRaw: attributesRaw), highlight)
}

private func appendMarkdownListHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    var ordered = false
    var start: Int64 = 1
    var tight = true
    if (let Some(metadata) <- node.metadata) {
        if (metadata.kind == "list") {
            ordered = metadata.listKind.getOrThrow() == "ordered"
            start = metadata.listStart.getOrThrow()
            tight = metadata.listTight.getOrThrow()
        }
    }
    let tag = if (ordered) { "ol" } else { "ul" }
    if (ordered) {
        w.open(tag, attrs: [htmlAttr("start", start.toString())])
    } else {
        w.open(tag)
    }
    for (child in node.children) {
        appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context, tightListItem: tight)
    }
    w.close(tag)
    w.newline()
}

private func appendListItemHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    tightListItem: Bool): Unit {
    w.open("li")
    if (let Some(metadata) <- node.metadata) {
        if (metadata.kind == "list_item") { appendTaskStateHtml(w, metadata.taskState.getOrThrow()) }
    }
    for (child in node.children) {
        if (tightListItem && child.kind == "paragraph") {
            appendMarkdownChildrenHtml(w, child, assetLookup, rootPrefix, context)
        } else {
            appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
        }
    }
    w.close("li")
}

private func appendTaskStateHtml(w: HtmlWriter, taskState: String): Unit {
    match (taskState) {
        case "checked" =>
            w.void("input", attrs: [htmlAttr("type", "checkbox"), htmlFlag("disabled"),
                htmlFlag("checked")])
            w.text(" ")
        case "unchecked" =>
            w.void("input", attrs: [htmlAttr("type", "checkbox"), htmlFlag("disabled")])
            w.text(" ")
        case _ => ()
    }
}

// Captured source links may be rebased with leading `../` runs, which no plain
// relative destination allows; nothing else gains a link that was not safe before.
private func markdownLinkUrl(destination: String, mappedRelative: Bool): ?SafeUrl {
    if (safeLinkDestination(destination)) { return SafeUrl.external(destination) }
    if (safeRelativeLinkDestination(destination)) { return SafeUrl.relative(destination) }
    if (mappedRelative && safeMappedRelativeLinkDestination(destination)) {
        return SafeUrl.site(destination)
    }
    None
}

private func appendMarkdownLinkHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let sourceDestination = context.sourceLinks.get(node.literal)
    let destination = match (sourceDestination) {
        case Some(target) => target
        case None => match (context.fragmentTargets.get(node.literal)) {
            case Some(target) => "#${target}"
            case None => node.literal
        }
    }
    let isRemote = destination.startsWith("http://") || destination.startsWith("https://")
    let permitted = context.allowExternalLinks || !isRemote
    let url = if (permitted) { markdownLinkUrl(destination, sourceDestination.isSome()) }
        else { None<SafeUrl> }
    match (url) {
        case Some(value) =>
            let attrs = ArrayList<HtmlAttr>([htmlHref(value)])
            if (isRemote) { attrs.add(htmlAttr("rel", "noopener noreferrer")) }
            w.open("a", attrs: attrs.toArray())
            appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
            w.close("a")
        case None => appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    }
}

// A semantic reference is only navigable when its destination and permission
// checks both pass; otherwise its label text stays as plain content.
private func appendSemanticLinkHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let navigation: ?TypeNavigation = match (node.metadata) {
        case Some(metadata) => metadata.semanticNavigation
        case None => None
    }
    let semanticState: ?String = match (node.metadata) {
        case Some(metadata) => metadata.semanticState
        case None => None
    }
    let source = match (semanticLinkSource(node)) {
        case Some(value) => value
        case None =>
            appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
            appendReferenceStateNote(w, semanticState, context)
            return
    }
    let href = semanticLinkHref(source, rootPrefix, navigation)
    match (semanticLinkUrl(href, source, navigation, context.allowExternalLinks)) {
        case Some(url) =>
            let attrs = ArrayList<HtmlAttr>([htmlClass("cj-type-link"), htmlHref(url)])
            attrs.add(all: navigationAttrs(navigation))
            w.open("a", attrs: attrs.toArray())
            appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
            w.close("a")
        case None => appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    }
    appendReferenceStateNote(w, semanticState, context)
}

private func semanticLinkSource(node: MarkdownNode): ?String {
    match (node.metadata) {
        case Some(metadata) => match (metadata.semanticNavigation) {
            case Some(value) => if (value.state == "resolved") { Some(value.url) } else { None }
            case None => metadata.semanticExternalUrl
        }
        case None => None
    }
}

private func semanticLinkHref(source: String, rootPrefix: String,
    navigation: ?TypeNavigation): String {
    if (navigation.isSome()) { return navigationHref(rootPrefix, source).getOrDefault({ => "" }) }
    if (source.startsWith("http://") || source.startsWith("https://") || source.startsWith("#")) {
        return source
    }
    rootPrefix + source
}

// A resolved navigation target is already vetted by `navigationHref`, so it may
// stay navigable even where author-written remote links are suppressed; author
// links keep obeying `allowExternalLinks`.
private func semanticLinkUrl(href: String, source: String,
    navigation: ?TypeNavigation, allowExternalLinks: Bool): ?SafeUrl {
    if (href.isEmpty()) { return None }
    let isRemote = href.startsWith("http://") || href.startsWith("https://")
    if (isRemote) {
        if (!allowExternalLinks && navigation.isNone()) { return None }
        return SafeUrl.external(href)
    }
    if (href.startsWith("#")) { return SafeUrl.external(href) }
    // Both the navigation and the author-relative branch already produced a
    // root-prefixed site route, so the site form preserves the exact destination.
    if (navigation.isSome() || safeRelativeLinkDestination(source)) { return SafeUrl.site(href) }
    None
}

private func appendReferenceStateNote(w: HtmlWriter, semanticState: ?String,
    context: HtmlMarkdownContext): Unit {
    match (semanticState) {
        case Some(state) => if (state != "resolved") {
            let status = match (state) {
                case "unresolved" => label(context.locale, "Reference semantics unresolved", "引用语义未解析")
                case "ambiguous" => label(context.locale, "Reference semantics ambiguous", "引用语义不明确")
                case _ => label(context.locale, "Reference semantics unavailable", "暂无引用语义信息")
            }
            w.textElement("span", status, attrs: [htmlClass("cj-state-note"),
                htmlAttr("data-reference-state", state)])
        }
        case None => ()
    }
}

private func appendMarkdownImageHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String): Unit {
    let alt = markdownNodeText(node)
    match (imageUrl(node.literal, assetLookup, rootPrefix)) {
        case Some(url) =>
            w.void("img", attrs: [htmlSrc(url), htmlAttr("alt", alt),
                htmlAttr("loading", "lazy")])
        case None => w.text(alt)
    }
}

// Unresolved images keep their alternative text, exactly as before assets existed.
private func imageUrl(destination: String, assetLookup: HashMap<String, String>,
    rootPrefix: String): ?SafeUrl {
    let path = match (assetReference(assetLookup, destination)) {
        case Some(value) => value
        case None => return None
    }
    SafeUrl.site(rootPrefix + path)
}

private func appendMarkdownTableHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    w.open("div", attrs: [htmlClass("cj-table-wrap")])
    w.open("table", attrs: [htmlClass("cj-table")])
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close("table")
    w.close("div")
    w.newline()
}

private func appendTableRowHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    let header = match (node.metadata) {
        case Some(metadata) => metadata.kind == "table_row" && metadata.tableHeader.getOrThrow()
        case None => false
    }
    w.open("tr")
    for (child in node.children) {
        appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context, tableHeader: header)
    }
    w.close("tr")
}

private func appendTableCellHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    tableHeader: Bool): Unit {
    let tag = if (tableHeader) { "th" } else { "td" }
    let attrs = ArrayList<HtmlAttr>()
    if (let Some(metadata) <- node.metadata) {
        if (metadata.kind == "table_cell") {
            let alignment = metadata.tableAlignment.getOrThrow()
            if (alignment != "none") { attrs.add(htmlClass("cj-align-" + alignment)) }
        }
    }
    w.open(tag, attrs: attrs.toArray())
    appendMarkdownChildrenHtml(w, node, assetLookup, rootPrefix, context)
    w.close(tag)
}

private func bindingChip(node: MarkdownNode, context: HtmlMarkdownContext): ?TrustedHtml {
    if (node.literal != "<!-- cjdoc-bind -->" || node.source.isNone()) { return None }
    let chips = match (context.bindingChips) {
        case Some(value) => value
        case None => return None
    }
    let source = node.source.getOrThrow()
    if (source.path != context.bindingSource) { return None }
    chips.get(source.start.line)
}

// Raw HTML in author Markdown is never interpreted: it stays escaped text
// inside a <pre>, so a captured document cannot inject markup.
private func appendRawHtmlBlock(w: HtmlWriter, node: MarkdownNode,
    context: HtmlMarkdownContext): Unit {
    if (let Some(chip) <- bindingChip(node, context)) {
        w.trusted(chip)
        return
    }
    w.open("pre")
    w.text(node.literal)
    w.close("pre")
    w.newline()
}

private func appendRawHtmlInline(w: HtmlWriter, node: MarkdownNode,
    context: HtmlMarkdownContext): Unit {
    match (bindingChip(node, context)) {
        case Some(chip) => w.trusted(chip)
        case None => w.text(node.literal)
    }
}
