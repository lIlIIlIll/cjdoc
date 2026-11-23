protected package cjdoc.render.reading

import cjdoc.model.*

/** Returns a level only for a structurally usable captured admonition node. */
protected func capturedAdmonitionLevel(node: MarkdownNode): ?String {
    if (node.kind != "admonition" || !node.literal.isEmpty() || node.children.isEmpty()) {
        return None
    }
    match (node.metadata) {
        case Some(metadata) =>
            if (metadata.kind == "admonition") {
                match (metadata.admonitionLevel) {
                    case Some(level) => if (isAdmonitionLevel(level)) { Some(level) } else { None }
                    case None => None
                }
            } else { None }
        case None => None
    }
}

protected func capturedAdmonitionTreeContains(node: MarkdownNode, level: String): Bool {
    if (capturedAdmonitionLevel(node) == Some(level)) { return true }
    for (child in node.children) {
        if (capturedAdmonitionTreeContains(child, level)) { return true }
    }
    false
}

protected func capturedAdmonitionMarkdownMarker(level: String): ?String {
    match (level) {
        case "note" => Some("NOTE")
        case "warning" => Some("WARNING")
        case "danger" => Some("CAUTION")
        case _ => None
    }
}

protected class ExampleFenceOpening {
    protected let marker: String
    protected let length: Int64
    protected let language: String
    protected let info: String

    init(marker: String, length: Int64, language: String, info: String) {
        this.marker = marker
        this.length = length
        this.language = language
        this.info = info
    }
}

protected func trimExampleBlankLines(value: String): String {
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

protected func exampleFenceLineValue(line: String): ?String {
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

protected func exampleFenceOpening(line: String): ?ExampleFenceOpening {
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
    ExampleFenceOpening(marker, length, language, info)
}

protected func isExampleFenceClosing(line: String, fence: ExampleFenceOpening): Bool {
    let value = match (exampleFenceLineValue(line)) {
        case Some(candidate) => candidate
        case None => return false
    }
    if (!value.startsWith(fence.marker)) { return false }
    var length: Int64 = 0
    while (length < value.size && value[length] == fence.marker[0]) { length++ }
    length >= fence.length && value[length..].trimAscii().isEmpty()
}
