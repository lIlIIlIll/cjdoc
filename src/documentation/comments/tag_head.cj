protected package cjdoc.documentation.comments

import cjdoc.model as public_model
import std.collection.*

protected let LOCALIZED_TAG_NAMES = ["summary", "description", "param", "return", "throws", "see",
    "deprecated", "example", "precondition", "postcondition", "invariant", "performance", "state",
    "concurrency", "platform", "compatibility", "error", "since", "version", "author", "group",
    "tag", "replacement"]

// Tags whose meaning belongs to the declaration, not to one documentation
// language, so a language qualifier is rejected with CJDOC3112.
protected let SHARED_METADATA_TAGS = ["since", "version", "author", "group", "tag", "replacement"]

protected class LocalizedTagHead {
    protected let name: String
    protected let language: ?String
    protected let rest: String
    protected let error: ?String
    protected let entryId: ?String
    init(name: String, language: ?String, rest: String, error!: ?String = None,
        entryId!: ?String = None) {
        this.name = name; this.language = language; this.rest = rest
        this.error = error; this.entryId = entryId
    }
}

protected class AdmonitionTagHead {
    protected let level: String
    protected let language: ?String
    protected let rest: String
    protected let error: ?String
    protected let entryId: ?String
    init(level: String, language: ?String, rest: String, error!: ?String = None,
        entryId!: ?String = None) {
        this.level = level; this.language = language; this.rest = rest
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
protected func wellFormedDocumentationLanguage(value: String): Bool {
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

// Shared strict author-entry identity rule. Throws keeps its existing accepted
// language and attribute grammar; admonition tags reuse only this validator.
protected func validDocumentationEntryId(value: String): Bool {
    if (value.isEmpty() || value.size > 64) { return false }
    for (index in 0..value.size) {
        let byte = value[index]
        if (byte >= b'a' && byte <= b'z') { continue }
        if (index > 0 && ((byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_')) { continue }
        return false
    }
    true
}

// Admonition prompts share the tag vocabulary, so their classification lives here
// rather than in the localization pass that also consumes it.
protected func isAdmonitionKind(value: String): Bool {
    value == "note" || value == "warning" || value == "danger"
}

protected func admonitionTagHead(line: String): ?AdmonitionTagHead {
    let text = line.trimAscii()
    if (!text.startsWith("@")) { return None }
    let end = commentTagWordEnd(text)
    let level = text[1..end]
    if (!["note", "warning", "danger"].contains(level)) { return None }
    admonitionTagHeadAfter(text, level, end)
}

private func admonitionTagHeadAfter(text: String, level: String, nameEnd: Int64): ?AdmonitionTagHead {
    var end = nameEnd
    if (end < text.size && text[end] != b'[' && text[end] != b' ' && text[end] != b'\t') {
        return None
    }
    var language: ?String = None
    var entryId: ?String = None
    if (end < text.size && text[end] == b'[') {
        let close = text[end..].indexOf("]")
        if (close.isNone()) {
            return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3115"))
        }
        let stop = end + close.getOrThrow()
        let attribute = text[end + 1..stop]
        if (attribute.contains(" ") || attribute.contains("\t") ||
            attribute.contains("\"") || attribute.contains("'")) {
            return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3115"))
        }
        let attributes = attribute.split(",", removeEmpty: false)
        if (attributes.size == 1 && attributes[0].startsWith("id=")) {
            let value = attributes[0][3..]
            if (!validDocumentationEntryId(value)) {
                return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3116"))
            }
            entryId = Some(value)
        } else if ((attributes.size == 1 && attributes[0].startsWith("lang=")) ||
            (attributes.size == 2 && attributes[0].startsWith("lang=") && attributes[1].startsWith("id="))) {
            let value = attributes[0][5..]
            if (!wellFormedDocumentationLanguage(value)) {
                return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3102"))
            }
            language = try { Some(public_model.documentationLanguage(value)) } catch (_: Exception) {
                return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3103"))
            }
            if (!["en", "zh-CN"].contains(language.getOrThrow())) {
                return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3103"))
            }
            if (attributes.size == 2) {
                let idValue = attributes[1][3..]
                if (!validDocumentationEntryId(idValue)) {
                    return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3116"))
                }
                entryId = Some(idValue)
            }
        } else {
            return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3115"))
        }
        end = stop + 1
    }
    if (end < text.size && text[end] != b' ' && text[end] != b'\t') {
        return Some(AdmonitionTagHead(level, language, "", error: "CJDOC3115"))
    }
    let rest = text[end..].trimAscii()
    Some(AdmonitionTagHead(level, language, rest, entryId: entryId))
}

private func validThrowsEntryId(value: String): Bool {
    validDocumentationEntryId(value)
}

protected func localizedTagHead(line: String): ?LocalizedTagHead {
    let text = line.trimAscii()
    if (!text.startsWith("@")) { return None }
    let end = commentTagWordEnd(text)
    let name = text[1..end]
    if (!LOCALIZED_TAG_NAMES.contains(name)) { return None }
    localizedTagHeadAfter(text, name, end)
}

private func localizedTagHeadAfter(text: String, name: String, nameEnd: Int64): ?LocalizedTagHead {
    var end = nameEnd
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
        // Shared, language-independent metadata rejects any qualifier: a
        // qualifier cannot narrow which declarations carry a group or a tag.
        if (SHARED_METADATA_TAGS.contains(name)) {
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

/**
 * One classified tag header in a top-level paragraph.
 *
 * `authored` is exactly what the author wrote; `formal` is the builtin tag or
 * project field it denotes. Payload text starts after the authored header, so a
 * span computed from the authored spelling stays correct for aliases too.
 */
protected class CommentTagHeader {
    protected let authored: String
    protected let formal: String
    protected let language: ?String
    protected let entryId: ?String
    protected let error: ?String
    protected let rest: String
    internal let authoredEnd: Int64
    protected let field: Bool

    protected init(authored: String, formal: String, language: ?String, entryId: ?String,
        error: ?String, rest: String, authoredEnd: Int64,
        field!: Bool = false) {
        this.authored = authored
        this.formal = formal
        this.language = language
        this.entryId = entryId
        this.error = error
        this.rest = rest
        this.authoredEnd = authoredEnd
        this.field = field
    }
}

private func commentTagWordEnd(text: String): Int64 {
    var end: Int64 = 1
    while (end < text.size) {
        let byte = text[end]
        let word = (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'_'
        if (!word) { break }
        end++
    }
    end
}


/**
 * Classify one line as a tag header, resolving module aliases and fields.
 *
 * Matching is by complete lexical head: `@team-2` is a header only when that
 * exact name is declared, so a longer unknown name is prose, never a prefix
 * match of a known tag.
 */
protected func commentTagHeader(line: String, spec: ?CommentSpec): ?CommentTagHeader {
    let text = line.trimAscii()
    if (!text.startsWith("@")) { return None }
    let offset = line.size - line.trimAsciiStart().size
    let end = commentTagWordEnd(text)
    if (end <= 1) { return None }
    let token = text[1..end]
    let formal = match (spec) {
        case Some(value) => value.resolve(token)
        case None => token
    }
    let authoredEnd = offset + end
    if (isAdmonitionKind(formal)) {
        return admonitionTagHeadAfter(text, formal, end).map({ head =>
            CommentTagHeader(token, formal, head.language, head.entryId, head.error,
                head.rest, authoredEnd)
        })
    }
    if (LOCALIZED_TAG_NAMES.contains(formal)) {
        return localizedTagHeadAfter(text, formal, end).map({ head =>
            CommentTagHeader(token, formal, head.language, head.entryId, head.error,
                head.rest, authoredEnd)
        })
    }
    if (let Some(policy) <- spec) {
        if (policy.field(formal).isSome()) {
            if (end < text.size && text[end] != b' ' && text[end] != b'\t') {
                return Some(CommentTagHeader(token, formal, None, None,
                    if (text[end] == b'[') { "CJDOC3140" } else { "malformed" },
                    "", authoredEnd, field: true))
            }
            return Some(CommentTagHeader(token, formal, None, None, None,
                text[end..].trimAscii(), authoredEnd, field: true))
        }
    }
    None
}
