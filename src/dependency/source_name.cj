protected package cjdoc.dependency

protected func safeDependencyLogicalName(name: String): Bool {
    if (name.isEmpty()) { return false }
    var segmentBytes: Int64 = 0
    for (byte in name.toArray()) {
        if (byte == b'.') {
            if (segmentBytes == 0) { return false }
            segmentBytes = 0
            continue
        }
        let allowed = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-'
        if (!allowed) { return false }
        segmentBytes++
    }
    segmentBytes > 0
}

protected func validateDependencySourceName(name: String): Unit {
    if (!safeDependencyLogicalName(name)) {
        throw IllegalArgumentException("dependency name must use non-empty ASCII alphanumeric, '_' or '-' dot-separated segments")
    }
}
