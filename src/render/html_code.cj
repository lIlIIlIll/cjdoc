package cjdoc.render

import cjdoc.model.*
import std.collection.*


// HTML normalizes CRLF, but the copy contract binds to the extracted original.
// JSON string escapes also preserve NUL and tabs without relying on DOM text.
internal func codeSourceAttr(raw: String): HtmlAttr {
    htmlAttr("data-cjdoc-source", escapeJsonString(raw))
}

// Validate before writing anything: malformed input never leaves half-colored HTML.
internal func appendHighlightedSpansHtml(w: HtmlWriter, raw: String,
    spans: Array<(Int64, Int64, String)>): Unit {
    var previousEnd: Int64 = 0
    for ((start, end, className) in spans) {
        if (start < previousEnd || end <= start || end > raw.size ||
            (raw[start] & 0xC0) == 0x80 || (end < raw.size && (raw[end] & 0xC0) == 0x80)) {
            w.text(raw); return
        }
        previousEnd = end
    }
    var cursor: Int64 = 0
    for ((start, end, className) in spans) {
        w.text(raw[cursor..start])
        appendHtmlCodeToken(w, raw[start..end], className)
        cursor = end
    }
    w.text(raw[cursor..])
}

// Link ranges and display ranges remain independent. Clipping at link boundaries
// emits <a><span>...</span></a>, never crossing or inventing a type link.
internal func appendCodeHighlightRangeHtml(w: HtmlWriter, raw: String,
    highlight: CodeHighlight, start: Int64, end: Int64): Unit {
    let spans = ArrayList<(Int64, Int64, String)>()
    for (span in highlight.spans) {
        if (span.endByte <= start) { continue }
        if (span.startByte >= end) { break }
        let left = if (span.startByte < start) { start } else { span.startByte }
        let right = if (span.endByte > end) { end } else { span.endByte }
        spans.add((left - start, right - start, codeKindClass(span.kind)))
    }
    appendHighlightedSpansHtml(w, raw[start..end], spans.toArray())
}

// The class name is a fixed highlight category, never backend text, so a token
// can only ever carry one of the renderer's own classes.
internal func appendHtmlCodeToken(w: HtmlWriter, value: String, className: String): Unit {
    if (className.isEmpty()) {
        w.text(value)
        return
    }
    w.open("span", attrs: [htmlClass(className)])
    w.text(value)
    w.close("span")
}

// Missing highlight metadata or disabled highlighting degrades to escaped
// plain text. The renderer never supplies a second Cangjie scanner.
internal func appendHighlightedCodeHtml(w: HtmlWriter, raw: String,
    language: String, highlight!: ?CodeHighlight = None): Unit {
    if (let Some(prepared) <- highlight) {
        if (prepared.matchesSource(raw)) {
            appendCodeHighlightRangeHtml(w, raw, prepared, 0, raw.size)
            return
        }
    }
    w.text(raw)
}
