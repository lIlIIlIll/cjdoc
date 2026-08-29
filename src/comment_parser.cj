package cjdoc

import std.collection.*

private func joinLines(lines: ArrayList<String>, start: Int64, end: Int64): String {
    let builder = StringBuilder()
    var index = start
    while (index < end) {
        if (index > start) { builder.append("\n") }
        builder.append(lines[index])
        index++
    }
    return builder.toString().trimAscii()
}

private func cleanDocLines(raw: String): ArrayList<String> {
    var content = raw.trimAscii()
    if (content.startsWith("/**")) { content = content.removePrefix("/**") }
    if (content.endsWith("*/")) { content = content.removeSuffix("*/") }
    let result = ArrayList<String>()
    for (sourceLine in content.split("\n")) {
        var line = sourceLine.trimAsciiEnd().trimAsciiStart()
        if (line.startsWith("*")) {
            line = line.removePrefix("*")
            if (line.startsWith(" ")) { line = line.removePrefix(" ") }
        }
        result.add(line)
    }
    while (!result.isEmpty() && result[0].isEmpty()) { result.remove(at: 0) }
    while (!result.isEmpty() && result[result.size - 1].isEmpty()) { result.remove(at: result.size - 1) }
    return result
}

private func splitSubject(rest: String): (String, String) {
    let parts = rest.trimAscii().split(" ", 2, removeEmpty: true)
    if (parts.size == 0) { return ("", "") }
    if (parts.size == 1) { return (parts[0], "") }
    return (parts[0], parts[1].trimAscii())
}

func parseDocComment(raw: String): DocComment {
    let lines = cleanDocLines(raw)
    let body = ArrayList<String>()
    let params = ArrayList<DocTag>()
    let throwsTags = ArrayList<DocTag>()
    let seeTags = ArrayList<DocTag>()
    let authors = ArrayList<String>()
    var returns: ?DocTag = None
    var returnTagCount: Int64 = 0
    var since: ?String = None
    var deprecated: ?String = None
    var version: ?String = None
    var currentTag: ?DocTag = None
    var inFence = false

    for (line in lines) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("```")) {
            inFence = !inFence
            body.add(line)
            currentTag = None
            continue
        }
        if (!inFence && trimmed.startsWith("@")) {
            currentTag = None
            if (trimmed.startsWith("@param ")) {
                let (subject, description) = splitSubject(trimmed.removePrefix("@param "))
                let tag = DocTag("param", subject, description)
                params.add(tag)
                currentTag = tag
            } else if (trimmed == "@return" || trimmed.startsWith("@return ")) {
                let description = if (trimmed == "@return") { "" } else { trimmed.removePrefix("@return ").trimAscii() }
                let tag = DocTag("return", "", description)
                returns = tag
                returnTagCount++
                currentTag = tag
            } else if (trimmed.startsWith("@throws ")) {
                let (subject, description) = splitSubject(trimmed.removePrefix("@throws "))
                let tag = DocTag("throws", subject, description)
                throwsTags.add(tag)
                currentTag = tag
            } else if (trimmed == "@see" || trimmed.startsWith("@see ")) {
                let rest = if (trimmed == "@see") { "" } else { trimmed.removePrefix("@see ") }
                let (subject, description) = splitSubject(rest)
                let tag = DocTag("see", subject, description)
                seeTags.add(tag)
                currentTag = tag
            } else if (trimmed.startsWith("@since ")) {
                since = trimmed.removePrefix("@since ").trimAscii()
            } else if (trimmed == "@deprecated" || trimmed.startsWith("@deprecated ")) {
                deprecated = if (trimmed == "@deprecated") { "" } else { trimmed.removePrefix("@deprecated ").trimAscii() }
            } else if (trimmed.startsWith("@author ")) {
                authors.add(trimmed.removePrefix("@author ").trimAscii())
            } else if (trimmed.startsWith("@version ")) {
                version = trimmed.removePrefix("@version ").trimAscii()
            } else {
                body.add(line)
            }
            continue
        }
        match (currentTag) {
            case Some(tag) =>
                if (!trimmed.isEmpty()) {
                    tag.description = if (tag.description.isEmpty()) { trimmed } else { tag.description + "\n" + trimmed }
                } else {
                    body.add(line)
                    currentTag = None
                }
            case None => body.add(line)
        }
    }

    var splitAt = body.size
    var index: Int64 = 0
    var seenContent = false
    while (index < body.size) {
        if (body[index].trimAscii().isEmpty()) {
            if (seenContent) { splitAt = index; break }
        } else {
            seenContent = true
        }
        index++
    }
    var descriptionStart = splitAt
    while (descriptionStart < body.size && body[descriptionStart].trimAscii().isEmpty()) { descriptionStart++ }
    let parsed = DocComment(raw, joinLines(body, 0, splitAt), joinLines(body, descriptionStart, body.size))
    parsed.params.add(all: params)
    parsed.returns = returns
    parsed.returnTagCount = returnTagCount
    parsed.throwsTags.add(all: throwsTags)
    parsed.see.add(all: seeTags)
    parsed.since = since
    parsed.deprecated = deprecated
    parsed.authors.add(all: authors)
    parsed.version = version
    return parsed
}
