package cjdoc

import std.collection.*
import std.env.*
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
    private var worker: ?HighlightWorkerProcess = None
    private var starts: Int64 = 0
    private var requestNumber: Int64 = 0
    private var closed: Bool = false

    func close(): Unit {
        closed = true
        resetWorker()
    }

    private func resetWorker(): Unit {
        if (let Some(active) <- worker) { active.close() }
        worker = None
    }

    func exchange(request: String): String {
        if (closed || Thread.currentThread.hasPendingCancellation) {
            close()
            throw IllegalStateException("highlight session closed or cancelled")
        }
        try {
            if (worker.isNone()) {
                if (starts >= 3) { throw IllegalStateException("highlight restart limit") }
                starts++
                // Allow only process essentials; never inherit NODE_OPTIONS, NODE_PATH,
                // loader/preload settings, credentials or project environment hooks.
                let environment = HashMap<String, String>()
                for (name in ["PATH", "SystemRoot", "WINDIR", "TEMP", "TMP", "TMPDIR", "LANG"]) {
                    if (let Some(value) <- getVariable(name)) { environment[name] = value }
                }
                worker = Some(HighlightWorkerProcess(nodeExecutable, [adapterPath], environment))
            }
            worker.getOrThrow().exchange(request, { => Thread.currentThread.hasPendingCancellation })
        } catch (error: Exception) { resetWorker(); throw error }
    }

    func nextId(): String { requestNumber++; requestNumber.toString() }

    func rejectResponse(): Unit { resetWorker() }

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
    let id = options.nextId()
    let request = "{\"protocol\":\"${EXTERNAL_HIGHLIGHT_PROTOCOL}\",\"id\":${escapeJsonString(id)}," +
        "\"language\":${escapeJsonString(language)},\"code\":${escapeJsonString(source)}}\n"
    if (request.size > EXTERNAL_HIGHLIGHT_INPUT_BYTES + 1) {
        return externalHighlightPlain(source, language, "resource-limit")
    }
    try {
        let result = validateExternalHighlightResponse(source, language, id, options.exchange(request))
        if (result.reason == Some("backend-unavailable") || result.reason == Some("invalid-spans")) {
            options.rejectResponse()
        }
        result
    } catch (_: Exception) { externalHighlightPlain(source, language, "backend-unavailable") }
}
