package cjdoc

import std.collection.*
import std.env.*
import yjson.*

@When[os != "Windows"]
import std.posix.{read}

@When[os == "Windows"]
foreign func _read(descriptor: Int32, buffer: CPointer<UInt8>, count: UInt32): Int32

/**
 * Native, read-only Model Context Protocol adapter for the documentation query core.
 *
 * The adapter owns only the stdio transport, the MCP lifecycle and the
 * tools/list, tools/call envelope. Every query decision (field validation,
 * visibility, ranking, pagination, budgets and the readable body) stays in
 * `DocumentationQuerySession.execute`; tool input and output schemas are read
 * from the same schema functions a machine client uses, so this file never
 * maintains a second field whitelist.
 *
 * Transport: newline-delimited UTF-8 JSON-RPC 2.0 on stdin/stdout
 * (MCP 2025-11-25 stdio transport). Lifecycle: `initialize` request, then
 * `notifications/initialized`, then requests. EOF on stdin is a graceful
 * shutdown; no shutdown RPC exists for stdio.
 */

private let MCP_PROTOCOL_VERSION: String = "2025-11-25"
private let MCP_SERVER_NAME: String = "cjdoc"
// Kept in step with cjpm.toml/package version; a future shared version constant
// should replace this literal rather than being duplicated again.
private let MCP_SERVER_VERSION: String = "0.7.7"
private let MCP_SERVER_INSTRUCTIONS: String =
    "Read-only documentation queries over captured cjdoc snapshots. " +
    "Call resolve_docs, search or get_symbol; every tool result is one JSON object " +
    "with schemaVersion cjdoc.query-result/1 and an explicit status."

// A single JSON-RPC message is one line. 1 MiB is far above any request the
// three tools accept (snapshot paths are command-line arguments, not request
// fields), and reading stops buffering at this bound instead of relying on
// readln() to allocate an unbounded line.
private let MCP_REQUEST_LIMIT: Int64 = 1024 * 1024
private let MCP_SCHEMA_LIMIT: Int64 = 8 * 1024 * 1024
// A core result is at most 64 MiB. MCP also carries its encoded text again,
// plus a request id of at most 1 MiB and fixed framing.
private let MCP_RESPONSE_LIMIT: Int64 = 130 * 1024 * 1024
private let MCP_READ_CHUNK_BYTES: Int64 = 16 * 1024
private let MCP_REQUEST_MAX_DEPTH: Int64 = 64
private let MCP_STDIN_DESCRIPTOR: Int32 = 0

private let MCP_JSONRPC_PARSE_ERROR: Int64 = -32700
private let MCP_JSONRPC_INVALID_REQUEST: Int64 = -32600
private let MCP_JSONRPC_METHOD_NOT_FOUND: Int64 = -32601
private let MCP_JSONRPC_INVALID_PARAMS: Int64 = -32602
private let MCP_JSONRPC_INTERNAL_ERROR: Int64 = -32603

private let MCP_QUERY_RESULT_SCHEMA: String = "cjdoc.query-result/1"

private func mcpReadOptions(maxBytes: Int64, maxDepth: Int64): JsonReadOptions {
    JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        maxInputBytes: maxBytes, maxStringBytes: maxBytes,
        maxBufferedValueBytes: maxBytes, maxDepth: maxDepth)
}

/** Tool names are the stable public surface; each maps to one query operation. */
private let MCP_TOOL_OPERATIONS: Array<String> = ["resolve_docs", "search", "get_symbol"]

private func mcpToolTitle(operation: String): String {
    match (operation) {
        case "resolve_docs" => "Resolve documentation"
        case "search" => "Search documentation"
        case _ => "Get symbol documentation"
    }
}

private func mcpToolDescription(operation: String): String {
    match (operation) {
        case "resolve_docs" =>
            "Select captured documentation sets by library, API version, module/package " +
            "or explicit consumer/dependency context. Returns fixed snapshot identities, " +
            "matching evidence, candidates and unknowns. Use search to find symbols."
        case "search" =>
            "Search visible documentation text and identifiers in the loaded snapshots " +
            "and return ranked hits with their documentation identity."
        case _ =>
            "Read the complete documentation record of one visible symbol, optionally " +
            "with sections and one relation expansion."
    }
}

/**
 * Statuses the query core reports as ordinary documentation outcomes: the tool
 * call succeeded, the documentation simply says something other than "one hit".
 */
private func mcpStatusIsDomainSuccess(status: String): Bool {
    match (status) {
        case "ok" => true
        case "ambiguous" => true
        case "not_found" => true
        case "source_incomplete" => true
        case _ => false
    }
}

/** Every other declared status is a tool execution failure, never a success. */
private func mcpKnownStatus(status: String): Bool {
    match (status) {
        case "ok" => true
        case "ambiguous" => true
        case "not_found" => true
        case "source_incomplete" => true
        case "budget_exceeded" => true
        case "stale_cursor" => true
        case "invalid_request" => true
        case "scope_mismatch" => true
        case "resource_limit" => true
        case "unavailable" => true
        case _ => false
    }
}

private func mcpValidRequestId(node: JsonNode): Bool {
    match (node.kind()) {
        case JsonKind.String => true
        case JsonKind.Number => mcpIntegerLiteral(node.asNumberText())
        case _ => false
    }
}

/** Test integrality of an already parsed JSON number, without Float64 rounding. */
private func mcpIntegerLiteral(text: String): Bool {
    if (text.isEmpty()) { return false }
    var index: Int64 = if (text[0] == b'-') { 1 } else { 0 }
    var fractional = false
    var fractionDigits: Int64 = 0
    var trailingZeros: Int64 = 0
    var allZero = true
    while (index < text.size) {
        let byte = text[index]
        if (byte == b'e' || byte == b'E') { break }
        index++
        if (byte == b'.') { fractional = true; continue }
        if (byte < b'0' || byte > b'9') { return false }
        if (fractional) { fractionDigits++ }
        if (byte == b'0') { trailingZeros++ }
        else { trailingZeros = 0; allZero = false }
    }
    if (allZero) { return true }
    let requiredExponent = fractionDigits - trailingZeros
    if (index == text.size) { return requiredExponent <= 0 }
    index++
    var negative = false
    if (index < text.size && (text[index] == b'+' || text[index] == b'-')) {
        negative = text[index] == b'-'
        index++
    }
    if (index == text.size) { return false }
    var exponent: Int64 = 0
    while (index < text.size) {
        let byte = text[index]
        if (byte < b'0' || byte > b'9') { return false }
        // Only comparison with a significand length is needed. Saturating at
        // the input bound preserves exactness and prevents integer overflow.
        if (exponent < MCP_REQUEST_LIMIT) {
            exponent = exponent * 10 + Int64(byte) - Int64(b'0')
            if (exponent > MCP_REQUEST_LIMIT) { exponent = MCP_REQUEST_LIMIT }
        }
        index++
    }
    if (negative) { exponent = -exponent }
    exponent >= requiredExponent
}

private func mcpLineIsBlank(bytes: Array<Byte>): Bool {
    for (byte in bytes) {
        if (byte != b' ' && byte != b'\t' && byte != b'\r') { return false }
    }
    true
}

/**
 * Read one bounded chunk of standard input: > 0 bytes, 0 at EOF, < 0 on error.
 *
 * POSIX `read(2)` is used directly instead of `getStdIn().read(Array<Byte>)`:
 * the std console reader is line-oriented and only returns once the whole
 * requested array is filled, so it would stall on a single small request until
 * the client closed stdin; its C line buffer also reallocates without bound for
 * a long unterminated line.
 */
@When[os != "Windows"]
internal func readDocumentationStdinChunk(buffer: Array<Byte>): Int64 {
    unsafe {
        let handle = acquireArrayRawData(buffer)
        try { Int64(read(MCP_STDIN_DESCRIPTOR, handle.pointer, UIntNative(buffer.size))) } finally {
            releaseArrayRawData(handle)
        }
    }
}

// The CRT descriptor API is bounded on Windows too; ConsoleReader's internal
// line buffering must not allocate an unbounded message before we can reject it.
@When[os == "Windows"]
internal func readDocumentationStdinChunk(buffer: Array<Byte>): Int64 {
    unsafe {
        let handle = acquireArrayRawData(buffer)
        try { Int64(_read(MCP_STDIN_DESCRIPTOR, handle.pointer, UInt32(buffer.size))) } finally {
            releaseArrayRawData(handle)
        }
    }
}

private func mcpStringValue(value: ?JsonNode): String {
    if (value.isNone() || value.getOrThrow().kind() != JsonKind.String) { return "" }
    value.getOrThrow().asString()
}

private func mcpStringField(object: JsonObject, key: String): String {
    let value = object.get(key)
    if (value.isNone() || value.getOrThrow().kind() != JsonKind.String) {
        throw IllegalArgumentException("documentation query result field '${key}' must be a string")
    }
    value.getOrThrow().asString()
}

private func mcpSchemaNode(text: String, operation: String): JsonNode {
    let parsed = JsonNode.parse(text, config: mcpReadOptions(MCP_SCHEMA_LIMIT,
        MCP_REQUEST_MAX_DEPTH))
    if (parsed.kind() != JsonKind.Object) {
        throw IllegalArgumentException("documentation query schema for '${operation}' is not a JSON object")
    }
    parsed
}

private func mcpOptionalSchema(text: String, operation: String): ?JsonNode {
    let parsed: ?JsonNode = try { Some(mcpSchemaNode(text, operation)) } catch (_: Exception) { None }
    parsed
}

/** Validate the tool result contract once; callers then trust the whole object. */
private func mcpQueryResult(object: JsonObject): JsonObject {
    if (mcpStringField(object, "schemaVersion") != MCP_QUERY_RESULT_SCHEMA) {
        throw IllegalArgumentException("documentation query result schemaVersion is not ${MCP_QUERY_RESULT_SCHEMA}")
    }
    let status = mcpStringField(object, "status")
    if (!mcpKnownStatus(status)) {
        throw IllegalArgumentException("documentation query result status '${status}' is not a declared status")
    }
    // Presence and type are contract; the body itself is the core's text and is
    // passed through unchanged, never re-derived or summarized here.
    let _ = mcpStringField(object, "text")
    object
}

private func mcpToolDefinition(operation: String, inputSchema: JsonNode,
    outputSchema: JsonNode): JsonNode {
    let annotations = JsonNode.object()
    annotations.put("readOnlyHint", JsonNode.boolean(true))
    annotations.put("openWorldHint", JsonNode.boolean(false))
    annotations.put("idempotentHint", JsonNode.boolean(true))
    let tool = JsonNode.object()
    tool.put("name", JsonNode.string(operation))
    tool.put("title", JsonNode.string(mcpToolTitle(operation)))
    tool.put("description", JsonNode.string(mcpToolDescription(operation)))
    tool.put("inputSchema", inputSchema)
    tool.put("outputSchema", outputSchema)
    tool.put("annotations", annotations)
    tool
}

/**
 * One stdio MCP server instance over one initialized query session.
 *
 * The session is created before this adapter runs and is used unchanged, so the
 * adapter cannot observe source, SDKs, the network or the project tree.
 */
private class McpServer {
    let session: DocumentationQuerySession
    var negotiated: Bool = false
    var ready: Bool = false
    var writable: Bool = true

    init(session: DocumentationQuerySession) {
        this.session = session
    }

    func serve(): Int64 {
        let chunk = Array<Byte>(MCP_READ_CHUNK_BYTES, repeat: 0)
        let line = ArrayList<Byte>()
        var oversized = false
        while (true) {
            var count = readDocumentationStdinChunk(chunk)
            // A signal may interrupt one read without ending the stream; only a
            // repeated failure is a broken session.
            var retries: Int64 = 0
            while (count < 0 && retries < 3) {
                count = readDocumentationStdinChunk(chunk)
                retries++
            }
            if (count < 0) {
                mcpFatal("cjdoc mcp: standard input could not be read")
                return 1
            }
            if (count == 0) { break }
            var index: Int64 = 0
            while (index < count) {
                let byte = chunk[index]
                index++
                if (byte == b'\n') {
                    if (!acceptLine(line, oversized)) { return 1 }
                    line.clear()
                    oversized = false
                    continue
                }
                if (line.size >= MCP_REQUEST_LIMIT) {
                    oversized = true
                } else {
                    line.add(byte)
                }
            }
        }
        // A client that closes stdin right after an unterminated message still
        // deserves a response; EOF after that is a graceful shutdown.
        if (oversized || !line.isEmpty()) {
            if (!acceptLine(line, oversized)) { return 1 }
        }
        0
    }

    /** A false result means stdout is gone: no later message could reach the client. */
    private func acceptLine(line: ArrayList<Byte>, oversized: Bool): Bool {
        if (oversized) {
            writeError(Option<JsonNode>.None, MCP_JSONRPC_INVALID_REQUEST,
                "request exceeds ${MCP_REQUEST_LIMIT} bytes")
            return writable
        }
        var bytes = line.toArray()
        // Tolerate CRLF clients: only the final CR of the line terminator is
        // removed, so no JSON text can change.
        if (bytes.size > 0 && bytes[bytes.size - 1] == b'\r') {
            bytes = bytes[..bytes.size - 1]
        }
        if (mcpLineIsBlank(bytes)) { return writable }
        let decoded: ?String = try { Some(String.fromUtf8(bytes)) } catch (_: Exception) { None }
        if (decoded.isNone()) {
            writeError(Option<JsonNode>.None, MCP_JSONRPC_PARSE_ERROR, "request is not valid UTF-8")
            return writable
        }
        handleText(decoded.getOrThrow())
        writable
    }

    private func handleText(text: String): Unit {
        let parsed: ?JsonNode = try {
            Some(JsonNode.parse(text, config: mcpReadOptions(MCP_REQUEST_LIMIT,
                MCP_REQUEST_MAX_DEPTH)))
        } catch (_: Exception) { None }
        if (parsed.isNone()) {
            writeError(Option<JsonNode>.None, MCP_JSONRPC_PARSE_ERROR, "request is not valid JSON")
            return
        }
        let root = parsed.getOrThrow()
        if (root.kind() != JsonKind.Object) {
            writeError(Option<JsonNode>.None, MCP_JSONRPC_INVALID_REQUEST,
                "JSON-RPC messages must be single objects; batch requests are not supported")
            return
        }
        dispatch(root.asObject())
    }

    private func dispatch(object: JsonObject): Unit {
        // We never send requests, so a client response (result/error, no method)
        // is a stray; JSON-RPC says to ignore responses with unknown ids.
        if (!object.contains("method") && (object.contains("result") || object.contains("error"))) {
            return
        }

        var id: ?JsonNode = None
        var hasId = false
        let idNode = object.get("id")
        match (idNode) {
            case Some(rawId) =>
                if (!mcpValidRequestId(rawId)) {
                    writeError(Option<JsonNode>.None, MCP_JSONRPC_INVALID_REQUEST,
                        "request id must be a string or an integer")
                    return
                }
                id = Some(rawId)
                hasId = true
            case None => ()
        }

        let methodNode = object.get("method")
        let hasMethod = !methodNode.isNone()
        // A message with a method and no id is a notification: the receiver
        // MUST NOT respond, not even to complain about a malformed one. A
        // message with neither method nor id is an invalid request, which does
        // get an error response with a null id.
        if (!hasId && hasMethod) {
            if (negotiated && mcpStringValue(object.get("jsonrpc")) == "2.0" &&
                mcpStringValue(methodNode) == "notifications/initialized") {
                let params = object.get("params")
                if (params.isNone() || params.getOrThrow().kind() == JsonKind.Object) { ready = true }
            }
            return
        }

        if (mcpStringValue(object.get("jsonrpc")) != "2.0") {
            writeError(id, MCP_JSONRPC_INVALID_REQUEST, "request must declare jsonrpc '2.0'")
            return
        }

        if (!hasMethod || methodNode.getOrThrow().kind() != JsonKind.String) {
            writeError(id, MCP_JSONRPC_INVALID_REQUEST, "request must carry a string method")
            return
        }
        let method = methodNode.getOrThrow().asString()
        if (method.isEmpty()) {
            writeError(id, MCP_JSONRPC_INVALID_REQUEST, "request method must not be empty")
            return
        }

        var params = JsonNode.object()
        let paramsNode = object.get("params")
        if (!paramsNode.isNone()) {
            let value = paramsNode.getOrThrow()
            if (value.kind() != JsonKind.Object) {
                // The params member must be a structured value; this adapter's
                // methods take object parameters only.
                writeError(id, MCP_JSONRPC_INVALID_PARAMS, "params must be an object")
                return
            }
            params = value.asObject()
        }

        // Only requests reach this point; notifications were answered above by
        // silence, as the protocol requires.
        let identifier = id.getOrThrow()
        // No request may crash the server: a handler that could not complete
        // reports a JSON-RPC internal error and the stream keeps serving.
        try {
            route(identifier, method, params)
        } catch (_: Exception) {
            writeError(Some(identifier), MCP_JSONRPC_INTERNAL_ERROR,
                "server failed to process the request")
        }
    }

    private func route(id: JsonNode, method: String, params: JsonObject): Unit {
        if (method == "initialize") {
            handleInitialize(id, params)
            return
        }
        if (method == "ping") {
            writeResult(id, JsonNode.object())
            return
        }
        if (method == "tools/list") {
            if (!ready) {
                writeNotInitialized(id)
                return
            }
            handleToolsList(id, params)
            return
        }
        if (method == "tools/call") {
            if (!ready) {
                writeNotInitialized(id)
                return
            }
            handleToolsCall(id, params)
            return
        }
        writeError(Some(id), MCP_JSONRPC_METHOD_NOT_FOUND, "method not found: ${method}")
    }

    private func writeNotInitialized(id: JsonNode): Unit {
        writeError(Some(id), MCP_JSONRPC_INVALID_REQUEST,
            "server is not ready; send initialize and notifications/initialized first")
    }

    private func handleInitialize(id: JsonNode, params: JsonObject): Unit {
        if (negotiated) {
            writeError(Some(id), MCP_JSONRPC_INVALID_REQUEST,
                "server is already initialized")
            return
        }
        let requested = mcpStringValue(params.get("protocolVersion"))
        if (requested.isEmpty()) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                "initialize requires a string protocolVersion")
            return
        }
        let clientCapabilities = params.get("capabilities")
        let clientInfo = params.get("clientInfo")
        if (clientCapabilities.isNone() || clientCapabilities.getOrThrow().kind() != JsonKind.Object ||
            clientInfo.isNone() || clientInfo.getOrThrow().kind() != JsonKind.Object) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                "initialize requires object capabilities and clientInfo")
            return
        }
        let implementation = clientInfo.getOrThrow().asObject()
        for (field in ["name", "version"]) {
            let value = implementation.get(field)
            if (value.isNone() || value.getOrThrow().kind() != JsonKind.String) {
                writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                    "clientInfo requires string name and version")
                return
            }
        }
        // Version negotiation: answer with the newest version this adapter
        // implements, exactly once, whether or not the client asked for it.
        let toolsCapability = JsonNode.object()
        toolsCapability.put("listChanged", JsonNode.boolean(false))
        let capabilities = JsonNode.object()
        capabilities.put("tools", toolsCapability)
        let serverInfo = JsonNode.object()
        serverInfo.put("name", JsonNode.string(MCP_SERVER_NAME))
        serverInfo.put("version", JsonNode.string(MCP_SERVER_VERSION))
        let result = JsonNode.object()
        result.put("protocolVersion", JsonNode.string(MCP_PROTOCOL_VERSION))
        result.put("capabilities", capabilities)
        result.put("serverInfo", serverInfo)
        result.put("instructions", JsonNode.string(MCP_SERVER_INSTRUCTIONS))
        negotiated = true
        writeResult(id, result)
    }

    private func handleToolsList(id: JsonNode, params: JsonObject): Unit {
        // The tool set is fixed and small: one page, no cursor exists, so any
        // supplied cursor is invalid rather than silently ignored.
        if (params.contains("cursor")) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS, "unknown tools/list cursor")
            return
        }
        let outputSchema = mcpOptionalSchema(documentationQueryOutputSchema(), "output")
        if (outputSchema.isNone()) {
            writeError(Some(id), MCP_JSONRPC_INTERNAL_ERROR,
                "documentation query output schema is unavailable")
            return
        }
        let tools = JsonNode.array()
        for (operation in MCP_TOOL_OPERATIONS) {
            let inputSchema = mcpOptionalSchema(documentationQueryToolSchema(operation), operation)
            if (inputSchema.isNone()) {
                writeError(Some(id), MCP_JSONRPC_INTERNAL_ERROR,
                    "documentation query input schema for '${operation}' is unavailable")
                return
            }
            tools.add(mcpToolDefinition(operation, inputSchema.getOrThrow(),
                outputSchema.getOrThrow()))
        }
        let result = JsonNode.object()
        result.put("tools", tools)
        writeResult(id, result)
    }

    private func handleToolsCall(id: JsonNode, params: JsonObject): Unit {
        let nameValue = mcpStringValue(params.get("name"))
        if (nameValue.isEmpty()) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                "tools/call requires a tool name")
            return
        }
        var known = false
        for (operation in MCP_TOOL_OPERATIONS) {
            if (operation == nameValue) { known = true }
        }
        if (!known) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS, "unknown tool: ${nameValue}")
            return
        }
        var arguments = JsonNode.object()
        let argumentsNode = params.get("arguments")
        if (!argumentsNode.isNone()) {
            let value = argumentsNode.getOrThrow()
            if (value.kind() != JsonKind.Object) {
                writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                    "tool arguments must be an object")
                return
            }
            arguments = value.asObject()
        }
        // The operation is derived from the tool name, never from the client:
        // the input schema deliberately omits it. The children are detached by
        // being placed in a new object; no query field is inspected here.
        if (arguments.contains("operation")) {
            writeError(Some(id), MCP_JSONRPC_INVALID_PARAMS,
                "tool arguments must not contain operation; it is selected by the tool name")
            return
        }
        let request = JsonNode.object()
        for (index in 0..arguments.size()) {
            request.put(arguments.nameAt(index), arguments.valueAt(index))
        }
        request.put("operation", JsonNode.string(nameValue))
        let executed: ?String = try {
            Some(session.execute(request.toString()))
        } catch (_: Exception) { None }
        if (executed.isNone()) {
            writeError(Some(id), MCP_JSONRPC_INTERNAL_ERROR,
                "documentation query execution failed")
            return
        }
        let parsedResult: ?JsonObject = try {
            Some(mcpQueryResult(queryDecodeResponse(executed.getOrThrow())))
        } catch (_: Exception) { None }
        if (parsedResult.isNone()) {
            writeError(Some(id), MCP_JSONRPC_INTERNAL_ERROR,
                "documentation query returned a result outside ${MCP_QUERY_RESULT_SCHEMA}")
            return
        }
        let queryResult = parsedResult.getOrThrow()
        let status = mcpStringField(queryResult, "status")
        let body = mcpStringField(queryResult, "text")
        // The visible text is the core's own readable body (scope, status and
        // completeness cues included); the structured object is the complete
        // result, so both views always agree.
        let textContent = JsonNode.object()
        textContent.put("type", JsonNode.string("text"))
        textContent.put("text", JsonNode.string(body))
        let content = JsonNode.array()
        content.add(textContent)
        let toolResult = JsonNode.object()
        toolResult.put("content", content)
        toolResult.put("structuredContent", queryResult)
        toolResult.put("isError", JsonNode.boolean(!mcpStatusIsDomainSuccess(status)))
        writeResult(id, toolResult)
    }

    private func writeResult(id: JsonNode, result: JsonNode): Unit {
        let response = JsonNode.object()
        response.put("jsonrpc", JsonNode.string("2.0"))
        // A validated request id is a string or integer scalar, which has no
        // mutable children, so echoing the same node cannot alias container
        // state between the request and the response.
        response.put("id", id)
        response.put("result", result)
        writeMessage(response.toJson(options: JsonWriteOptions(
            maxOutputBytes: MCP_RESPONSE_LIMIT, maxDepth: 512)))
    }

    private func writeError(id: ?JsonNode, code: Int64, message: String): Unit {
        let error = JsonNode.object()
        error.put("code", JsonNode.int64(code))
        error.put("message", JsonNode.string(message))
        let response = JsonNode.object()
        response.put("jsonrpc", JsonNode.string("2.0"))
        if (id.isNone()) {
            response.put("id", JsonNode.nullValue)
        } else {
            response.put("id", id.getOrThrow())
        }
        response.put("error", error)
        writeMessage(response.toJson(options: JsonWriteOptions(
            maxOutputBytes: MCP_RESPONSE_LIMIT, maxDepth: 512)))
    }

    /** Exactly one complete message per write; stdout carries nothing else. */
    private func writeMessage(message: String): Unit {
        if (!writable) { return }
        try {
            let output = getStdOut()
            // One write per message keeps concurrent readers from seeing a
            // partial line; compact JSON cannot contain a raw newline.
            output.write(message + "\n")
            output.flush()
        } catch (_: Exception) {
            writable = false
        }
    }
}

private func mcpFatal(message: String): Unit {
    try {
        let error = getStdErr()
        error.write(message + "\n")
        error.flush()
    } catch (_: Exception) { return }
}

/**
 * Serve the documentation query session over the MCP 2025-11-25 stdio
 * transport until the client closes stdin. Returns 0 for a graceful EOF, and 1
 * when standard input cannot be read or the client's stdout disappears, since
 * in both cases the protocol session itself is broken.
 */
internal func runDocumentationMcp(session: DocumentationQuerySession): Int64 {
    McpServer(session).serve()
}
