protected package cjdoc.examples

import std.collection.*
import std.convert.Parsable

// `cjc` reports every diagnostic as a headline line plus an `==>` location line.
// Attributing a failure to the example body therefore means reading that location,
// not asking whether the output mentions the generated file at all: the generated
// file also carries the package clause and the captured imports, and those are the
// declaring package's context, not the example.
private let ATTRIBUTION_LOCATION_PREFIX = "==>"

protected class ExampleCompileAttribution {
    let bodyBlocks: Array<String>
    let contextBlocks: Array<String>

    init(bodyBlocks: Array<String>, contextBlocks: Array<String>) {
        this.bodyBlocks = bodyBlocks
        this.contextBlocks = contextBlocks
    }

    prop hasBodyFailure: Bool { get() { !bodyBlocks.isEmpty() } }
    prop hasContextFailure: Bool { get() { !contextBlocks.isEmpty() } }

    // Only body diagnostics may satisfy `failureContains`; a message produced by
    // an import, an option or another context file can never satisfy a pin.
    func bodyText(): String {
        let out = StringBuilder()
        var first = true
        for (block in bodyBlocks) {
            if (!first) { out.append("\n") }
            out.append(block)
            first = false
        }
        out.toString()
    }
}

private func parseLocationNumber(value: String): ?Int64 {
    if (value.isEmpty()) { return None }
    for (byte in value.toArray()) {
        if (byte < b'0' || byte > b'9') { return None }
    }
    try { Some(Int64.parse(value)) } catch (_: Exception) { None }
}

// Splits `<file>:line:column` from the right, so a Windows drive letter or a path
// segment containing colons keeps its path intact.
private func parseDiagnosticLocation(value: String): ?(String, Int64) {
    let bytes = value.toArray()
    var columnSeparator: Int64 = -1
    var index = bytes.size
    var separators = 0
    while (index > 0) {
        index--
        if (bytes[index] != b':') { continue }
        separators++
        if (separators == 2) { columnSeparator = index; break }
    }
    if (columnSeparator <= 0) { return None }
    var lineSeparator: Int64 = -1
    index = columnSeparator
    while (index > 0) {
        index--
        if (bytes[index] == b':') { lineSeparator = index; break }
    }
    if (lineSeparator <= 0) { return None }
    let line = match (parseLocationNumber(value[lineSeparator + 1..columnSeparator])) {
        case Some(found) => found
        case None => return None
    }
    let path = value[..lineSeparator]
    if (path.isEmpty() || line <= 0) { return None }
    Some((path, line))
}

private func blockLocation(block: String): ?(String, Int64) {
    for (line in block.split("\n")) {
        let trimmed = line.trimAscii()
        if (!trimmed.startsWith(ATTRIBUTION_LOCATION_PREFIX)) { continue }
        var location = trimmed[ATTRIBUTION_LOCATION_PREFIX.size..].trimAscii()
        if (location.endsWith(":")) { location = location[..location.size - 1] }
        return parseDiagnosticLocation(location)
    }
    None
}

// Header lines (package clause, captured imports, the wrapper signature) belong to
// the declaring package even though `cjc` reports them under the generated file.
private func blockBelongsToBody(block: String, generatedLabel: String,
    bodyStartLine: Int64, bodyEndLine: Int64): Bool {
    if (bodyStartLine <= 0 || bodyEndLine < bodyStartLine) { return false }
    let (path, line) = match (blockLocation(block)) {
        case Some(value) => value
        case None => return false
    }
    path == generatedLabel && bodyStartLine <= line && line <= bodyEndLine
}

private func startsDiagnosticReport(line: String): Bool {
    let trimmed = line.trimAscii()
    trimmed.startsWith("error:") || trimmed.startsWith("fatal:")
}

private func appendAttributedBlock(bodyBlocks: ArrayList<String>,
    contextBlocks: ArrayList<String>, lines: ArrayList<String>, generatedLabel: String,
    bodyStartLine: Int64, bodyEndLine: Int64): Unit {
    if (lines.isEmpty()) { return }
    let builder = StringBuilder()
    var first = true
    for (line in lines) {
        if (!first) { builder.append("\n") }
        builder.append(line)
        first = false
    }
    let block = builder.toString().trimAscii()
    if (block.isEmpty()) { return }
    if (blockBelongsToBody(block, generatedLabel, bodyStartLine, bodyEndLine)) {
        bodyBlocks.add(block)
    } else {
        contextBlocks.add(block)
    }
}

protected func attributeExampleCompilerOutput(outputText: String,
    bodyStartLine: Int64, bodyEndLine: Int64, generatedLabel!: String = "<generated-example>"):
    ExampleCompileAttribution {
    let bodyBlocks = ArrayList<String>()
    let contextBlocks = ArrayList<String>()
    let lines = ArrayList<String>()
    for (line in outputText.split("\n")) {
        if (startsDiagnosticReport(line)) {
            appendAttributedBlock(bodyBlocks, contextBlocks, lines, generatedLabel,
                bodyStartLine, bodyEndLine)
            lines.clear()
            lines.add(line)
        } else if (!lines.isEmpty()) {
            lines.add(line)
        }
    }
    appendAttributedBlock(bodyBlocks, contextBlocks, lines, generatedLabel,
        bodyStartLine, bodyEndLine)
    ExampleCompileAttribution(bodyBlocks.toArray(), contextBlocks.toArray())
}
