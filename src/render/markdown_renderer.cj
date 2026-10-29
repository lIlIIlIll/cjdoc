package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func markdownRelativeDestination(destination: String, pagePath: String): String {
    if (destination.startsWith("https://") || destination.startsWith("http://")) { return destination }
    if (pagePath.startsWith("symbols/") && destination.startsWith("symbols/")) {
        destination["symbols/".size..]
    } else if (pagePath.startsWith("packages/") || pagePath.startsWith("symbols/")) {
        "../" + destination
    } else { destination }
}

// Agent references are published inside the HTML document root. pagePath is
// relative to that root, not the generator's staging directory. Never embed
// the staging directory name: a site can be deployed at any HTTP subpath.
// Aggregate site Markdown retains its historical sibling-directory routing.
internal func markdownOutputRootPrefix(pagePath: String): String {
    let segments = ArrayList<String>()
    for (segment in pagePath.split("/")) {
        if (!segment.isEmpty()) { segments.add(segment) }
    }
    var hops = segments.size
    if (!pagePath.endsWith("/") && hops > 0) { hops-- }
    var prefix = ""
    for (_ in 0..hops) { prefix += "../" }
    prefix
}

internal func markdownCanonicalHtmlDestination(value: String, pagePath: String): ?String {
    if (value.startsWith("https://") || value.startsWith("http://")) {
        return markdownLinkDestination(value)
    }
    let relative = value.removePrefix("./")
    let parts = relative.split("#", 2)
    if (parts.isEmpty() || !safeRelativeLinkDestination(parts[0])) { return None }
    var destination = markdownOutputRootPrefix(pagePath) + parts[0]
    if (parts.size == 2) {
        if (!safeLinkDestination("#" + parts[1])) { return None }
        destination += "#" + parts[1]
    }
    Some(encodeMarkdownDestination(destination))
}

internal func markdownCanonicalSymbolDestination(symbol: SymbolDoc, pagePath: String): ?String {
    markdownCanonicalHtmlDestination(symbolPagePath(symbol), pagePath)
}

internal func markdownResolvedNavigationDestination(navigation: TypeNavigation,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml: Bool): ?String {
    if (canonicalHtml) {
        if (navigation.symbolKey.startsWith("cjdoc:v2:") &&
            !symbolIndex.contains(navigation.symbolKey)) { return None }
        if (let Some(target) <- symbolIndex.get(navigation.symbolKey)) {
            // Standalone HTML pages do not carry aggregate Markdown anchors.
            // Keep their canonical route rather than inventing a fragment.
            if (navigation.url == symbolPagePath(target)) {
                return markdownCanonicalSymbolDestination(target, pagePath)
            }
        }
        return markdownCanonicalHtmlDestination(navigation.url, pagePath)
    }
    return markdownNavigationDestination(navigation, pagePath, symbolIndex)
}

internal func markdownTargetPagePath(target: SymbolDoc,
    symbolIndex: HashMap<String, SymbolDoc>): String {
    if (isContainerDeclaration(target)) {
        markdownSymbolPagePath(target)
    } else {
        match (target.ownerId) {
            case Some(ownerId) => match (symbolIndex.get(ownerId)) {
                case Some(owner) => markdownSymbolPagePath(owner)
                case None => markdownPackagePagePath(target.moduleId, target.packageName)
            }
            case None => markdownPackagePagePath(target.moduleId, target.packageName)
        }
    }
}

private func markdownSemanticLinkDestination(destination: String, pagePath: String,
    targetSymbolId!: ?String = None,
    symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    canonicalHtml!: Bool = false): ?String {
    match ((targetSymbolId, symbolIndex)) {
        case (Some(targetId), Some(index)) => match (index.get(targetId)) {
            case Some(target) =>
                if (canonicalHtml) {
                    return markdownCanonicalSymbolDestination(target, pagePath)
                }
                let targetPage = if (pagePath.isEmpty()) {
                    "#${symbolAnchor(target)}"
                } else {
                    let page = markdownTargetPagePath(target, index)
                    if (page == pagePath) {
                        "#${symbolAnchor(target)}"
                    } else {
                        "${markdownRelativeDestination(page, pagePath)}#${symbolAnchor(target)}"
                    }
                }
                return markdownLinkDestination(targetPage, allowRelative: true)
            case None => ()
        }
        case _ => ()
    }
    if (canonicalHtml) { return markdownCanonicalHtmlDestination(destination, pagePath) }
    let localDestination = if (!pagePath.isEmpty() && destination.startsWith("symbols/") &&
        destination.endsWith(".html")) {
        destination[..destination.size - 5] + ".md"
    } else { destination }
    let relativeDestination = markdownRelativeDestination(localDestination, pagePath)
    markdownLinkDestination(relativeDestination, allowRelative: true)
}

internal func appendMarkdownInlineNode(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    pagePath!: String = "", symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    tableCell!: Bool = false, capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: Bool = false): Unit {
    match (node.kind) {
        case "text" => appendEscapedMarkdownText(out, node.literal)
        case "soft_break" => out.append(if (tableCell) { "<br>" } else { "\n" })
        case "hard_break" => out.append(if (tableCell) { "<br>" } else { "  \n" })
        case "emphasis" =>
            out.append("*"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("*")
        case "strong" =>
            out.append("**"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("**")
        case "strikethrough" =>
            out.append("~~"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("~~")
        case "code_span" => appendMarkdownCodeSpan(out, node.literal, tableCell: tableCell)
        case "link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("]")
            let captured: ?String = match (capturedLinks) { case Some(links) => links.get(node.literal); case None => None }
            if (let Some(destination) <- captured) {
                // Only captured page routes enter this map; arbitrary author URLs keep the normal validator.
                out.append("(" + encodeMarkdownDestination(destination) + ")")
            } else {
                match (markdownLinkDestination(node.literal)) {
                    case Some(destination) => out.append("(${destination})")
                    case None => ()
                }
            }
        case "semantic_link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: tableCell)
            }; out.append("]")
            match (node.metadata) {
                case Some(metadata) =>
                    if (let Some(navigation) <- metadata.semanticNavigation) {
                        let index = symbolIndex.getOrDefault({ => HashMap<String, SymbolDoc>() })
                        if (let Some(encoded) <- markdownResolvedNavigationDestination(navigation,
                            pagePath, index, canonicalHtml)) {
                            out.append("(" + encoded)
                            appendMarkdownNavigationTitle(out, Some(navigation))
                            out.append(")")
                        }
                    } else if (let Some(destination) <- metadata.semanticExternalUrl) {
                        if (let Some(encoded) <- markdownSemanticLinkDestination(destination, pagePath,
                            targetSymbolId: metadata.semanticTargetSymbolId, symbolIndex: symbolIndex,
                            canonicalHtml: canonicalHtml)) {
                            out.append("(" + encoded + ")")
                        }
                    }
                case None => ()
            }
        case "image" =>
            let alt = markdownNodeText(node)
            match (assetReference(assetLookup, node.literal)) {
                case Some(path) =>
                    out.append("!["); appendEscapedMarkdownText(out, alt)
                    match (markdownLinkDestination("#${path}")) {
                        case Some(encoded) => out.append("](${encoded[1..]})")
                        case None => out.append("]")
                    }
                case None => appendEscapedMarkdownText(out, alt)
            }
        case "html_inline" | "html_block" => appendEscapedMarkdownText(out, node.literal)
        case _ => for (child in node.children) {
            appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                tableCell: tableCell)
        }
    }
}

internal func appendMarkdownPrefixedBlock(out: RenderTextBuffer, content: String,
    firstPrefix: String, continuationPrefix: String,
    prefixBlankLines!: Bool = true): Unit {
    let lines = content.split("\n")
    var end = lines.size
    while (end > 0 && lines[end - 1].isEmpty()) { end-- }
    var index: Int64 = 0
    var wrote = false
    while (index < end) {
        if (!lines[index].isEmpty() || prefixBlankLines) {
            out.append(if (!wrote) { firstPrefix } else { continuationPrefix })
        }
        out.append(lines[index]); out.append("\n")
        wrote = true
        index++
    }
    if (!wrote) { out.append(firstPrefix); out.append("\n") }
}

internal func appendMarkdownTableMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64, pagePath!: String = "",
    symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: Bool = false): Unit {
    var rowIndex: Int64 = 0
    for (row in node.children) {
        out.append("|")
        for (cell in row.children) {
            out.append(" ")
            for (child in cell.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml, capturedLinks: capturedLinks,
                    tableCell: true)
            }
            out.append(" |")
        }
        out.append("\n")
        if (rowIndex == 0) {
            out.append("|")
            var column: Int64 = 0
            for (_ in row.children) {
                let alignment = match (node.metadata) {
                    case Some(metadata) => if (column < metadata.tableAlignments.size) {
                        metadata.tableAlignments[column]
                    } else { "none" }
                    case None => "none"
                }
                match (alignment) {
                    case "left" => out.append(" :--- |")
                    case "center" => out.append(" :---: |")
                    case "right" => out.append(" ---: |")
                    case _ => out.append(" --- |")
                }
                column++
            }
            out.append("\n")
        }
        rowIndex++
    }
    out.append("\n")
}

internal func appendMarkdownNodeMarkdown(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    pagePath!: String = "", symbolIndex!: ?HashMap<String, SymbolDoc> = None,
    capturedLinks!: ?HashMap<String, String> = None,
    canonicalHtml!: Bool = false): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        }
        case "paragraph" =>
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
            out.append("\n\n")
        case "heading" =>
            appendMarkdownMarks(out, "#", markdownHeadingLevel(node, headingBase)); out.append(" ")
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
            out.append("\n\n")
        case "text" | "soft_break" | "hard_break" | "emphasis" | "strong" |
            "strikethrough" | "code_span" | "link" | "image" | "html_inline" =>
            appendMarkdownInlineNode(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "code_block" =>
            match (node.metadata) {
                case Some(metadata) => if (metadata.kind == "code_block" &&
                    metadata.codeKind.getOrThrow() == "fenced") {
                    let marker = metadata.fenceCharacter.getOrThrow()
                    let fenceLength = metadata.fenceLength.getOrThrow()
                    let infoRaw = metadata.infoRaw.getOrThrow()
                    appendMarkdownCodeBlock(out, node.literal, infoRaw, marker, fenceLength)
                } else {
                    appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
                }
                case None => appendMarkdownCodeBlock(out, node.literal, "", "`", 3)
            }
        case "thematic_break" => out.append("---\n\n")
        case "block_quote" =>
            let nested = RenderTextBuffer()
            for (child in node.children) {
                appendMarkdownNodeMarkdown(nested, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
            appendMarkdownPrefixedBlock(out, nested.toString(), "> ", "> ")
            out.append("\n")
        case "list" =>
            var itemIndex: Int64 = 0
            let tight = match (node.metadata) {
                case Some(value) => value.kind == "list" && value.listTight.getOrThrow()
                case None => true
            }
            for (child in node.children) {
                let marker = if (let Some(value) <- node.metadata) {
                    if (value.kind == "list" && value.listKind.getOrThrow() == "ordered") {
                        let delimiter = if (value.listDelimiter.getOrThrow() == "parenthesis") {
                            ") "
                        } else { ". " }
                        "${value.listStart.getOrThrow() + itemIndex}${delimiter}"
                    } else { "- " }
                } else { "- " }
                let firstPrefix = RenderTextBuffer()
                firstPrefix.append(marker)
                if (let Some(itemMetadata) <- child.metadata) {
                    if (itemMetadata.kind == "list_item") {
                        match (itemMetadata.taskState.getOrThrow()) {
                            case "checked" => firstPrefix.append("[x] ")
                            case "unchecked" => firstPrefix.append("[ ] ")
                            case _ => ()
                        }
                    }
                }
                let nested = RenderTextBuffer()
                for (itemChild in child.children) {
                    appendMarkdownNodeMarkdown(nested, itemChild, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
                }
                let continuation = RenderTextBuffer()
                appendMarkdownMarks(continuation, " ", firstPrefix.toString().size)
                appendMarkdownPrefixedBlock(out, nested.toString(), firstPrefix.toString(),
                    continuation.toString(), prefixBlankLines: false)
                if (!tight && itemIndex + 1 < node.children.size) { out.append("\n") }
                itemIndex++
            }
            out.append("\n")
        case "list_item" =>
            for (child in node.children) {
                appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
            }
        case "table" => appendMarkdownTableMarkdown(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "table_row" | "table_cell" | "custom_block" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        }
        case "custom_inline" => appendMarkdownInlineNode(out, node, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        case "html_block" => appendEscapedMarkdownText(out, node.literal); out.append("\n\n")
        case _ => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase, pagePath: pagePath, symbolIndex: symbolIndex, capturedLinks: capturedLinks, canonicalHtml: canonicalHtml)
        }
    }
}

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
        if (tag.name == "deprecated" || tag.name == "summary" || tag.name == "description") {
            return true
        }
    }
    if (comment.localizedTexts.isEmpty()) {
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

internal func appendDocumentationTagMarkdown(out: RenderTextBuffer, tag: DocTag,
    assetLookup: HashMap<String, String>, locale: String, pagePath: String,
    symbolIndex: ?HashMap<String, SymbolDoc>, canonicalHtml!: Bool = false,
    headingBase!: Int64 = 4): Unit {
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
        case Some(tree) => appendMarkdownNodeMarkdown(out, tree, assetLookup, headingBase,
            pagePath: pagePath, symbolIndex: symbolIndex, canonicalHtml: canonicalHtml)
        case None => appendEscapedMarkdownText(out, tag.description)
    }
}

internal func appendDocumentationListTagMarkdown(out: RenderTextBuffer, tag: DocTag,
    assetLookup: HashMap<String, String>, locale: String, pagePath: String,
    symbolIndex: ?HashMap<String, SymbolDoc>, canonicalHtml!: Bool = false,
    headingBase!: Int64 = 4): Unit {
    let content = RenderTextBuffer()
    appendDocumentationTagMarkdown(content, tag, assetLookup, locale, pagePath, symbolIndex,
        canonicalHtml: canonicalHtml, headingBase: headingBase)
    appendMarkdownPrefixedBlock(out, content.toString(), "", "    ")
}

// One projection feeds the Markdown site, declaration references and the
// reading core. Callers select chapters; the chapters themselves stay the
// author's unmodified text and code.
internal func appendDocumentationMarkdown(out: RenderTextBuffer, comment: DocComment,
    assetLookup: HashMap<String, String>, locale!: String = "en", pagePath!: String = "",
    symbolIndex!: ?HashMap<String, SymbolDoc> = None, canonicalHtml!: Bool = false,
    sections!: ?Array<String> = None, headingPrefix!: String = "####",
    headingBase!: Int64 = 4): Unit {
    if (markdownSectionSelected(sections, "description") && markdownHasDescription(comment)) {
        if (sections.isSome()) {
            out.append("${headingPrefix} ${label(locale, "Description", "说明")}\n\n")
        }
        if (comment.localizedTexts.isEmpty()) {
            appendMarkdownNodeMarkdown(out, comment.markdown, assetLookup, headingBase, pagePath: pagePath,
                symbolIndex: symbolIndex, canonicalHtml: canonicalHtml)
        } else {
            for (tag in comment.tags where tag.name == "summary" || tag.name == "description") {
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase)
                out.append("\n\n")
            }
        }
    }
    if (markdownSectionSelected(sections, "contracts")) {
        for (tag in comment.tags) {
            if (tag.name == "deprecated") {
                let content = RenderTextBuffer()
                content.append("**${label(locale, "Deprecated.", "已弃用。")}** ")
                appendDocumentationTagMarkdown(content, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase)
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
                    out.append("${headingPrefix}# ")
                    appendEscapedMarkdownText(out, tag.subject)
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
            for (tag in comment.tags) {
                if (tag.name == "param") {
                    out.append("- "); appendMarkdownCodeSpan(out, tag.subject); out.append(" — ")
                    appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase)
                }
            }
            out.append("\n")
        }
    }
    if (markdownSectionSelected(sections, "returns")) {
        for (tag in comment.tags) {
            if (tag.name == "return" || tag.name == "returns") {
                out.append("${headingPrefix} ${label(locale, "Returns", "返回值")}\n\n")
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase)
                out.append("\n\n")
            }
        }
    }
    if (markdownSectionSelected(sections, "contracts")) {
        var hasThrows = false
        for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
        if (hasThrows) {
            out.append("${headingPrefix} ${label(locale, "Throws", "异常")}\n\n")
            for (tag in comment.tags) {
                if (tag.name == "throws") {
                    out.append("- ")
                    appendTagSubjectMarkdown(out, tag, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml)
                    out.append(" — ")
                    appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml, headingBase: headingBase)
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
            for (tag in comment.tags) {
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
                        canonicalHtml: canonicalHtml, headingBase: headingBase)
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
            for (tag in comment.tags) {
                if (tag.name == "see") {
                    out.append("- "); appendTagSubjectMarkdown(out, tag, pagePath, symbolIndex,
                        canonicalHtml: canonicalHtml)
                    if (!tag.description.isEmpty() || !tag.translationState.isEmpty()) {
                        out.append(" — ")
                        appendDocumentationListTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                            canonicalHtml: canonicalHtml, headingBase: headingBase)
                    }
                    out.append("\n")
                }
            }
            out.append("\n")
        }
    }
    if (sections.isNone()) {
        if (let Some(tag) <- documentationGroup(comment)) {
            out.append(label(locale, "API group: ", "接口分组："))
            appendEscapedMarkdownText(out, tag.description)
            out.append("\n\n")
        }
    }
    for ((name, heading) in [("since", "Since"), ("author", "Authors"),
            ("version", "Version")]) {
        if ((name == "since" && !markdownSectionSelected(sections, "contracts")) ||
            (name != "since" && !markdownSectionSelected(sections, "relations"))) { continue }
            var opened = false
            for (tag in comment.tags) {
                if (tag.name != name) { continue }
                if (!opened) {
                    out.append("${headingPrefix} ${label(locale, heading, match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" })}\n\n")
                    opened = true
                }
                out.append("- ")
                appendDocumentationTagMarkdown(out, tag, assetLookup, locale, pagePath, symbolIndex,
                    canonicalHtml: canonicalHtml, headingBase: headingBase)
                out.append("\n")
            }
            if (opened) { out.append("\n") }
        }
}

internal func markdownNavigationDestination(navigation: TypeNavigation, pagePath: String,
    symbolIndex: HashMap<String, SymbolDoc>): ?String {
    if (navigation.state != "resolved" || navigationHref("", navigation.url).isNone()) { return None }
    if (navigation.symbolKey.startsWith("cjdoc:v2:") && !symbolIndex.contains(navigation.symbolKey)) { return None }
    if (let Some(target) <- symbolIndex.get(navigation.symbolKey)) {
        if (navigation.url == symbolPagePath(target)) {
            let destination = if (pagePath.isEmpty()) { "#" + symbolAnchor(target) } else {
                let targetPage = markdownTargetPagePath(target, symbolIndex)
                if (targetPage == pagePath) { "#" + symbolAnchor(target) } else {
                    markdownRelativeDestination(targetPage, pagePath) + "#" + symbolAnchor(target)
                }
            }
            return Some(encodeMarkdownDestination(destination))
        }
    }
    let prefix = if (pagePath.startsWith("packages/") || pagePath.startsWith("symbols/")) { "../../html/" } else { "../html/" }
    let destination = if (navigation.url.startsWith("https://") || navigation.url.startsWith("http://")) {
        navigation.url
    } else { prefix + navigation.url.removePrefix("./") }
    // The document-root route was validated above. Only this renderer adds
    // the fixed parent prefix needed to reach html/; untrusted parent paths
    // never pass navigationHref. Do not reclassify that layout prefix as input.
    Some(encodeMarkdownDestination(destination))
}
private func appendMarkdownNavigationTitle(out: RenderTextBuffer, navigation: ?TypeNavigation): Unit {
    if (let Some(value) <- navigation) {
        if (value.state == "resolved") {
            // JSON's quoted-string escaping also protects Markdown's double-quoted
            // title delimiters, without altering the link label or destination.
            out.append(" "); out.append(escapeJsonString(value.matchLevel + ": " + value.reason))
        }
    }
}


internal func appendTagSubjectMarkdown(out: RenderTextBuffer, tag: DocTag,
    pagePath: String, symbolIndex: ?HashMap<String, SymbolDoc>,
    canonicalHtml!: Bool = false): Unit {
    let index = symbolIndex.getOrDefault({ => HashMap<String, SymbolDoc>() })
    let destination: ?String = match (tag.navigation) {
        case Some(navigation) => markdownResolvedNavigationDestination(navigation, pagePath,
            index, canonicalHtml)
        case None => None
    }
    if (destination.isSome()) { out.append("[") }
    appendMarkdownCodeSpan(out, tag.subject)
    if (let Some(url) <- destination) {
        out.append("](" + url); appendMarkdownNavigationTitle(out, tag.navigation); out.append(")")
    }
}

private func appendMarkdownTypeAtom(out: RenderTextBuffer, typeRef: TypeRef,
    spelling: String, pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml: Bool): Unit {
    if (typeRef.navigation.isNone()) {
        appendMarkdownCodeSpan(out, spelling); return
    }
    let destination: ?String = match (typeRef.navigation) {
        case Some(navigation) => markdownResolvedNavigationDestination(navigation, pagePath,
            symbolIndex, canonicalHtml)
        case None => None
    }
    if (destination.isSome()) { out.append("[") }
    appendMarkdownCodeSpan(out, spelling)
    if (let Some(url) <- destination) {
        out.append("](" + url); appendMarkdownNavigationTitle(out, typeRef.navigation); out.append(")")
    }
}

internal func appendTypeRefMarkdown(out: RenderTextBuffer, typeRef: TypeRef,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    canonicalHtml!: Bool = false): Unit {
    if (typeRef.kind == "optional" && typeRef.arguments.size == 1) {
        out.append("?")
        appendTypeRefMarkdown(out, typeRef.arguments[0], pagePath, symbolIndex,
            canonicalHtml: canonicalHtml)
    } else if ((typeRef.kind == "tuple" || typeRef.kind == "function") && !typeRef.arguments.isEmpty()) {
        appendEscapedMarkdownText(out, "(")
        for (index in 0..typeRef.arguments.size) {
            if (typeRef.kind == "function" && index == typeRef.arguments.size - 1) {
                appendEscapedMarkdownText(out, ") -> ")
            } else if (index > 0) { out.append(", ") }
            appendTypeRefMarkdown(out, typeRef.arguments[index], pagePath, symbolIndex,
                canonicalHtml: canonicalHtml)
        }
        if (typeRef.kind == "tuple") { appendEscapedMarkdownText(out, ")") }
    } else if (!typeRef.arguments.isEmpty() && typeRef.spelling.contains("<")) {
        appendMarkdownTypeAtom(out, typeRef, typeHeadSpelling(typeRef.spelling), pagePath, symbolIndex,
            canonicalHtml)
        appendEscapedMarkdownText(out, "<")
        var first = true
        for (child in typeRef.arguments) {
            if (!first) { out.append(", ") }; first = false
            appendTypeRefMarkdown(out, child, pagePath, symbolIndex, canonicalHtml: canonicalHtml)
        }
        appendEscapedMarkdownText(out, ">" + typeGenericSuffix(typeRef.spelling))
    } else {
        appendMarkdownTypeAtom(out, typeRef, typeRef.spelling, pagePath, symbolIndex, canonicalHtml)
    }
}

private func hasResolvedTypeNavigation(value: TypeRef): Bool {
    if (let Some(navigation) <- value.navigation) { if (navigation.state == "resolved") { return true } }
    for (child in value.arguments) { if (hasResolvedTypeNavigation(child)) { return true } }
    false
}

// Keep the source signature in a copyable fence; expose links where readers
// inspect parameter, return and relationship types rather than rewriting code.
internal func appendMarkdownTypeDetails(out: RenderTextBuffer, symbol: SymbolDoc,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>, locale: String): Unit {
    var linked = false
    for (parameter in symbol.parameters) { linked = linked || hasResolvedTypeNavigation(parameter.typeRef) }
    if (let Some(value) <- symbol.returnType) { linked = linked || hasResolvedTypeNavigation(value) }
    for (relationship in symbol.typeRelationships) { linked = linked || hasResolvedTypeNavigation(relationship.target) }
    if (!linked) { return }
    for (parameter in symbol.parameters) {
        out.append("- " + label(locale, "Parameter", "参数") + " ")
        appendMarkdownCodeSpan(out, parameter.name); out.append(": ")
        appendTypeRefMarkdown(out, parameter.typeRef, pagePath, symbolIndex); out.append("\n")
    }
    if (let Some(value) <- symbol.returnType) {
        out.append("- " + label(locale, "Returns", "返回值") + ": ")
        appendTypeRefMarkdown(out, value, pagePath, symbolIndex); out.append("\n")
    }
    for (relationship in symbol.typeRelationships where !pagePath.isEmpty()) {
        out.append("- "); appendEscapedMarkdownText(out, readerRelationshipLabel(relationship.kind, locale))
        out.append(": "); appendTypeRefMarkdown(out, relationship.target, pagePath, symbolIndex); out.append("\n")
    }
    if (!symbol.parameters.isEmpty() || symbol.returnType.isSome() ||
        (!pagePath.isEmpty() && !symbol.typeRelationships.isEmpty())) { out.append("\n") }
}

public class MarkdownDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "markdown" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: locale)
    }
}
