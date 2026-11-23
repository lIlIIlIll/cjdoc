protected package cjdoc.documentation

protected func qualityTomlLine(value: String): String {
    var cleaned = value.trimAscii()
    var quoted = false
    var escaped = false
    var index: Int64 = 0
    while (index < cleaned.size) {
        let byte = cleaned[index]
        if (byte == b'"' && !escaped) { quoted = !quoted }
        if (byte == b'\\' && quoted) {
            escaped = !escaped
            index++
            continue
        }
        if (byte == b'#' && !quoted) {
            cleaned = cleaned[..index].trimAscii()
            break
        }
        escaped = false
        index++
    }
    cleaned
}

protected func qualityTomlValue(value: String): String {
    let cleaned = qualityTomlLine(value)
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        return cleaned.removePrefix("\"").removeSuffix("\"")
    }
    cleaned
}
