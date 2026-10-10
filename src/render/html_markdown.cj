package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func escapeHtml(value: String): String {
    let out = RenderTextBuffer()
    appendHtmlEscapedValue(out, value)
    out.toString()
}

private func safeMappedRelativeLinkDestination(value: String): Bool {
    let parts = value.split("#", 2)
    var path = parts[0]
    while (path.startsWith("../")) { path = path.removePrefix("../") }
    if (path.contains("%") || !safeRelativeLinkDestination(path)) { return false }
    parts.size == 1 || safeLinkDestination("#" + parts[1])
}

public func renderStandaloneMarkdownHtml(node: MarkdownNode,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None): String {
    let context = HtmlMarkdownContext(2, sourceLinks: sourceLinks)
    collectMarkdownHeadings(node, "standalone", HashMap<String, Int64>(), context)
    let out = RenderTextBuffer()
    appendStandaloneMarkdownHtml(out, node, context, pageTitle)
    out.toString()
}

// Suppress exactly the Markdown's own leading level-1 heading when the page
// shell already rendered the same title as the page <h1>. A differently titled
// or absent leading heading is untouched, and any later heading — including one
// repeating the same text — keeps the heading stream and its shareable anchor.
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

private func appendStandaloneMarkdownHtml(out: RenderTextBuffer, node: MarkdownNode,
    context: HtmlMarkdownContext, pageTitle: ?String): Unit {
    match (standaloneTitleHeadingIndex(node, pageTitle)) {
        case Some(index) =>
            for (childIndex in 0..node.children.size) {
                if (childIndex == index) { context.nextHeading++; continue }
                appendMarkdownNodeHtml(out, node.children[childIndex], HashMap<String, String>(), "", context)
            }
        case None =>
            appendMarkdownNodeHtml(out, node, HashMap<String, String>(), "", context)
    }
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

internal func appendStructuredTextHtml(out: RenderTextBuffer, value: String): Unit {
    if (!value.isEmpty()) { out.append("<p>${escapeHtml(value)}</p>\n") }
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

internal func appendExampleCodeHtml(out: RenderTextBuffer, code: String, language: String): Unit {
    let normalizedLanguage = if (language == "cj") { "cangjie" } else { language }
    out.append("<pre><code")
    if (!normalizedLanguage.isEmpty()) {
        out.append(" class=\"language-${htmlStableSlug(normalizedLanguage)}\"")
        out.append(" data-language=\"${escapeHtml(normalizedLanguage)}\"")
    }
    out.append(">"); appendHighlightedCodeHtml(out, code, normalizedLanguage); out.append("</code></pre>\n")
}

internal func appendExampleHtml(out: RenderTextBuffer, value: String): Unit {
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
                    appendExampleCodeHtml(out, code.toString(), fence.language)
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
                        appendStructuredTextHtml(out, trimExampleBlankLines(prose.toString()))
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
        case Some(fence) => appendExampleCodeHtml(out, code.toString(), fence.language)
        case None => ()
    }
    appendStructuredTextHtml(out, trimExampleBlankLines(prose.toString()))
}

private func isBehaviorContractTag(name: String): Bool {
    name == "precondition" || name == "postcondition" || name == "invariant" ||
        name == "performance" || name == "state" || name == "concurrency" ||
        name == "platform" || name == "compatibility" || name == "error"
}

private func behaviorContractLabel(name: String, locale: String): String {
    if (locale == "zh-CN") {
        match (name) {
            case "precondition" => "前置条件"
            case "postcondition" => "后置条件"
            case "invariant" => "不变量"
            case "performance" => "性能"
            case "state" => "状态"
            case "concurrency" => "并发"
            case "platform" => "平台"
            case "compatibility" => "兼容性"
            case "error" => "错误行为"
            case _ => name
        }
    } else { name }
}

// The single-kind heading is the reader's entry point, not an internal
// "behavior contracts" category followed by a redundant label.
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

internal func appendDocumentationContractsHtml(out: RenderTextBuffer, comment: DocComment,
    locale: String, anchor: String): Unit {
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
    let headingId = escapeHtml(anchor + "--behavior-contracts-heading")
    out.append("<section class=\"behavior-contracts\" aria-labelledby=\"${headingId}\">\n")
    if (contractCount == 1) {
        match (soleContract) {
            case Some(tag) =>
                out.append("<h3 id=\"${headingId}\">" +
                    escapeHtml(behaviorContractHeading(tag.name, locale)) +
                    "</h3><div class=\"behavior-contract-single\">")
                if (!tag.subject.isEmpty()) {
                    out.append("<p class=\"behavior-contract-subject\"><code>" +
                        escapeHtml(tag.subject) + "</code></p>")
                }
                if (tag.description.trimAscii().isEmpty()) {
                    out.append("<span class=\"badge\" data-state=\"incomplete\">" +
                        label(locale, "incomplete", "不完整") + "</span>")
                } else {
                    appendStructuredTextHtml(out, tag.description)
                }
                out.append("</div></section>\n")
            case None => ()
        }
        return
    }

    out.append("<h3 id=\"${headingId}\">" +
        label(locale, "Behavioral constraints", "行为约束") + "</h3><dl>\n")
    for (tag in comment.tags) {
        if (!isBehaviorContractTag(tag.name)) { continue }
        out.append("<dt><code>" + escapeHtml(behaviorContractLabel(tag.name, locale)) + "</code>")
        if (!tag.subject.isEmpty()) { out.append(" <code>" + escapeHtml(tag.subject) + "</code>") }
        out.append("</dt><dd>")
        if (tag.description.trimAscii().isEmpty()) {
            out.append("<span class=\"badge\" data-state=\"incomplete\">" +
                label(locale, "incomplete", "不完整") + "</span>")
        } else {
            appendStructuredTextHtml(out, tag.description)
        }
        out.append("</dd>\n")
    }
    out.append("</dl></section>\n")
}

// Per-example execution status, keyed by "symbolId\u{0}title". The value is the
// native doctest status. Only statuses the native runner actually recorded are
// shown; an example without an entry is left unlabelled rather than guessed.
internal func appendExampleEvidenceHtml(out: RenderTextBuffer, symbol: SymbolDoc, tag: DocTag,
    evidence: HashMap<String, String>, locale: String,
    evidenceRootPrefix!: String = "../../"): Unit {
    match (evidence.get(exampleEvidenceKey(symbol.id, tag.subject))) {
        case None =>
            // When doctests ran, an example with no result is evidence that was
            // not recorded, which a reader must not mistake for a verified or
            // merely absent claim. When no doctests ran at all the map is empty
            // and no claim system is active, so nothing is shown.
            if (evidence.isEmpty()) { return }
            out.append("<p class=\"example-evidence\"><span class=\"badge\" data-example-state=\"unverified\">")
            out.append(label(locale, "Not verified by execution", "未经执行验证"))
            out.append("</span></p>")
        case Some(status) =>
            let wording = match (status) {
                case "passed" => label(locale, "Verified by execution", "已执行验证")
                case "failed" => label(locale, "Execution failed", "执行失败")
                case "timeout" => label(locale, "Execution timed out", "执行超时")
                case "skipped" => label(locale, "Not executed", "未执行")
                case _ => status
            }
            out.append("<p class=\"example-evidence\"><span class=\"badge\" data-example-state=\"")
            out.append(escapeHtml(status))
            out.append("\">")
            out.append(escapeHtml(wording))
            out.append("</span> <a href=\"" + evidenceRootPrefix + "doctest/results.json\">")
            out.append(label(locale, "Raw execution evidence", "原始执行证据"))
            out.append("</a></p>")
    }
}

// Shared between the renderer and the CLI that builds the evidence map, so both
// sides derive the same key.
public func exampleEvidenceKey(symbolId: String, title: String): String {
    symbolId + "\u{0}" + title
}

internal func appendDocumentationExamplesHtml(out: RenderTextBuffer, comment: DocComment,
    locale: String, headingLevel!: Int64 = 3, symbol!: ?SymbolDoc = None,
    exampleEvidence!: HashMap<String, String> = HashMap<String, String>(),
    exampleEvidenceRootPrefix!: String = "../../"): Unit {
    var hasExamples = false
    for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
    if (!hasExamples) { return }
    out.append("<h${headingLevel}>${label(locale, "Examples", "示例")}</h${headingLevel}><div class=\"example-list\">\n")
    for (tag in comment.tags) {
        if (tag.name != "example") { continue }
        out.append("<div class=\"example-block\">")
        if (!tag.subject.isEmpty()) {
            out.append("<h${min(6, headingLevel + 1)} class=\"example-title\">${escapeHtml(tag.subject)}</h${min(6, headingLevel + 1)}>")
        }
        match (symbol) {
            case Some(value) => appendExampleEvidenceHtml(out, value, tag, exampleEvidence, locale,
                evidenceRootPrefix: exampleEvidenceRootPrefix)
            case None => ()
        }
        if (trimExampleBlankLines(tag.description).isEmpty()) {
            let emptyLabel = label(locale, "No example content.", "示例内容为空。")
            out.append("<p class=\"empty-state\">${emptyLabel}</p>\n")
        } else {
            appendExampleHtml(out, tag.description)
        }
        out.append("</div>\n")
    }
    out.append("</div>\n")
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
    let fragmentTargets = HashMap<String, String>()
    let usedHeadingSlugs = HashSet<String>()
    let sourceLinks: HashMap<String, String>
    var nextHeading: Int64 = 0

    init(headingBase: Int64, allowExternalLinks!: Bool = true,
        sourceLinks!: HashMap<String, String> = HashMap<String, String>()) {
        this.headingBase = headingBase
        this.allowExternalLinks = allowExternalLinks
        this.sourceLinks = sourceLinks
    }
}

internal func collectMarkdownHeadings(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, context: HtmlMarkdownContext): Unit {
    if (node.kind == "heading") {
        let base = markdownFragmentSlug(markdownNodeText(node))
        var occurrence = match (counts.get(base)) { case Some(value) => value case None => 0 }
        var slug = if (occurrence == 0) { base } else { "${base}-${occurrence}" }
        while (context.usedHeadingSlugs.contains(slug)) {
            occurrence++
            slug = "${base}-${occurrence}"
        }
        counts[base] = occurrence + 1
        let _ = context.usedHeadingSlugs.add(slug)
        let target = "${anchorPrefix}--doc-${slug}"
        context.headingIds.add(target)
        context.fragmentTargets["#${slug}"] = target
    }
    for (child in node.children) {
        collectMarkdownHeadings(child, anchorPrefix, counts, context)
    }
}

internal func markdownHtmlContext(comment: DocComment, symbol: SymbolDoc,
    headingBase: Int64): HtmlMarkdownContext {
    let context = HtmlMarkdownContext(headingBase)
    collectMarkdownHeadings(comment.markdown, symbolAnchor(symbol), HashMap<String, Int64>(), context)
    context
}

internal func appendMarkdownNodeHtml(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    tableHeader!: Bool = false, tightListItem!: Bool = false): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
        }
        case "paragraph" =>
            out.append("<p>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</p>\n")
        case "heading" =>
            let level = markdownHeadingLevel(node, context.headingBase)
            let id = context.headingIds[context.nextHeading]
            context.nextHeading++
            out.append("<h${level} id=\"${escapeHtml(id)}\">"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</h${level}>\n")
        case "text" => out.append(escapeHtml(node.literal))
        case "soft_break" => out.append("\n")
        case "hard_break" => out.append("<br>\n")
        case "emphasis" =>
            out.append("<em>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</em>")
        case "strong" =>
            out.append("<strong>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</strong>")
        case "strikethrough" =>
            out.append("<del>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</del>")
        case "code_span" => out.append("<code>${escapeHtml(node.literal)}</code>")
        case "code_block" =>
            out.append("<pre><code")
            var displayLanguage = ""
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "code_block") {
                    let language = metadata.language.getOrThrow()
                    displayLanguage = language
                    if (!language.isEmpty()) {
                        out.append(" class=\"language-${htmlStableSlug(language)}\"")
                        out.append(" data-language=\"${escapeHtml(language)}\"")
                    }
                    if (!metadata.attributesRaw.getOrThrow().isEmpty()) {
                        out.append(" data-cjdoc-attributes=\"${escapeHtml(metadata.attributesRaw.getOrThrow())}\"")
                    }
                }
            }
            out.append(">")
            appendHighlightedCodeHtml(out, node.literal, displayLanguage)
            out.append("</code></pre>\n")
        case "thematic_break" => out.append("<hr>\n")
        case "block_quote" =>
            out.append("<blockquote>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</blockquote>\n")
        case "list" =>
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
            if (ordered) { out.append("<ol start=\"${start}\">") } else { out.append("<ul>") }
            for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context,
                    tightListItem: tight)
            }
            if (ordered) { out.append("</ol>\n") } else { out.append("</ul>\n") }
        case "list_item" =>
            out.append("<li>")
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "list_item") {
                    match (metadata.taskState.getOrThrow()) {
                        case "checked" => out.append("<input type=\"checkbox\" disabled checked> ")
                        case "unchecked" => out.append("<input type=\"checkbox\" disabled> ")
                        case _ => ()
                    }
                }
            }
            for (child in node.children) {
                if (tightListItem && child.kind == "paragraph") {
                    for (grandchild in child.children) {
                        appendMarkdownNodeHtml(out, grandchild, assetLookup, rootPrefix, context)
                    }
                } else {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
            }; out.append("</li>")
        case "link" =>
            let sourceDestination = context.sourceLinks.get(node.literal)
            let destination = match (sourceDestination) {
                case Some(target) => target
                case None => match (context.fragmentTargets.get(node.literal)) {
                    case Some(target) => "#${target}"
                    case None => node.literal
                }
            }
            let isRemote = destination.startsWith("http://") || destination.startsWith("https://")
            let safeDestination = safeLinkDestination(destination) ||
                safeRelativeLinkDestination(destination) ||
                (sourceDestination.isSome() && safeMappedRelativeLinkDestination(destination))
            if (safeDestination && (context.allowExternalLinks || !isRemote)) {
                out.append("<a href=\"${escapeHtml(destination)}\"")
                if (destination.startsWith("http://") || destination.startsWith("https://")) {
                    out.append(" rel=\"noopener noreferrer\"")
                }
                out.append(">")
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
                out.append("</a>")
            } else {
                for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
            }
        case "semantic_link" =>
            let destination: ?String = match (node.metadata) {
                case Some(metadata) => metadata.semanticExternalUrl
                case None => None
            }
            match (destination) {
                case Some(value) =>
                    let href = if (value.startsWith("http://") || value.startsWith("https://") || value.startsWith("#")) {
                        value
                    } else {
                        rootPrefix + value
                    }
                    let isRemote = value.startsWith("http://") || value.startsWith("https://")
                    let isFragment = value.startsWith("#")
                    let permitted = if (isRemote) {
                        context.allowExternalLinks && safeLinkDestination(href)
                    } else if (isFragment) {
                        safeLinkDestination(href)
                    } else {
                        safeRelativeLinkDestination(value)
                    }
                    if (permitted) {
                        out.append("<a href=\"${escapeHtml(href)}\">")
                        for (child in node.children) {
                            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                        }
                        out.append("</a>")
                    } else {
                        for (child in node.children) {
                            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                        }
                    }
                case None => for (child in node.children) {
                    appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
                }
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) => out.append("<img src=\"${rootPrefix}${escapeHtml(path)}\" alt=\"${escapeHtml(alt)}\" loading=\"lazy\">")
                case None => out.append(escapeHtml(alt))
            }
        case "table" =>
            out.append("<table>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</table>\n")
        case "table_row" =>
            let header = match (node.metadata) {
                case Some(metadata) => metadata.kind == "table_row" && metadata.tableHeader.getOrThrow()
                case None => false
            }
            out.append("<tr>"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context,
                    tableHeader: header)
            }; out.append("</tr>")
        case "table_cell" =>
            let tag = if (tableHeader) { "th" } else { "td" }
            out.append("<${tag}")
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "table_cell" && metadata.tableAlignment.getOrThrow() != "none") {
                    out.append(" class=\"align-${metadata.tableAlignment.getOrThrow()}\"")
                }
            }
            out.append(">"); for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }; out.append("</${tag}>")
        case "html_block" => out.append("<pre>${escapeHtml(node.literal)}</pre>\n")
        case "html_inline" => out.append(escapeHtml(node.literal))
        case "custom_block" | "custom_inline" => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
        }
        case _ => out.append(escapeHtml(markdownNodeText(node)))
    }
}
