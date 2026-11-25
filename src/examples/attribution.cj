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
    protected let bodyBlocks: Array<String>
    protected let contextBlocks: Array<String>

    init(bodyBlocks: Array<String>, contextBlocks: Array<String>) {
        this.bodyBlocks = bodyBlocks
        this.contextBlocks = contextBlocks
    }

    protected prop hasBodyFailure: Bool { get() { !bodyBlocks.isEmpty() } }
    protected prop hasContextFailure: Bool { get() { !contextBlocks.isEmpty() } }

    // Source excerpts and related notes are not the compiler error message.
    protected func bodyMessageContains(expected: String): Bool {
        for (block in bodyBlocks) {
            let end = block.indexOf("\n") ?? block.size
            if (block[..end].contains(expected)) { return true }
        }
        false
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
    while (index > 0) {
        index--
        if (bytes[index] == b':') { columnSeparator = index; break }
    }
    if (columnSeparator <= 0) { return None }
    var lineSeparator: Int64 = -1
    index = columnSeparator
    while (index > 0) {
        index--
        if (bytes[index] == b':') { lineSeparator = index; break }
    }
    if (lineSeparator <= 0) { return None }
    let column = parseLocationNumber(value[columnSeparator + 1..]) ?? 0
    if (column <= 0) { return None }
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

private func diagnosticSeverity(line: String): Int64 {
    if (line.startsWith("error:") || line.startsWith("fatal:")) { return 2 }
    if (line.startsWith("warning:") || line.startsWith("note:")) { return 1 }
    0
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
        let severity = diagnosticSeverity(line)
        if (severity > 0) {
            appendAttributedBlock(bodyBlocks, contextBlocks, lines, generatedLabel,
                bodyStartLine, bodyEndLine)
            lines.clear()
            if (severity == 2) { lines.add(line) }
        } else if (line == EXAMPLE_COMPILER_OUTPUT_TRUNCATED) {
            contextBlocks.add(line)
        } else if (!lines.isEmpty()) {
            lines.add(line)
        }
    }
    appendAttributedBlock(bodyBlocks, contextBlocks, lines, generatedLabel,
        bodyStartLine, bodyEndLine)
    ExampleCompileAttribution(bodyBlocks.toArray(), contextBlocks.toArray())
}
