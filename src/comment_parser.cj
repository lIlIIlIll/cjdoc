package cjdoc

import markdown.{MarkdownEngine, MarkdownProfile, NodeKind, SourceSpan}
import std.collection.*

private func cleanDocLines(raw: String): ArrayList<String> {
    var content = raw.trimAscii()
    if (content.startsWith("/**")) { content = content.removePrefix("/**") }
    if (content.endsWith("*/")) { content = content.removeSuffix("*/") }
    let result = ArrayList<String>()
    for (sourceLine in content.split("\n")) {
        var line = sourceLine.trimAsciiEnd()
        var prefix: Int64 = 0
        while (prefix < line.size && (line[prefix] == b' ' || line[prefix] == b'\t')) {
            prefix++
        }
        if (prefix < line.size && line[prefix] == b'*') {
            line = line[prefix + 1..]
            if (line.startsWith(" ")) { line = line.removePrefix(" ") }
        } else {
            // Preserve indentation after the conventional leading `*`: four
            // spaces are semantically significant for Markdown code blocks.
            // Unstarred block comments retain the historical normalization.
            line = line.trimAsciiStart()
        }
        if (!result.isEmpty() || !line.isEmpty()) { result.add(line) }
    }
    while (!result.isEmpty() && result[result.size - 1].isEmpty()) { result.remove(at: result.size - 1) }
    return result
}

private func splitSubject(rest: String): (String, String) {
    let parts = rest.trimAscii().split(" ", 2, removeEmpty: true)
    if (parts.size == 0) { return ("", "") }
    if (parts.size == 1) { return (parts[0], "") }
    return (parts[0], parts[1].trimAscii())
}

private func splitReferenceSubject(rest: String): (String, String) {
    let value = rest.trimAscii()
    if (value.isEmpty()) { return ("", "") }
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    var angleDepth: Int64 = 0
    var braceDepth: Int64 = 0
    var index: Int64 = 0
    while (index < value.size) {
        match (value[index]) {
            case b'(' => roundDepth++
            case b')' => if (roundDepth > 0) { roundDepth-- }
            case b'[' => squareDepth++
            case b']' => if (squareDepth > 0) { squareDepth-- }
            case b'<' => angleDepth++
            case b'>' =>
                if (angleDepth > 0 && !(index > 0 && value[index - 1] == b'-')) { angleDepth-- }
            case b'{' => braceDepth++
            case b'}' => if (braceDepth > 0) { braceDepth-- }
            case b' ' | b'\t' | b'\r' | b'\n' =>
                if (roundDepth == 0 && squareDepth == 0 && angleDepth == 0 && braceDepth == 0) {
                    return (value[..index], value[index..].trimAscii())
                }
            case _ => ()
        }
        index++
    }
    (value, "")
}

private func isStructuredDocTag(tagText: String): Bool {
    tagText.startsWith("@param ") ||
        tagText == "@return" || tagText.startsWith("@return ") ||
        tagText.startsWith("@throws ") ||
        tagText == "@see" || tagText.startsWith("@see ") ||
        tagText.startsWith("@since ") ||
        tagText == "@deprecated" || tagText.startsWith("@deprecated ") ||
        tagText.startsWith("@author ") ||
        tagText.startsWith("@version ") ||
        tagText == "@example" || tagText.startsWith("@example ")
}

private func rawJoinLines(lines: ArrayList<String>): String {
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < lines.size) {
        if (index > 0) { builder.append("\n") }
        builder.append(lines[index])
        index++
    }
    builder.toString()
}

private class MarkdownBlockStructure {
    let topLevelParagraphs: ArrayList<SourceSpan>
    let available: Bool

    init(topLevelParagraphs: ArrayList<SourceSpan>, available: Bool) {
        this.topLevelParagraphs = topLevelParagraphs
        this.available = available
    }
}

// Structured tags are recognized only in top-level Markdown paragraphs. This
// deliberately delegates fenced/indented/list/blockquote structure to the same
// GFM parser used by the public adapter instead of maintaining a second fence
// state machine with subtly different CommonMark rules.
private func markdownBlockStructure(source: String): MarkdownBlockStructure {
    try {
        let parsed = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).
            build().parse(source)
        let children = parsed.document.root().children()
        let paragraphs = ArrayList<SourceSpan>()
        var index: Int64 = 0
        while (index < children.size) {
            let child = children[index]
            match (child.kind) {
                case NodeKind.Paragraph =>
                    if (let Some(span) <- child.span) { paragraphs.add(span) }
                case _ => ()
            }
            index++
        }
        MarkdownBlockStructure(paragraphs, true)
    } catch (_: Exception) {
        // Malformed or resource-rejected Markdown must not promote apparent
        // tags out of unknown block structure.
        MarkdownBlockStructure(ArrayList<SourceSpan>(), false)
    }
}

private func topLevelParagraphLines(lines: ArrayList<String>,
    structure: MarkdownBlockStructure): Array<Bool> {
    let eligible = Array<Bool>(lines.size, repeat: false)
    if (!structure.available) { return eligible }
    var paragraphIndex: Int64 = 0
    var lineStart: Int64 = 0
    var lineIndex: Int64 = 0
    while (lineIndex < lines.size) {
        let lineEnd = lineStart + lines[lineIndex].size
        while (paragraphIndex < structure.topLevelParagraphs.size &&
            structure.topLevelParagraphs[paragraphIndex].endByte <= lineStart) {
            paragraphIndex++
        }
        if (paragraphIndex < structure.topLevelParagraphs.size) {
            let span = structure.topLevelParagraphs[paragraphIndex]
            eligible[lineIndex] = lineStart < span.endByte && lineEnd > span.startByte
        }
        lineStart = lineEnd + 1
        lineIndex++
    }
    eligible
}

private func splitMarkdownBody(body: ArrayList<String>): (String, String) {
    let source = rawJoinLines(body).trimAscii()
    if (source.isEmpty()) { return ("", "") }
    let structure = markdownBlockStructure(source)
    if (!structure.topLevelParagraphs.isEmpty()) {
        let paragraph = structure.topLevelParagraphs[0]
        if (paragraph.startByte >= 0 && paragraph.endByte > paragraph.startByte &&
            paragraph.endByte <= source.size) {
            let before = source[..paragraph.startByte].trimAscii()
            let after = source[paragraph.endByte..].trimAscii()
            let description = if (before.isEmpty()) {
                after
            } else if (after.isEmpty()) {
                before
            } else {
                "${before}\n\n${after}"
            }
            return (source[paragraph.startByte..paragraph.endByte].trimAscii(), description)
        }
    }
    if (structure.available) {
        // A document containing only non-paragraph blocks has no prose summary;
        // retain every block as description instead of promoting a heading,
        // list, or code block into the summary field.
        return ("", source)
    }
    // Fail soft while preserving the complete prose if Markdown parsing does
    // not provide a trustworthy first-block boundary.
    (source, "")
}

private class DocCommentParseState {
    let body = ArrayList<String>()
    let params = ArrayList<DocTag>()
    let examples = ArrayList<DocTag>()
    let throwsTags = ArrayList<DocTag>()
    let seeTags = ArrayList<DocTag>()
    let authors = ArrayList<String>()
    var returns: ?DocTag = None
    var returnTagCount: Int64 = 0
    var since: ?String = None
    var deprecated: ?String = None
    var version: ?String = None
    var currentTag: ?DocTag = None
    var currentExample: ?DocTag = None

    private func appendExampleText(example: DocTag, line: String): Unit {
        example.description = if (example.description.isEmpty()) {
            line
        } else {
            example.description + "\n" + line
        }
    }

    func consumeExampleLine(line: String, tagEligible: Bool): Bool {
        match (currentExample) {
            case Some(example) =>
                if (tagEligible && isStructuredDocTag(line.trimAscii())) {
                    currentExample = None
                    false
                } else {
                    appendExampleText(example, line)
                    true
                }
            case None => false
        }
    }

    func appendBodyLine(line: String): Unit {
        body.add(line)
        currentTag = None
    }

    func consumeStructuredTag(line: String, tagText: String): Bool {
        if (!tagText.startsWith("@")) { return false }
        currentTag = None
        if (tagText.startsWith("@param ")) {
            let (subject, description) = splitSubject(tagText.removePrefix("@param "))
            let tag = DocTag("param", subject, description)
            params.add(tag)
            currentTag = tag
        } else if (tagText == "@return" || tagText.startsWith("@return ")) {
            let description = if (tagText == "@return") {
                ""
            } else {
                tagText.removePrefix("@return ").trimAscii()
            }
            let tag = DocTag("return", "", description)
            returns = tag
            returnTagCount++
            currentTag = tag
        } else if (tagText.startsWith("@throws ")) {
            let (subject, description) = splitSubject(tagText.removePrefix("@throws "))
            let tag = DocTag("throws", subject, description)
            throwsTags.add(tag)
            currentTag = tag
        } else if (tagText == "@see" || tagText.startsWith("@see ")) {
            let rest = if (tagText == "@see") { "" } else { tagText.removePrefix("@see ") }
            let (subject, description) = splitReferenceSubject(rest)
            let tag = DocTag("see", subject, description)
            seeTags.add(tag)
            currentTag = tag
        } else if (tagText == "@example" || tagText.startsWith("@example ")) {
            let title = tagText.removePrefix("@example").trimAscii()
            let tag = DocTag("example", title, "")
            examples.add(tag)
            currentExample = Some(tag)
        } else if (tagText.startsWith("@since ")) {
            since = tagText.removePrefix("@since ").trimAscii()
        } else if (tagText == "@deprecated" || tagText.startsWith("@deprecated ")) {
            deprecated = if (tagText == "@deprecated") {
                ""
            } else {
                tagText.removePrefix("@deprecated ").trimAscii()
            }
        } else if (tagText.startsWith("@author ")) {
            authors.add(tagText.removePrefix("@author ").trimAscii())
        } else if (tagText.startsWith("@version ")) {
            version = tagText.removePrefix("@version ").trimAscii()
        } else {
            body.add(line)
        }
        true
    }

    func consumeTagContinuation(line: String, tagText: String): Unit {
        match (currentTag) {
            case Some(tag) =>
                if (!tagText.isEmpty()) {
                    tag.description = if (tag.description.isEmpty()) {
                        tagText
                    } else {
                        tag.description + "\n" + tagText
                    }
                } else {
                    appendBodyLine(line)
                }
            case None => body.add(line)
        }
    }

    func toDocComment(raw: String): DocComment {
        let (summary, description) = splitMarkdownBody(body)
        let parsed = DocComment(raw, summary, description)
        parsed.params.add(all: params)
        parsed.examples.add(all: examples)
        parsed.returns = returns
        parsed.returnTagCount = returnTagCount
        parsed.throwsTags.add(all: throwsTags)
        parsed.see.add(all: seeTags)
        parsed.since = since
        parsed.deprecated = deprecated
        parsed.authors.add(all: authors)
        parsed.version = version
        parsed
    }
}

func parseDocComment(raw: String): DocComment {
    let lines = cleanDocLines(raw)
    let state = DocCommentParseState()
    let structure = markdownBlockStructure(rawJoinLines(lines))
    let tagEligible = topLevelParagraphLines(lines, structure)
    var lineIndex: Int64 = 0
    while (lineIndex < lines.size) {
        let line = lines[lineIndex]
        if (state.consumeExampleLine(line, tagEligible[lineIndex])) {
            lineIndex++
            continue
        }
        if (!tagEligible[lineIndex]) {
            state.appendBodyLine(line)
            lineIndex++
            continue
        }
        let tagText = line.trimAscii()
        if (state.consumeStructuredTag(line, tagText)) {
            lineIndex++
            continue
        }
        state.consumeTagContinuation(line, tagText)
        lineIndex++
    }
    state.toDocComment(raw)
}
