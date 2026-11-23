protected package cjdoc.documentation.comments

import cjdoc.source.SourceLocation
import std.collection.*

// Maps one cleaned comment line back to its byte position inside the raw comment.
// Both the base parser and the localization pass need the same mapping, so it is
// defined once here instead of being restated by each consumer.
protected class LocalizedCommentLineMap {
    let row: Int64
    let columnOffset: Int64
    let text: String
    init(row: Int64, columnOffset: Int64, text: String) {
        this.row = row; this.columnOffset = columnOffset; this.text = text
    }
}

private func leadingCommentWhitespace(value: String): Int64 {
    var index: Int64 = 0
    for (byte in value.toArray()) {
        if (byte != b' ' && byte != b'\t' && byte != b'\r' && byte != b'\n') { break }
        index++
    }
    index
}

protected func localizedCommentRows(raw: String): Array<LocalizedCommentLineMap> {
    let result = ArrayList<LocalizedCommentLineMap>()
    let leading = leadingCommentWhitespace(raw)
    var content = raw.trimAscii()
    var sourceLineStart = leading
    var row: Int64 = 0
    for (byte in raw[..leading].toArray()) { if (byte == b'\n') { row++ } }
    var lineBase = sourceLineStart
    if (content.startsWith("/**")) {
        content = content.removePrefix("/**")
        sourceLineStart += 3
    }
    if (content.endsWith("*/")) { content = content.removeSuffix("*/") }
    var started = false
    for (sourceLine in content.split("\n")) {
        var line = sourceLine.trimAsciiEnd()
        var columnOffset = sourceLineStart - lineBase
        var prefix: Int64 = 0
        while (prefix < line.size && (line[prefix] == b' ' || line[prefix] == b'\t')) { prefix++ }
        if (prefix < line.size && line[prefix] == b'*') {
            columnOffset += prefix + 1
            line = line[prefix + 1..]
            if (line.startsWith(" ")) { line = line.removePrefix(" "); columnOffset++ }
        } else {
            columnOffset += prefix
            line = line[prefix..]
        }
        if (started || !line.isEmpty()) {
            result.add(LocalizedCommentLineMap(row, columnOffset, line))
            started = true
        }
        sourceLineStart += sourceLine.size + 1
        lineBase = sourceLineStart
        row++
    }
    while (!result.isEmpty() && result[result.size - 1].text.isEmpty()) { result.remove(at: result.size - 1) }
    result.toArray()
}

protected func localizedLineRange(source: ?SourceLocation, rows: Array<LocalizedCommentLineMap>,
    line: Int64): ?SourceLocation {
    if (line >= rows.size) { return None }
    match (source) {
        case None => None
        case Some(origin) =>
            let mapping = rows[line]
            var markerOffset = mapping.text.size
            if (let Some(index) <- mapping.text.indexOf("@")) { markerOffset = index }
            let startOffset = mapping.columnOffset + markerOffset
            let endOffset = mapping.columnOffset + mapping.text.size
            let startLine = origin.startLine + mapping.row
            let startColumn = if (mapping.row == 0) { origin.startColumn + startOffset } else { startOffset + 1 }
            let endColumn = if (mapping.row == 0) { origin.startColumn + endOffset } else { endOffset + 1 }
            Some(SourceLocation(origin.path, startLine, startColumn, startLine, endColumn))
    }
}
