package cjdoc.render

// Presentation only. These classes never contribute declarations, links, or IR.
internal func htmlCodeWordClass(word: String): String {
    match (word) {
        case "public" | "protected" | "private" | "internal" | "class" | "struct" |
            "interface" | "enum" | "extend" | "type" | "func" | "init" | "prop" |
            "let" | "var" | "const" | "static" | "mut" | "open" | "override" |
            "abstract" | "operator" | "where" | "if" | "else" | "for" | "in" |
            "while" | "do" | "match" | "case" | "return" | "throw" | "try" |
            "catch" | "finally" | "break" | "continue" | "import" | "package" |
            "foreign" | "unsafe" | "is" | "as" | "this" | "super" => "code-keyword"
        case "true" | "false" => "code-number"
        case "Int8" | "Int16" | "Int32" | "Int64" | "IntNative" | "UInt8" |
            "UInt16" | "UInt32" | "UInt64" | "UIntNative" | "Float16" | "Float32" |
            "Float64" | "Bool" | "Rune" | "String" | "Unit" | "Nothing" => "code-type"
        case _ => ""
    }
}

internal func appendHtmlCodeToken(out: RenderTextBuffer, value: String, className: String): Unit {
    if (!className.isEmpty()) { out.append("<span class=\"${className}\">") }
    appendHtmlEscapedValue(out, value)
    if (!className.isEmpty()) { out.append("</span>") }
}

private func htmlCodeWordByte(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'_' || byte >= 0x80
}

// Only simple, self-contained lexical spans are colored. Unfinished comments or
// strings and unsupported raw/multiline string delimiters fall back to escaped
// original text as a whole. Non-ASCII bytes stay in one source slice unchanged.
internal func appendHighlightedCodeHtml(out: RenderTextBuffer, raw: String,
    language: String): Unit {
    if (language != "cj" && language != "cangjie") {
        appendHtmlEscapedValue(out, raw); return
    }
    let colored = RenderTextBuffer()
    var cursor: Int64 = 0
    var plainStart: Int64 = 0
    while (cursor < raw.size) {
        let start = cursor
        let byte = raw[cursor]
        var className = ""
        if (byte == b'#' || (cursor + 2 < raw.size &&
            (byte == b'"' || byte == b'\'') && raw[cursor + 1] == byte && raw[cursor + 2] == byte)) {
            appendHtmlEscapedValue(out, raw); return
        }
        if (byte == b'"' || byte == b'\'') {
            cursor++
            var closed = false
            while (cursor < raw.size) {
                if (raw[cursor] == b'\\') { cursor += 2; continue }
                if (raw[cursor] == byte) { cursor++; closed = true; break }
                cursor++
            }
            if (!closed) { appendHtmlEscapedValue(out, raw); return }
            className = "code-string"
        } else if (byte == b'/' && cursor + 1 < raw.size && raw[cursor + 1] == b'/') {
            cursor += 2
            while (cursor < raw.size && raw[cursor] != b'\n') { cursor++ }
            className = "code-comment"
        } else if (byte == b'/' && cursor + 1 < raw.size && raw[cursor + 1] == b'*') {
            cursor += 2
            var depth: Int64 = 1
            while (cursor < raw.size && depth > 0) {
                if (cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'*') {
                    depth++; cursor += 2
                } else if (cursor + 1 < raw.size && raw[cursor] == b'*' && raw[cursor + 1] == b'/') {
                    depth--; cursor += 2
                } else { cursor++ }
            }
            if (depth != 0) { appendHtmlEscapedValue(out, raw); return }
            className = "code-comment"
        } else if (htmlCodeWordByte(byte)) {
            cursor++
            while (cursor < raw.size && htmlCodeWordByte(raw[cursor])) { cursor++ }
            className = if (byte >= b'0' && byte <= b'9') {
                "code-number"
            } else { htmlCodeWordClass(raw[start..cursor]) }
        } else { cursor++ }
        if (!className.isEmpty()) {
            appendHtmlEscapedValue(colored, raw[plainStart..start])
            appendHtmlCodeToken(colored, raw[start..cursor], className)
            plainStart = cursor
        }
    }
    appendHtmlEscapedValue(colored, raw[plainStart..])
    out.append(colored.toString())
}
