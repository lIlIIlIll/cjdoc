protected package cjdoc.render.html

import cjdoc.render.foundation.RenderTextBuffer
import cjdoc.render.browser.{HTML_TOKENS_STYLE, HTML_LAYOUT_STYLE, HTML_COMPONENT_STYLE}

/**
 * Optional CSS font-family lists for the generated HTML site. Each value is a
 * comma-separated list of family names (letters, digits, spaces, `_`, `-`,
 * optionally double-quoted), at most 256 bytes; anything else is rejected so
 * the value can never break out of its declaration.
 */
public struct HtmlFontOptions {
    public let sans: ?String
    public let mono: ?String

    public init(sans!: ?String = None, mono!: ?String = None) {
        for ((value, option) in [(sans, "--html-font-sans"), (mono, "--html-font-mono")]) {
            if (let Some(list) <- value) {
                if (!isValidHtmlFontFamilyList(list)) {
                    throw IllegalArgumentException("invalid ${option} value")
                }
            }
        }
        this.sans = sans
        this.mono = mono
    }
}

private let HTML_FONT_FAMILY_LIST_LIMIT: Int64 = 256

private func htmlFontNameByte(byte: Byte): Bool {
    (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
        (byte >= b'0' && byte <= b'9') || byte == b' ' || byte == b'_' || byte == b'-'
}

private func validHtmlFontFamily(family: String): Bool {
    let quoted = family.size >= 2 && family.startsWith("\"") && family.endsWith("\"")
    let name = if (quoted) { family[1..family.size - 1] } else { family }
    if (name.isEmpty() || name.startsWith(" ") || name.endsWith(" ")) { return false }
    for (byte in name.toArray()) {
        if (!htmlFontNameByte(byte)) { return false }
    }
    true
}

// Only the space character may separate list items; other whitespace (tabs,
// newlines) is rejected rather than silently trimmed into the stylesheet.
private func trimSpaces(value: String): String {
    var start: Int64 = 0
    var end = value.size
    while (start < end && value[start] == b' ') { start++ }
    while (end > start && value[end - 1] == b' ') { end-- }
    value[start..end]
}

public func isValidHtmlFontFamilyList(value: String): Bool {
    if (value.isEmpty() || value.size > HTML_FONT_FAMILY_LIST_LIMIT) { return false }
    for (part in value.split(",")) {
        if (!validHtmlFontFamily(trimSpaces(part))) { return false }
    }
    true
}

// Appended last so it overrides the default stacks, while the reader's own
// data-cj-font preference (higher specificity) still wins in the browser.
protected func renderHtmlStylesheet(fonts: HtmlFontOptions): String {
    let out = RenderTextBuffer()
    out.append(HTML_TOKENS_STYLE)
    out.append(HTML_LAYOUT_STYLE)
    out.append(HTML_COMPONENT_STYLE)
    if (let Some(sans) <- fonts.sans) { out.append(":root{--cj-font-sans:${sans};}\n") }
    if (let Some(mono) <- fonts.mono) { out.append(":root{--cj-font-mono:${mono};}\n") }
    out.toString()
}
