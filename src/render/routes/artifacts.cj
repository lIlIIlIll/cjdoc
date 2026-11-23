protected package cjdoc.render.routes

import cjdoc.model.*
import cjdoc.render.foundation.RenderTextBuffer

private func routeByteAllowed(byte: Byte, extra: String): Bool {
    if ((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'.' ||
        byte == b'_' || byte == b'~' || byte == b'/') { return true }
    for (candidate in extra.toArray()) {
        if (candidate == byte) { return true }
    }
    false
}

protected func percentEncodeRouteComponent(value: String, allowedExtra: String): String {
    let digits = "0123456789ABCDEF"
    let out = RenderTextBuffer()
    for (byte in value.toArray()) {
        let allowed = routeByteAllowed(byte, allowedExtra)
        if (allowed) {
            out.append(String.fromUtf8([byte]))
        } else {
            let high = Int64((byte >> 4) & 0x0F)
            let low = Int64(byte & 0x0F)
            out.append("%")
            out.append(digits[high..high + 1])
            out.append(digits[low..low + 1])
        }
    }
    out.toString()
}

protected func markdownPackagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.md"
}

protected func markdownSymbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.md"
}

protected func agentDeclarationMarkdownPath(symbol: SymbolDoc): String {
    "agent/" + markdownSymbolPagePath(symbol)
}

protected func agentDeclarationJsonPath(symbol: SymbolDoc): String {
    "agent/symbols/symbol-${boundedHtmlSlug(symbol.id)}.json"
}

protected func agentPageMarkdownPath(page: DocumentationPage): String {
    "agent/pages/page-${boundedHtmlSlug(page.id)}.md"
}

protected func agentPageJsonPath(page: DocumentationPage): String {
    "agent/pages/page-${boundedHtmlSlug(page.id)}.json"
}

protected func agentPackageMarkdownPath(moduleId: String, name: String): String {
    "agent/packages/package-${boundedHtmlSlug(moduleId + ":" + name)}.md"
}

protected func agentPackageJsonPath(moduleId: String, name: String): String {
    "agent/packages/package-${boundedHtmlSlug(moduleId + ":" + name)}.json"
}

// Stable anchor for a documented member block, also used by the search index.
protected func docBlockAnchor(symbol: SymbolDoc, block: String): String {
    symbolAnchor(symbol) + "--" + block
}
