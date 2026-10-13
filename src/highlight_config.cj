package cjdoc

import cjdoc.model.normalizeCodeLanguage
import std.collection.*
import std.fs.*

internal let HIGHLIGHT_CONFIG_MAX_BYTES: Int64 = 64 * 1024

// A language list selects presentation, never permission to execute a program.
// Without explicit host authorization non-Cangjie languages stay explainably plain.
internal class HighlightConfig {
    public let mode: String
    public let languages: Array<String>
    public let onError: String

    public init(mode!: String = "static", languages!: Array<String> = ["cangjie"],
        onError!: String = "warn") {
        if (mode != "static" && mode != "off") {
            throw IllegalArgumentException("[highlight].mode must be static or off")
        }
        if (onError != "warn" && onError != "error") {
            throw IllegalArgumentException("[highlight].on-error must be warn or error")
        }
        if (languages.isEmpty()) {
            throw IllegalArgumentException("[highlight].languages must not be empty")
        }
        let normalized = ArrayList<String>()
        let seen = HashSet<String>()
        for (language in languages) {
            let value = normalizeCodeLanguage(language)
            if (value.isEmpty()) {
                throw IllegalArgumentException("[highlight].languages must not contain an empty or plain-text language")
            }
            if (!seen.add(value)) {
                throw IllegalArgumentException("[highlight].languages contains duplicate language '${value}'")
            }
            normalized.add(value)
        }
        this.mode = mode
        this.languages = normalized.toArray()
        this.onError = onError
    }

    public func allowsLanguage(language: String): Bool {
        languages.contains(normalizeCodeLanguage(language))
    }
}

// Kept identical to doctest's file-private comment scanner: quoted # is data.
private func stripTomlComment(value: String): String {
    var quoted = false
    var escaped = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (byte == b'"' && !escaped) {
            quoted = !quoted
        } else if (byte == b'\\' && quoted) {
            escaped = !escaped
            index++
            continue
        } else if (byte == b'#' && !quoted) {
            return value[..index].trimAscii()
        }
        escaped = false
        index++
    }
    value.trimAscii()
}


private func highlightTomlValue(value: String, key: String): String {
    let cleaned = stripTomlComment(value)
    if (cleaned.isEmpty()) { throw IllegalArgumentException("[highlight].${key} requires a value") }
    if (cleaned.startsWith("\"") && cleaned.endsWith("\"") && cleaned.size >= 2) {
        cleaned.removePrefix("\"").removeSuffix("\"")
    } else {
        cleaned
    }
}

private func highlightTomlLanguages(value: String): Array<String> {
    let cleaned = stripTomlComment(value)
    if (!cleaned.startsWith("[") || !cleaned.endsWith("]")) {
        throw IllegalArgumentException("[highlight].languages must be an array of quoted strings")
    }
    let body = cleaned.removePrefix("[").removeSuffix("]").trimAscii()
    if (body.isEmpty()) { return [] }
    let languages = ArrayList<String>()
    // Language identifiers use the same simple single-line TOML style as doctest.
    // Do not accept unquoted items or silently split a quoted identifier at a comma.
    var index: Int64 = 0
    while (index < body.size) {
        while (index < body.size && (body[index] == b' ' || body[index] == b'\t')) { index++ }
        if (index >= body.size || body[index] != b'"') {
            throw IllegalArgumentException("[highlight].languages must be an array of quoted strings")
        }
        index++
        let start = index
        while (index < body.size && body[index] != b'"' && body[index] != b'\\') { index++ }
        if (index >= body.size || body[index] != b'"') {
            throw IllegalArgumentException("[highlight].languages contains an invalid quoted language")
        }
        languages.add(body[start..index])
        index++
        while (index < body.size && (body[index] == b' ' || body[index] == b'\t')) { index++ }
        if (index == body.size) { break }
        if (body[index] != b',') {
            throw IllegalArgumentException("[highlight].languages requires commas between languages")
        }
        index++
        // A trailing comma is permitted by TOML, but an empty item is not.
        if (body[index..].trimAscii().isEmpty()) { break }
    }
    languages.toArray()
}

internal func loadHighlightConfig(projectRoot: String): HighlightConfig {
    let path = Path(projectRoot).join("cjdoc.toml")
    if (!exists(path)) { return HighlightConfig() }
    let text = readTextBounded(path, HIGHLIGHT_CONFIG_MAX_BYTES)
    var section = ""
    var mode = "static"
    var languages: Array<String> = ["cangjie"]
    var onError = "warn"
    let seen = HashSet<String>()
    for (rawLine in text.split("\n")) {
        let line = stripTomlComment(rawLine.trimAscii())
        if (line.isEmpty()) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            section = line.removePrefix("[").removeSuffix("]").trimAscii()
            continue
        }
        if (section != "highlight") { continue }
        let parts = line.split("=", 2)
        if (parts.size != 2) { throw IllegalArgumentException("invalid [highlight] setting") }
        let key = parts[0].trimAscii()
        if (key.isEmpty() || !seen.add(key)) {
            throw IllegalArgumentException("duplicate or empty [highlight] setting '${key}'")
        }
        match (key) {
            case "mode" => mode = highlightTomlValue(parts[1], key)
            case "languages" => languages = highlightTomlLanguages(parts[1])
            case "on-error" => onError = highlightTomlValue(parts[1], key)
            case _ => throw IllegalArgumentException("unknown [highlight] setting '${key}'")
        }
    }
    HighlightConfig(mode: mode, languages: languages, onError: onError)
}
