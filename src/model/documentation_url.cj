package cjdoc.model

import std.collection.*

private func documentationUrlHex(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') { return Int64(byte - b'0') }
    if (byte >= b'A' && byte <= b'F') { return Int64(byte - b'A') + 10 }
    if (byte >= b'a' && byte <= b'f') { return Int64(byte - b'a') + 10 }
    -1
}

private func safeDocumentationUrlComponent(value: String, fragment: Bool): Bool {
    if (value.isEmpty()) { return false }
    var decoded: ?ArrayList<Byte> = None
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (byte == b'%') {
            if (index + 2 >= value.size) { return false }
            let high = documentationUrlHex(value[index + 1]); let low = documentationUrlHex(value[index + 2])
            if (high < 0 || low < 0) { return false }
            let actual = UInt8(high * 16 + low)
            if (actual < 0x80) { return false }
            if (decoded.isNone()) {
                let buffer = ArrayList<Byte>()
                for (prefix in 0..index) { buffer.add(value[prefix]) }
                decoded = Some(buffer)
            }
            decoded.getOrThrow().add(actual); index += 3; continue
        }
        if (byte <= 0x20 || byte == 0x7F || byte == b'\\' || byte == b'?' || byte == b'#' ||
            byte == b'/' || byte == b'@' || byte == b'<' || byte == b'>' || byte == b'"' || byte == b'\'') { return false }
        if (byte == b':' && !fragment) { return false }
        if (let Some(buffer) <- decoded) { buffer.add(byte) }
        index++
    }
    if (let Some(buffer) <- decoded) {
        try { let _ = String.fromUtf8(buffer.toArray()) } catch (_: Exception) { return false }
    }
    value != "." && value != ".."
}

private func safeDocumentationQueryAtom(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_' ||
            byte == b'.' || byte == b'~')) { return false }
    }
    true
}

private func safeDocumentationUrlQuery(value: String): Bool {
    let fields = value.split("&", 33)
    if (fields.size > 32) { return false }
    let names = HashSet<String>()
    for (field in fields) {
        let pair = field.split("=", 3)
        if (pair.size != 2 || !safeDocumentationQueryAtom(pair[0]) ||
            !safeDocumentationQueryAtom(pair[1]) || !names.add(pair[0])) { return false }
    }
    true
}

/** Pure route validation shared by inventory binding and persisted navigation consumers. */
public func isSafeDocumentationRoute(value: String): Bool {
    let parts = value.split("#", 2)
    if (parts.size == 2 && !safeDocumentationUrlComponent(parts[1], true)) { return false }
    let route = parts[0].split("?", 2)
    if (route.size == 2 && !safeDocumentationUrlQuery(route[1])) { return false }
    if (route[0].isEmpty() || route[0].startsWith("/")) { return false }
    for (segment in route[0].split("/")) {
        if (!safeDocumentationUrlComponent(segment, false)) { return false }
    }
    true
}

/** Supported HTTP(S) navigation profile; not a claim about remote hosting authenticity. */
public func isSafeAbsoluteDocumentationUrl(value: String, allowFragment!: Bool = true,
    allowQuery!: Bool = true): Bool {
    if (!value.startsWith("https://") && !value.startsWith("http://")) { return false }
    let fragmentParts = value.split("#", 2)
    if (fragmentParts.size == 2 && (!allowFragment || !safeDocumentationUrlComponent(fragmentParts[1], true))) { return false }
    let offset: Int64 = if (value.startsWith("https://")) { 8 } else { 7 }
    let parts = fragmentParts[0][offset..].split("/", 2)
    let authority = parts[0].split(":")
    if (authority.isEmpty() || authority.size > 2 || authority[0].isEmpty()) { return false }
    for (segment in authority[0].split(".")) {
        if (segment.isEmpty() || segment.startsWith("-") || segment.endsWith("-")) { return false }
        for (byte in segment.toArray()) {
            if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'-')) { return false }
        }
    }
    if (authority.size == 2) {
        var port: Int64 = 0
        if (authority[1].isEmpty() || authority[1].size > 5) { return false }
        for (byte in authority[1].toArray()) {
            if (byte < b'0' || byte > b'9') { return false }
            port = port * 10 + Int64(byte - b'0')
        }
        if (port < 1 || port > 65535) { return false }
    }
    if (parts.size == 2 && !parts[1].isEmpty()) {
        let pathAndQuery = parts[1].split("?", 2)
        if (pathAndQuery.size == 2 && (!allowQuery || !safeDocumentationUrlQuery(pathAndQuery[1]))) { return false }
        let path = pathAndQuery[0]
        let route = if (path.endsWith("/")) { path[..path.size - 1] } else { path }
        if (!route.isEmpty() && !isSafeDocumentationRoute(route)) { return false }
    }
    true
}
