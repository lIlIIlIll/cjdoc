package cjdoc

import std.collection.*

private func chirTomlCode(line: String): String {
    let bytes = line.toArray()
    var quoteByte: UInt8 = 0u8
    var escaped = false
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (quoteByte != 0u8) {
            if (quoteByte == b'"' && escaped) {
                escaped = false
            } else if (quoteByte == b'"' && byte == b'\\') {
                escaped = true
            } else if (byte == quoteByte) {
                quoteByte = 0u8
            }
        } else if (byte == b'"' || byte == b'\'') {
            quoteByte = byte
        } else if (byte == b'#') {
            return String.fromUtf8(bytes[..index]).trimAscii()
        }
        index++
    }
    line.trimAscii()
}

private func chirCompileOptionArrayClosed(value: String): Bool {
    var quoteByte: UInt8 = 0u8
    var escaped = false
    for (index in 0..value.size) {
        let byte = value[index]
        if (quoteByte != 0u8) {
            if (quoteByte == b'"' && escaped) { escaped = false }
            else if (quoteByte == b'"' && byte == b'\\') { escaped = true }
            else if (byte == quoteByte) { quoteByte = 0u8 }
        } else if (byte == b'"' || byte == b'\'') {
            quoteByte = byte
        } else if (byte == b']') {
            return true
        }
    }
    false
}

private func chirManifestKey(raw: String): ?String {
    let key = raw.trimAscii()
    if (key.isEmpty() || (key[0] != b'"' && key[0] != b'\'')) { return Some(key) }
    let decoded = decodeTomlString(key, 0)
    if (decoded.invalid || decoded.nextOffset != key.size) { return None }
    decoded.value
}

internal func chirManifestUnsupportedReason(manifest: ?String): ?String {
    match (manifest) {
        case None => None
        case Some(text) =>
            var continuedOptions = false
            for (line in text.split("\n")) {
                let trimmed = chirTomlCode(line)
                if (continuedOptions) {
                    if (!chirCompileOptionValueSupported(trimmed)) {
                        return Some("CHIR rejects unsupported compiler options in cjpm.toml")
                    }
                    continuedOptions = !chirCompileOptionArrayClosed(trimmed)
                    continue
                }
                if (trimmed == "[features]" || trimmed.startsWith("[package-configuration") ||
                    trimmed == "[build]") {
                    return Some("CHIR does not support this cjpm manifest section")
                }
                match (tomlAssignmentEquals(trimmed)) {
                    case Some(index) =>
                        let key = match (chirManifestKey(trimmed[..index])) {
                            case Some(value) => value
                            case None => return Some("CHIR cannot safely represent a quoted cjpm manifest key")
                        }
                        let value = trimmed[index + 1..].trimAscii()
                        if (key == "compile-option" || key == "override-compile-option") {
                            if (!chirCompileOptionValueSupported(value)) {
                                return Some("CHIR rejects unsupported compiler options in cjpm.toml")
                            }
                            continuedOptions = value.startsWith("[") &&
                                !chirCompileOptionArrayClosed(value)
                        }
                    case None => ()
                }
            }
            if (continuedOptions) {
                return Some("CHIR rejects an unterminated compiler-option array in cjpm.toml")
            }
            None
    }
}

private func chirCompileOptionValueSupported(value: String): Bool {
    if (value.isEmpty() || value == "[]" || value == "\"\"" || value == "''") { return true }
    let allowed = ["-O0", "-O1", "-O2", "-O3", "-g", "--static", "--static-libs",
        "CJDOC_STDX_LINK_OPTIONS", "-lstdc++", "-lgcc_s"]
    let bytes = value.toArray()
    for (byte in bytes) {
        if (byte == b'\n' || byte == b'\r') { return false }
    }
    let tokens = ArrayList<String>()
    var start: Int64 = 0
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte == b' ' || byte == b'\t' || byte == b'[' || byte == b']' ||
            byte == b',' || byte == b'"' || byte == b'\'') {
            if (index > start) { tokens.add(String.fromUtf8(bytes[start..index])) }
            start = index + 1
        }
        index++
    }
    if (start < bytes.size) { tokens.add(String.fromUtf8(bytes[start..])) }
    for (token in tokens) {
        var known = false
        for (candidate in allowed) {
            if (token == candidate) { known = true; break }
        }
        if (!known) { return false }
    }
    true
}
