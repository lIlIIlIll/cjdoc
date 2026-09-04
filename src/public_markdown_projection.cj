package cjdoc

import cjdoc.model as public_model
import markdown.{CodeBlockKind, ListDelimiter, ListKind, MarkdownEngine, MarkdownProfile, NodeKind, NodeRef, 
    SourceBuffer, TableAlignment, TaskState}
import std.collection.*

internal func publicType(value: TypeRef, provider: String, providerState: String): public_model.TypeRef {
    // A failed module transaction retains source spellings in the internal
    // fallback TypeRef, but none of those spellings are provider facts. Expose
    // them as unavailable semantics while preserving the source-facing shape.
    let state = if (providerState == "unavailable") { "unavailable" } else { value.state }
    let canonical: ?String = if (providerState == "unavailable") { None } else { value.canonical }
    let semanticProvider: ?String = if (state == "unavailable") {
        None
    } else {
        Some(provider)
    }
    let arguments = ArrayList<public_model.TypeRef>()
    for (argument in value.arguments) {
        arguments.add(publicType(argument, provider, providerState))
    }
    public_model.TypeRef(value.kind, value.display,
        public_model.SemanticType(state, canonical: canonical, provider: semanticProvider),
        nullable: value.nullable, arguments: arguments.toArray())
}

internal func publicTag(value: DocTag): public_model.DocTag {
    let state = match (value.referenceState) {
        case "resolved" => "resolved"
        case "ambiguous" => "ambiguous"
        case "unresolved" => "unavailable"
        case "broken" => "unavailable"
        case _ => "unavailable"
    }
    public_model.DocTag(value.name, value.subject, value.description, referenceState: state,
        targetSymbolId: value.targetSymbolId)
}

internal let MAX_GENERATED_MARKDOWN_DEPTH: Int64 = 48
internal let MAX_GENERATED_MARKDOWN_NODES: Int64 = 100000
internal let MAX_GENERATED_MARKDOWN_STRING_BYTES: Int64 = 1024 * 1024
internal let MAX_GENERATED_MARKDOWN_TOTAL_BYTES: Int64 = 16 * 1024 * 1024
internal let MARKDOWN_FALLBACK_TEXT = "Documentation omitted because Markdown resource limits were exceeded."

internal class MarkdownGenerationContext {
    private var nodes: Int64 = 0
    private var textBytes: Int64 = 0
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let failedSymbols = HashSet<String>()
    var incomplete: Bool = false

    func consumeNode(depth: Int64): Unit {
        if (depth < 0 || depth > MAX_GENERATED_MARKDOWN_DEPTH || nodes >= MAX_GENERATED_MARKDOWN_NODES) {
            throw IllegalArgumentException("generated Markdown exceeds node/depth budget")
        }
        nodes++
    }

    func consumeText(value: String): Unit {
        let size = value.size
        if (size > MAX_GENERATED_MARKDOWN_STRING_BYTES || size > MAX_GENERATED_MARKDOWN_TOTAL_BYTES - textBytes) {
            throw IllegalArgumentException("generated Markdown exceeds text budget")
        }
        textBytes += size
    }

    func requireBodySize(summary: String, description: String): Unit {
        let separator: Int64 = if (description.isEmpty()) {
            0
        } else {
            2
        }
        if (summary.size > MAX_GENERATED_MARKDOWN_STRING_BYTES || description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES ||
            description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES - separator || summary.size >
            MAX_GENERATED_MARKDOWN_STRING_BYTES - description.size - separator) {
            throw IllegalArgumentException("generated Markdown input exceeds comment budget")
        }
    }

    func fail(source: public_model.SourceRange, symbolId: String): Unit {
        incomplete = true
        if (!failedSymbols.add(symbolId)) {
            return
        }
        diagnosticsStorage.add(
            public_model.Diagnostic("warning", "CJDOC3026",
                "documentation Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
                source: Some(source), symbolId: Some(symbolId)))
    }

    func diagnostics(): Array<public_model.Diagnostic> {
        diagnosticsStorage.toArray()
    }
}

internal func fallbackPublicMarkdown(): public_model.MarkdownNode {
    public_model.MarkdownNode("document",
        children: [public_model.MarkdownNode("paragraph",
            children: [public_model.MarkdownNode("text", literal: MARKDOWN_FALLBACK_TEXT)])])
}

internal func publicMarkdownKind(kind: NodeKind): String {
    match (kind) {
        case NodeKind.DocumentNode => "document"
        case NodeKind.BlockQuote => "block_quote"
        case NodeKind.List => "list"
        case NodeKind.ListItem => "list_item"
        case NodeKind.Paragraph => "paragraph"
        case NodeKind.Heading => "heading"
        case NodeKind.ThematicBreak => "thematic_break"
        case NodeKind.CodeBlock => "code_block"
        case NodeKind.HtmlBlock => "html_block"
        case NodeKind.Table => "table"
        case NodeKind.TableRow => "table_row"
        case NodeKind.TableCell => "table_cell"
        case NodeKind.CustomBlock => "custom_block"
        case NodeKind.Text => "text"
        case NodeKind.SoftBreak => "soft_break"
        case NodeKind.HardBreak => "hard_break"
        case NodeKind.CodeSpan => "code_span"
        case NodeKind.Emphasis => "emphasis"
        case NodeKind.Strong => "strong"
        case NodeKind.Strikethrough => "strikethrough"
        case NodeKind.Link => "link"
        case NodeKind.Image => "image"
        case NodeKind.HtmlInline => "html_inline"
        case NodeKind.CustomInline => "custom_inline"
    }
}

internal func publicListKind(value: ListKind): String {
    match (value) {
        case ListKind.Bullet => "bullet"
        case ListKind.Ordered => "ordered"
    }
}

internal func publicListDelimiter(value: ListDelimiter): String {
    match (value) {
        case ListDelimiter.Period => "period"
        case ListDelimiter.Parenthesis => "parenthesis"
        case ListDelimiter.None => "none"
    }
}

internal func publicTaskState(value: TaskState): String {
    match (value) {
        case TaskState.NotTask => "notTask"
        case TaskState.Checked => "checked"
        case TaskState.Unchecked => "unchecked"
    }
}

internal func publicCodeBlockKind(value: CodeBlockKind): String {
    match (value) {
        case CodeBlockKind.Indented => "indented"
        case CodeBlockKind.Fenced => "fenced"
    }
}

internal func publicTableAlignment(value: TableAlignment): String {
    match (value) {
        case TableAlignment.None => "none"
        case TableAlignment.Left => "left"
        case TableAlignment.Center => "center"
        case TableAlignment.Right => "right"
    }
}

internal func publicMarkdownMetadata(node: NodeRef, context: MarkdownGenerationContext): ?public_model.MarkdownNodeMetadata {
    match (node.kind) {
        case NodeKind.Heading => Some(public_model.MarkdownNodeMetadata.forHeading(node.asHeading().getOrThrow().level))
        case NodeKind.List =>
            let value = node.asList().getOrThrow()
            Some(
                public_model
                    .MarkdownNodeMetadata
                    .forList(publicListKind(value.listKind), value.start, publicListDelimiter(value.delimiter),
                        value.tight))
        case NodeKind.ListItem => Some(
            public_model.MarkdownNodeMetadata.forListItem(publicTaskState(node.asListItem().getOrThrow().taskState)))
        case NodeKind.CodeBlock =>
            let value = node.asCodeBlock().getOrThrow()
            context.consumeText(value.infoRaw)
            context.consumeText(value.language)
            context.consumeText(value.attributesRaw)
            let fenceCharacter = match (value.fenceCharacter) {
                case Some(marker) => Some(String.fromUtf8([marker]))
                case None => None<String>
            }
            Some(
                public_model
                    .MarkdownNodeMetadata
                    .forCodeBlock(publicCodeBlockKind(value.codeKind), fenceCharacter, value.fenceLength, value.infoRaw,
                        value.language, value.attributesRaw))
        case NodeKind.Table =>
            let alignments = ArrayList<String>()
            let sourceAlignments = node.asTable().getOrThrow().alignments
            var index: Int64 = 0
            while (index < sourceAlignments.size) {
                alignments.add(publicTableAlignment(sourceAlignments[index]))
                index++
            }
            Some(public_model.MarkdownNodeMetadata.forTable(alignments.toArray()))
        case NodeKind.TableRow => Some(
            public_model.MarkdownNodeMetadata.forTableRow(node.asTableRow().getOrThrow().header))
        case NodeKind.TableCell => Some(
            public_model
                .MarkdownNodeMetadata
                .forTableCell(publicTableAlignment(node.asTableCell().getOrThrow().alignment)))
        case _ => None<public_model.MarkdownNodeMetadata>
    }
}

internal func publicMarkdownNode(node: NodeRef, source: SourceBuffer, assetCollector: LocalAssetCollector,
    sourcePath: String, declarationSource: public_model.SourceRange, symbolId: String,
    context: MarkdownGenerationContext, depth: Int64): public_model.MarkdownNode {
    context.consumeNode(depth)
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = node.children()
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(
            publicMarkdownNode(sourceChildren[index], source, assetCollector, sourcePath, declarationSource, symbolId,
                context, depth + 1))
        index++
    }
    let literal = match (node.kind) {
        case NodeKind.Text => node.asText().getOrThrow().value
        case NodeKind.CodeBlock => node.asCodeBlock().getOrThrow().literal
        case NodeKind.CodeSpan => node.asCodeSpan().getOrThrow().literal
        case NodeKind.HtmlBlock => node.asHtmlBlock().getOrThrow().literal
        case NodeKind.HtmlInline => node.asHtmlInline().getOrThrow().literal
        case NodeKind.Link => node.asLink().getOrThrow().destination
        case NodeKind.Image =>
            let destination = node.asImage().getOrThrow().destination
            match (assetCollector.reference(sourcePath, destination, declarationSource, symbolId)) {
                case Some(assetId) => assetId
                case None => destination
            }
        case NodeKind.DocumentNode | NodeKind.BlockQuote | NodeKind.List | NodeKind.ListItem | NodeKind.Paragraph
            | NodeKind.Heading | NodeKind.ThematicBreak | NodeKind.Table | NodeKind.TableRow | NodeKind.TableCell
            | NodeKind.SoftBreak | NodeKind.HardBreak | NodeKind.Emphasis | NodeKind.Strong | NodeKind.Strikethrough => ""
        case _ =>
            if (sourceChildren.isEmpty()) {
                source.text(node)
            } else {
                ""
            }
    }
    context.consumeText(literal)
    match (publicMarkdownMetadata(node, context)) {
        case Some(metadata) => public_model.MarkdownNode(publicMarkdownKind(node.kind), metadata, literal: literal,
            children: children.toArray())
        case None => public_model.MarkdownNode(publicMarkdownKind(node.kind), literal: literal,
            children: children.toArray())
    }
}

internal func publicMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext): public_model.MarkdownNode {
    if (body.isEmpty()) {
        return public_model.MarkdownNode("document")
    }
    let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    publicMarkdownNode(result.document.root(), result.source, assetCollector, sourcePath, declarationSource, symbolId,
        context, 0)
}

internal func publicComment(value: DocComment, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext): public_model.DocComment {
    try {
        context.consumeText(value.raw)
        context.consumeText(value.summaryMarkdown)
        context.consumeText(value.descriptionMarkdown)
        context.requireBodySize(value.summaryMarkdown, value.descriptionMarkdown)
        let tags = ArrayList<public_model.DocTag>()
        for (tag in value.params) {
            tags.add(publicTag(tag))
        }
        for (tag in value.examples) {
            tags.add(publicTag(tag))
        }
        match (value.returns) {
            case Some(tag) => tags.add(publicTag(tag))
            case None => ()
        }
        for (tag in value.throwsTags) {
            tags.add(publicTag(tag))
        }
        for (tag in value.see) {
            tags.add(publicTag(tag))
        }
        match (value.since) {
            case Some(text) => tags.add(public_model.DocTag("since", "", text))
            case None => ()
        }
        match (value.deprecated) {
            case Some(text) => tags.add(public_model.DocTag("deprecated", "", text))
            case None => ()
        }
        for (text in value.authors) {
            tags.add(public_model.DocTag("author", "", text))
        }
        match (value.version) {
            case Some(text) => tags.add(public_model.DocTag("version", "", text))
            case None => ()
        }
        for (tag in tags) {
            context.consumeText(tag.name);
            context.consumeText(tag.subject)
            context.consumeText(tag.description)
            match (tag.targetSymbolId) {
                case Some(value) => context.consumeText(value)
                case None => ()
            }
        }
        let body = if (value.descriptionMarkdown.isEmpty()) {
            value.summaryMarkdown
        } else {
            "${value.summaryMarkdown}\n\n${value.descriptionMarkdown}"
        }
        return public_model.DocComment(value.raw, value.summaryMarkdown, value.descriptionMarkdown,
            publicMarkdown(body, assetCollector, sourcePath, declarationSource, symbolId, context), tags: tags.toArray())
    } catch (_: Exception) {
        context.fail(declarationSource, symbolId)
        return public_model.DocComment("", MARKDOWN_FALLBACK_TEXT, "", fallbackPublicMarkdown())
    }
}
