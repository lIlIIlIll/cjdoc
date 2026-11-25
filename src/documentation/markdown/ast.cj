protected package cjdoc.documentation.markdown

import cjdoc.documentation.assets.LocalAssetCollector
import cjdoc.model as public_model
import markdown.{CodeBlockKind, ListDelimiter, ListKind, MarkdownEngine, MarkdownProfile, NodeKind, NodeRef, 
    SourceBuffer, TableAlignment, TaskState}
import std.collection.*

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
    if (depth == 1 && let NodeKind.BlockQuote <- node.kind) {
        let quoteChildren = node.children()
        if (!quoteChildren.isEmpty() && let NodeKind.Paragraph <- quoteChildren[0].kind) {
            let paragraph = quoteChildren[0]
            let paragraphChildren = paragraph.children()
            if (!paragraphChildren.isEmpty() && let NodeKind.Text <- paragraphChildren[0].kind) {
                let markerNode = paragraphChildren[0]
                let markerText = markerNode.asText().getOrThrow().value
                let level: ?String = match (markerText) {
                    case "[!NOTE]" => Some("note")
                    case "[!WARNING]" => Some("warning")
                    case "[!CAUTION]" => Some("danger")
                    case _ => None
                }
                if (let Some(admonitionLevel) <- level) {
                    var removeCount: Int64 = 1
                    var markerLayout = true
                    if (paragraphChildren.size > 1) {
                        if (let NodeKind.SoftBreak | NodeKind.HardBreak <- paragraphChildren[1].kind) {
                            removeCount = 2
                        } else {
                            markerLayout = false
                        }
                    }
                    if (markerLayout && source.text(markerNode) == markerText) {
                        let hasBody = paragraphChildren.size > removeCount || quoteChildren.size > 1
                        if (!hasBody) {
                            context.admonitionWithoutBody(symbolId, source: Some(declarationSource))
                        } else {
                            let blocks = ArrayList<public_model.MarkdownNode>()
                            if (paragraphChildren.size > removeCount) {
                                context.consumeNode(depth + 1)
                                let inline = ArrayList<public_model.MarkdownNode>()
                                var inlineIndex = removeCount
                                while (inlineIndex < paragraphChildren.size) {
                                    inline.add(publicMarkdownNode(paragraphChildren[inlineIndex], source,
                                        assetCollector, sourcePath, declarationSource, symbolId, context,
                                        depth + 2, bindingPositions: bindingPositions,
                                        allowBindingMarkers: false))
                                    inlineIndex++
                                }
                                blocks.add(public_model.MarkdownNode("paragraph", children: inline.toArray()))
                            }
                            var blockIndex: Int64 = 1
                            while (blockIndex < quoteChildren.size) {
                                blocks.add(publicMarkdownNode(quoteChildren[blockIndex], source,
                                    assetCollector, sourcePath, declarationSource, symbolId, context,
                                    depth + 1, bindingPositions: bindingPositions,
                                    allowBindingMarkers: false))
                                blockIndex++
                            }
                            context.consumeText(admonitionLevel)
                            return public_model.MarkdownNode("admonition",
                                public_model.MarkdownNodeMetadata.forAdmonition(admonitionLevel),
                                children: blocks.toArray())
                        }
                    }
                }
            }
        }
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

// Author text before an unusable `{@link ...}` is never dropped: the search
// cursor may advance past an unemitted fragment, but the emission cursor only
// moves after a node is actually published. A later valid link is still bound.
private func explicitSemanticLinkNodes(value: String): ?Array<public_model.MarkdownNode> {
    let marker = "{@link "
    let nodes = ArrayList<public_model.MarkdownNode>()
    var search: Int64 = 0
    var emitted: Int64 = 0
    var found = false
    while (search < value.size) {
        match (value[search..].indexOf(marker)) {
            case None => break
            case Some(relativeOpen) =>
                let open = search + relativeOpen
                let targetStart = open + marker.size
                match (value[targetStart..].indexOf("}")) {
                    case None => break
                    case Some(relativeClose) =>
                        let close = targetStart + relativeClose
                        let target = value[targetStart..close].trimAscii()
                        if (target.isEmpty() || target.contains("{") || target.contains("}")) {
                            // Keep the fragment as ordinary text; rescan one byte
                            // later so a nested valid marker is still reachable.
                            search = open + 1
                            continue
                        }
                        if (open > emitted) {
                            nodes.add(public_model.MarkdownNode("text", literal: value[emitted..open]))
                        }
                        nodes.add(explicitSemanticLinkNode(target))
                        emitted = close + 1
                        search = emitted
                        found = true
                }
        }
    }
    if (!found) { return None }
    if (emitted < value.size) {
        nodes.add(public_model.MarkdownNode("text", literal: value[emitted..]))
    }
    Some(nodes.toArray())
}

protected func publicMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext,
    bindingPositions!: ?HashMap<Int64, CapturedPageBindingPosition> = None): public_model.MarkdownNode {
    if (body.isEmpty()) {
        return public_model.MarkdownNode("document")
    }
    let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    publicMarkdownNode(result.document.root(), result.source, assetCollector, sourcePath, declarationSource, symbolId,
        context, 0, bindingPositions: bindingPositions)
}
protected func publicAdmonitionMarkdown(level: String, body: String,
    assetCollector: LocalAssetCollector, sourcePath: String, declarationSource: public_model.SourceRange,
    symbolId: String, context: MarkdownGenerationContext): public_model.MarkdownNode {
    if (!public_model.isAdmonitionLevel(level) || body.trimAscii().isEmpty()) {
        return public_model.MarkdownNode("document")
    }
    let parsed = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = parsed.document.root().children()
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(publicMarkdownNode(sourceChildren[index], parsed.source, assetCollector, sourcePath,
            declarationSource, symbolId, context, 2, allowBindingMarkers: false))
        index++
    }
    if (children.isEmpty()) {
        context.consumeNode(0)
        return public_model.MarkdownNode("document")
    }
    context.consumeNode(1)
    context.consumeNode(0)
    context.consumeText(level)
    let admonition = public_model.MarkdownNode("admonition",
        public_model.MarkdownNodeMetadata.forAdmonition(level),
        children: children.toArray())
    public_model.MarkdownNode("document", children: [admonition])
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

protected func publicExampleMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
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

protected func publicMarkdownContainsCode(node: public_model.MarkdownNode): Bool {
    if (node.kind == "code_block") { return true }
    for (child in node.children) { if (publicMarkdownContainsCode(child)) { return true } }
    false
}
