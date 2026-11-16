package cjdoc.render

import cjdoc.model.*
import std.collection.*


// Markdown block/inline dispatch lives in html_markdown_nodes.cj so this file
// stays within the repository size guidance.

internal func escapeHtml(value: String): String {
    let out = RenderTextBuffer()
    appendHtmlEscapedValue(out, value)
    out.toString()
}

internal func safeMappedRelativeLinkDestination(value: String): Bool {
    let parts = value.split("#", 2)
    var path = parts[0]
    while (path.startsWith("../")) { path = path.removePrefix("../") }
    if (path.contains("%") || !safeRelativeLinkDestination(path)) { return false }
    parts.size == 1 || safeLinkDestination("#" + parts[1])
}

/**
 * Standalone Markdown as a self-contained HTML fragment.
 *
 * This is the only HTML entry point in the renderer that still returns a String:
 * callers outside the `cjdoc.render` package cannot name `HtmlWriter`, so the
 * value is produced by capturing a writer and therefore still passes every
 * escaping and balance check. Renderer-internal callers append through
 * `appendStandaloneMarkdownHtml` instead of building a string first.
 */
public func renderStandaloneMarkdownHtml(node: MarkdownNode,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None, locale!: String = "en"): String {
    TrustedHtml.capture({ w =>
        appendStandaloneMarkdownHtml(w, node, sourceLinks: sourceLinks, pageTitle: pageTitle,
            locale: locale)
    }).value
}

internal func appendStandaloneMarkdownHtml(w: HtmlWriter, node: MarkdownNode,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None,
    sectionIds!: HashMap<String, String> = HashMap<String, String>(),
    locale!: String = "en"): Unit {
    appendStandaloneMarkdownHtmlWithAssets(w, node, HashMap<String, String>(), "",
        sourceLinks: sourceLinks, pageTitle: pageTitle, sectionIds: sectionIds, locale: locale)
}

internal func appendStandaloneMarkdownHtmlWithAssets(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None, bindingSource!: String = "",
    bindingChips!: ?HashMap<Int64, TrustedHtml> = None, headingBase!: Int64 = 2,
    afterFirstCode!: ?TrustedHtml = None,
    sectionIds!: HashMap<String, String> = HashMap<String, String>(),
    locale!: String = "en"): Unit {
    let context = HtmlMarkdownContext(headingBase, sourceLinks: sourceLinks,
        bindingSource: bindingSource, bindingChips: bindingChips, locale: locale)
    context.sectionIds = sectionIds
    collectMarkdownHeadings(node, "standalone", HashMap<String, Int64>(), context)
    appendStandaloneDocumentHtml(w, node, context, pageTitle, assetLookup, rootPrefix,
        afterFirstCode)
}

private func appendAfterFirstCode(w: HtmlWriter, fragment: ?TrustedHtml): Unit {
    if (let Some(value) <- fragment) { w.trusted(value) }
}

// Suppress exactly the Markdown's own leading level-1 heading when the page
// shell already rendered the same title as the page <h1>. A differently titled
// or absent leading heading is untouched, and any later heading — including one
// repeating the same text — keeps the heading stream and its shareable anchor.
// The suppressed title retains its fragment so source links and section mappings
// still address the title without repeating its visible text.
private func standaloneTitleHeadingIndex(node: MarkdownNode, pageTitle: ?String): ?Int64 {
    let title = match (pageTitle) {
        case Some(value) => value
        case None => return None
    }
    for (index in 0..node.children.size) {
        let child = node.children[index]
        if (child.kind != "heading") { return None }
        let sourceLevel = match (child.metadata) {
            case Some(metadata) => match (metadata.headingLevel) {
                case Some(value) => value
                case None => 1
            }
            case None => 1
        }
        if (sourceLevel != 1) { return None }
        return if (markdownNodeText(child) == title) { Some(index) } else { None }
    }
    None
}

private func appendStandaloneDocumentHtml(w: HtmlWriter, node: MarkdownNode,
    context: HtmlMarkdownContext, pageTitle: ?String, assetLookup: HashMap<String, String>,
    rootPrefix: String, afterFirstCode: ?TrustedHtml): Unit {
    if (node.kind != "document") {
        appendMarkdownNodeHtml(w, node, assetLookup, rootPrefix, context)
        appendAfterFirstCode(w, afterFirstCode)
        return
    }
    let titleIndex = standaloneTitleHeadingIndex(node, pageTitle)
    var inserted = false
    for (index in 0..node.children.size) {
        let child = node.children[index]
        if (titleIndex == Some(index)) {
            let id = context.headingIds[context.nextHeading]
            context.nextHeading++
            w.open("span", attrs: anchorAttrs(id, context))
            w.close("span")
            w.newline()
        } else {
            appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
        }
        if (!inserted && child.kind == "code_block") {
            appendAfterFirstCode(w, afterFirstCode)
            inserted = true
        }
    }
    if (!inserted) { appendAfterFirstCode(w, afterFirstCode) }
}

// `id` stays the first attribute: the captured-page producer splices a section
// identity onto these anchors by matching `id="…"` byte-for-byte.
internal func anchorAttrs(id: String, context: HtmlMarkdownContext): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>()
    attrs.add(htmlAttr("id", id))
    if (let Some(sectionId) <- context.sectionIds.get(id)) {
        attrs.add(htmlAttr("data-semantic-section", sectionId))
    }
    attrs.toArray()
}

/** Resolve a source Markdown fragment using the same heading IDs as standalone HTML. */
public func standaloneMarkdownFragment(node: MarkdownNode, fragment: String): ?String {
    let context = HtmlMarkdownContext(2)
    collectMarkdownHeadings(node, "standalone", HashMap<String, Int64>(), context)
    match (context.fragmentTargets.get(fragment)) {
        case Some(target) => Some("#" + target)
        case None => None
    }
}

public func escapeStandaloneHtml(value: String): String {
    escapeHtml(value)
}

internal func assetMediaExtension(mediaType: String): String {
    match (mediaType) {
        case "image/png" => "png"
        case "image/jpeg" => "jpg"
        case "image/gif" => "gif"
        case "image/webp" => "webp"
        case "image/avif" => "avif"
        case _ => throw IllegalArgumentException("unsupported local asset media type '${mediaType}'")
    }
}

internal func base64Digit(value: Byte): Int64 {
    if (value >= b'A' && value <= b'Z') { return Int64(value - b'A') }
    if (value >= b'a' && value <= b'z') { return Int64(value - b'a') + 26 }
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') + 52 }
    if (value == b'+') { return 62 }
    if (value == b'/') { return 63 }
    return -1
}

internal func decodeAssetBase64(value: String): Array<Byte> {
    let encoded = value.toArray()
    if (encoded.isEmpty() || encoded.size % 4 != 0) {
        throw IllegalArgumentException("invalid local asset base64")
    }
    let decoded = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < encoded.size) {
        let last = index + 4 == encoded.size
        let first = base64Digit(encoded[index])
        let second = base64Digit(encoded[index + 1])
        if (first < 0 || second < 0) { throw IllegalArgumentException("invalid local asset base64") }
        let thirdPadding = encoded[index + 2] == b'='
        let fourthPadding = encoded[index + 3] == b'='
        if (thirdPadding) {
            if (!last || !fourthPadding || (second & 15) != 0) {
                throw IllegalArgumentException("invalid local asset base64 padding")
            }
            decoded.add(UInt8((first << 2) | (second >> 4)))
        } else {
            let third = base64Digit(encoded[index + 2])
            if (third < 0) { throw IllegalArgumentException("invalid local asset base64") }
            decoded.add(UInt8((first << 2) | (second >> 4)))
            decoded.add(UInt8(((second & 15) << 4) | (third >> 2)))
            if (fourthPadding) {
                if (!last || (third & 3) != 0) {
                    throw IllegalArgumentException("invalid local asset base64 padding")
                }
            } else {
                let fourth = base64Digit(encoded[index + 3])
                if (fourth < 0) { throw IllegalArgumentException("invalid local asset base64") }
                decoded.add(UInt8(((third & 3) << 6) | fourth))
            }
        }
        index += 4
    }
    decoded.toArray()
}

internal func appendStructuredTextHtml(w: HtmlWriter, value: String): Unit {
    if (value.isEmpty()) { return }
    w.textElement("p", value)
    w.newline()
}

internal class ExampleFenceOpening {
    let marker: String
    let length: Int64
    let language: String

    init(marker: String, length: Int64, language: String) {
        this.marker = marker
        this.length = length
        this.language = language
    }
}

internal func trimExampleBlankLines(value: String): String {
    // Fence tracking must use the same line boundaries as Markdown consumers.
    let normalized = value.replace("\r\n", "\n").replace("\r", "\n")
    let lines = normalized.split("\n")
    var first: Int64 = 0
    while (first < lines.size && lines[first].trimAscii().isEmpty()) { first++ }
    var last = lines.size
    while (last > first && lines[last - 1].trimAscii().isEmpty()) { last-- }
    if (first >= last) { return "" }
    let out = StringBuilder()
    var index = first
    while (index < last) {
        if (index > first) { out.append("\n") }
        out.append(lines[index])
        index++
    }
    out.toString()
}

internal func exampleFenceLineValue(line: String): ?String {
    // CommonMark permits only up to three ASCII spaces before a fence.
    var leadingSpaces: Int64 = 0
    while (leadingSpaces < line.size && line[leadingSpaces] == b' ') {
        leadingSpaces++
    }
    if (leadingSpaces > 3) { return None }
    let remainder = line[leadingSpaces..]
    if (!remainder.isEmpty() && remainder[0] != b'`' && remainder[0] != b'~') {
        return None
    }
    Some(remainder.trimAscii())
}

internal func exampleFenceOpening(line: String): ?ExampleFenceOpening {
    let value = match (exampleFenceLineValue(line)) {
        case Some(candidate) => candidate
        case None => return None
    }
    if (value.isEmpty()) { return None }
    let marker = if (value[0] == b'`') {
        "`"
    } else if (value[0] == b'~') {
        "~"
    } else {
        return None
    }
    var length: Int64 = 0
    while (length < value.size && value[length] == marker[0]) { length++ }
    if (length < 3) { return None }
    let info = value[length..].trimAscii()
    if (marker == "`" && info.contains("`")) { return None }
    let fields = info.split(" ", 2, removeEmpty: true)
    let language = if (fields.isEmpty()) { "" } else { fields[0] }
    Some(ExampleFenceOpening(marker, length, language))
}

internal func isExampleFenceClosing(line: String, fence: ExampleFenceOpening): Bool {
    let value = match (exampleFenceLineValue(line)) {
        case Some(candidate) => candidate
        case None => return false
    }
    if (!value.startsWith(fence.marker)) { return false }
    var length: Int64 = 0
    while (length < value.size && value[length] == fence.marker[0]) { length++ }
    length >= fence.length && value[length..].trimAscii().isEmpty()
}

internal func appendExampleCodeHtml(w: HtmlWriter, code: String, language: String): Unit {
    appendCodeBlockHtml(w, code, codeBlockAttrs(code, normalizeCodeLanguage(language)), None)
}

/** Code-block attributes shared by author examples and Markdown fences. */
internal func codeBlockAttrs(raw: String, language: String,
    attributesRaw!: String = ""): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>()
    attrs.add(codeSourceAttr(raw))
    if (!language.isEmpty()) { attrs.add(htmlAttr("data-language", language)) }
    if (!attributesRaw.isEmpty()) {
        attrs.add(htmlAttr("data-cjdoc-attributes", attributesRaw))
    }
    attrs.toArray()
}

// Author examples and Markdown fences share one code-block structure, so the
// copy controller sees a single DOM shape everywhere.
internal func appendCodeBlockHtml(w: HtmlWriter, code: String,
    attrs: Array<HtmlAttr>, highlight: ?CodeHighlight): Unit {
    w.element("div", [htmlClass("cj-code")]) { block =>
        block.element("pre", [htmlClass("cj-code__pre")]) { pre =>
            pre.open("code", attrs: attrs)
            appendHighlightedCodeHtml(pre, code, "", highlight: highlight)
            pre.close("code")
        }
    }
    w.newline()
}

internal func appendExampleHtml(w: HtmlWriter, value: String): Unit {
    let content = trimExampleBlankLines(value)
    if (content.isEmpty()) { return }
    var prose = StringBuilder()
    var proseLineCount: Int64 = 0
    var code = StringBuilder()
    var codeLineCount: Int64 = 0
    var activeFence: ?ExampleFenceOpening = None
    for (line in content.split("\n")) {
        match (activeFence) {
            case Some(fence) =>
                if (isExampleFenceClosing(line, fence)) {
                    appendExampleCodeHtml(w, code.toString(), fence.language)
                    activeFence = None
                    code = StringBuilder()
                    codeLineCount = 0
                } else {
                    if (codeLineCount > 0) { code.append("\n") }
                    code.append(line)
                    codeLineCount++
                }
            case None =>
                match (exampleFenceOpening(line)) {
                    case Some(fence) =>
                        appendStructuredTextHtml(w, trimExampleBlankLines(prose.toString()))
                        prose = StringBuilder()
                        proseLineCount = 0
                        activeFence = Some(fence)
                    case None =>
                        if (proseLineCount > 0) { prose.append("\n") }
                        prose.append(line)
                        proseLineCount++
                }
        }
    }
    match (activeFence) {
        case Some(fence) => appendExampleCodeHtml(w, code.toString(), fence.language)
        case None => ()
    }
    appendStructuredTextHtml(w, trimExampleBlankLines(prose.toString()))
}

// The single-kind heading is the reader's entry point, not an internal
// "behavior contracts" category followed by a redundant label. Chinese reuses
// the published label; English headings read as prose while list labels stay
// the raw tag names the author wrote.
private func behaviorContractHeading(name: String, locale: String): String {
    if (locale == "zh-CN") { return behaviorContractLabel(name, locale) }
    match (name) {
        case "precondition" => "Precondition"
        case "postcondition" => "Postcondition"
        case "invariant" => "Invariant"
        case "performance" => "Performance"
        case "state" => "State"
        case "concurrency" => "Concurrency"
        case "platform" => "Platform"
        case "compatibility" => "Compatibility"
        case "error" => "Error behavior"
        case _ => name
    }
}

private func appendIncompleteBadge(w: HtmlWriter, locale: String): Unit {
    w.textElement("span", label(locale, "incomplete", "不完整"),
        attrs: [htmlClass("cj-badge"), htmlAttr("data-state", "incomplete")])
}

internal func appendDocumentationContractsHtml(w: HtmlWriter, comment: DocComment,
    locale: String, anchor: String, assetLookup!: HashMap<String, String> = HashMap<String, String>(),
    rootPrefix!: String = "", markdownContext!: HtmlMarkdownContext = HtmlMarkdownContext(2),
    headingLevel!: Int64 = 3): Unit {
    let heading = "h${min(6, headingLevel)}"
    var contractCount: Int64 = 0
    var soleContract: ?DocTag = None
    for (tag in comment.tags) {
        if (!isBehaviorContractTag(tag.name)) { continue }
        contractCount++
        if (contractCount == 1) { soleContract = Some(tag) }
    }
    if (contractCount == 0) { return }

    // Keep the previously published heading anchor stable, including when
    // the visible heading becomes more specific.
    let headingId = anchor + "--behavior-contracts-heading"
    w.open("section", attrs: [htmlClass("cj-contracts"),
        htmlAttr("aria-labelledby", headingId)])
    if (contractCount == 1) {
        match (soleContract) {
            case Some(tag) =>
                w.textElement(heading, behaviorContractHeading(tag.name, locale),
                    attrs: [htmlAttr("id", headingId)])
                w.open("div", attrs: [htmlClass("cj-contracts--single")])
                appendSoleContractBody(w, tag, locale, assetLookup, rootPrefix, markdownContext)
                w.close("div")
            case None => ()
        }
        w.close("section")
        w.newline()
        return
    }
    w.textElement(heading, label(locale, "Behavioral constraints", "行为约束"),
        attrs: [htmlAttr("id", headingId)])
    appendContractTerms(w, comment, locale, assetLookup, rootPrefix, markdownContext)
    w.close("section")
    w.newline()
}

private func appendContractTerms(w: HtmlWriter, comment: DocComment, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext): Unit {
    w.open("dl")
    w.newline()
    for (tag in comment.tags) {
        if (!isBehaviorContractTag(tag.name)) { continue }
        w.element("dt", Array<HtmlAttr>()) { term =>
            term.textElement("code", behaviorContractLabel(tag.name, locale))
            if (!tag.subject.isEmpty()) {
                term.text(" ")
                term.textElement("code", tag.subject)
            }
        }
        w.element("dd", Array<HtmlAttr>()) { body =>
            if (tag.description.trimAscii().isEmpty()) {
                appendIncompleteBadge(body, locale)
            } else {
                appendDocumentationTagHtml(body, tag, locale, assetLookup, rootPrefix,
                    markdownContext)
            }
        }
        w.newline()
    }
    w.close("dl")
}

private func appendSoleContractBody(w: HtmlWriter, tag: DocTag, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext): Unit {
    if (!tag.subject.isEmpty()) {
        w.element("p", [htmlClass("cj-contracts__subject")]) { body =>
            body.textElement("code", tag.subject)
        }
    }
    if (tag.description.trimAscii().isEmpty()) {
        appendIncompleteBadge(w, locale)
    } else {
        appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix, markdownContext)
    }
}

internal func appendDocumentationExamplesHtml(w: HtmlWriter, comment: DocComment,
    locale: String, headingLevel!: Int64 = 3, symbol!: ?SymbolDoc = None,
    assetLookup!: HashMap<String, String> = HashMap<String, String>(), rootPrefix!: String = "",
    markdownContext!: HtmlMarkdownContext = HtmlMarkdownContext(2)): Unit {
    var hasExamples = false
    for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
    if (!hasExamples) { return }
    w.textElement("h${headingLevel}", label(locale, "Examples", "示例"))
    w.open("div", attrs: [htmlClass("cj-examples")])
    w.newline()
    var exampleIndex: Int64 = 0
    let symbolPrefix = match (symbol) { case Some(value) => symbolAnchor(value) case None => "examples" }
    for (tag in comment.tags) {
        if (tag.name != "example") { continue }
        exampleIndex++
        w.open("div", attrs: [htmlClass("cj-example")])
        appendContentLanguageHtml(w, tag, locale)
        if (!tag.subject.isEmpty()) {
            w.textElement("h${min(6, headingLevel + 1)}", tag.subject,
                attrs: [htmlClass("cj-example__title")])
        }
        appendExampleBodyHtml(w, tag, locale, assetLookup, rootPrefix, markdownContext,
            symbolPrefix, exampleIndex)
        w.close("div")
        w.newline()
    }
    w.close("div")
    w.newline()
}

private func appendExampleBodyHtml(w: HtmlWriter, tag: DocTag, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext, symbolPrefix: String, exampleIndex: Int64): Unit {
    if (trimExampleBlankLines(tag.description).isEmpty()) {
        w.textElement("p", label(locale, "No example content.", "示例内容为空。"),
            attrs: [htmlClass("cj-empty")])
        w.newline()
        return
    }
    match (tag.exampleMarkdown) {
        case Some(tree) =>
            // Share the enclosing heading stream, but scope source fragments to
            // this example so repeated #usage links stay local.
            let enclosingTargets = markdownContext.fragmentTargets
            markdownContext.fragmentTargets = HashMap<String, String>()
            markdownContext.nextHeading = markdownContext.headingIds.size
            collectMarkdownHeadings(tree, "${symbolPrefix}--example-${exampleIndex}",
                HashMap<String, Int64>(), markdownContext)
            appendMarkdownNodeHtml(w, tree, assetLookup, rootPrefix, markdownContext)
            markdownContext.fragmentTargets = enclosingTargets
        case None => appendExampleHtml(w, tag.description)
    }
}

internal func markdownFragmentSlug(value: String): String {
    let out = RenderTextBuffer()
    var pendingDash = false
    var wrote = false
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (code == 0x20u32 || code == 0x09u32 || code == 0x0Au32 || code == 0x0Du32) {
            pendingDash = wrote
            continue
        }
        let keep = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) ||
            (code >= 0x61u32 && code <= 0x7Au32) || code == 0x2Du32 || code == 0x5Fu32 ||
            code >= 0x80u32
        if (!keep) { continue }
        if (pendingDash) { out.append("-"); pendingDash = false }
        if (code >= 0x41u32 && code <= 0x5Au32) {
            out.append(String.fromUtf8([UInt8(code + 0x20u32)]))
        } else {
            out.append(rune)
        }
        wrote = true
    }
    let slug = out.toString()
    if (slug.isEmpty()) { "section" } else { slug }
}

internal class HtmlMarkdownContext {
    let headingBase: Int64
    let allowExternalLinks: Bool
    let headingIds = ArrayList<String>()
    var fragmentTargets = HashMap<String, String>()
    let usedHeadingSlugs = HashSet<String>()
    let sourceLinks: HashMap<String, String>
    let bindingSource: String
    let bindingChips: ?HashMap<Int64, TrustedHtml>
    let locale: String
    let fieldAnchorNamespace: String
    var nextHeading: Int64 = 0
    // Filled by the standalone page renderer; empty for symbol/field contexts.
    var sectionIds = HashMap<String, String>()

    init(headingBase: Int64, allowExternalLinks!: Bool = true,
        sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
        bindingSource!: String = "", bindingChips!: ?HashMap<Int64, TrustedHtml> = None,
        locale!: String = "en", fieldAnchorNamespace!: String = "") {
        this.headingBase = headingBase
        this.allowExternalLinks = allowExternalLinks
        this.sourceLinks = sourceLinks
        this.bindingSource = bindingSource
        this.bindingChips = bindingChips
        this.locale = locale
        this.fieldAnchorNamespace = fieldAnchorNamespace
    }
}

internal func markdownHtmlContext(comment: DocComment, symbol: SymbolDoc,
    headingBase: Int64, locale!: String = "en",
    fieldAnchorNamespace!: String = ""): HtmlMarkdownContext {
    let context = HtmlMarkdownContext(headingBase, locale: locale,
        fieldAnchorNamespace: fieldAnchorNamespace)
    collectMarkdownHeadings(comment.markdown, symbolAnchor(symbol), HashMap<String, Int64>(), context)
    context
}

internal func collectMarkdownHeadings(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, context: HtmlMarkdownContext): Unit {
    if (node.kind == "heading") {
        let (slug, target) = allocateMarkdownHeadingTarget(markdownNodeText(node), anchorPrefix,
            counts, context.usedHeadingSlugs)
        context.headingIds.add(target)
        context.fragmentTargets["#${slug}"] = target
    }
    for (child in node.children) {
        collectMarkdownHeadings(child, anchorPrefix, counts, context)
    }
}

internal func appendMarkdownChildrenHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    for (child in node.children) {
        appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
    }
}
