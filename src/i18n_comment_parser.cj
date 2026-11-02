package cjdoc

import std.collection.*

internal class LocalizedCommentItem {
    let tag: DocTag
    let language: ?String
    let entryId: ?String
    var source: ?SourceLocation
    var state = "valid"
    var fieldId = ""
    // Recomputed from the owning input profile; not source/API identity or IR.
    var highlightEligible: Bool = true
    init(tag: DocTag, language: ?String, source: ?SourceLocation,
        entryId!: ?String = None) {
        this.tag = tag; this.language = language; this.source = source
        this.entryId = entryId
    }
}

private class LocalizedCommentLineMap {
    let row: Int64
    let columnOffset: Int64
    let text: String
    init(row: Int64, columnOffset: Int64, text: String) {
        this.row = row; this.columnOffset = columnOffset; this.text = text
    }
}

private func leadingCommentWhitespace(value: String): Int64 {
    var index: Int64 = 0
    for (byte in value.toArray()) {
        if (byte != b' ' && byte != b'\t' && byte != b'\r' && byte != b'\n') { break }
        index++
    }
    index
}

private func localizedCommentRows(raw: String): Array<LocalizedCommentLineMap> {
    let result = ArrayList<LocalizedCommentLineMap>()
    let leading = leadingCommentWhitespace(raw)
    var content = raw.trimAscii()
    var sourceLineStart = leading
    var row: Int64 = 0
    for (byte in raw[..leading].toArray()) { if (byte == b'\n') { row++ } }
    var lineBase = sourceLineStart
    if (content.startsWith("/**")) {
        content = content.removePrefix("/**")
        sourceLineStart += 3
    }
    if (content.endsWith("*/")) { content = content.removeSuffix("*/") }
    var started = false
    for (sourceLine in content.split("\n")) {
        var line = sourceLine.trimAsciiEnd()
        var columnOffset = sourceLineStart - lineBase
        var prefix: Int64 = 0
        while (prefix < line.size && (line[prefix] == b' ' || line[prefix] == b'\t')) { prefix++ }
        if (prefix < line.size && line[prefix] == b'*') {
            columnOffset += prefix + 1
            line = line[prefix + 1..]
            if (line.startsWith(" ")) { line = line.removePrefix(" "); columnOffset++ }
        } else {
            columnOffset += prefix
            line = line[prefix..]
        }
        if (started || !line.isEmpty()) {
            result.add(LocalizedCommentLineMap(row, columnOffset, line))
            started = true
        }
        sourceLineStart += sourceLine.size + 1
        lineBase = sourceLineStart
        row++
    }
    while (!result.isEmpty() && result[result.size - 1].text.isEmpty()) { result.remove(at: result.size - 1) }
    result.toArray()
}

private func localizedLineSource(base: DocComment, rows: Array<LocalizedCommentLineMap>,
    line: Int64): ?SourceLocation {
    if (line >= rows.size) { return None }
    match (base.commentSource) {
        case None => None
        case Some(origin) =>
            let mapping = rows[line]
            var markerOffset = mapping.text.size
            if (let Some(index) <- mapping.text.indexOf("@")) { markerOffset = index }
            let startOffset = mapping.columnOffset + markerOffset
            let endOffset = mapping.columnOffset + mapping.text.size
            let startLine = origin.startLine + mapping.row
            let startColumn = if (mapping.row == 0) { origin.startColumn + startOffset } else { startOffset + 1 }
            let endColumn = if (mapping.row == 0) { origin.startColumn + endOffset } else { endOffset + 1 }
            Some(SourceLocation(origin.path, startLine, startColumn, startLine, endColumn))
    }
}

private func appendLocalizedContinuation(item: LocalizedCommentItem, line: String,
    source: ?SourceLocation): Unit {
    item.tag.description += "\n" + line
    if (let Some(end) <- source) {
        if (let Some(start) <- item.source) {
            let combined = SourceLocation(start.path, start.startLine, start.startColumn,
                end.endLine, end.endColumn)
            item.source = Some(combined)
            if (isAdmonitionKind(item.tag.name)) { item.tag.source = Some(combined) }
        }
    }
}

private func appendLocalizedBodyBoundary(body: ArrayList<String>): Unit {
    if (!body.isEmpty() && !body[body.size - 1].isEmpty()) { body.add("") }
}

internal func isAdmonitionKind(value: String): Bool {
    value == "note" || value == "warning" || value == "danger"
}

private func localizedItem(head: LocalizedTagHead, defaultLanguage: ?String,
    source: ?SourceLocation): LocalizedCommentItem {
    let language = if (head.language.isSome()) { head.language } else { defaultLanguage }
    let (subject, body) = if (head.name == "param" || head.name == "throws") {
        splitSubject(head.rest)
    } else if (head.name == "see") {
        splitReferenceSubject(head.rest)
    } else if (head.name == "example") {
        let (title, _) = splitExampleDirectives(head.rest)
        (title, "")
    } else { ("", head.rest) }
    let tag = DocTag(head.name, subject, body)
    if (head.name == "example") {
        let (_, directives) = splitExampleDirectives(head.rest)
        tag.directives = directives
    }
    LocalizedCommentItem(tag, language, source, entryId: head.entryId)
}

private func localizedAdmonitionItem(head: AdmonitionTagHead, defaultLanguage: ?String,
    source: ?SourceLocation): LocalizedCommentItem {
    let language = if (head.language.isSome()) { head.language } else { defaultLanguage }
    let tag = DocTag(head.level, "", head.rest, entryId: head.entryId, source: source)
    LocalizedCommentItem(tag, language, source, entryId: head.entryId)
}

internal func parseLocalizedComment(base: DocComment, defaultLanguage: ?String,
    diagnostics: ArrayList<Diagnostic>, symbolId: String): DocComment {
    let lines = cleanDocLines(base.raw)
    let rows = localizedCommentRows(base.raw)
    let eligible = topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    let items = ArrayList<LocalizedCommentItem>()
    let body = ArrayList<String>()
    var current: ?LocalizedCommentItem = None
    var rejected = false
    var index: Int64 = 0
    while (index < lines.size) {
        let line = lines[index]
        let source = localizedLineSource(base, rows, index)
        if (let Some(active) <- current) {
            if (isAdmonitionKind(active.tag.name) &&
                (line.trimAscii().isEmpty() || !eligible[index] || line.trimAscii().startsWith("@"))) {
                current = None
            }
        }
        let prompt: ?AdmonitionTagHead = if (eligible[index]) { admonitionTagHead(line) } else { None }
        if (let Some(value) <- prompt) {
            current = None
            rejected = false
            appendLocalizedBodyBoundary(body)
            if (let Some(code) <- value.error) {
                diagnostics.add(Diagnostic("error", code,
                    "invalid documentation admonition @" + value.level,
                    source: source, symbolId: Some(symbolId)))
                body.add(line)
            } else {
                let item = localizedAdmonitionItem(value, defaultLanguage, source)
                items.add(item)
                current = Some(item)
            }
            index++
            continue
        }
        let head: ?LocalizedTagHead = if (eligible[index]) { localizedTagHead(line) } else { None }
        if (let Some(value) <- head) {
            current = None
            rejected = false
            if (let Some(code) <- value.error) {
                diagnostics.add(Diagnostic("error", code,
                    "invalid documentation tag @" + value.name + "; language qualifier rejected",
                    source: source, symbolId: Some(symbolId)))
                rejected = true
            } else if (SHARED_METADATA_TAGS.contains(value.name)) {
                // Shared metadata is retained by the legacy parser; it has no
                // documentation-language scope and cannot acquire translations.
                ()
            } else {
                let item = localizedItem(value, defaultLanguage, source)
                if ((value.name == "param" || value.name == "throws" || value.name == "see") &&
                    item.tag.subject.isEmpty()) {
                    item.state = "invalid"
                    diagnostics.add(Diagnostic("error", "CJDOC3109", "@" + value.name +
                        " requires a subject", source: source, symbolId: Some(symbolId)))
                }
                items.add(item)
                current = Some(item)
            }
        } else if (!rejected) {
            match (current) {
                case Some(item) => appendLocalizedContinuation(item, line, source)
                case None => body.add(line)
            }
        }
        index++
    }
    let (summary, description) = splitMarkdownBody(body)
    let result = DocComment(base.raw, summary, description)
    result.commentSource = base.commentSource
    result.defaultLanguage = defaultLanguage
    result.localizationScope = "all"
    result.since = base.since; result.version = base.version; result.authors.add(all: base.authors)
    for (tag in base.contracts where tag.name == "group" || tag.name == "tag") {
        result.contracts.add(tag)
    }
    if (!summary.isEmpty()) {
        result.languageItems.add(LocalizedCommentItem(DocTag("summary", "", summary),
            defaultLanguage, base.commentSource))
    }
    if (!description.isEmpty()) {
        result.languageItems.add(LocalizedCommentItem(DocTag("description", "", description),
            defaultLanguage, base.commentSource))
    }
    for (item in items) {
        item.tag.description = item.tag.description.trimAscii()
        if (isAdmonitionKind(item.tag.name)) { result.admonitions.add(item.tag) }
    }
    result.languageItems.add(all: items)
    result
}

internal func parseAdmonitionsOnlyComment(base: DocComment,
    diagnostics: ArrayList<Diagnostic>, symbolId: String): DocComment {
    let lines = cleanDocLines(base.raw)
    let rows = localizedCommentRows(base.raw)
    let eligible = topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    let items = ArrayList<LocalizedCommentItem>()
    var current: ?LocalizedCommentItem = None
    var index: Int64 = 0
    while (index < lines.size) {
        let line = lines[index]
        let source = localizedLineSource(base, rows, index)
        if (let Some(active) <- current) {
            if (line.trimAscii().isEmpty() || !eligible[index] || line.trimAscii().startsWith("@")) {
                current = None
            }
        }
        if (eligible[index]) {
            if (let Some(head) <- admonitionTagHead(line)) {
                current = None
                if (let Some(code) <- head.error) {
                    diagnostics.add(Diagnostic("error", code,
                        "invalid documentation admonition @" + head.level,
                        source: source, symbolId: Some(symbolId)))
                } else {
                    let item = localizedAdmonitionItem(head, None<String>, source)
                    items.add(item)
                    current = Some(item)
                }
            } else if (let Some(active) <- current) {
                appendLocalizedContinuation(active, line, source)
            }
        }
        index++
    }
    let result = DocComment(base.raw, base.summaryMarkdown, base.descriptionMarkdown)
    result.commentSource = base.commentSource
    result.defaultLanguage = None
    result.localizationScope = "admonitions"
    result.params.add(all: base.params)
    result.examples.add(all: base.examples)
    result.returns = base.returns; result.returnTagCount = base.returnTagCount
    result.throwsTags.add(all: base.throwsTags); result.see.add(all: base.see)
    result.contracts.add(all: base.contracts)
    result.since = base.since; result.version = base.version
    result.deprecated = base.deprecated; result.authors.add(all: base.authors)
    for (item in items) {
        item.tag.description = item.tag.description.trimAscii()
        result.admonitions.add(item.tag)
        result.languageItems.add(item)
    }
    result
}

private func requiresLocalizedFeature(raw: String, includeAdmonitions: Bool): Bool {
    let lines = cleanDocLines(raw)
    let eligible = topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    var index: Int64 = 0
    while (index < lines.size) {
        if (eligible[index]) {
            if (includeAdmonitions && admonitionTagHead(lines[index]).isSome()) { return true }
            if (let Some(head) <- localizedTagHead(lines[index])) {
                if (head.language.isSome() || head.entryId.isSome() || head.error.isSome() ||
                    head.name == "summary" || head.name == "description") { return true }
            }
        }
        index++
    }
    false
}

internal func hasTopLevelAdmonitionTag(raw: String): Bool {
    let lines = cleanDocLines(raw)
    let eligible = topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    var index: Int64 = 0
    while (index < lines.size) {
        if (eligible[index] && admonitionTagHead(lines[index]).isSome()) { return true }
        index++
    }
    false
}

internal func requiresNonAdmonitionLocalizedComment(raw: String): Bool {
    requiresLocalizedFeature(raw, false)
}

internal func requiresLocalizedComment(raw: String): Bool {
    requiresLocalizedFeature(raw, true)
}
