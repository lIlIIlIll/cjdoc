package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func appendCodeHighlight(out: StringBuilder, value: CodeHighlight): Unit {
    out.append("{\"language\":${escapeJsonString(value.language)},")
    out.append("\"sourceHash\":${escapeJsonString(value.sourceHash)},\"byteLength\":${value.byteLength},")
    out.append("\"engineId\":${escapeJsonString(value.engineId)},")
    out.append("\"engineRevision\":${escapeJsonString(value.engineRevision)},")
    out.append("\"state\":${escapeJsonString(value.state)},\"reason\":")
    match (value.reason) {
        case Some(reason) => out.append(escapeJsonString(reason))
        case None => out.append("null")
    }
    out.append(",\"spans\":[")
    var first = true
    for (span in value.spans) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"startByte\":${span.startByte},\"endByte\":${span.endByte},")
        out.append("\"kind\":${escapeJsonString(span.kind)}}")
    }
    out.append("]}")
}

internal func decodeCodeHighlight(node: JsonNode, path: String): CodeHighlight {
    let value = strictObject(node, path, ["language", "sourceHash", "byteLength", "engineId",
        "engineRevision", "state", "reason", "spans"])
    let spans = ArrayList<CodeSpan>()
    let items = arrayAt(value, "spans", path)
    for (index in 0..items.size()) {
        let spanPath = "${path}.spans[${index}]"
        let span = strictObject(items.get(index).getOrThrow(), spanPath,
            ["startByte", "endByte", "kind"])
        try {
            spans.add(CodeSpan(intAt(span, "startByte", spanPath),
                intAt(span, "endByte", spanPath), stringAt(span, "kind", spanPath)))
        } catch (error: IllegalArgumentException) { domainFail(spanPath, error.message) }
    }
    // Persisted highlights may be stale. Source hash/length matching belongs only
    // at render consumption (matchesSource), where mismatches fall back to plain.
    // The immutable constructor owns span/kind/state/reason validation.
    try {
        CodeHighlight(stringAt(value, "language", path), stringAt(value, "sourceHash", path),
            intAt(value, "byteLength", path), stringAt(value, "engineId", path),
            stringAt(value, "engineRevision", path), stringAt(value, "state", path),
            nullableStringAt(value, "reason", path), spans.toArray())
    } catch (error: IllegalArgumentException) { domainFail(path, error.message) }
}

internal func optionalCodeHighlightAt(value: JsonObject, key: String,
    path: String): ?CodeHighlight {
    match (value.get(key)) {
        case Some(node) => Some(decodeCodeHighlight(node, "${path}.${key}"))
        case None => None
    }
}

internal func optionalExampleMarkdownAt(value: JsonObject, path: String, legacy: Bool,
    assetReferences: HashMap<String, String>): ?MarkdownNode {
    match (value.get("exampleMarkdown")) {
        case Some(node) => Some(decodeMarkdown(node, "${path}.exampleMarkdown", 0,
            legacy, assetReferences))
        case None => None
    }
}

internal func consumeCodeHighlightEncoding(value: CodeHighlight, path: String,
    jsonDepth: Int64, budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path, depth: jsonDepth, fields: 8)
    budget.consumeString(value.language, "${path}.language")
    budget.consumeString(value.sourceHash, "${path}.sourceHash")
    budget.consumeString(value.engineId, "${path}.engineId")
    budget.consumeString(value.engineRevision, "${path}.engineRevision")
    budget.consumeString(value.state, "${path}.state")
    budget.consumeOptionalString(value.reason, "${path}.reason")
    budget.consumeCollection(value.spans.size, "${path}.spans", depth: jsonDepth + 1)
    var index: Int64 = 0
    for (span in value.spans) {
        let spanPath = "${path}.spans[${index}]"
        budget.consumeObject(spanPath, depth: jsonDepth + 2, fields: 3)
        budget.consumeString(span.kind, "${spanPath}.kind")
        index++
    }
}

private func markdownContainsCode(value: MarkdownNode): Bool {
    if (value.kind == "code_block") { return true }
    for (child in value.children) {
        if (markdownContainsCode(child)) { return true }
    }
    false
}

internal func validateExampleMarkdown(value: DocTag, path: String): Unit {
    match (value.exampleMarkdown) {
        case Some(markdown) =>
            if (value.name != "example" || markdown.kind != "document") {
                domainFail(path, "example Markdown requires an @example tag and a document root")
            }
            validateMarkdown(markdown, path, 0)
            if (!markdownContainsCode(markdown)) {
                domainFail(path, "example Markdown must contain code")
            }
        case None => ()
    }
}
