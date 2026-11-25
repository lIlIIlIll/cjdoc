protected package cjdoc.cli

import cjdoc.filesystem.{
    ensureNoSymbolicLinkAncestors, ensureRegularNonSymlink, pathContains, readFileBounded}
import cjdoc.output.{isSafeOutputPath, prepareOutputAndCacheDirectories}
import cjdoc.model.DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES
import std.collection.*
import std.fs.*
import std.net.*
import std.process.*

internal let SERVE_REQUEST_LIMIT: Int64 = 64 * 1024
internal let SERVE_FILE_LIMIT: Int64 = DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES
internal let SERVE_ACCEPT_TIMEOUT = Some(Duration.second / 4)

internal class ServeSnapshot {
    let entries: HashMap<String, String>
    let paths: ArrayList<String>

    init(entries: HashMap<String, String>, paths: ArrayList<String>) {
        this.entries = entries
        this.paths = paths
    }
}

internal class ServeState {
    var buildCount: Int64 = 0
    var successfulBuildCount: Int64 = 0
    var lastError = ""

    func markBuild(result: Int64): Unit {
        buildCount++
        if (result == 0) {
            successfulBuildCount++
            lastError = ""
        } else {
            lastError = "documentation build failed"
        }
    }

    func markException(): Unit {
        buildCount++
        lastError = "documentation build failed"
    }

    func markFailure(message: String): Unit {
        buildCount++
        lastError = message
    }
}

private func serveWatchedFile(info: FileInfo): Bool {
    if (!info.isRegular() || info.isSymbolicLink() || info.isHidden()) { return false }
    info.name == "cjpm.toml" || info.name == "cjpm.lock" || info.name == "cjdoc.toml" ||
        info.path.extensionName == "cj" || info.path.extensionName == "md"
}
private func servePathMatchesExclusion(path: Path, excludedDirectories: ArrayList<String>): Bool {
    let candidate = canonicalize(path).toString()
    for (excluded in excludedDirectories) {
        if (candidate == excluded) { return true }
    }
    false
}

private func collectServeSnapshotInDirectory(directory: Path, entries: HashMap<String, String>,
    paths: ArrayList<String>, excludedDirectories: ArrayList<String>): Unit {
    for (info in Directory.readFrom(directory)) {
        if (info.isSymbolicLink() || info.isHidden()) { continue }
        if (info.isDirectory()) {
            if (info.name != "target" && info.name != ".git" &&
                !servePathMatchesExclusion(info.path, excludedDirectories)) {
                collectServeSnapshotInDirectory(info.path, entries, paths, excludedDirectories)
            }
            continue
        }
        if (serveWatchedFile(info)) {
            let path = info.path.toString()
            entries[path] = "${info.size}:${info.lastModificationTime.toString()}"
            paths.add(path)
        }
    }
}


private func collectServeSnapshot(root: Path, excludedDirectories: ArrayList<String>): ServeSnapshot {
    let entries = HashMap<String, String>()
    let paths = ArrayList<String>()
    collectServeSnapshotInDirectory(root, entries, paths, excludedDirectories)
    ServeSnapshot(entries, paths)
}

private func serveSnapshotsEqual(first: ServeSnapshot, second: ServeSnapshot): Bool {
    if (first.paths.size != second.paths.size) { return false }
    for (path in first.paths) {
        match (second.entries.get(path)) {
            case Some(value) => match (first.entries.get(path)) {
                case Some(previous) => if (previous != value) { return false }
                case None => return false
            }
            case None => return false
        }
    }
    true
}

private func serveJsonEscape(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case '"' => out.append("\\\"")
            case '\\' => out.append("\\\\")
            case '\n' => out.append("\\n")
            case '\r' => out.append("\\r")
            case '\t' => out.append("\\t")
            case _ => out.append(rune)
        }
    }
    out.toString()
}

private func serveStatusJson(state: ServeState, port: Int64): Array<Byte> {
    let status = if (state.lastError.isEmpty()) { "ok" } else { "error" }
    ("{\"schemaVersion\":\"cjdoc.serve-status/1\",\"status\":\"${status}\",\"port\":${port}," +
        "\"builds\":${state.buildCount},\"successfulBuilds\":${state.successfulBuildCount}," +
        "\"lastError\":\"${serveJsonEscape(state.lastError)}\"}\n").toArray()

}
private func serveContentType(path: String): String {
    if (path.endsWith(".html")) { return "text/html; charset=utf-8" }
    if (path.endsWith(".css")) { return "text/css; charset=utf-8" }
    if (path.endsWith(".js")) { return "text/javascript; charset=utf-8" }
    if (path.endsWith(".json")) { return "application/json; charset=utf-8" }
    if (path.endsWith(".svg")) { return "image/svg+xml" }
    if (path.endsWith(".png")) { return "image/png" }
    if (path.endsWith(".jpg") || path.endsWith(".jpeg")) { return "image/jpeg" }
    if (path.endsWith(".gif")) { return "image/gif" }
    "application/octet-stream"
}

private func serveResponse(socket: TcpSocket, status: String, contentType: String,
    body: Array<Byte>, headOnly!: Bool = false, location!: String = ""): Unit {
    let redirect = if (location.isEmpty()) { "" } else { "Location: ${location}\r\n" }
    let header = "HTTP/1.1 ${status}\r\nContent-Type: ${contentType}\r\n" + redirect +
        "Content-Length: ${body.size}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
    socket.write(header.toArray())
    if (!headOnly) { socket.write(body) }
}

private func serveError(socket: TcpSocket, status: String, message: String, headOnly!: Bool = false): Unit {
    let body = "${status}\n${message}\n".toArray()
    // A client can disconnect after any read or write. Reporting its error is
    // best-effort: another failed write must never escape into the accept loop.
    try {
        serveResponse(socket, status, "text/plain; charset=utf-8", body, headOnly: headOnly)
    } catch (_: Exception) { () }
}

private func readServeRequest(socket: TcpSocket): String {
    let bytes = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    var request = ""
    while (bytes.size < SERVE_REQUEST_LIMIT && !request.contains("\r\n\r\n")) {
        let count = socket.read(buffer)
        if (count <= 0) { break }
        for (byte in buffer[0..count]) { bytes.add(byte) }
        request = String.fromUtf8(bytes.toArray())
    }
    request
}

private func serveHexDigit(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value - b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value - b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value - b'A') + 10 }
    -1
}

private func servePercentDecode(value: String): String {
    let source = value.toArray()
    let decoded = ArrayList<Byte>()
    var index: Int64 = 0
    while (index < source.size) {
        let byte = source[index]
        if (byte != b'%') {
            decoded.add(byte)
            index++
            continue
        }
        if (index + 2 >= source.size) { throw IllegalArgumentException("invalid URL path encoding") }
        let high = serveHexDigit(source[index + 1])
        let low = serveHexDigit(source[index + 2])
        if (high < 0 || low < 0) { throw IllegalArgumentException("invalid URL path encoding") }
        let decodedByte = UInt8(high * 16 + low)
        if (decodedByte == b'/' || decodedByte == b'\\' || decodedByte < 0x20 || decodedByte == 0x7F) {
            throw IllegalArgumentException("unsafe encoded HTTP path byte")
        }
        decoded.add(decodedByte)
        index += 3
    }
    try { String.fromUtf8(decoded.toArray()) } catch (_: Exception) {
        throw IllegalArgumentException("invalid URL path encoding")
    }
}

private struct ServeRequestPath {
    let relative: String
    let headOnly: Bool
    let directory: Bool
    let encodedPath: String
    let query: String

    init(path: String, encodedPath: String, query: String, headOnly: Bool) {
        relative = path.removePrefix("/")
        directory = path.endsWith("/")
        this.encodedPath = encodedPath
        this.query = query
        this.headOnly = headOnly
    }
}

private func serveRequestPath(request: String): ServeRequestPath {
    let lines = request.split("\r\n")
    if (lines.isEmpty()) { throw IllegalArgumentException("empty HTTP request") }
    let fields = lines[0].split(" ")
    if (fields.size != 3 || (fields[0] != "GET" && fields[0] != "HEAD") || fields[2] != "HTTP/1.1") {
        throw IllegalArgumentException("unsupported HTTP request")
    }
    let target = fields[1]
    for (byte in target.toArray()) {
        if (byte <= 0x20 || byte >= 0x7F || byte == b'#') { throw IllegalArgumentException("unsafe HTTP target") }
    }
    let queryOffset = target.indexOf(b'?').getOrDefault({ => target.size })
    let encodedPath = target[0..queryOffset]
    if (!encodedPath.startsWith("/") || encodedPath.startsWith("//") || encodedPath.contains("\\")) {
        throw IllegalArgumentException("unsafe HTTP path")
    }
    let rawPath = servePercentDecode(encodedPath)
    if (!rawPath.startsWith("/") || rawPath.contains("\\") ||
        rawPath.contains("..") || rawPath.contains("\u{0000}")) {
        throw IllegalArgumentException("unsafe HTTP path")
    }
    ServeRequestPath(rawPath, encodedPath, target[queryOffset..target.size], fields[0] == "HEAD")
}

private func serveStaticFile(siteRoot: Path, relative: String): Path {
    if (!isSafeOutputPath(relative)) { throw IllegalArgumentException("unsafe static path") }
    let path = siteRoot.join(relative)
    ensureNoSymbolicLinkAncestors(path, "served artifact")
    ensureRegularNonSymlink(path, "served artifact")
    let canonicalRoot = canonicalize(siteRoot)
    let canonicalPath = canonicalize(path)
    if (!pathContains(canonicalRoot, canonicalPath)) {
        throw IllegalArgumentException("served artifact escaped site root")
    }
    canonicalPath
}

private func serveArtifact(socket: TcpSocket, siteRoot: Path, request: ServeRequestPath): Unit {
    let relative = if (request.directory) { request.relative + "index.html" } else { request.relative }
    let file = try { Some(serveStaticFile(siteRoot, relative)) } catch (_: Exception) { None<Path> }
    if (let Some(path) <- file) {
        let body = try { Some(readFileBounded(path, SERVE_FILE_LIMIT)) } catch (_: Exception) { None<Array<Byte>> }
        if (let Some(content) <- body) {
            serveResponse(socket, "200 OK", serveContentType(relative), content, headOnly: request.headOnly)
            return
        }
    } else if (!request.directory) {
        let hasIndex = try {
            let _ = serveStaticFile(siteRoot, relative + "/index.html")
            true
        } catch (_: Exception) { false }
        if (hasIndex) {
            serveResponse(socket, "308 Permanent Redirect", "text/plain; charset=utf-8", [],
                headOnly: request.headOnly, location: request.encodedPath + "/" + request.query)
            return
        }
    }
    serveError(socket, "404 Not Found", "artifact not found", headOnly: request.headOnly)
}

private func serveClient(socket: TcpSocket, siteRoot: Path, state: ServeState,
    port: Int64): Unit {
    try {
        socket.readTimeout = Some(Duration.second * 5)
        let request = serveRequestPath(readServeRequest(socket))
        if (!request.directory && request.relative == "__cjdoc/status.json") {
            serveResponse(socket, "200 OK", "application/json; charset=utf-8",
                serveStatusJson(state, port), headOnly: request.headOnly)
        } else {
            serveArtifact(socket, siteRoot, request)
        }
    } catch (_: SocketTimeoutException) {
        serveError(socket, "408 Request Timeout", "request timed out")
    } catch (_: Exception) {
        serveError(socket, "400 Bad Request", "bad request")
    } finally {
        try { socket.close() } catch (_: Exception) { () }
    }
}

// One rebuild re-resolves the project configuration from the original command
// line, so [analysis] and [semantic] edits and removals take effect while CLI
// overrides keep winning. The output, cache, and listener stay fixed for the
// session: a change there would write somewhere the running server does not
// serve, so it is rejected with a restart hint and the old site is retained.
private func serveRebuildFromArguments(originalArgs: Array<String>, baselineOutput: String,
    baselineCache: ?String, state: ServeState, rebuild: ServeRebuild): Unit {
    let fresh = try {
        let parsed = reparseServeCommand(originalArgs)
        parsed.command = "generate"
        if (!parsed.formats.contains("html")) { parsed.formats.add("html") }
        parsed
    } catch (_: Exception) {
        state.markFailure("configuration is invalid; fix cjdoc.toml")
        eprintln("serve: configuration is invalid; keeping the last successful site")
        return
    }
    var moved = true
    try {
        let (output, cache) = prepareOutputAndCacheDirectories(
            selectedOutputDirectory(fresh), selectedSourceCacheDirectory(fresh))
        // The session serves one fixed location; a repositioned build would
        // silently publish outside the site this server is expecting.
        moved = !sameServeLocation(output, cache, baselineOutput, baselineCache)
    } catch (_: Exception) { moved = true }
    if (moved) {
        state.markFailure("output or cache location changed; restart serve")
        eprintln("serve: output or cache location changed; restart serve to use it; " +
            "keeping the last successful site")
        return
    }
    serveBuild(fresh, baselineOutput, baselineCache, state, rebuild)
}

private func sameServeLocation(output: String, cache: ?String,
    baselineOutput: String, baselineCache: ?String): Bool {
    if (output != baselineOutput) { return false }
    match ((cache, baselineCache)) {
        case (None, None) => return true
        case (Some(current), Some(previous)) => return current == previous
        case _ => return false
    }
}

private func serveBuild(options: NewCliOptions, output: String, cache: ?String,
    state: ServeState, rebuild: ServeRebuild): Unit {
    try {
        let result = rebuild(options, output, cache, false)
        state.markBuild(result)
        if (result == 0) { eprintln("serve: generated html") }
        else { eprintln("serve: generated html with diagnostics") }
    } catch (_: Exception) {
        state.markException()
        eprintln("serve: rebuild failed; keeping the last successful site")
    }
}

@When[os == "Linux"]
private func serveBrowserCommand(url: String): (String, Array<String>) {
    ("xdg-open", [url])
}

@When[os == "macOS"]
private func serveBrowserCommand(url: String): (String, Array<String>) {
    ("open", [url])
}

@When[os == "Windows"]
private func serveBrowserCommand(url: String): (String, Array<String>) {
    ("cmd.exe", ["/c", "start", "", url])
}

private func launchServeBrowser(url: String): Unit {
    try {
        let (command, arguments) = serveBrowserCommand(url)
        let _ = launch(command, arguments)
    } catch (_: Exception) {
        eprintln("serve: unable to open a browser; visit ${url}")
    }
}


private func serveSnapshotExclusions(output: String, cache: ?String): ArrayList<String> {
    let exclusions = ArrayList<String>()
    exclusions.add(canonicalize(Path(output)).toString())
    match (cache) {
        case Some(path) => exclusions.add(canonicalize(Path(path)).toString())
        case None => ()
    }
    exclusions
}

protected type ServeRebuild = (NewCliOptions, String, ?String, Bool) -> Int64

protected func runServeCommand(options: NewCliOptions, rebuild: ServeRebuild): Int64 {
    let originalCommand = options.command
    options.command = "generate"
    if (!options.formats.contains("html")) { options.formats.add("html") }
    let output = selectedOutputDirectory(options)
    let requestedCache = selectedSourceCacheDirectory(options)
    let (preparedOutput, selectedCache) = prepareOutputAndCacheDirectories(output, requestedCache)
    let siteRoot = Path(preparedOutput).join("html")
    let requestedPort = options.servePort
    let server = TcpServerSocket(bindAt: IPSocketAddress("127.0.0.1", UInt16(requestedPort)))
    try {
        server.reuseAddress = true
        try {
            server.bind()
        } catch (error: SocketException) {
            throw IllegalArgumentException("cannot listen on 127.0.0.1:${requestedPort}: ${error.message}")
        }
        let port = match (server.localAddress) {
            case address: IPSocketAddress => Int64(address.port)
            case _ => throw IllegalStateException("preview listener did not return an IP address")
        }
        let url = "http://127.0.0.1:${port}/"
        let state = ServeState()
        eprintln("serve: ${url}")
        serveBuild(options, preparedOutput, selectedCache, state, rebuild)
        if (options.serveOpen) { launchServeBrowser(url) }
        let excludedDirectories = serveSnapshotExclusions(preparedOutput, selectedCache)
        var snapshot = collectServeSnapshot(canonicalize(Path(options.project)), excludedDirectories)
        while (true) {
            let current = collectServeSnapshot(canonicalize(Path(options.project)), excludedDirectories)
            if (!serveSnapshotsEqual(snapshot, current)) {
                serveRebuildFromArguments(options.serveArgs, preparedOutput, selectedCache, state, rebuild)
                snapshot = current
            }
            try {
                let client = server.accept(timeout: SERVE_ACCEPT_TIMEOUT)
                serveClient(client, siteRoot, state, port)
            } catch (_: SocketTimeoutException) { () }
        }
    } finally {
        try { server.close() } catch (_: Exception) { () }
        options.command = originalCommand
    }
    0
}
