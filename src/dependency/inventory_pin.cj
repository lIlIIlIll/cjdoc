protected package cjdoc.dependency

protected func validateInventoryPin(path: String, sha256: String): Unit {
    if (path.trimAscii().isEmpty() || path.contains("\u{0}") || sha256.size != 64) {
        throw IllegalArgumentException("inventory pin requires a path and lowercase SHA-256")
    }
    var index: Int64 = 0
    while (index < sha256.size) {
        let byte = sha256[index]
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
            throw IllegalArgumentException("inventory pin requires a lowercase SHA-256")
        }
        index++
    }
}
