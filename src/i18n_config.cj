package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*

internal func i18nStringArray(value: String): Array<String> {
    let input = value.trimAscii()
    if (!input.startsWith("[") || !input.endsWith("]")) {
        throw IllegalArgumentException("i18n language list must be an array of quoted strings")
    }
    let result = ArrayList<String>()
    let body = input[1..input.size - 1].trimAscii()
    if (body.isEmpty()) { return [] }
    let parts = body.split(",")
    for (index in 0..parts.size) {
        let part = parts[index]
        let text = part.trimAscii()
        if (text.isEmpty() && index == parts.size - 1) { continue }
        if (!text.startsWith("\"") || !text.endsWith("\"") || text.size < 2) {
            throw IllegalArgumentException("i18n language list must contain quoted strings")
        }
        result.add(text[1..text.size - 1])
    }
    result.toArray()
}

private func i18nLogicalLines(text: String): Array<String> {
    let lines = ArrayList<String>()
    var section = ""
    var pending = ""
    for (raw in text.split("\n")) {
        let line = qualityTomlLine(raw)
        if (!pending.isEmpty()) {
            pending += " " + line
            if (line.endsWith("]")) { lines.add(pending); pending = "" }
            continue
        }
        if (line.startsWith("[") && line.endsWith("]")) { section = line }
        if (section == "[i18n]" && line.startsWith("languages")) {
            let equals = line.indexOf("=")
            if (let Some(position) <- equals) {
                let value = line[position + 1..].trimAscii()
                if (value.startsWith("[") && !value.endsWith("]")) { pending = line; continue }
            }
        }
        lines.add(line)
    }
    if (!pending.isEmpty()) { throw IllegalArgumentException("unterminated [i18n].languages array") }
    lines.toArray()
}

internal func loadDocumentationLanguages(root: String): ?public_model.DocumentationLanguageOptions {
    let path = Path(root).join("cjdoc.toml")
    if (!exists(path)) { return None }
    let text = readTextBounded(path, 64 * 1024)
    var section = ""
    var enabled = false
    var defaultLanguage = ""
    var missing = "warn"
    var languages: Array<String> = []
    let seen = HashSet<String>()
    for (raw in i18nLogicalLines(text)) {
        let line = raw.trimAscii()
        if (line.isEmpty() || line.startsWith("#")) { continue }
        if (line.startsWith("[") && line.endsWith("]")) {
            section = line
            if (section == "[i18n]") { enabled = true }
            continue
        }
        if (section != "[i18n]") { continue }
        let equals = line.indexOf("=")
        if (equals.isNone()) { throw IllegalArgumentException("invalid [i18n] assignment") }
        let position = equals.getOrThrow()
        let key = line[..position].trimAscii()
        let value = line[position + 1..].trimAscii()
        if (!seen.add(key)) { throw IllegalArgumentException("duplicate [i18n] key '" + key + "'") }
        match (key) {
            case "default-language" => defaultLanguage = qualityTomlValue(value)
            case "languages" => languages = i18nStringArray(qualityTomlValue(value))
            case "missing-translation" => missing = qualityTomlValue(value)
            case _ => throw IllegalArgumentException("unknown [i18n] setting '" + key + "'")
        }
    }
    if (!enabled) { return None }
    if (defaultLanguage.isEmpty()) {
        throw IllegalArgumentException("CJDOC3105: [i18n] requires default-language")
    }
    if (seen.contains("languages") && languages.isEmpty()) {
        throw IllegalArgumentException("[i18n].languages must not be empty")
    }
    Some(public_model.DocumentationLanguageOptions(defaultLanguage, languages: languages,
        missingTranslation: missing))
}
