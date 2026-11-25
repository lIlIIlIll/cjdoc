protected package cjdoc.documentation.comments

import cjdoc.source.Diagnostic
import cjdoc.source.SourceLocation
import std.collection.*

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

private func localizedItem(head: CommentTagHeader, defaultLanguage: ?String,
    source: ?SourceLocation): LocalizedCommentItem {
    let language = if (head.language.isSome()) { head.language } else { defaultLanguage }
    let (subject, body) = if (head.formal == "param" || head.formal == "throws") {
        splitSubject(head.rest)
    } else if (head.formal == "see") {
        splitReferenceSubject(head.rest)
    } else if (head.formal == "example") {
        let (title, _) = splitExampleDirectives(head.rest)
        (title, "")
    } else { ("", head.rest) }
    let tag = DocTag(head.formal, subject, body)
    if (head.formal == "example") {
        let (_, directives) = splitExampleDirectives(head.rest)
        tag.directives = directives
    }
    LocalizedCommentItem(tag, language, source, entryId: head.entryId)
}

private func localizedAdmonitionItem(head: CommentTagHeader, defaultLanguage: ?String,
    source: ?SourceLocation): LocalizedCommentItem {
    let language = if (head.language.isSome()) { head.language } else { defaultLanguage }
    let tag = DocTag(head.formal, "", head.rest, entryId: head.entryId, source: source)
    LocalizedCommentItem(tag, language, source, entryId: head.entryId)
}

protected func parseLocalizedComment(base: DocComment, defaultLanguage: ?String,
    diagnostics: ArrayList<Diagnostic>, symbolId: String): DocComment {
    let prepared = base.preparedPolicy
    let lines = match (prepared) {
        case Some(value) => value.lines
        case None => cleanDocLines(base.raw)
    }
    let rows = localizedCommentRows(base.raw)
    let eligible = match (prepared) {
        case Some(value) => value.eligible
        case None => topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    }
    let items = ArrayList<LocalizedCommentItem>()
    let body = ArrayList<String>()
    var current: ?LocalizedCommentItem = None
    var rejected = false
    var index: Int64 = 0
    while (index < lines.size) {
        let line = lines[index]
        let source = localizedLineRange(base.commentSource, rows, index)
        let head = localizedPreparedHead(prepared, line, index, eligible[index])
        if (let Some(field) <- head) {
            if (field.field) {
                current = None
                rejected = false
                index++
                continue
            }
        }
        if (let Some(active) <- current) {
            if (isAdmonitionKind(active.tag.name) &&
                (line.trimAscii().isEmpty() || !eligible[index] || line.trimAscii().startsWith("@"))) {
                current = None
            }
        }
        if (let Some(value) <- head) {
            if (isAdmonitionKind(value.formal)) {
                current = None
                rejected = false
                appendLocalizedBodyBoundary(body)
                if (let Some(code) <- value.error) {
                    diagnostics.add(Diagnostic("error", code,
                        "invalid documentation admonition @" + value.authored,
                        source: source, symbolId: Some(symbolId)))
                    body.add(line)
                } else {
                    let item = localizedAdmonitionItem(value, defaultLanguage, source)
                    items.add(item)
                    associateLocalizedPolicyTag(prepared, index, item)
                    current = Some(item)
                }
                index++
                continue
            }
        }
        if (let Some(value) <- head) {
            current = None
            rejected = false
            if (value.formal == "replacement") {
                // The source parser owns single-line metadata, including invalid entries.
                ()
            } else if (let Some(code) <- value.error) {
                diagnostics.add(Diagnostic("error", code,
                    "invalid documentation tag @" + value.authored + "; language qualifier rejected",
                    source: source, symbolId: Some(symbolId)))
                rejected = true
            } else if (SHARED_METADATA_TAGS.contains(value.formal)) {
                // Shared metadata is retained by the legacy parser; it has no
                // documentation-language scope and cannot acquire translations.
                ()
            } else {
                let item = localizedItem(value, defaultLanguage, source)
                if ((value.formal == "param" || value.formal == "throws" || value.formal == "see") &&
                    item.tag.subject.isEmpty()) {
                    item.state = "invalid"
                    diagnostics.add(Diagnostic("error", "CJDOC3109", "@" + value.authored +
                        " requires a subject", source: source, symbolId: Some(symbolId)))
                }
                items.add(item)
                if (item.state != "invalid") { associateLocalizedPolicyTag(prepared, index, item) }
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
    // Policy facts belong to the comment, not to one language: without them a
    // rule or a published field would disappear whenever i18n is configured.
    result.occurrences = base.occurrences
    result.fieldValues.add(all: base.fieldValues)
    result.problems.add(all: base.problems)
    result.replacements.add(all: base.replacements)
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

protected func parseAdmonitionsOnlyComment(base: DocComment,
    diagnostics: ArrayList<Diagnostic>, symbolId: String): DocComment {
    let prepared = base.preparedPolicy
    let lines = prepared.map({ value => value.lines }).getOrDefault({ => cleanDocLines(base.raw) })
    let rows = localizedCommentRows(base.raw)
    let eligible = prepared.map({ value => value.eligible }).getOrDefault({ =>
        topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    })
    let items = ArrayList<LocalizedCommentItem>()
    var current: ?LocalizedCommentItem = None
    var index: Int64 = 0
    while (index < lines.size) {
        let line = lines[index]
        let source = localizedLineRange(base.commentSource, rows, index)
        if (let Some(active) <- current) {
            if (line.trimAscii().isEmpty() || !eligible[index] || line.trimAscii().startsWith("@")) {
                current = None
            }
        }
        if (eligible[index]) {
            let header = localizedPreparedHead(prepared, line, index, true)
            if (let Some(head) <- header) {
                if (isAdmonitionKind(head.formal)) {
                    current = None
                    if (let Some(code) <- head.error) {
                        diagnostics.add(Diagnostic("error", code,
                            "invalid documentation admonition @" + head.authored,
                            source: source, symbolId: Some(symbolId)))
                    } else {
                        let item = localizedAdmonitionItem(head, None<String>, source)
                        items.add(item)
                        current = Some(item)
                        associateLocalizedPolicyTag(prepared, index, item)
                    }
                    index++
                    continue
                }
            }
            if (let Some(active) <- current) { appendLocalizedContinuation(active, line, source) }
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
    result.replacements.add(all: base.replacements)
    result.contracts.add(all: base.contracts)
    result.since = base.since; result.version = base.version
    result.deprecated = base.deprecated; result.authors.add(all: base.authors)
    result.occurrences = base.occurrences
    result.fieldValues.add(all: base.fieldValues)
    result.problems.add(all: base.problems)
    for (item in items) {
        item.tag.description = item.tag.description.trimAscii()
        result.admonitions.add(item.tag)
        result.languageItems.add(item)
    }
    result
}

private func localizedPreparedHead(prepared: ?CommentSpecLines, line: String,
    index: Int64, eligible: Bool): ?CommentTagHeader {
    if (!eligible) { return None }
    match (prepared) {
        case Some(policy) => policy.headers[index]
        case None => commentTagHeader(line, None)
    }
}

private func associateLocalizedPolicyTag(prepared: ?CommentSpecLines, index: Int64,
    item: LocalizedCommentItem): Unit {
    if (let Some(policy) <- prepared) {
        if (let Some(occurrence) <- policy.occurrencesByLine[index]) {
            occurrence.tag = Some(item.tag)
        }
    }
}

/** Detect localized syntax from the same authored headers both parsers consume. */
protected func localizedCommentFeatures(comment: DocComment): (Bool, Bool) {
    let prepared = comment.preparedPolicy
    let lines = prepared.map({ value => value.lines }).getOrDefault({ => cleanDocLines(comment.raw) })
    let eligible = prepared.map({ value => value.eligible }).getOrDefault({ =>
        topLevelParagraphLines(lines, markdownBlockStructure(rawJoinLines(lines)))
    })
    var admonitions = false
    var other = false
    for (index in 0..lines.size) {
        if (let Some(head) <- localizedPreparedHead(prepared, lines[index], index, eligible[index])) {
            if (head.field || head.formal == "replacement") { continue }
            if (isAdmonitionKind(head.formal)) {
                admonitions = true
            } else if (head.language.isSome() || head.entryId.isSome() || head.error.isSome() ||
                head.formal == "summary" || head.formal == "description") {
                other = true
            }
            if (admonitions && other) { break }
        }
    }
    (admonitions, other)
}
