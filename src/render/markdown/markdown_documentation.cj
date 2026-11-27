protected package cjdoc.render.markdown

import cjdoc.render.routes.ApiHtmlRoutes
import cjdoc.render.reading.{
    ExampleFenceOpening, behaviorContractLabel, capturedAdmonitionTreeContains, contentLanguageLabel,
    exampleFenceOpening, isBehaviorContractTag, isExampleFenceClosing, trimExampleBlankLines}
import cjdoc.render.routes.label
import cjdoc.render.foundation.{
    RenderTextBuffer, appendEscapedMarkdownText, appendMarkdownMarks, appendMarkdownCodeSpan}
import cjdoc.model.*
import std.collection.*

internal func appendEscapedMarkdownExampleProse(out: RenderTextBuffer, value: String): Unit {
    for (rune in value.runes()) {
        match (rune) {
            case '<' => out.append("&lt;")
            case '>' => out.append("&gt;")
            case '\\' | '`' | '*' | '_' | '{' | '}' | '[' | ']' | '(' | ')' |
                '#' | '+' | '-' | '.' | '!' | '|' | '=' | '~' =>
                out.append("\\"); out.append(rune)
            case _ => out.append(rune)
        }
    }
}

internal func appendMarkdownExampleContent(out: RenderTextBuffer, value: String): Unit {
    let content = trimExampleBlankLines(value)
    if (content.isEmpty()) { return }
    var activeFence: ?ExampleFenceOpening = None
    for (line in content.split("\n")) {
        match (activeFence) {
            case Some(fence) =>
                out.append(line); out.append("\n")
                if (isExampleFenceClosing(line, fence)) { activeFence = None }
            case None =>
                match (exampleFenceOpening(line)) {
                    case Some(fence) =>
                        out.append(line); out.append("\n")
                        activeFence = Some(fence)
                    case None =>
                        appendEscapedMarkdownExampleProse(out, line)
                        out.append("\n")
                }
        }
    }
    match (activeFence) {
        case Some(fence) =>
            appendMarkdownMarks(out, fence.marker, fence.length)
            out.append("\n")
        case None => ()
    }
}

private func markdownHasDescription(comment: DocComment): Bool {
    for (tag in comment.tags) {
        if (tag.name == "deprecated" || tag.name == "summary" ||
            tag.name == "description" || isAdmonitionLevel(tag.name)) {
            return true
        }
    }
    if (comment.localizationScope == "admonitions" || comment.localizedTexts.isEmpty()) {
        return !comment.markdown.children.isEmpty() || !comment.markdown.literal.isEmpty()
    }
    false
}

private func markdownSectionSelected(sections: ?Array<String>, name: String): Bool {
    match (sections) {
        case Some(values) => values.contains(name)
        case None => true
    }
}

protected func appendDocumentationTagMarkdown(out: RenderTextBuffer, tag: DocTag,
    assetLookup: HashMap<String, String>, locale: String, pagePath: String,
    symbolIndex: ?HashMap<String, SymbolDoc>, canonicalHtml!: ?ApiHtmlRoutes = None,
    headingBase!: Int64 = 4, headingAnchorPrefix!: String = "markdown",
    headingOrdinal!: Int64 = -1,
    headingContext!: ?MarkdownOutputHeadingContext = None): Unit {
    let languageLabel = contentLanguageLabel(tag, locale)
    if (!tag.translationState.isEmpty() && !languageLabel.isEmpty()) {
        out.append("_"); appendEscapedMarkdownText(out, languageLabel); out.append("_.\n\n")
    }
    if (tag.name == "example") {
        // Examples stay in their authored line structure: fence markers,
        // indentation, Unicode and nested fences survive unchanged.
        appendMarkdownExampleContent(out, tag.description)
        return
    }
    match (tag.descriptionMarkdown) {
        case Some(tree) =>
            // Independent tag bodies own fragments even when their headings still fit H1–H6.
            let context = if (headingContext.isSome()) { headingContext }
                else { markdownOutputHeadingContext(tree, headingBase, headingAnchorPrefix, headingOrdinal,
                    namespaceHeadings: tag.name != "summary" && tag.name != "description") }
            let fragmentLinks: ?HashMap<String, String> = match (context) {
                case Some(value) => Some(markdownHeadingFragmentLinks(value, None))
                case None => None
            }
            appendMarkdownNodeMarkdown(out, tree, assetLookup, headingBase,
                pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: fragmentLinks,
                canonicalHtml: canonicalHtml, headingContext: context,
                headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: headingOrdinal)
        case None => appendEscapedMarkdownText(out, tag.description)
    }
}

private func appendDocumentationAdmonitionsMarkdown(out: RenderTextBuffer,
    comment: DocComment, assetLookup: HashMap<String, String>, locale: String,
    pagePath: String, symbolIndex: ?HashMap<String, SymbolDoc>, canonicalHtml: ?ApiHtmlRoutes,
    headingBase: Int64, headingAnchorPrefix: String): Unit {
    for (tagIndex in 0..comment.tags.size) {
        let tag = comment.tags[tagIndex]
        if (!isAdmonitionLevel(tag.name)) { continue }
        match (tag.descriptionMarkdown) {
            case Some(tree) =>
                if (capturedAdmonitionTreeContains(tree, tag.name)) {
                    appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath,
                        symbolIndex, canonicalHtml: canonicalHtml, headingBase: headingBase,
                        headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                    out.append("\n\n")
                }
            case None => ()
        }
    }
}

protected func appendDocumentationListTagMarkdown(out: RenderTextBuffer, tag: DocTag,
    assetLookup: HashMap<String, String>, locale: String, pagePath: String,
    symbolIndex: ?HashMap<String, SymbolDoc>, canonicalHtml!: ?ApiHtmlRoutes = None,
    headingBase!: Int64 = 4, headingAnchorPrefix!: String = "markdown",
    headingOrdinal!: Int64 = -1): Unit {
    let content = RenderTextBuffer()
    appendDocumentationTagMarkdown(content, tag, assetLookup, locale, pagePath, symbolIndex,
        canonicalHtml: canonicalHtml, headingBase: headingBase,
        headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: headingOrdinal)
    appendMarkdownPrefixedBlock(out, content.toString(), "", "    ")
}

// One projection feeds the Markdown site, declaration references and the
// reading core. Callers select chapters; the chapters themselves stay the
// author's unmodified text and code.
protected func appendDocumentationMarkdown(out: RenderTextBuffer, comment: DocComment,
    assetLookup: HashMap<String, String>, locale!: String = "en", pagePath!: String = "",
    symbolIndex!: ?HashMap<String, SymbolDoc> = None, canonicalHtml!: ?ApiHtmlRoutes = None,
    sections!: ?Array<String> = None, headingPrefix!: String = "####",
    headingBase!: Int64 = 4, headingAnchorPrefix!: String = "markdown",
    payloadKind!: String = ""): Unit {
    if (markdownSectionSelected(sections, "description") && markdownHasDescription(comment)) {
        if (sections.isSome()) {
            out.append("${headingPrefix} ${label(locale, "Description", "说明")}\n\n")
        }
        if (comment.localizationScope == "admonitions" || comment.localizedTexts.isEmpty()) {
            appendMarkdownNodeMarkdown(out, comment.markdown, assetLookup, headingBase, pagePath: pagePath,
                symbolIndex: symbolIndex, canonicalHtml: canonicalHtml,
                headingAnchorPrefix: headingAnchorPrefix)
        } else {
            let context = markdownDescriptionHeadingContext(comment, headingBase, headingAnchorPrefix)
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (tag.name != "summary" && tag.name != "description") { continue }
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase,
                    headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex,
                    headingContext: context)
                out.append("\n\n")
            }
        }
        appendDocumentationAdmonitionsMarkdown(out, comment, assetLookup, locale, pagePath,
            symbolIndex, canonicalHtml, headingBase, headingAnchorPrefix)
    }
    if (markdownSectionSelected(sections, "contracts")) {
        for (tagIndex in 0..comment.tags.size) {
            let tag = comment.tags[tagIndex]
            if (tag.name == "deprecated") {
                let content = RenderTextBuffer()
                content.append("**${label(locale, "Deprecated.", "已弃用。")}** ")
                appendDocumentationTagMarkdown(content, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase,
                    headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                appendMarkdownPrefixedBlock(out, content.toString(), "> ", "> ")
                out.append("\n")
                break
            }
        }
    }
    if (markdownSectionSelected(sections, "examples")) {
        var hasExamples = false
        for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
        if (hasExamples) {
            out.append("${headingPrefix} ${label(locale, "Examples", "示例")}\n\n")
            for (tag in comment.tags) {
                if (tag.name != "example") { continue }
                if (!tag.subject.isEmpty()) {
                    if (headingPrefix.size < 6) { out.append("${headingPrefix}# ") }
                    else { out.append("**") }
                    appendEscapedMarkdownText(out, tag.subject)
                    if (headingPrefix.size >= 6) { out.append("**") }
                    out.append("\n\n")
                }
                let content = trimExampleBlankLines(tag.description)
                if (!content.isEmpty() || !tag.translationState.isEmpty()) {
                    appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase)
                    out.append("\n")
                }
            }
        }
    }
    if (markdownSectionSelected(sections, "parameters")) {
        var hasParameters = false
        for (tag in comment.tags) { if (tag.name == "param") { hasParameters = true; break } }
        if (hasParameters) {
            out.append("${headingPrefix} ${label(locale, "Parameters", "参数")}\n\n")
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (tag.name == "param") {
                    out.append("- ")
                    appendMarkdownCodeSpan(out, parameterSubjectDisplay(payloadKind, tag.subject))
                    out.append(" — ")
                    appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase,
                        headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                }
            }
            out.append("\n")
        }
    }
    if (markdownSectionSelected(sections, "returns")) {
        for (tagIndex in 0..comment.tags.size) {
            let tag = comment.tags[tagIndex]
            if (tag.name == "return" || tag.name == "returns") {
                out.append("${headingPrefix} ${label(locale, "Returns", "返回值")}\n\n")
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase,
                    headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                out.append("\n\n")
            }
        }
    }
    if (markdownSectionSelected(sections, "contracts")) {
        var hasThrows = false
        for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
        if (hasThrows) {
            out.append("${headingPrefix} ${label(locale, "Throws", "异常")}\n\n")
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (tag.name == "throws") {
                    out.append("- ")
                    appendTagSubjectMarkdown(out, tag, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml)
                    out.append(" — ")
                    appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase,
                        headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                }
            }
            out.append("\n")
        }
    }
    if (markdownSectionSelected(sections, "contracts")) {
        var hasContracts = false
        for (tag in comment.tags) {
            if (isBehaviorContractTag(tag.name)) { hasContracts = true; break }
        }
        if (hasContracts) {
            out.append("${headingPrefix} " + label(locale, "Behavior contracts", "行为契约") + "\n\n")
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (!isBehaviorContractTag(tag.name)) { continue }
                out.append("- **")
                appendEscapedMarkdownText(out, behaviorContractLabel(tag.name, locale))
                out.append("**")
                if (!tag.subject.isEmpty()) {
                    out.append(" (")
                    appendMarkdownCodeSpan(out, tag.subject)
                    out.append(")")
                }
                out.append(" — ")
                if (tag.description.trimAscii().isEmpty()) {
                    out.append("**incomplete**")
                } else {
                    appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase,
                        headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                }
                out.append("\n")
            }
            out.append("\n")
        }
    }
    if (markdownSectionSelected(sections, "relations")) {
        var hasSee = false
        for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
        if (hasSee) {
            out.append("${headingPrefix} ${label(locale, "See also", "另请参阅")}\n\n")
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (tag.name == "see") {
                    out.append("- "); appendTagSubjectMarkdown(out, tag, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml)
                    if (!tag.description.isEmpty() || !tag.translationState.isEmpty()) {
                        out.append(" — ")
                        appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                            canonicalHtml: canonicalHtml, headingBase: headingBase,
                            headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                    }
                    out.append("\n")
                }
            }
            out.append("\n")
        }
    }
    for ((name, heading) in [("since", "Since"), ("author", "Authors"),
            ("version", "Version")]) {
        if ((name == "since" && !markdownSectionSelected(sections, "contracts")) ||
            (name != "since" && !markdownSectionSelected(sections, "relations"))) { continue }
            var opened = false
            for (tagIndex in 0..comment.tags.size) {
                let tag = comment.tags[tagIndex]
                if (tag.name != name) { continue }
                if (!opened) {
                    out.append("${headingPrefix} ${label(locale, heading, match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" })}\n\n")
                    opened = true
                }
                out.append("- ")
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase,
                    headingAnchorPrefix: headingAnchorPrefix, headingOrdinal: tagIndex)
                out.append("\n")
            }
            if (opened) { out.append("\n") }
        }
}

