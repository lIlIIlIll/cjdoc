package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendMarkdownInlineNode(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, headingBase: Int64,
    tableCell!: Bool = false): Unit {
    match (node.kind) {
        case "text" => appendEscapedMarkdownText(out, node.literal)
        case "soft_break" => out.append(if (tableCell) { "<br>" } else { "\n" })
        case "hard_break" => out.append(if (tableCell) { "<br>" } else { "  \n" })
        case "emphasis" =>
            out.append("*"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("*")
        case "strong" =>
            out.append("**"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("**")
        case "strikethrough" =>
            out.append("~~"); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("~~")
        case "code_span" => appendMarkdownCodeSpan(out, node.literal, tableCell: tableCell)
        case "link" =>
            out.append("["); for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
                    tableCell: tableCell)
            }; out.append("]")
            match (markdownLinkDestination(node.literal)) {
                case Some(destination) => out.append("(${destination})")
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
            appendMarkdownInlineNode(out, child, assetLookup, headingBase,
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
    assetLookup: HashMap<String, String>, headingBase: Int64): Unit {
    var rowIndex: Int64 = 0
    for (row in node.children) {
        out.append("|")
        for (cell in row.children) {
            out.append(" ")
            for (child in cell.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase,
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
    assetLookup: HashMap<String, String>, headingBase: Int64): Unit {
    match (node.kind) {
        case "document" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
        }
        case "paragraph" =>
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase)
            }
            out.append("\n\n")
        case "heading" =>
            appendMarkdownMarks(out, "#", markdownHeadingLevel(node, headingBase)); out.append(" ")
            for (child in node.children) {
                appendMarkdownInlineNode(out, child, assetLookup, headingBase)
            }
            out.append("\n\n")
        case "text" | "soft_break" | "hard_break" | "emphasis" | "strong" |
            "strikethrough" | "code_span" | "link" | "image" | "html_inline" =>
            appendMarkdownInlineNode(out, node, assetLookup, headingBase)
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
                appendMarkdownNodeMarkdown(nested, child, assetLookup, headingBase)
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
                    appendMarkdownNodeMarkdown(nested, itemChild, assetLookup, headingBase)
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
                appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
            }
        case "table" => appendMarkdownTableMarkdown(out, node, assetLookup, headingBase)
        case "table_row" | "table_cell" | "custom_block" => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
        }
        case "custom_inline" => appendMarkdownInlineNode(out, node, assetLookup, headingBase)
        case "html_block" => appendEscapedMarkdownText(out, node.literal); out.append("\n\n")
        case _ => for (child in node.children) {
            appendMarkdownNodeMarkdown(out, child, assetLookup, headingBase)
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
}

internal func appendDocumentationMarkdown(out: RenderTextBuffer, comment: DocComment,
    assetLookup: HashMap<String, String>, locale!: String = "en"): Unit {
    for (tag in comment.tags) {
        if (tag.name == "deprecated") {
            out.append("> **${label(locale, "Deprecated.", "已弃用。")}** ")
            appendEscapedMarkdownText(out, tag.description)
            out.append("\n\n")
            break
        }
    }
    appendMarkdownNodeMarkdown(out, comment.markdown, assetLookup, 4)
    var hasExamples = false
    for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
    if (hasExamples) {
        out.append("#### ${label(locale, "Examples", "示例")}\n\n")
        for (tag in comment.tags) {
            if (tag.name != "example") { continue }
            if (!tag.subject.isEmpty()) {
                out.append("##### ")
                appendEscapedMarkdownText(out, tag.subject)
                out.append("\n\n")
            }
            let content = trimExampleBlankLines(tag.description)
            if (!content.isEmpty()) {
                appendMarkdownExampleContent(out, content)
                out.append("\n")
            }
        }
    }
    var hasParameters = false
    for (tag in comment.tags) { if (tag.name == "param") { hasParameters = true; break } }
    if (hasParameters) {
        out.append("#### ${label(locale, "Parameters", "参数")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "param") {
                out.append("- "); appendMarkdownCodeSpan(out, tag.subject); out.append(" — ")
                appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    for (tag in comment.tags) {
        if (tag.name == "return") {
            out.append("#### ${label(locale, "Returns", "返回值")}\n\n"); appendEscapedMarkdownText(out, tag.description); out.append("\n\n")
        }
    }
    var hasThrows = false
    for (tag in comment.tags) { if (tag.name == "throws") { hasThrows = true; break } }
    if (hasThrows) {
        out.append("#### ${label(locale, "Throws", "异常")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "throws") {
                out.append("- "); appendMarkdownCodeSpan(out, tag.subject); out.append(" — ")
                appendEscapedMarkdownText(out, tag.description); out.append("\n")
            }
        }
        out.append("\n")
    }
    var hasSee = false
    for (tag in comment.tags) { if (tag.name == "see") { hasSee = true; break } }
    if (hasSee) {
        out.append("#### ${label(locale, "See also", "另请参阅")}\n\n")
        for (tag in comment.tags) {
            if (tag.name == "see") { out.append("- "); appendMarkdownCodeSpan(out, tag.subject)
                if (!tag.description.isEmpty()) {
                    out.append(" — "); appendEscapedMarkdownText(out, tag.description)
                }; out.append("\n") }
        }
        out.append("\n")
    }
    for ((name, heading) in [("since", "Since"), ("author", "Authors"),
        ("version", "Version")]) {
        var opened = false
        for (tag in comment.tags) {
            if (tag.name != name) { continue }
            if (!opened) { out.append("#### ${label(locale, heading, match (name) { case "since" => "自版本"; case "author" => "作者"; case _ => "版本" })}\n\n"); opened = true }
            out.append("- "); appendEscapedMarkdownText(out, tag.description); out.append("\n")
        }
        if (opened) { out.append("\n") }
    }
}

public class MarkdownDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "markdown" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendMarkdownArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

internal func appendMarkdownArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
        validateTypedDocumentationSet(documentation)
        let out = RenderTextBuffer()
        let projection = RenderProjection(documentation)
        let projectedAssets = projectAssets(documentation, projection)
        let assetLookup = buildAssetLookup(projectedAssets)
        out.append("# "); appendEscapedMarkdownText(out, documentation.project.name); out.append("\n\n")
        out.append("Generated by "); appendMarkdownCodeSpan(out,
            "cjdoc ${documentation.generator.version}"); out.append(" from ")
        appendMarkdownCodeSpan(out, documentation.schemaVersion); out.append(".\n\n")
        out.append("## API\n\n")
        for (declaration in projection.visibleSymbols) {
            out.append("### "); appendMarkdownCodeSpan(out, declaration.qualifiedName)
            out.append("\n\n")
            appendMarkdownCodeBlock(out, declaration.headerSpelling, "cj", "`", 3)
            match (declaration.documentation) {
                case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup)
                case None => ()
            }
            out.append("- Kind: "); appendMarkdownCodeSpan(out, declaration.kind); out.append("\n")
            out.append("- Visibility: "); appendMarkdownCodeSpan(out, declaration.visibility)
            out.append("\n- Semantic state: "); appendMarkdownCodeSpan(out,
                declaration.semantic.state)
            out.append("\n- Source: "); appendMarkdownCodeSpan(out,
                "${declaration.source.path}:${declaration.source.start.line}:${declaration.source.start.column}")
            out.append("\n\n")
            if (!declaration.typeRelationships.isEmpty()) {
                out.append("#### Type relationships\n\n")
                for (relationship in declaration.typeRelationships) {
                    out.append("- "); appendMarkdownCodeSpan(out, relationship.kind)
                    out.append(" → "); appendMarkdownCodeSpan(out, relationship.target.spelling)
                    out.append(" ("); appendMarkdownCodeSpan(out, relationship.target.semantic.state)
                    out.append(")\n")
                }
                out.append("\n")
            }
            if (!declaration.symbolRelationships.isEmpty()) {
                out.append("#### Symbol relationships\n\n")
                for (relationship in declaration.symbolRelationships) {
                    out.append("- "); appendMarkdownCodeSpan(out, relationship.kind)
                    out.append(" → "); appendMarkdownCodeSpan(out, relationship.targetDisplay)
                    out.append(" ("); appendMarkdownCodeSpan(out, relationship.state)
                    out.append(")\n")
                }
                out.append("\n")
            }
        }
        artifacts.addText("markdown/docs.md", "text/markdown; charset=utf-8", out.toString())
        appendAssetArtifacts(artifacts, projectedAssets, "markdown")
}
