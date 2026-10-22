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

private func localizedCommentRows(raw: String): Array<Int64> {
    let rows = ArrayList<Int64>()
    let sourceLines = raw.split("\n")
    var row: Int64 = 0
    var started = false
    for (original in sourceLines) {
        var line = original
        if (row == 0) { line = line.trimAsciiStart().removePrefix("/**") }
        if (row == sourceLines.size - 1) { line = line.trimAsciiEnd().removeSuffix("*/") }
        let cleaned = line.trimAscii().removePrefix("*").trimAscii()
        if (started || !cleaned.isEmpty()) { rows.add(row); started = true }
        row++
    }
    rows.toArray()
}

private func localizedLineSource(base: DocComment, rows: Array<Int64>, line: Int64): ?SourceLocation {
    if (line >= rows.size) { return base.commentSource }
    match (base.commentSource) {
        case None => None
        case Some(origin) =>
            let rawLines = base.raw.split("\n")
            let row = rows[line]
            let content = rawLines[row]
            let column = match (content.indexOf("@")) {
                case Some(index) => index + 1
                case None => 1
            }
            let offset = if (row == 0) { origin.startColumn - 1 } else { 0 }
            Some(SourceLocation(origin.path, origin.startLine + row, column + offset,
                origin.startLine + row, content.size + 1 + offset))
    }
}

private func appendLocalizedContinuation(item: LocalizedCommentItem, line: String,
    source: ?SourceLocation): Unit {
    item.tag.description += "\n" + line
    if (let Some(end) <- source) {
        if (let Some(start) <- item.source) {
            item.source = Some(SourceLocation(start.path, start.startLine, start.startColumn,
                end.endLine, end.endColumn))
        }
    }
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
        let head: ?LocalizedTagHead = if (eligible[index]) { localizedTagHead(line) } else { None }
        if (let Some(value) <- head) {
            current = None
            rejected = false
            if (let Some(code) <- value.error) {
                diagnostics.add(Diagnostic("error", code,
                    "invalid documentation tag @" + value.name + "; language qualifier rejected",
                    source: source, symbolId: Some(symbolId)))
                rejected = true
            } else if (["since", "version", "author"].contains(value.name)) {
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
    result.since = base.since; result.version = base.version; result.authors.add(all: base.authors)
    if (!summary.isEmpty()) {
        result.languageItems.add(LocalizedCommentItem(DocTag("summary", "", summary),
            defaultLanguage, base.commentSource))
    }
    if (!description.isEmpty()) {
        result.languageItems.add(LocalizedCommentItem(DocTag("description", "", description),
            defaultLanguage, base.commentSource))
    }
    for (item in items) { item.tag.description = item.tag.description.trimAscii() }
    result.languageItems.add(all: items)
    result
}

internal func requiresLocalizedComment(raw: String): Bool {
    let lines = cleanDocLines(raw)
    var candidate = false
    for (line in lines) {
        if (let Some(head) <- localizedTagHead(line)) {
            if (head.language.isSome() || head.entryId.isSome() || head.error.isSome() || head.name == "summary" || head.name == "description") { candidate = true; break }
        }
    }
    if (!candidate) { return false }
    let eligible = topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    var index: Int64 = 0
    while (index < lines.size) {
        if (eligible[index]) {
            if (let Some(head) <- localizedTagHead(lines[index])) {
                if (head.language.isSome() || head.entryId.isSome() || head.error.isSome() ||
                    head.name == "summary" || head.name == "description") { return true }
            }
        }
        index++
    }
    false
}
