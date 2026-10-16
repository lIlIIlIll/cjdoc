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

internal func publicTag(value: DocTag, targetVisible!: Bool = true): public_model.DocTag {
    let state = if (!targetVisible) {
        "unavailable"
    } else {
        match (value.referenceState) {
            case "resolved" => "resolved"
            case "ambiguous" => "ambiguous"
            case "unresolved" => "unavailable"
            case "broken" => "unavailable"
            case _ => "unavailable"
        }
    }
    let targetSymbolId: ?String = if (state == "resolved") { value.targetSymbolId } else { None }
    public_model.DocTag(value.name, value.subject, value.description, referenceState: state,
        targetSymbolId: targetSymbolId, directives: value.directives)
}

internal func publicTagForAudience(value: DocTag, renderableIds: HashSet<String>): public_model.DocTag {
    match (value.targetSymbolId) {
        case Some(targetId) => publicTag(value, targetVisible: renderableIds.contains(targetId))
        case None => publicTag(value)
    }
}
internal let MAX_GENERATED_MARKDOWN_DEPTH: Int64 = 48
internal let MAX_GENERATED_MARKDOWN_NODES: Int64 = 100000
internal let MAX_GENERATED_MARKDOWN_STRING_BYTES: Int64 = 1024 * 1024
internal let MAX_GENERATED_MARKDOWN_TOTAL_BYTES: Int64 = 16 * 1024 * 1024
internal let MARKDOWN_FALLBACK_TEXT = "Documentation omitted because Markdown resource limits were exceeded."

internal class MarkdownGenerationContext {
    let highlightMode: String
    let highlightBudget: HighlightGenerationBudget

    init(highlightMode!: String = "auto", highlightLanguages!: ?HighlightConfig = None,
        highlightBytes!: Int64 = MAX_HIGHLIGHT_TOTAL_BYTES,
        externalOptions!: ?HighlightExternalOptions = None) {
        this.highlightMode = highlightMode
        this.highlightBudget = HighlightGenerationBudget(byteLimit: highlightBytes,
            highlightLanguages: highlightLanguages,
            onError: match (highlightLanguages) { case Some(value) => value.onError case None => "warn" },
            externalOptions: externalOptions)
    }
    private var nodes: Int64 = 0
    private var textBytes: Int64 = 0
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let retainedHighlightFailures = ArrayList<public_model.Diagnostic>()
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

    func retainHighlightFailures(diagnostics: Array<public_model.Diagnostic>): Unit {
        for (diagnostic in diagnostics) {
            if (diagnostic.isHighlightFailure) { retainedHighlightFailures.add(diagnostic) }
        }
    }

    func highlightDiagnostics(): Array<public_model.Diagnostic> {
        let result = ArrayList<public_model.Diagnostic>(retainedHighlightFailures.toArray())
        result.add(all: highlightBudget.diagnostics())
        result.add(all: highlightBudget.escalationDiagnostics())
        result.toArray()
    }

    func collectionDiagnostics(): Array<public_model.Diagnostic> { diagnosticsStorage.toArray() }

    func diagnostics(): Array<public_model.Diagnostic> {
        let result = ArrayList<public_model.Diagnostic>(diagnosticsStorage.toArray())
        result.add(all: highlightDiagnostics())
        result.toArray()
    }

    func highlight(source: String, language: String, witness!: Array<String> = []): ?public_model.CodeHighlight {
        if (highlightMode == "off") { return None }
        highlightBudget.prepare(source, language, witness: witness)
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
                        value.language, value.attributesRaw,
                        codeHighlight: context.highlight(value.literal, value.language)))
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
    context: MarkdownGenerationContext, depth: Int64,
    bindingPositions!: ?HashMap<Int64, CapturedPageBindingPosition> = None,
    allowBindingMarkers!: Bool = true): public_model.MarkdownNode {
    context.consumeNode(depth)
    if (let Some(marker) <- capturedBindingMarker(node, bindingPositions, allowBindingMarkers)) {
        context.consumeText(marker.literal)
        return marker
    }
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = node.children()
    let childMarkersAllowed = allowBindingMarkers &&
        match (node.kind) { case NodeKind.BlockQuote => false; case _ => true }
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(
            publicMarkdownNode(sourceChildren[index], source, assetCollector, sourcePath, declarationSource, symbolId,
                context, depth + 1, bindingPositions: bindingPositions, allowBindingMarkers: childMarkersAllowed))
        index++
    }
    match (node.kind) {
        case NodeKind.Paragraph => if (let Some(block) <- capturedBindingParagraph(children, context, depth)) { return block }
        case _ => ()
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
    // GFM bare-link scanning can include following Chinese sentence punctuation.
    // Only correct a bare source URL; explicitly authored Markdown/autolinks may
    // intentionally contain Unicode punctuation and must retain their target.
    let isLink = match (node.kind) { case NodeKind.Link => true; case _ => false }
    if (isLink && source.text(node) == literal &&
        (literal.startsWith("http://") || literal.startsWith("https://"))) {
        var boundary = literal.size
        for (punctuation in ["。", "，", "；", "！", "？", "、", "："]) {
            match (literal.indexOf(punctuation)) {
                case Some(position) => if (position < boundary) { boundary = position }
                case None => ()
            }
        }
        if (boundary < literal.size) {
            let target = literal[..boundary]
            let suffix = literal[boundary..]
            context.consumeNode(depth + 1)
            context.consumeNode(depth + 2)
            context.consumeNode(depth + 1)
            return public_model.MarkdownNode("custom_inline", children: [
                public_model.MarkdownNode("link", literal: target,
                    children: [public_model.MarkdownNode("text", literal: target)]),
                public_model.MarkdownNode("text", literal: suffix)])
        }
    }
    match (node.kind) {
        case NodeKind.Text => match (explicitSemanticLinkNodes(literal)) {
            case Some(linkChildren) =>
                return public_model.MarkdownNode("custom_inline", children: linkChildren)
            case None => ()
        }
        case _ => ()
    }
    match (publicMarkdownMetadata(node, context)) {
        case Some(metadata) => public_model.MarkdownNode(publicMarkdownKind(node.kind), metadata, literal: literal,
            children: children.toArray())
        case None => public_model.MarkdownNode(publicMarkdownKind(node.kind), literal: literal,
            children: children.toArray())
    }
}

private func explicitSemanticLinkNode(target: String): public_model.MarkdownNode {
    public_model.MarkdownNode("semantic_link",
        public_model.MarkdownNodeMetadata.forSemanticLink(target, "unresolved"),
        literal: target, children: [public_model.MarkdownNode("text", literal: target)])
}

private func explicitSemanticLinkNodes(value: String): ?Array<public_model.MarkdownNode> {
    let marker = "{@link "
    let nodes = ArrayList<public_model.MarkdownNode>()
    var cursor: Int64 = 0
    var found = false
    while (cursor < value.size) {
        match (value[cursor..].indexOf(marker)) {
            case None => break
            case Some(relativeOpen) =>
                let open = cursor + relativeOpen
                let targetStart = open + marker.size
                match (value[targetStart..].indexOf("}")) {
                    case None => break
                    case Some(relativeClose) =>
                        let close = targetStart + relativeClose
                        let target = value[targetStart..close].trimAscii()
                        if (target.isEmpty() || target.contains("{") || target.contains("}")) {
                            cursor = targetStart
                            continue
                        }
                        if (open > cursor) {
                            nodes.add(public_model.MarkdownNode("text", literal: value[cursor..open]))
                        }
                        nodes.add(explicitSemanticLinkNode(target))
                        cursor = close + 1
                        found = true
                }
        }
    }
    if (!found) { return None }
    if (cursor < value.size) { nodes.add(public_model.MarkdownNode("text", literal: value[cursor..])) }
    Some(nodes.toArray())
}

internal func publicMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext,
    bindingPositions!: ?HashMap<Int64, CapturedPageBindingPosition> = None): public_model.MarkdownNode {
    if (body.isEmpty()) {
        return public_model.MarkdownNode("document")
    }
    let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    publicMarkdownNode(result.document.root(), result.source, assetCollector, sourcePath, declarationSource, symbolId,
        context, 0, bindingPositions: bindingPositions)
}
public func parseStandaloneMarkdown(body: String, highlightMode!: String = "auto",
    highlightAdapter!: ?String = None, highlightNode!: ?String = None): public_model.MarkdownNode {
    let source = public_model.SourceRange("conceptual.md", public_model.SourcePosition(1, 1, 0),
        public_model.SourcePosition(1, 1, 0))
    let assets = LocalAssetCollector(ArrayList<SourceFileOrigin>())
    let context = MarkdownGenerationContext(highlightMode: highlightMode,
        externalOptions: highlightExternalOptions(highlightAdapter, highlightNode))
    try { publicMarkdown(body, assets, "conceptual.md", source, "cjdoc:conceptual", context) }
    finally { context.highlightBudget.close() }
}

internal func parseCapturedPageMarkdown(body: String, assetCollector: LocalAssetCollector,
    sourcePath: String, request: GenerationRequest,
    sharedContext!: ?MarkdownGenerationContext = None,
    bindingLines!: ?HashSet<Int64> = None): (String, public_model.MarkdownNode, HashSet<Int64>) {
    let source = public_model.SourceRange(sourcePath, public_model.SourcePosition(1, 1, 0),
        public_model.SourcePosition(1, 1, 0))
    let highlightConfig = request.highlight.getOrDefault({ => loadHighlightConfig(request.projectRoot) })
    let context = sharedContext.getOrDefault({ => MarkdownGenerationContext(
        highlightMode: if (highlightConfig.mode == "off") { "off" } else { "auto" },
        highlightLanguages: highlightConfig,
        externalOptions: highlightExternalOptions(request.highlightAdapter, request.highlightNode)) })
    try {
        let (prepared, text, positions) = prepareCapturedPageBindings(body, sourcePath, bindingLines)
        let tree = publicMarkdown(prepared, assetCollector, sourcePath, source, "", context, bindingPositions: Some(positions))
        let accepted = HashSet<Int64>()
        for ((_, position) in positions) { let _ = accepted.add(position.source.start.line) }
        (text, tree, accepted)
    }
    finally { if (sharedContext.isNone()) { context.highlightBudget.close() } }
}

// Inspect the already parsed AST before allowing asset collection. Discarded
// examples keep the legacy description path and must have no collector effects.
private func exampleMarkdownCodeInspection(node: NodeRef, depth: Int64,
    remaining: Int64): (Bool, Int64) {
    if (depth > MAX_GENERATED_MARKDOWN_DEPTH || remaining <= 0) {
        throw IllegalArgumentException("example Markdown inspection exceeds node/depth budget")
    }
    var hasCode = match (node.kind) { case NodeKind.CodeBlock => true case _ => false }
    var left = remaining - 1
    let children = node.children()
    var index: Int64 = 0
    while (index < children.size) {
        let (childHasCode, childRemaining) = exampleMarkdownCodeInspection(children[index], depth + 1, left)
        hasCode = hasCode || childHasCode
        left = childRemaining
        index++
    }
    (hasCode, left)
}

private func publicExampleMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String,
    context: MarkdownGenerationContext): ?public_model.MarkdownNode {
    if (body.isEmpty()) { return None }
    let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    let root = result.document.root()
    let hasCode = try {
        let (found, _) = exampleMarkdownCodeInspection(root, 0, MAX_GENERATED_MARKDOWN_NODES)
        found
    } catch (_: IllegalArgumentException) {
        return None
    }
    if (!hasCode) { return None }
    Some(publicMarkdownNode(root, result.source, assetCollector, sourcePath,
        declarationSource, symbolId, context, 0))
}

private func publicMarkdownContainsCode(node: public_model.MarkdownNode): Bool {
    if (node.kind == "code_block") { return true }
    for (child in node.children) { if (publicMarkdownContainsCode(child)) { return true } }
    false
}

internal func publicComment(value: DocComment, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext,
    renderableIds: HashSet<String>, sourceMapper: PublicSourceMapper): public_model.DocComment {
    try {
        context.consumeText(value.raw)
        context.consumeText(value.summaryMarkdown)
        context.consumeText(value.descriptionMarkdown)
        context.requireBodySize(value.summaryMarkdown, value.descriptionMarkdown)
        let localized = publicLocalizedTexts(value, assetCollector, sourcePath, declarationSource,
            symbolId, context, renderableIds, sourceMapper)
        let tags = ArrayList<public_model.DocTag>()
        for (tag in value.params) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        for (tag in value.examples) {
            var tree: ?public_model.MarkdownNode = None
            if (localized.isEmpty()) {
                tree = publicExampleMarkdown(tag.description, assetCollector, sourcePath,
                    declarationSource, symbolId, context)
            } else {
                for (text in localized where text.kind == "example" && text.language == value.defaultLanguage &&
                    text.subject == tag.subject && text.text == tag.description) {
                    if (publicMarkdownContainsCode(text.markdown)) { tree = Some(text.markdown) }
                    break
                }
            }
            let ordinary = publicTagForAudience(tag, renderableIds)
            tags.add(public_model.DocTag(ordinary.name, ordinary.subject, ordinary.description,
                referenceState: ordinary.referenceState, targetSymbolId: ordinary.targetSymbolId,
                directives: ordinary.directives,
                exampleMarkdown: tree))
        }
        match (value.returns) {
            case Some(tag) => tags.add(publicTagForAudience(tag, renderableIds))
            case None => ()
        }
        for (tag in value.throwsTags) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        for (tag in value.see) {
            tags.add(publicTagForAudience(tag, renderableIds))
        }
        for (tag in value.contracts) {
            tags.add(publicTagForAudience(tag, renderableIds))
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
            if (!tag.directives.isEmpty()) { context.consumeText(tag.directives) }
        }
        let body = if (value.descriptionMarkdown.isEmpty()) {
            value.summaryMarkdown
        } else {
            "${value.summaryMarkdown}\n\n${value.descriptionMarkdown}"
        }
        let bodyTree = if (localized.isEmpty()) {
            publicMarkdown(body, assetCollector, sourcePath, declarationSource, symbolId, context)
        } else {
            let children = ArrayList<public_model.MarkdownNode>()
            for (kind in ["summary", "description"]) {
                for (text in localized) {
                    if (text.kind == kind && text.language == value.defaultLanguage && text.state == "valid") {
                        children.add(all: text.markdown.children)
                    }
                }
            }
            public_model.MarkdownNode("document", children: children.toArray())
        }
        return public_model.DocComment(value.raw, value.summaryMarkdown, value.descriptionMarkdown,
            bodyTree, tags: tags.toArray(), defaultLanguage: value.defaultLanguage, localizedTexts: localized)
    } catch (_: Exception) {
        context.fail(declarationSource, symbolId)
        return public_model.DocComment("", MARKDOWN_FALLBACK_TEXT, "", fallbackPublicMarkdown())
    }
}
