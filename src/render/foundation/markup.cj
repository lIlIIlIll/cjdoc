protected package cjdoc.render.foundation

import cjdoc.model.*
import std.collection.*

protected func isVisibleForAudience(declaration: SymbolDoc, audience: String): Bool {
    match (audience) {
        case "external" => declaration.visibility == "public" || declaration.visibility == "protected"
        case "package" => declaration.visibility != "private"
        case "all" => true
        case _ => false
    }
}

internal func appendMarkdownPlainText(out: RenderTextBuffer, node: MarkdownNode): Unit {
    match (node.kind) {
        case "text" | "code_span" | "code_block" | "html_inline" | "html_block" =>
            out.append(node.literal)
        case "soft_break" | "hard_break" => out.append("\n")
        case "thematic_break" => out.append("\n")
        case "admonition" =>
            out.append("\n")
            for (child in node.children) { appendMarkdownPlainText(out, child) }
            out.append("\n")
        case _ =>
            var first = true
            for (child in node.children) {
                if (!first && (node.kind == "paragraph" || node.kind == "heading" ||
                    node.kind == "list_item" || node.kind == "table_cell")) { out.append(" ") }
                first = false
                appendMarkdownPlainText(out, child)
            }
            if (node.kind == "paragraph" || node.kind == "heading" ||
                node.kind == "list_item" || node.kind == "block_quote") { out.append("\n") }
    }
}

protected func markdownNodeText(node: MarkdownNode): String {
    let out = RenderTextBuffer()
    appendMarkdownPlainText(out, node)
    out.toString().trimAscii()
}

protected func documentationTagPlainText(tag: DocTag): String {
    match (tag.descriptionMarkdown) {
        case Some(tree) => markdownNodeText(tree)
        case None => tag.description
    }
}

protected func appendEscapedMarkdownText(out: RenderTextBuffer, value: String): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '(' | ')' | '<' | '>' |
                '#' | '+' | '-' | '.' | '!' | '|' | '=' | '~' =>
                out.append("\\"); out.append(rune)
            case _ => out.append(rune)
        }
    }
}

protected func safeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.contains("\n") || value.contains("\r")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    value.startsWith("https://") || value.startsWith("http://") ||
        value.startsWith("mailto:") || value.startsWith("#")
}

internal func markdownHexByte(value: Byte): Bool {
    (value >= b'0' && value <= b'9') || (value >= b'a' && value <= b'f') ||
        (value >= b'A' && value <= b'F')
}

internal func markdownDestinationByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'-' || value == b'.' ||
        value == b'_' || value == b'~' || value == b':' || value == b'/' ||
        value == b'?' || value == b'#' || value == b'[' || value == b']' ||
        value == b'@' || value == b'!' || value == b'$' || value == b'&' ||
        value == b'*' || value == b'+' || value == b',' || value == b';' || value == b'='
}

internal func appendMarkdownPercentByte(out: RenderTextBuffer, value: Byte): Unit {
    let digits = "0123456789ABCDEF"
    let high = Int64((value >> 4) & 0x0F)
    let low = Int64(value & 0x0F)
    out.append("%")
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

protected func safeRelativeLinkDestination(value: String): Bool {
    if (value.isEmpty() || value.startsWith("//") || value.startsWith("/") ||
        value.contains("..") || value.contains("\\") || value.contains("#") ||
        value.contains("?") || value.contains(":") || value.contains(" ") ||
        value.contains("\n") || value.contains("\r")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20 || byte == 0x7F) { return false }
    }
    true
}

protected func markdownLinkDestination(value: String, allowRelative!: Bool = false): ?String {
    if (!safeLinkDestination(value) && (!allowRelative || !safeRelativeLinkDestination(value))) { return None }
    Some(encodeMarkdownDestination(value))
}

protected func encodeMarkdownDestination(value: String): String {
    let bytes = value.toArray()
    let out = RenderTextBuffer()
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte == b'%' && index + 2 < bytes.size && markdownHexByte(bytes[index + 1]) &&
            markdownHexByte(bytes[index + 2])) {
            out.append(String.fromUtf8([byte, bytes[index + 1], bytes[index + 2]]))
            index += 3
        } else {
            if (markdownDestinationByte(byte)) { out.append(String.fromUtf8([byte])) } else {
                appendMarkdownPercentByte(out, byte)
            }
            index++
        }
    }
    out.toString()
}

protected func assetReference(assetLookup: HashMap<String, String>, destination: String): ?String {
    match (assetLookup.get("path:${destination}")) {
        case Some(value) => Some(value)
        case None => match (assetLookup.get("id:${destination}")) {
            case Some(value) => Some(value)
            case None => if (destination.startsWith("./")) {
                assetLookup.get("path:${destination[2..]}")
            } else { None }
        }
    }
}

protected func markdownRequestedHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    let sourceLevel = match (node.metadata) {
        case Some(metadata) => if (metadata.kind == "heading") {
            metadata.headingLevel.getOrThrow()
        } else { 1 }
        case None => 1
    }
    base + sourceLevel - 1
}

protected func markdownHeadingLevel(node: MarkdownNode, base: Int64): Int64 {
    min(6, markdownRequestedHeadingLevel(node, base))
}

protected func appendMarkdownMarks(out: RenderTextBuffer, marker: String, count: Int64): Unit {
    if (count < 0 || count > DOC_IR_MAX_FENCE_LENGTH) {
        throw IllegalArgumentException("Markdown marker count exceeds renderer limit")
    }
    var index: Int64 = 0
    while (index < count) { out.append(marker); index++ }
}

internal func longestMarkdownMarkerRun(value: String, marker: Byte): Int64 {
    var longest: Int64 = 0
    var current: Int64 = 0
    for (byte in value.toArray()) {
        if (byte == marker) {
            current++
            if (current > longest) { longest = current }
        } else { current = 0 }
    }
    longest
}

internal func markdownAllSpaces(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (rune in value.runes()) { if (UInt32(rune) != 0x20u32) { return false } }
    true
}

protected func appendHtmlEscapedValue(out: RenderTextBuffer, value: String,
    encodeTablePipe!: Bool = false): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '&' => out.append("&amp;")
            case '<' => out.append("&lt;")
            case '>' => out.append("&gt;")
            case '"' => out.append("&quot;")
            case '\'' => out.append("&#39;")
            case '|' => if (encodeTablePipe) { out.append("&#124;") } else { out.append(rune) }
            case _ => out.append(rune)
        }
    }
}

protected func appendMarkdownCodeSpan(out: RenderTextBuffer, value: String,
    tableCell!: Bool = false): Unit {
    let normalizedValue = value.replace("\r", " ").replace("\n", " ")
    // Backslash escaping cannot represent every pipe inside a GFM table code span:
    // an odd run of preceding backslashes changes whether the table parser sees
    // the pipe as escaped. Inline HTML has stable table parsing and preserves the
    // exact code text after entity decoding.
    if (tableCell && normalizedValue.contains("|")) {
        out.append("<code>")
        appendHtmlEscapedValue(out, normalizedValue, encodeTablePipe: true)
        out.append("</code>")
        return
    }
    let normalized = normalizedValue
    let delimiterLength = longestMarkdownMarkerRun(normalized, b'`') + 1
    if (delimiterLength > DOC_IR_MAX_FENCE_LENGTH) {
        out.append("<code>${escapeHtml(normalized)}</code>")
        return
    }
    let padded = !markdownAllSpaces(normalized) &&
        (normalized.startsWith(" ") || normalized.endsWith(" ") ||
        normalized.startsWith("`") || normalized.endsWith("`"))
    appendMarkdownMarks(out, "`", delimiterLength)
    if (padded) { out.append(" ") }
    out.append(normalized)
    if (padded) { out.append(" ") }
    appendMarkdownMarks(out, "`", delimiterLength)
}

internal class MarkdownFence {
    let marker: String
    let length: Int64

    init(marker: String, length: Int64) { this.marker = marker; this.length = length }
}

internal func markdownFenceCandidate(literal: String, marker: String, requestedLength: Int64,
    infoRaw: String): ?MarkdownFence {
    if ((marker != "`" && marker != "~") || requestedLength < 3 ||
        (marker == "`" && infoRaw.contains("`"))) { return None }
    let markerByte = if (marker == "`") { b'`' } else { b'~' }
    let run = longestMarkdownMarkerRun(literal, markerByte)
    let length = max(requestedLength, run + 1)
    if (length > DOC_IR_MAX_FENCE_LENGTH) { return None }
    Some(MarkdownFence(marker, length))
}

internal func selectMarkdownFence(literal: String, requestedMarker: String,
    requestedLength: Int64, infoRaw: String): MarkdownFence {
    if (infoRaw.contains("\n") || infoRaw.contains("\r")) {
        throw IllegalArgumentException("invalid fenced-code renderer info string")
    }
    match (markdownFenceCandidate(literal, requestedMarker, requestedLength, infoRaw)) {
        case Some(value) => return value
        case None => ()
    }
    let alternate = if (requestedMarker == "~") { "`" } else { "~" }
    match (markdownFenceCandidate(literal, alternate, 3, infoRaw)) {
        case Some(value) => value
        case None => throw IllegalArgumentException(
            "code block cannot be represented within the Markdown fence limit")
    }
}

protected func appendMarkdownCodeBlock(out: RenderTextBuffer, literal: String, infoRaw: String,
    requestedMarker: String, requestedLength: Int64): Unit {
    let fence = selectMarkdownFence(literal, requestedMarker, requestedLength, infoRaw)
    appendMarkdownMarks(out, fence.marker, fence.length)
    if (!infoRaw.isEmpty()) { out.append(infoRaw) }
    out.append("\n")
    out.append(literal)
    if (!literal.endsWith("\n")) { out.append("\n") }
    appendMarkdownMarks(out, fence.marker, fence.length)
    out.append("\n\n")
}

protected func escapeHtml(value: String): String {
    let out = RenderTextBuffer()
    appendHtmlEscapedValue(out, value)
    out.toString()
}
