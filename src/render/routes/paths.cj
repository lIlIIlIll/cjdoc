protected package cjdoc.render.routes

import cjdoc.model.*

internal func appendSlugByte(out: StringBuilder, byte: Byte): Unit {
    let digits = "0123456789abcdef"
    let high = Int64((byte >> 4) & 0x0F)
    let low = Int64(byte & 0x0F)
    out.append(digits[high..high + 1])
    out.append(digits[low..low + 1])
}

protected func htmlStableSlug(value: String): String {
    if (value.isEmpty()) { return "root" }
    let out = StringBuilder()
    for (byte in value.toArray()) { appendSlugByte(out, byte) }
    out.toString()
}

protected func stableFileHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

protected func boundedHtmlSlug(value: String): String {
    // Keep staged Windows paths below MAX_PATH after the transaction prefix.
    let slug = htmlStableSlug(value)
    if (slug.size <= 96) { return slug }
    slug[..64] + "--" + stableFileHash(value)
}

protected func routeKey(moduleId: String, packageName: String): String {
    "${moduleId.size}:${moduleId}${packageName}"
}

protected func historicalPackagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.html"
}

// Historical flat route, also retained verbatim as the v18 local-link evidence.
protected func symbolPagePath(symbol: SymbolDoc): String {
    historicalSymbolPagePath(symbol.id)
}

protected func historicalSymbolPagePath(symbolId: String): String {
    "symbols/symbol-${boundedHtmlSlug(symbolId)}.html"
}

// Historical readable slug. Never use it as a new publication destination.
protected func symbolReadablePagePath(symbol: SymbolDoc): String {
    let name = StringBuilder()
    var length: Int64 = 0
    var separator = false
    for (byte in symbol.qualifiedName.toArray()) {
        if (length >= 48) { break }
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_') {
            if (separator && length > 0) {
                if (length + 2 > 48) { break }
                name.append("-"); length++
            }
            name.append(String.fromUtf8([byte]))
            length++
            separator = false
        } else { separator = true }
    }
    let readable = if (length == 0) { "api" } else { name.toString() }
    "symbols/${readable}-${stableFileHash(symbol.id)}.html"
}

protected func symbolAnchor(symbol: SymbolDoc): String {
    "symbol-${htmlStableSlug(symbol.id)}"
}

// Prebound document-root paths are rebased; absolute web URLs stay absolute.
protected func navigationHref(rootPrefix: String, url: String): ?String {
    if (url.isEmpty() || url.contains("\\")) { return None }
    for (byte in url.toArray()) {
        if (byte <= 0x20 || byte == 0x7F || byte == b'"' || byte == b'<' || byte == b'>') { return None }
    }
    if (url.startsWith("https://") || url.startsWith("http://")) {
        return if (isSafeAbsoluteDocumentationUrl(url)) { Some(url) } else { None }
    }
    let relative = url.removePrefix("./")
    let path = relative.split("#", 2)[0].split("?", 2)[0]
    if (!safeRelativePath(path) || !isSafeDocumentationRoute(relative)) { return None }
    Some(rootPrefix + relative)
}

// This exact form is the v18 evidence for a captured local declaration.
protected func isCapturedLocalApiLink(value: TypeNavigation): Bool {
    value.state == "resolved" && value.matchLevel == "exact" &&
        value.documentSetId.isEmpty() && value.dependencyInstanceId.isEmpty() &&
        value.symbolKey.startsWith("cjdoc:v2:") &&
        value.url == historicalSymbolPagePath(value.symbolKey)
}

// Only a default-language API body can live outside its own resource tree.
protected func publicApiRootPrefix(resourcePrefix: String, unprefixedLocale: String): String {
    if (unprefixedLocale.isEmpty()) { return resourcePrefix }
    let directory = unprefixedLocale + "/"
    if (resourcePrefix.endsWith(directory)) {
        resourcePrefix.removeSuffix(directory)
    } else { resourcePrefix + "../" }
}

protected func safeRelativePath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.endsWith("/") ||
        value.contains("//") || value.contains("\\")) { return false }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    let first = segments[0].toArray()
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'A' && first[0] <= b'Z') ||
        (first[0] >= b'a' && first[0] <= b'z'))) {
        return false
    }
    true
}

protected func label(locale: String, english: String, chinese: String): String {
    if (locale == "zh-CN") { chinese } else { english }
}
