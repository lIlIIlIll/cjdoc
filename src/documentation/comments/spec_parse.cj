protected package cjdoc.documentation.comments

import cjdoc.model.documentationFieldValueProblem
import cjdoc.source.SourceLocation
import markdown.{MarkdownEngine, MarkdownProfile, NodeKind}
import std.collection.*

/** One explicit author tag appearance, kept for rule evaluation only. */
protected class CommentTagOccurrence {
    protected let name: String
    protected let authored: String
    protected let source: ?SourceLocation
    protected let language: ?String
    internal var inlinePayload: Bool
    internal var tag: ?DocTag = None

    protected init(name: String, authored: String, source: ?SourceLocation,
        language: ?String, payload: Bool) {
        this.name = name
        this.authored = authored
        this.source = source
        this.language = language
        this.inlinePayload = payload
    }

    protected prop payload: Bool {
        get() {
            if (let Some(item) <- tag) { return authoredTagPayload(item) }
            inlinePayload
        }
    }
}

/** A structural comment problem discovered while applying a module policy. */
protected class CommentProblem {
    protected let code: String
    protected let message: String
    protected let source: ?SourceLocation

    protected init(code: String, message: String, source: ?SourceLocation) {
        this.code = code
        this.message = message
        this.source = source
    }
}

/**
 * One pass over the original Markdown rows for a module policy.
 *
 * The parser, feature probe and localized view all consume the same classified
 * headers. The raw comment and source rows retain the author's spelling.
 */
protected class CommentSpecLines {
    protected let lines: ArrayList<String>
    internal let headers = ArrayList<?CommentTagHeader>()
    internal let occurrencesByLine = ArrayList<?CommentTagOccurrence>()
    internal let rows: Array<LocalizedCommentLineMap>
    protected let eligible: Array<Bool>
    protected let occurrences = ArrayList<CommentTagOccurrence>()
    protected let fieldValues = ArrayList<DocFieldValue>()
    protected let problems = ArrayList<CommentProblem>()
    private let firstFieldLine = HashMap<String, Int64>()
    private let conflictingFields = HashSet<String>()

    protected init(raw: String, source: ?SourceLocation, spec: CommentSpec) {
        let original = cleanDocLines(raw)
        let structure = markdownBlockStructure(rawJoinLines(original))
        let eligibility = topLevelParagraphLines(original, structure)
        this.rows = if (source.isSome()) { localizedCommentRows(raw) } else { [] }
        var order: Int64 = 0
        var index: Int64 = 0
        while (index < original.size) {
            let line = original[index]
            let header: ?CommentTagHeader = if (eligibility[index]) {
                commentTagHeader(line, Some(spec))
            } else {
                None<CommentTagHeader>
            }
            headers.add(header)
            if (let Some(found) <- header) {
                let lineSource = localizedLineRange(source, rows, index)
                let payload = if (found.field) {
                    captureCommentField(found, lineSource, index, order,
                        spec.field(found.formal).getOrThrow().repeatable,
                        fieldValues, problems, firstFieldLine, conflictingFields)
                } else { commentPayloadFor(found) }
                let occurrence = CommentTagOccurrence(found.formal, found.authored,
                    lineSource, found.language, payload)
                occurrences.add(occurrence)
                occurrencesByLine.add(Some(occurrence))
                if (found.field) { order++ }
            } else {
                occurrencesByLine.add(None)
            }
            index++
        }
        this.lines = original
        this.eligible = eligibility
        for (occurrence in occurrences where conflictingFields.contains(occurrence.name)) {
            occurrence.inlinePayload = false
        }
    }

    /** Values that survived structural validation, in author order. */
    protected func validFieldValues(): Array<DocFieldValue> {
        let result = ArrayList<DocFieldValue>()
        for (entry in fieldValues) {
            if (conflictingFields.contains(entry.fieldId)) { continue }
            result.add(entry)
        }
        result.toArray()
    }
}

private func authoredTagPayload(tag: DocTag): Bool {
    match (tag.name) {
        case "see" | "replacement" => !tag.subject.isEmpty()
        case "group" => isDeclarationTagId(tag.subject)
        case "tag" => isDeclarationTagId(tag.subject) && tag.description.isEmpty()
        case "example" => !tag.subject.isEmpty() || exampleHasContent(tag.description)
        case _ => !tag.description.trimAscii().isEmpty()
    }
}

private func exampleHasContent(body: String): Bool {
    if (body.trimAscii().isEmpty()) { return false }
    try {
        let document = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1())
            .build().parse(body).document
        let children = document.root().children()
        for (index in 0..children.size) {
            let child = children[index]
            match (child.kind) {
                case NodeKind.CodeBlock =>
                    if (!child.asCodeBlock().getOrThrow().literal.trimAscii().isEmpty()) {
                        return true
                    }
                case _ => return true
            }
        }
        false
    } catch (_: Exception) { false }
}

private func commentPayloadFor(header: CommentTagHeader): Bool {
    if (header.error.isSome()) { return false }
    let rest = header.rest
    match (header.formal) {
        case "param" | "throws" =>
            let (_, description) = splitSubject(rest)
            return !description.isEmpty()
        case "return" => return !rest.isEmpty()
        case "see" | "replacement" =>
            let (subject, _) = splitReferenceSubject(rest)
            return !subject.isEmpty()
        case "tag" =>
            let entry = declarationTagLine(rest)
            return isDeclarationTagId(entry.id) && entry.rest.isEmpty()
        case "group" => return isDeclarationTagId(splitSubject(rest)[0])
        case "example" => return !splitExampleDirectives(rest)[0].isEmpty()
        case _ => return !rest.isEmpty()
    }
}

/** Match the legacy parser without rewriting the author's source rows. */
internal func normalizedBuiltinTagText(line: String, header: CommentTagHeader): String {
    if (header.error.isNone() && header.entryId.isNone() && header.language.isNone()) {
        return "@" + header.formal + (if (header.rest.isEmpty()) { "" } else { " " + header.rest })
    }
    ("@" + header.formal + line[header.authoredEnd..]).trimAscii()
}

private func captureCommentField(header: CommentTagHeader, source: ?SourceLocation,
    index: Int64, order: Int64, repeatable: Bool, values: ArrayList<DocFieldValue>,
    problems: ArrayList<CommentProblem>, firstLines: HashMap<String, Int64>,
    conflicts: HashSet<String>): Bool {
    if (!repeatable) {
        if (let Some(first) <- firstLines.get(header.formal)) {
            if (conflicts.add(header.formal)) {
                problems.add(CommentProblem("CJDOC3141",
                    "@" + header.authored + " repeats single-value field '" + header.formal +
                    "' first written on line " + first.toString() +
                    "; the declaration has no valid value for it", source))
            }
        } else {
            firstLines[header.formal] = source.map({ location => location.startLine })
                .getOrDefault({ => index + 1 })
        }
    }
    if (header.error.isSome()) {
        let detail = if (header.error.getOrThrow() == "CJDOC3140") {
            "@" + header.authored + " does not accept attributes; a comment field line is one value"
        } else {
            "@" + header.authored + " has a malformed header"
        }
        problems.add(CommentProblem("CJDOC3140", detail, source))
        return false
    }
    let value = header.rest
    let problem = documentationFieldValueProblem(value)
    if (!problem.isEmpty()) {
        let detail = match (problem) {
            case "empty" => "@" + header.authored + " requires a non-empty value"
            case "too-long" => "@" + header.authored +
                " value exceeds 16384 Unicode code points"
            case "multiline" => "@" + header.authored +
                " value must not contain a line or paragraph separator"
            case _ => "@" + header.authored +
                " value must not contain a control character"
        }
        problems.add(CommentProblem("CJDOC3140", detail, source))
        return false
    }
    values.add(DocFieldValue(header.formal, value, header.authored, source, order))
    true
}
