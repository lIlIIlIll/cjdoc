protected package cjdoc.manifest

protected func metadataHeaderCandidate(path: String): Bool {
    let value = path.trimAscii()
    if (value.startsWith("metadata")) {
        if (value.size == 8) { return true }
        let next = value[8]
        return next == b'.' || next == b' ' || next == b'\t' || next == b']'
    }
    if (!value.isEmpty() && (value[0] == b'"' || value[0] == b'\'')) {
        let decoded = decodeTomlString(value, 0)
        if (!decoded.invalid && decoded.value.isSome()) {
            return decoded.value.getOrThrow() == "metadata"
        }
        return value.startsWith("\"metadata") || value.startsWith("'metadata")
    }
    false
}
