protected package cjdoc.cli

import cjdoc.digest.Sha256Digest
import cjdoc.filesystem.{ensureNoSymbolicLinkAncestors, readTextBounded}
import cjdoc.query.{DocumentationQueryException, QUERY_INPUT_BYTES, queryStartupFailure}
import std.collection.*
import std.fs.*

private class DocumentationReadCommand {
    let snapshots = ArrayList<String>()
    var request: ?String = None
}

private func parseDocumentationReadCommand(args: Array<String>): DocumentationReadCommand {
    let options = DocumentationReadCommand()
    var index: Int64 = 1
    while (index < args.size) {
        let name = args[index]
        if (name != "--snapshot" && name != "--request") {
            throw DocumentationQueryException("invalid_request", "read_command_option",
                "${name} is not valid for ${args[0]}.")
        }
        if (index + 1 >= args.size) {
            throw DocumentationQueryException("invalid_request", "read_command_option", "${name} requires a path.")
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
    message: String, exitCode: (String) -> Int64): Int64 {
    if (command == "mcp") {
        eprintln("cjdoc mcp: " + message)
        return if (status == "invalid_request") { 2 } else { 3 }
    }
    let result = queryStartupFailure("cjdoc:catalog:v1:" + Sha256Digest.digest(""), status, code, message)
    let exit = exitCode(result)
    println(result)
    exit
}

/**
 * Run one captured read command (`query` or `mcp`).
 *
 * The caller supplies the frozen query entry point and the published exit-status
 * function, so this transport layer never opens a session itself, never decides
 * what a result status means, and never reaches generation, output locking, a
 * cache or SDK preflight.
 */
protected func runDocumentationReadCli(args: Array<String>,
    open: (Array<String>) -> (String) -> String, exitCode: (String) -> Int64): Int64 {
    try {
        let options = parseDocumentationReadCommand(args)
        // Loading explicit captured bytes is the only startup I/O. This path is
        // deliberately before generation, output locks, cache and SDK preflight.
        let execute = open(options.snapshots.toArray())
        if (args[0] == "mcp") { return runDocumentationMcp(execute) }
        let request = readDocumentationQueryRequest(options.request.getOrThrow())
        let result = execute(request)
        let exit = exitCode(result)
        println(result)
        exit
    } catch (error: DocumentationQueryException) {
        documentationReadCliFailure(args[0], error.status, error.code, error.message, exitCode)
    } catch (error: IllegalArgumentException) {
        let message = if (args[0] == "mcp") {
            "The captured read input is invalid: " + error.message
        } else {
            "An explicit read-command path, request or captured documentation value is invalid."
        }
        documentationReadCliFailure(args[0], "invalid_request", "read_command_input", message,
            exitCode)
    } catch (_: Exception) {
        documentationReadCliFailure(args[0], "unavailable", "snapshot_io",
            "An explicit frozen documentation input could not be loaded.", exitCode)
    }
}
