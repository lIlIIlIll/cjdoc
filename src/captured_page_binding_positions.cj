package cjdoc

import cjdoc.model as public_model
import markdown.{MarkdownEngine, MarkdownProfile, NodeKind, NodeRef, SourceBuffer, SourcePositionMap}
import std.collection.*

internal class CapturedPageBindingPosition {
    let startByte: Int64
    let endByte: Int64
    let source: public_model.SourceRange
    let original: String
    var parseStartByte: Int64
    var parseEndByte: Int64
    var nodeKind: String = ""
    var tablePlaceholder: Bool = false

    init(startByte: Int64, endByte: Int64, source: public_model.SourceRange, original: String) {
        this.startByte = startByte; this.endByte = endByte
        this.parseStartByte = startByte; this.parseEndByte = endByte
        this.source = source; this.original = original
    }
}

// The line collector nominates candidates; only the actual Markdown AST admits
// directives. Opaque HTML, inline code, references, quotes and escaped text are
// never rewritten merely because their physical line resembles a directive.
private class CapturedBindingSyntaxPass {
    let source: SourceBuffer
    let coordinates: SourcePositionMap
    let candidates: HashMap<Int64, CapturedPageBindingPosition>
    let admitted = ArrayList<CapturedPageBindingPosition>()
    var remaining: Int64 = MAX_GENERATED_MARKDOWN_NODES

    init(source: SourceBuffer, candidates: HashMap<Int64, CapturedPageBindingPosition>) {
        this.source = source; this.coordinates = SourcePositionMap(source); this.candidates = candidates
    }

    func collect(node: NodeRef, depth: Int64, allowed: Bool): Unit {
        if (depth > MAX_GENERATED_MARKDOWN_DEPTH || remaining <= 0) {
            throw IllegalArgumentException("captured binding syntax exceeds node/depth budget")
        }
        remaining--
        var tableContinuation = false
        var previousEndLine: Int64 = 0
        let children = node.children()
        var index: Int64 = 0
        while (index < children.size) {
            let child = children[index]
            var isMarker = false
            if (let Some(span) <- child.span) {
                let start = coordinates.sourcePosition(span.startByte)
                let end = coordinates.sourcePosition(span.endByte)
                if (start.line > previousEndLine + 1) { tableContinuation = false }
                let kind = publicMarkdownKind(child.kind)
                if (allowed && ["html_block", "html_inline"].contains(kind)) {
                    if (let Some(candidate) <- candidates.get(start.line)) {
                        if (source.slice(span).trimAscii() == candidate.original.trimAscii()) {
                            candidate.nodeKind = kind
                            candidate.tablePlaceholder = tableContinuation && kind == "html_block"
                            candidate.parseStartByte = if (candidate.tablePlaceholder) { candidate.startByte } else { span.startByte }
                            candidate.parseEndByte = if (candidate.tablePlaceholder) { candidate.endByte } else { span.endByte }
                            admitted.add(candidate)
                            isMarker = true
                        }
                    }
                }
                previousEndLine = end.line
            } else { tableContinuation = false }
            match (child.kind) {
                case NodeKind.Table => tableContinuation = true
                case NodeKind.Paragraph => ()
                case NodeKind.HtmlBlock | NodeKind.HtmlInline => tableContinuation = tableContinuation && isMarker
                case _ => tableContinuation = false
            }
            let childAllowed = allowed && match (child.kind) { case NodeKind.BlockQuote => false; case _ => true }
            collect(child, depth + 1, childAllowed)
            index++
        }
    }
}

private func admittedCapturedBindings(body: String,
    candidates: HashMap<Int64, CapturedPageBindingPosition>): Array<CapturedPageBindingPosition> {
    // This syntax-only pass has no generation context, lexer, provider, asset
    // collector or highlighter. Its AST is released before the projection pass.
    let parsed = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    let inspection = CapturedBindingSyntaxPass(parsed.source, candidates)
    inspection.collect(parsed.document.root(), 0, true)
    inspection.admitted.toArray()
}

internal func prepareCapturedPageBindings(body: String, sourcePath: String,
    bindingLines: ?HashSet<Int64>): (String, String, HashMap<Int64, CapturedPageBindingPosition>) {
    let positions = HashMap<Int64, CapturedPageBindingPosition>()
    if (bindingLines.isNone() || bindingLines.getOrThrow().isEmpty()) { return (body, body, positions) }
    let bytes = body.toArray()
    let candidates = HashMap<Int64, CapturedPageBindingPosition>()
    var cursor: Int64 = 0
    var line: Int64 = 1
    while (cursor < bytes.size) {
        let start = cursor
        while (cursor < bytes.size && bytes[cursor] != b'\r' && bytes[cursor] != b'\n') { cursor++ }
        let end = cursor
        if (bindingLines.getOrThrow().contains(line)) {
            let original = body[start..end]
            let marker = original.trimAscii()
            let leading = original.indexOf(marker).getOrThrow()
            let source = public_model.SourceRange(sourcePath,
                public_model.SourcePosition(line, leading + 1, start + leading),
                public_model.SourcePosition(line, leading + marker.size + 1, start + leading + marker.size))
            candidates[line] = CapturedPageBindingPosition(start, end, source, original)
        }
        if (cursor < bytes.size && bytes[cursor] == b'\r') {
            cursor++
            if (cursor < bytes.size && bytes[cursor] == b'\n') { cursor++ }
        } else if (cursor < bytes.size) { cursor++ }
        line++
    }
    let admitted = admittedCapturedBindings(body, candidates)
    let text = StringBuilder()
    var textCursor: Int64 = 0
    var masked = false
    for (position in admitted) {
        positions[position.parseStartByte] = position
        text.append(body[textCursor..position.startByte])
        textCursor = position.endByte
        if (position.tablePlaceholder) {
            for (index in position.startByte..position.endByte) { bytes[index] = b'x' }
            masked = true
        }
    }
    text.append(body[textCursor..])
    (if (masked) { String.fromUtf8(bytes) } else { body }, text.toString(), positions)
}

internal func capturedBindingMarker(node: NodeRef,
    positions: ?HashMap<Int64, CapturedPageBindingPosition>, allowed: Bool): ?public_model.MarkdownNode {
    if (positions.isNone()) { return None }
    let span = match (node.span) { case Some(value) => value; case None => return None }
    let position = match (positions.getOrThrow().get(span.startByte)) {
        case Some(value) => value
        case None => return None
    }
    if (span.endByte != position.parseEndByte) { return None }
    let kind = publicMarkdownKind(node.kind)
    let expectedKind = if (position.tablePlaceholder) { "text" } else { position.nodeKind }
    if (kind != expectedKind) { return None }
    if (!allowed) { return Some(public_model.MarkdownNode("text", literal: position.original)) }
    Some(public_model.MarkdownNode(if (position.tablePlaceholder) { "html_inline" } else { position.nodeKind },
        literal: "<!-- cjdoc-bind -->", source: Some(position.source)))
}


private func capturedMarkerNode(node: public_model.MarkdownNode): Bool {
    node.kind == "html_inline" && node.literal == "<!-- cjdoc-bind -->" && node.source.isSome()
}

// A real marker may share a parsed paragraph with either adjacent prose line.
// Split that paragraph into existing block nodes; never nest a chip's div in p.
internal func capturedBindingParagraph(children: ArrayList<public_model.MarkdownNode>,
    context: MarkdownGenerationContext, depth: Int64): ?public_model.MarkdownNode {
    var found = false
    for (child in children) { if (capturedMarkerNode(child)) { found = true; break } }
    if (!found) { return None }
    let blocks = ArrayList<public_model.MarkdownNode>()
    var prose = ArrayList<public_model.MarkdownNode>()
    var afterMarker = false
    for (child in children) {
        if (capturedMarkerNode(child)) {
            while (!prose.isEmpty() && ["soft_break", "hard_break"].contains(prose[prose.size - 1].kind)) {
                prose.remove(at: prose.size - 1)
            }
            if (!prose.isEmpty()) {
                context.consumeNode(depth + 1)
                blocks.add(public_model.MarkdownNode("paragraph", children: prose.toArray()))
                prose = ArrayList<public_model.MarkdownNode>()
            }
            blocks.add(public_model.MarkdownNode("html_block", literal: child.literal, source: child.source))
            afterMarker = true
        } else if (!(afterMarker && ["soft_break", "hard_break"].contains(child.kind))) {
            prose.add(child)
            afterMarker = false
        }
    }
    if (!prose.isEmpty()) {
        context.consumeNode(depth + 1)
        blocks.add(public_model.MarkdownNode("paragraph", children: prose.toArray()))
    }
    if (blocks.size == 1) { return Some(blocks[0]) }
    Some(public_model.MarkdownNode("custom_block", children: blocks.toArray()))
}
