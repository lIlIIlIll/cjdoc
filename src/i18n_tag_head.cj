package cjdoc

import cjdoc.model as public_model
import std.collection.*

internal let LOCALIZED_TAG_NAMES = ["summary", "description", "param", "return", "throws", "see",
    "deprecated", "example", "precondition", "postcondition", "invariant", "performance", "state",
    "concurrency", "platform", "compatibility", "error", "since", "version", "author", "group"]

internal class LocalizedTagHead {
    let name: String
    let language: ?String
    let rest: String
    let error: ?String
    let entryId: ?String
    init(name: String, language: ?String, rest: String, error!: ?String = None,
        entryId!: ?String = None) {
        this.name = name; this.language = language; this.rest = rest
        this.error = error; this.entryId = entryId
    }
}

private func languageLetters(value: String, minimum: Int64, maximum: Int64): Bool {
    if (value.size < minimum || value.size > maximum) { return false }
    for (byte in value.toArray()) { if (byte < b'a' || byte > b'z') { return false } }
    true
}

private func languageDigits(value: String): Bool {
    for (byte in value.toArray()) { if (byte < b'0' || byte > b'9') { return false } }
    !value.isEmpty()
}

// RFC 5646 structural grammar, including the fixed grandfathered productions.
// Registry membership and language equivalence are deliberately not inferred.
internal func wellFormedDocumentationLanguage(value: String): Bool {
    if (value.isEmpty() || value.size > 255) { return false }
    let lower = value.toAsciiLower()
    let grandfathered = ["en-gb-oed", "i-ami", "i-bnn", "i-default", "i-enochian", "i-hak",
        "i-klingon", "i-lux", "i-mingo", "i-navajo", "i-pwn", "i-tao", "i-tay", "i-tsu",
        "sgn-be-fr", "sgn-be-nl", "sgn-ch-de", "art-lojban", "cel-gaulish", "no-bok", "no-nyn",
        "zh-guoyu", "zh-hakka", "zh-min", "zh-min-nan", "zh-xiang"]
    if (grandfathered.contains(lower)) { return true }
    let parts = lower.split("-", removeEmpty: false)
    for (part in parts) {
        if (part.isEmpty() || part.size > 8) { return false }
        for (byte in part.toArray()) {
            if (!((byte >= b'a' && byte <= b'z') || (byte >= b'0' && byte <= b'9'))) { return false }
        }
    }
    if (parts[0] == "x") { return parts.size > 1 }
    if (!languageLetters(parts[0], 2, 8)) { return false }
    var index: Int64 = 1
    if (parts[0].size <= 3) {
        var extensions: Int64 = 0
        while (index < parts.size && languageLetters(parts[index], 3, 3) && extensions < 3) {
            index++; extensions++
        }
    }
    if (index < parts.size && languageLetters(parts[index], 4, 4)) { index++ }
    if (index < parts.size && (languageLetters(parts[index], 2, 2) ||
        (parts[index].size == 3 && languageDigits(parts[index])))) { index++ }
    let variants = HashSet<String>()
    while (index < parts.size && (parts[index].size >= 5 ||
        (parts[index].size == 4 && parts[index][0] >= b'0' && parts[index][0] <= b'9'))) {
        if (!variants.add(parts[index])) { return false }
        index++
    }
    let singletons = HashSet<String>()
    while (index < parts.size && parts[index].size == 1 && parts[index] != "x") {
        if (!singletons.add(parts[index])) { return false }
        index++
        let start = index
        while (index < parts.size && parts[index].size >= 2) { index++ }
        if (index == start) { return false }
    }
    if (index < parts.size && parts[index] == "x") { return index + 1 < parts.size }
    index == parts.size
}

// Scoped only to @throws: an author-provided identity for one exception condition.
private func validThrowsEntryId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if (byte >= b'a' && byte <= b'z') { continue }
        if (index > 0 && ((byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) { continue }
        return false
    }
    true
}

internal func localizedTagHead(line: String): ?LocalizedTagHead {
    let text = line.trimAscii()
    if (!text.startsWith("@")) { return None }
    var end: Int64 = 1
    while (end < text.size && text[end] >= b'a' && text[end] <= b'z') { end++ }
    let name = text[1..end]
    if (!LOCALIZED_TAG_NAMES.contains(name)) { return None }
    var language: ?String = None
    var entryId: ?String = None
    if (end < text.size && text[end] == b'[') {
        let close = text[end..].indexOf("]")
        if (close.isNone()) { return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101")) }
        let stop = end + close.getOrThrow()
        let attribute = text[end + 1..stop]
        if (attribute.contains(" ") || attribute.contains("\t") ||
            attribute.contains("\"") || attribute.contains("'")) {
            return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101"))
        }
        let attributes = attribute.split(",", removeEmpty: false)
        if (attributes.size > 2) { return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101")) }
        if (attributes[0].startsWith("lang=")) {
            let value = attributes[0][5..]
            if (!wellFormedDocumentationLanguage(value)) {
                return Some(LocalizedTagHead(name, language, "", error: "CJDOC3102"))
            }
            language = try { Some(public_model.documentationLanguage(value)) } catch (_: Exception) {
                return Some(LocalizedTagHead(name, language, "", error: "CJDOC3103"))
            }
            if (attributes.size == 2) {
                if (name != "throws" || !attributes[1].startsWith("id=")) {
                    return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101"))
                }
                let value = attributes[1][3..]
                if (!validThrowsEntryId(value)) {
                    return Some(LocalizedTagHead(name, language, "", error: "CJDOC3113"))
                }
                entryId = Some(value)
            }
        } else if (name == "throws" && attributes.size == 1 && attributes[0].startsWith("id=")) {
            let value = attributes[0][3..]
            if (!validThrowsEntryId(value)) {
                return Some(LocalizedTagHead(name, language, "", error: "CJDOC3113"))
            }
            entryId = Some(value)
        } else {
            return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101"))
        }
        end = stop + 1
        if (["since", "version", "author", "group"].contains(name)) {
            return Some(LocalizedTagHead(name, language, "", error: "CJDOC3112"))
        }
    }
    if (end < text.size && text[end] != b' ' && text[end] != b'\t') {
        return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101"))
    }
    let rest = text[end..].trimAscii()
    if (rest.startsWith("[")) {
        return Some(LocalizedTagHead(name, language, "", error: "CJDOC3101"))
    }
    Some(LocalizedTagHead(name, language, rest, entryId: entryId))
}
