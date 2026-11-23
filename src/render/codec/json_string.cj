protected package cjdoc.render.codec

import cjdoc.render.foundation.RenderTextBuffer
// Search index JSON strings are emitted both standalone and inline inside a
// <script> element: every caller shares one escaping rule. `<`, `>`, `&`
// become JSON string escapes so a value containing
// `</script>` or `<script>` can never terminate the element or execute: the
// client decodes them back to the original characters before matching.
protected func appendSearchJsonString(out: RenderTextBuffer, value: String): Unit {
    let digits = "0123456789abcdef"
    out.append("\"")
    for (rune in value.runes()) {
        match (rune) {
            case '"' => out.append("\\\"")
            case '\\' => out.append("\\\\")
            case '\u{0008}' => out.append("\\b")
            case '\u{000c}' => out.append("\\f")
            case '\n' => out.append("\\n")
            case '\r' => out.append("\\r")
            case '\t' => out.append("\\t")
            case '<' => out.append("\\u003c")
            case '>' => out.append("\\u003e")
            case '&' => out.append("\\u0026")
            case _ =>
                let code = UInt32(rune)
                if (code < 0x20u32) {
                    out.append("\\u")
                    out.append(digits[Int64((code >> 12) & 0xFu32)..
                        Int64((code >> 12) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 8) & 0xFu32)..
                        Int64((code >> 8) & 0xFu32) + 1])
                    out.append(digits[Int64((code >> 4) & 0xFu32)..
                        Int64((code >> 4) & 0xFu32) + 1])
                    out.append(digits[Int64(code & 0xFu32)..Int64(code & 0xFu32) + 1])
                } else { out.append(rune) }
        }
    }
    out.append("\"")
}

protected func appendOptionalSearchString(out: RenderTextBuffer, value: ?String): Unit {
    match (value) {
        case Some(text) => appendSearchJsonString(out, text)
        case None => out.append("null")
    }
}
