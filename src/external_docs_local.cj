package cjdoc

/**
 * Explicit, output-root-relative independent documentation. This namespace
 * never grants network access or accepts filesystem paths. Both the base and
 * index entries use unescaped ASCII URL segments, with no parent traversal.
 */
internal func safeLocalExternalPath(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (part in value.split("/")) {
        if (part.isEmpty() || part == "." || part == "..") { return false }
        for (byte in part.toArray()) {
            if (!((byte >= b'a' && byte <= b'z') ||
                (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') ||
                byte == b'-' || byte == b'_' || byte == b'.' || byte == b'~')) {
                return false
            }
        }
    }
    true
}

internal func safeLocalExternalBaseUrl(value: String): Bool {
    value.startsWith("./") && safeLocalExternalPath(value.removePrefix("./"))
}

internal func safeLocalExternalHref(baseUrl: String, href: String): ?String {
    if (!safeLocalExternalBaseUrl(baseUrl) || !safeLocalExternalPath(href)) { return None }
    // The native index exports standalone type/member pages. Fragments,
    // authority overrides, encoded components and arbitrary protocols are not
    // accepted by this deliberately separate, local-only extension.
    Some(baseUrl + "/" + href)
}
