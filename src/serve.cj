package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.net.*
import std.process.*

internal let SERVE_REQUEST_LIMIT: Int64 = 64 * 1024
internal let SERVE_FILE_LIMIT: Int64 = 32 * 1024 * 1024
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
}

private func serveWatchedFile(info: FileInfo): Bool {
    if (!info.isRegular() || info.isSymbolicLink() || info.isHidden()) { return false }
    info.name == "cjpm.toml" || info.name == "cjpm.lock" || info.name == "cjdoc.toml" ||
        info.path.extensionName == "cj" || info.path.extensionName == "md"
}

private func collectServeSnapshotInDirectory(directory: Path, entries: HashMap<String, String>,
    paths: ArrayList<String>): Unit {
    for (info in Directory.readFrom(directory)) {
        if (info.isSymbolicLink() || info.isHidden()) { continue }
        if (info.isDirectory()) {
            if (info.name != "target" && info.name != ".git") {
                collectServeSnapshotInDirectory(info.path, entries, paths)
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

private func collectServeSnapshot(root: Path): ServeSnapshot {
    let entries = HashMap<String, String>()
    let paths = ArrayList<String>()
    collectServeSnapshotInDirectory(root, entries, paths)
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
    body: Array<Byte>, headOnly!: Bool = false): Unit {
    let header = "HTTP/1.1 ${status}\r\nContent-Type: ${contentType}\r\n" +
        "Content-Length: ${body.size}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
    socket.write(header.toArray())
    if (!headOnly) { socket.write(body) }
}

private func serveError(socket: TcpSocket, status: String, message: String): Unit {
    let body = "${status}\n${message}\n".toArray()
    serveResponse(socket, status, "text/plain; charset=utf-8", body)
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
        decoded.add(UInt8(high * 16 + low))
        index += 3
    }
    try { String.fromUtf8(decoded.toArray()) } catch (_: Exception) {
        throw IllegalArgumentException("invalid URL path encoding")
    }
}

private func serveRequestPath(request: String): (String, Bool, Bool) {
    let lines = request.split("\r\n")
    if (lines.isEmpty()) { throw IllegalArgumentException("empty HTTP request") }
    let fields = lines[0].split(" ")
    if (fields.size != 3 || (fields[0] != "GET" && fields[0] != "HEAD") || fields[2] != "HTTP/1.1") {
        throw IllegalArgumentException("unsupported HTTP request")
    }
    let encodedPath = fields[1].split("?")[0]
    if (!encodedPath.startsWith("/") || encodedPath.contains("\\") ||
        encodedPath.contains("\u{0000}")) {
        throw IllegalArgumentException("unsafe HTTP path")
    }
    let rawPath = servePercentDecode(encodedPath)
    if (!rawPath.startsWith("/") || rawPath.contains("\\") ||
        rawPath.contains("..") || rawPath.contains("\u{0000}")) {
        throw IllegalArgumentException("unsafe HTTP path")
    }
    let relative = if (rawPath == "/") { "index.html" } else { rawPath[1..].toString() }
    (relative, fields[0] == "HEAD", true)
}

private func serveStaticPath(siteRoot: Path, relative: String): Array<Byte> {
    if (!isSafeOutputPath(relative)) { throw IllegalArgumentException("unsafe static path") }
    let path = siteRoot.join(relative)
    ensureRegularNonSymlink(path, "served artifact")
    let canonicalRoot = canonicalize(siteRoot)
    let canonicalPath = canonicalize(path)
    if (!pathContains(canonicalRoot, canonicalPath)) {
        throw IllegalArgumentException("served artifact escaped site root")
    }
    readFileBounded(canonicalPath, SERVE_FILE_LIMIT)
}

private func serveClient(socket: TcpSocket, siteRoot: Path, state: ServeState,
    port: Int64): Unit {
    socket.readTimeout = Some(Duration.second * 5)
    try {
        let request = readServeRequest(socket)
        let (relative, headOnly, _) = serveRequestPath(request)
        if (relative == "__cjdoc/status.json") {
            serveResponse(socket, "200 OK", "application/json; charset=utf-8",
                serveStatusJson(state, port), headOnly: headOnly)
        } else {
            try {
                let body = serveStaticPath(siteRoot, relative)
                serveResponse(socket, "200 OK", serveContentType(relative), body, headOnly: headOnly)
            } catch (_: Exception) {
                serveError(socket, "404 Not Found", "artifact not found")
            }
        }
    } catch (_: SocketTimeoutException) {
        serveError(socket, "408 Request Timeout", "request timed out")
    } catch (_: Exception) {
        serveError(socket, "400 Bad Request", "bad request")
    }
    try { socket.close() } catch (_: Exception) { () }
}

private func serveBuild(options: NewCliOptions, output: String, cache: ?String,
    state: ServeState): Unit {
    try {
        let result = withOutputLockResultGuard(output, { lock =>
            executeDocumentCommand(options, Some(output), cache, Some(lock), writeOnFailure: false)
        })
        state.markBuild(result)
        if (result == 0) { eprintln("serve: generated html") }
        else { eprintln("serve: generated html with diagnostics") }
    } catch (_: Exception) {
        state.markException()
        eprintln("serve: rebuild failed; keeping the last successful site")
    }
}

private func launchServeBrowser(port: Int64): Unit {
    try {
        let _ = launch("xdg-open", ["http://127.0.0.1:${port}/"])
    } catch (_: Exception) {
        eprintln("serve: unable to open a browser; visit http://127.0.0.1:${port}/")
    }
}

internal func runServeCommand(options: NewCliOptions): Int64 {
    let originalCommand = options.command
    options.command = "generate"
    if (!options.formats.contains("html")) { options.formats.add("html") }
    let output = selectedOutputDirectory(options)
    let requestedCache = selectedSourceCacheDirectory(options)
    let (preparedOutput, selectedCache) = prepareOutputAndCacheDirectories(output, requestedCache)
    let siteRoot = Path(preparedOutput).join("html")
    let port = options.servePort
    let server = TcpServerSocket(bindAt: IPSocketAddress("127.0.0.1", UInt16(port)))
    server.reuseAddress = true
    server.bind()
    let state = ServeState()
    eprintln("serve: http://127.0.0.1:${port}/")
    serveBuild(options, preparedOutput, selectedCache, state)
    if (options.serveOpen) { launchServeBrowser(port) }
    var snapshot = collectServeSnapshot(Path(options.project))
    try {
        while (true) {
            let current = collectServeSnapshot(Path(options.project))
            if (!serveSnapshotsEqual(snapshot, current)) {
                serveBuild(options, preparedOutput, selectedCache, state)
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
