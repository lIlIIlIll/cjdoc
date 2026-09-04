package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func escapeHtml(value: String): String {
    let out = RenderTextBuffer()
    appendHtmlEscapedValue(out, value)
    out.toString()
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
    let lines = value.split("\n")
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
    out.append("<pre><code")
    if (!language.isEmpty()) {
        out.append(" class=\"language-${htmlStableSlug(language)}\"")
        out.append(" data-language=\"${escapeHtml(language)}\"")
    }
    out.append(">"); appendHtmlEscapedValue(out, code); out.append("</code></pre>\n")
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

internal func appendDocumentationExamplesHtml(out: RenderTextBuffer, comment: DocComment,
    locale: String): Unit {
    var hasExamples = false
    for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
    if (!hasExamples) { return }
    out.append("<h3>${label(locale, "Examples", "示例")}</h3><div class=\"example-list\">\n")
    for (tag in comment.tags) {
        if (tag.name != "example") { continue }
        out.append("<div class=\"example-block\">")
        if (!tag.subject.isEmpty()) {
            out.append("<h4 class=\"example-title\">${escapeHtml(tag.subject)}</h4>")
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
    let headingIds = ArrayList<String>()
    let fragmentTargets = HashMap<String, String>()
    let usedHeadingSlugs = HashSet<String>()
    var nextHeading: Int64 = 0

    init(headingBase: Int64) { this.headingBase = headingBase }
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
            if (let Some(metadata) <- node.metadata) {
                if (metadata.kind == "code_block") {
                    let language = metadata.language.getOrThrow()
                    if (!language.isEmpty()) {
                        out.append(" class=\"language-${htmlStableSlug(language)}\"")
                        out.append(" data-language=\"${escapeHtml(language)}\"")
                    }
                    if (!metadata.attributesRaw.getOrThrow().isEmpty()) {
                        out.append(" data-cjdoc-attributes=\"${escapeHtml(metadata.attributesRaw.getOrThrow())}\"")
                    }
                }
            }
            out.append(">${escapeHtml(node.literal)}</code></pre>\n")
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
            let destination = match (context.fragmentTargets.get(node.literal)) {
                case Some(target) => "#${target}"
                case None => node.literal
            }
            if (safeLinkDestination(destination)) {
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
