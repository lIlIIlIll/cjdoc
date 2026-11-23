protected package cjdoc.semantic.chir

import cjdoc.dependency.navigation.dependencyTypeShape
import cjdoc.model as public_model
import cjdoc_chir_protocol.*
import std.collection.*

// Rebuild a TypeRef from the flattened node list. The node's own subtree is the
// run of following nodes with greater depth. The source-visible spelling of each
// node is taken from its own position in the source display, so the renderer's
// positional token match succeeds; the resolved identity stays in `canonical`,
// and the renderer decides whether a link target exists.
protected func chirTypeRefFromNodes(nodes: ArrayList<ChirTypeNode>, start: Int64,
    sourceDisplay: String): public_model.TypeRef {
    if (start < 0 || start >= nodes.size) {
        return public_model.TypeRef("source", "",
            public_model.SemanticType("unavailable"))
    }
    let head = nodes[start]
    // Defense in depth: never recurse past the model's type-depth limit, even if
    // a worker returns a longer chain. The decode step already rejects such
    // records, so this only bounds a trusted-but-wrong worker.
    if (head.depth >= public_model.DOC_IR_MAX_TYPE_DEPTH) {
        return public_model.TypeRef("source", chirUnqualifiedName(head.qualifiedName),
            public_model.SemanticType("resolved", canonical: Some(head.qualifiedName),
                provider: Some("chir")))
    }
    let rawChildren = ArrayList<Int64>()
    let childDepth = head.depth + 1
    var index = start + 1
    while (index < nodes.size && nodes[index].depth >= childDepth) {
        if (nodes[index].depth == childDepth) { rawChildren.add(index) }
        // Skip the whole child subtree.
        var cursor = index + 1
        while (cursor < nodes.size && nodes[cursor].depth > nodes[index].depth) { cursor++ }
        index = cursor
    }
    // CHIR wraps a custom type's arguments in a sole node repeating the type's
    // own name (`Box<Token>` becomes Box, Box, Token; `Box<Box<Token>>` nests the
    // pattern). Shift exactly one level through that wrapper, so a genuine
    // same-named argument, such as the inner Box of Box<Box<Token>>, is preserved
    // instead of being swallowed.
    var children = rawChildren
    if (rawChildren.size == 1 && nodes[rawChildren[0]].qualifiedName == head.qualifiedName) {
        children = chirDirectChildren(nodes, rawChildren[0])
    }
    // Align semantic children with the actual AST role. In particular ?Box<T>
    // has an optional child Box<T>, not the generic child T; functions and tuples
    // likewise own structured children even without angle brackets.
    let sourceShape = dependencyTypeShape(sourceDisplay)
    let sourceArguments = ArrayList<String>()
    if (let Some(shape) <- sourceShape) {
        for (child in shape.children) { sourceArguments.add(child.spelling) }
    }
    let argumentDisplays = ArrayList<String>()
    if (sourceDisplay.trimAscii().isEmpty()) {
        // No source display to compare against; keep CHIR's structure.
        for (_ in children) { argumentDisplays.add("") }
    } else if (sourceArguments.size == children.size) {
        for (argumentDisplay in sourceArguments) { argumentDisplays.add(argumentDisplay) }
    }
    let arguments = ArrayList<public_model.TypeRef>()
    var childIndex: Int64 = 0
    for (child in children) {
        if (childIndex >= argumentDisplays.size) { break }
        arguments.add(chirTypeRefFromNodes(nodes, child, argumentDisplays[childIndex]))
        childIndex++
    }
    // The spelling is the complete source subtree with whitespace removed, so the
    // renderer's whole-range comparison against the source tokens succeeds and it
    // can then recurse into `arguments`. A node with no matching source display
    // keeps its unqualified name, which simply fails to match and yields no link.
    let display = if (sourceDisplay.trimAscii().isEmpty()) {
        chirUnqualifiedName(head.qualifiedName)
    } else {
        chirCompactSpelling(sourceDisplay)
    }
    return public_model.TypeRef(sourceShape.map({ shape => shape.kind }).getOrDefault({ => "source" }), display,
        public_model.SemanticType("resolved", canonical: Some(head.qualifiedName),
            provider: Some("chir")),
        nullable: sourceShape.map({ shape => shape.nullable }).getOrDefault({ => false }), arguments: arguments.toArray())
}

// A source type display with all whitespace removed, matching how the renderer
// compares a signature range against a TypeRef spelling.
protected func chirCompactSpelling(display: String): String {
    let kept = ArrayList<Byte>()
    for (byte in display.toArray()) {
        if (byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n') { continue }
        kept.add(byte)
    }
    String.fromUtf8(kept.toArray())
}

// The direct children of a node in the flattened pre-order list.
private func chirDirectChildren(nodes: ArrayList<ChirTypeNode>, index: Int64): ArrayList<Int64> {
    let result = ArrayList<Int64>()
    let childDepth = nodes[index].depth + 1
    var cursor = index + 1
    while (cursor < nodes.size) {
        if (nodes[cursor].depth < childDepth) { break }
        if (nodes[cursor].depth == childDepth) {
            result.add(cursor)
            var skip = cursor + 1
            while (skip < nodes.size && nodes[skip].depth > nodes[cursor].depth) { skip++ }
            cursor = skip
            continue
        }
        cursor++
    }
    result
}

private func chirUnqualifiedName(qualifiedName: String): String {
    var index = qualifiedName.size
    while (index > 0) {
        index--
        if (qualifiedName[index] == b'.') { return qualifiedName[index + 1..] }
    }
    qualifiedName
}
