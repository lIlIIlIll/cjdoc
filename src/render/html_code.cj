package cjdoc.render

import cjdoc.model.*
import std.collection.*


// Validate before writing anything: malformed input never leaves half-colored HTML.
internal func appendHighlightedSpansHtml(out: RenderTextBuffer, raw: String,
    spans: Array<(Int64, Int64, String)>): Unit {
    var previousEnd: Int64 = 0
    for ((start, end, className) in spans) {
        if (start < previousEnd || end <= start || end > raw.size ||
            (raw[start] & 0xC0) == 0x80 || (end < raw.size && (raw[end] & 0xC0) == 0x80)) {
            appendHtmlEscapedValue(out, raw); return
        }
        previousEnd = end
    }
    var cursor: Int64 = 0
    for ((start, end, className) in spans) {
        appendHtmlEscapedValue(out, raw[cursor..start])
        if (!className.isEmpty()) { out.append("<span class=\""); appendHtmlEscapedValue(out, className); out.append("\">") }
        appendHtmlEscapedValue(out, raw[start..end])
        if (!className.isEmpty()) { out.append("</span>") }
        cursor = end
    }
    appendHtmlEscapedValue(out, raw[cursor..])
}

// Link ranges and display ranges remain independent. Clipping at link boundaries
// emits <a><span>...</span></a>, never crossing or inventing a type link.
internal func appendCodeHighlightRangeHtml(out: RenderTextBuffer, raw: String,
    highlight: CodeHighlight, start: Int64, end: Int64): Unit {
    let spans = ArrayList<(Int64, Int64, String)>()
    for (span in highlight.spans) {
        if (span.endByte <= start) { continue }
        if (span.startByte >= end) { break }
        let left = if (span.startByte < start) { start } else { span.startByte }
        let right = if (span.endByte > end) { end } else { span.endByte }
        spans.add((left - start, right - start, codeKindClass(span.kind)))
    }
    appendHighlightedSpansHtml(out, raw[start..end], spans.toArray())
}

internal func appendHtmlCodeToken(out: RenderTextBuffer, value: String, className: String): Unit {
    if (!className.isEmpty()) { out.append("<span class=\"${className}\">") }
    appendHtmlEscapedValue(out, value)
    if (!className.isEmpty()) { out.append("</span>") }
}

// Missing display metadata (legacy IR or highlighting disabled) degrades to
// escaped plain text. The renderer never supplies a second Cangjie scanner.
internal func appendHighlightedCodeHtml(out: RenderTextBuffer, raw: String,
    language: String, highlight!: ?CodeHighlight = None): Unit {
    if (let Some(prepared) <- highlight) {
        if (prepared.matchesSource(raw)) {
            appendCodeHighlightRangeHtml(out, raw, prepared, 0, raw.size)
        } else { appendHtmlEscapedValue(out, raw) }
    } else { appendHtmlEscapedValue(out, raw) }
}
