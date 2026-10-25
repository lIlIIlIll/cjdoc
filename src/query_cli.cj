package cjdoc

import std.collection.*
import std.fs.*
import yjson.*

private class DocumentationReadCommand {
    let snapshots = ArrayList<String>()
    var request: ?String = None
}

private func parseDocumentationReadCommand(args: Array<String>): DocumentationReadCommand {
    let options = DocumentationReadCommand()
    var index: Int64 = 1
    while (index < args.size) {
        let name = args[index]
        if ((name != "--snapshot" && name != "--request") || index + 1 >= args.size) {
            throw DocumentationQueryException("invalid_request", "read_command_option",
                "Read commands accept repeated --snapshot paths and query accepts one --request path or '-'.")
        }
        let value = args[index + 1]
        if (value.isEmpty()) { throw IllegalArgumentException("read command paths must not be empty") }
        if (name == "--snapshot") {
            options.snapshots.add(value)
        } else {
            if (args[0] != "query" || options.request.isSome()) {
                throw DocumentationQueryException("invalid_request", "request_option",
                    "Only query accepts one --request path or '-'.")
            }
            options.request = Some(value)
        }
        index += 2
    }
    if (options.snapshots.isEmpty() || options.snapshots.size > 64) {
        throw DocumentationQueryException("invalid_request", "snapshot_count",
            "Read commands require 1..64 explicit --snapshot inputs.")
    }
    if (args[0] == "query" && options.request.isNone()) {
        throw DocumentationQueryException("invalid_request", "request_required", "query requires --request <file|->.")
    }
    options
}

private func readDocumentationQueryStdin(): String {
    let bytes = ArrayList<Byte>()
    let chunk = Array<Byte>(4096, repeat: 0)
    while (true) {
        var count = readDocumentationStdinChunk(chunk)
        var retries: Int64 = 0
        while (count < 0 && retries < 3) { count = readDocumentationStdinChunk(chunk); retries++ }
        if (count < 0) { throw IllegalArgumentException("query standard input could not be read") }
        if (count == 0) { break }
        if (count > QUERY_INPUT_BYTES - bytes.size) {
            throw DocumentationQueryException("invalid_request", "request_byte_limit", "Query request exceeds 1 MiB UTF-8 bytes.")
        }
        for (index in 0..count) { bytes.add(chunk[index]) }
    }
    String.fromUtf8(bytes.toArray())
}

private func readDocumentationQueryRequest(path: String): String {
    if (path == "-") { return readDocumentationQueryStdin() }
    let input = Path(path)
    ensureNoSymbolicLinkAncestors(input, "query request")
    readTextBounded(input, QUERY_INPUT_BYTES)
}

private func documentationReadCliFailure(command: String, status: String, code: String,
    message: String): Int64 {
    if (command == "mcp") {
        eprintln("cjdoc mcp: " + message)
        return if (status == "invalid_request") { 2 } else { 3 }
    }
    let result = queryFailureResult(JsonNode.object(), ArrayList<QuerySnapshotInput>(),
        "cjdoc:catalog:v1:" + Sha256Digest.digest(""), status, code, message)
    let exitCode = documentationQueryExitCode(result)
    println(result)
    exitCode
}

internal func runDocumentationReadCli(args: Array<String>): Int64 {
    try {
        let options = parseDocumentationReadCommand(args)
        // Loading explicit captured bytes is the only startup I/O. This path is
        // deliberately before generation, output locks, cache and SDK preflight.
        let session = DocumentationQuerySession(options.snapshots.toArray())
        if (args[0] == "mcp") { return runDocumentationMcp(session) }
        let request = readDocumentationQueryRequest(options.request.getOrThrow())
        let result = session.execute(request)
        let exitCode = documentationQueryExitCode(result)
        println(result)
        exitCode
    } catch (error: DocumentationQueryException) {
        documentationReadCliFailure(args[0], error.status, error.code, error.message)
    } catch (error: IllegalArgumentException) {
        let message = if (args[0] == "mcp") {
            "The captured read input is invalid: " + error.message
        } else {
            "An explicit read-command path, request or captured documentation value is invalid."
        }
        documentationReadCliFailure(args[0], "invalid_request", "read_command_input", message)
    } catch (_: Exception) {
        documentationReadCliFailure(args[0], "unavailable", "snapshot_io",
            "An explicit frozen documentation input could not be loaded.")
    }
}
