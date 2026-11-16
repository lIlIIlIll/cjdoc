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
            var inPackage = true
            for (line in text.split("\n")) {
                let trimmed = chirTomlCode(line)
                if (continuedOptions) {
                    if (!chirCompileOptionValueSupported(trimmed, allowLanguageOptions: inPackage)) {
                        return Some("CHIR rejects unsupported compiler options in cjpm.toml")
                    }
                    continuedOptions = !chirCompileOptionArrayClosed(trimmed)
                    continue
                }
                if (trimmed.startsWith("[")) { inPackage = trimmed == "[package]" }
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
                            if (!chirCompileOptionValueSupported(value, allowLanguageOptions: inPackage)) {
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

// Only language switches need forwarding. CHIR owns output and compilation phase
// options; the previously accepted optimization/link options keep that policy.
private func chirLanguageOption(value: String): Bool {
    value == "--experimental" || value == "--enable-local-mode"
}

private func chirCompileOptionValueSupported(value: String, allowLanguageOptions!: Bool): Bool {
    let allowed = ["-O0", "-O1", "-O2", "-O3", "-g", "--static", "--static-libs",
        "CJDOC_STDX_LINK_OPTIONS", "-lstdc++", "-lgcc_s"]
    for (byte in value.toArray()) {
        if (byte == b'\n' || byte == b'\r') { return false }
    }
    for (token in chirCompileOptionTokens(value)) {
        if (chirLanguageOption(token)) {
            if (!allowLanguageOptions) { return false }
            continue
        }
        var known = false
        for (candidate in allowed) {
            if (token == candidate) { known = true; break }
        }
        if (!known) { return false }
    }
    true
}

private func chirCompileOptionTokens(value: String): ArrayList<String> {
    let bytes = value.toArray()
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
    tokens
}

// Read only the captured package manifest that passed the guard above. Options
// in target tables remain unsupported rather than leaking into another target.
internal func chirManifestCompilerOptions(manifest: ?String): ArrayList<String> {
    let result = ArrayList<String>()
    let text = match (manifest) {
        case Some(value) => value
        case None => return result
    }
    let compile = ArrayList<String>()
    let override = ArrayList<String>()
    var inPackage = true
    var activeKey = ""
    for (line in text.split("\n")) {
        let code = chirTomlCode(line)
        var value = code
        var arrayValue = !activeKey.isEmpty()
        if (activeKey.isEmpty()) {
            if (code.startsWith("[")) { inPackage = code == "[package]"; continue }
            if (!inPackage) { continue }
            let equals = match (tomlAssignmentEquals(code)) {
                case Some(index) => index
                case None => continue
            }
            let key = chirManifestKey(code[..equals]).getOrDefault({ => "" })
            if (key != "compile-option" && key != "override-compile-option") { continue }
            activeKey = key
            value = code[equals + 1..].trimAscii()
            arrayValue = value.startsWith("[")
        }
        let tokens = chirCompileOptionTokens(value)
        if (activeKey == "compile-option") { compile.add(all: tokens) }
        else { override.add(all: tokens) }
        if (!arrayValue || chirCompileOptionArrayClosed(value)) { activeKey = "" }
    }
    let selected = if (override.isEmpty()) { compile } else { override }
    for (token in selected) {
        if (chirLanguageOption(token) && !result.contains(token)) { result.add(token) }
    }
    result
}
