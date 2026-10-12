package cjdoc

import std.collection.*
import cjdoc.render.{escapeJsonString}
import yjson.*

internal let EXTERNAL_HIGHLIGHT_PROTOCOL = "cjdoc-highlight/1"
internal let EXTERNAL_HIGHLIGHT_ENGINE = "highlight.js"
internal let EXTERNAL_HIGHLIGHT_REVISION = "11.11.1/cjdoc-map-1"
internal let EXTERNAL_HIGHLIGHT_INPUT_BYTES: Int64 = 2097152
internal let EXTERNAL_HIGHLIGHT_OUTPUT_BYTES: Int64 = 3145728

internal class HighlightExternalOptions {
    let nodeExecutable: String
    let adapterPath: String

    init(nodeExecutable: String, adapterPath: String) {
        for (path in [nodeExecutable, adapterPath]) {
            if (path.trimAscii().isEmpty() || !highlightHostPathIsAbsolute(path) || path.contains("\u{0}")) {
                throw IllegalArgumentException("highlight host paths must be non-empty absolute paths")
            }
        }
        this.nodeExecutable = nodeExecutable
        this.adapterPath = adapterPath
    }
}

internal func highlightExternalOptions(adapter: ?String, node: ?String): ?HighlightExternalOptions {
    if (adapter.isNone() && node.isNone()) { return None }
    if (adapter.isNone() || node.isNone()) {
        throw IllegalArgumentException("highlightAdapter and highlightNode must be supplied together")
    }
    Some(HighlightExternalOptions(node.getOrThrow(), adapter.getOrThrow()))
}

private func externalHighlightPlain(source: String, language: String, reason: String): CodeHighlight {
    CodeHighlight(source, language, [], CodeHighlightState.Plain, Some(reason),
        engineId: EXTERNAL_HIGHLIGHT_ENGINE, engineRevision: EXTERNAL_HIGHLIGHT_REVISION)
}

private func externalHighlightObject(node: JsonNode, keys: Array<String>): JsonObject {
    let object = node.asObject()
    for (index in 0..object.size()) {
        if (!keys.contains(object.nameAt(index))) { throw IllegalArgumentException("invalid-spans") }
    }
    object
}

private func externalHighlightKind(name: String): CodeKind {
    match (name) {
        case "keyword" => CodeKind.Keyword
        case "type" => CodeKind.Type
        case "string" => CodeKind.StringLiteral
        case "number" => CodeKind.Number
        case "literal" => CodeKind.Literal
        case "comment" => CodeKind.Comment
        case "operator" => CodeKind.Operator
        case "punctuation" => CodeKind.Punctuation
        case "function" => CodeKind.Function
        case "property" => CodeKind.Property
        case "meta" => CodeKind.Meta
        case _ => throw IllegalArgumentException("invalid-spans")
    }
}

private func externalHighlightReason(value: JsonObject, state: String): ?String {
    let reason = match (value.get("reason")) {
        case None => None<String>
        case Some(node) => Some(node.asString())
    }
    if (state == "complete") {
        if (reason.isSome()) { throw IllegalArgumentException("invalid-spans") }
        return None
    }
    match (reason.getOrThrow()) {
        case "unsupported-language" => Some("unsupported")
        case "resource-limit" => Some("resource-limit")
        case "invalid-spans" => Some("invalid-spans")
        case "malformed-json" | "invalid-request" => Some("backend-unavailable")
        case _ => throw IllegalArgumentException("invalid-spans")
    }
}

internal func validateExternalHighlightResponse(source: String, language: String,
    requestId: String, response: String): CodeHighlight {
    try {
        if (response.size > EXTERNAL_HIGHLIGHT_OUTPUT_BYTES + 1 || !response.endsWith("\n") ||
            response[..response.size - 1].contains("\n")) {
            return externalHighlightPlain(source, language, "backend-unavailable")
        }
        let root = JsonNode.parse(response, config: JsonReadOptions(
            duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 4,
            maxStringBytes: 256, maxInputBytes: EXTERNAL_HIGHLIGHT_OUTPUT_BYTES + 1,
            maxBufferedValueBytes: EXTERNAL_HIGHLIGHT_OUTPUT_BYTES + 1))
        let value = externalHighlightObject(root,
            ["protocol", "id", "language", "engine", "state", "reason", "byteLength", "sourceHash", "spans"])
        let engine = externalHighlightObject(value["engine"], ["id", "revision"])
        if (value["protocol"].asString() != EXTERNAL_HIGHLIGHT_PROTOCOL ||
            value["id"].asString() != requestId || value["language"].asString() != language ||
            engine["id"].asString() != EXTERNAL_HIGHLIGHT_ENGINE ||
            engine["revision"].asString() != EXTERNAL_HIGHLIGHT_REVISION) {
            return externalHighlightPlain(source, language, "backend-unavailable")
        }
        if (value["byteLength"].asInt64() != source.size ||
            value["sourceHash"].asString() != Sha256Digest.digest(source)) {
            return externalHighlightPlain(source, language, "invalid-spans")
        }
        let state = value["state"].asString()
        if (state != "complete" && state != "plain") { throw IllegalArgumentException("invalid-spans") }
        let reason = externalHighlightReason(value, state)
        let array = value["spans"].asArray()
        if (array.size() > MAX_HIGHLIGHT_SPANS_PER_BLOCK || (state == "plain" && array.size() != 0)) {
            throw IllegalArgumentException("invalid-spans")
        }
        let spans = ArrayList<CodeSpan>()
        for (index in 0..array.size()) {
            let span = externalHighlightObject(array.get(index).getOrThrow(), ["startByte", "endByte", "kind"])
            spans.add(CodeSpan(span["startByte"].asInt64(), span["endByte"].asInt64(),
                externalHighlightKind(span["kind"].asString())))
        }
        CodeHighlight(source, language, spans.toArray(),
            if (state == "complete") { CodeHighlightState.Complete } else { CodeHighlightState.Plain }, reason,
            engineId: EXTERNAL_HIGHLIGHT_ENGINE, engineRevision: EXTERNAL_HIGHLIGHT_REVISION)
    } catch (_: Exception) { externalHighlightPlain(source, language, "invalid-spans") }
}

internal func externalCodeHighlight(source: String, language: String, options: HighlightExternalOptions): CodeHighlight {
    if (source.size > MAX_HIGHLIGHT_BLOCK_BYTES) { return externalHighlightPlain(source, language, "resource-limit") }
    // One request per isolated process: no worker state, retries or transient-result cache.
    let id = Sha256Digest.digest(language + "\n" + source)
    let request = "{\"protocol\":\"${EXTERNAL_HIGHLIGHT_PROTOCOL}\",\"id\":${escapeJsonString(id)}," +
        "\"language\":${escapeJsonString(language)},\"code\":${escapeJsonString(source)}}\n"
    if (request.size > EXTERNAL_HIGHLIGHT_INPUT_BYTES + 1) {
        return externalHighlightPlain(source, language, "resource-limit")
    }
    try {
        let (exitCode, output, _) = executeWithBoundedOutput(options.nodeExecutable, [options.adapterPath],
            timeoutMilliseconds: 5000, standardInput: request.toArray(),
            outputLimit: EXTERNAL_HIGHLIGHT_OUTPUT_BYTES + 2)
        if (exitCode != 0) { return externalHighlightPlain(source, language, "backend-unavailable") }
        validateExternalHighlightResponse(source, language, id, String.fromUtf8(output))
    } catch (_: Exception) { externalHighlightPlain(source, language, "backend-unavailable") }
}
