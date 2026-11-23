protected package cjdoc.source.frontend

import cjdoc.documentation.comments.parseDocCommentAt
import cjdoc.source.SourceLocation
import cjdoc.source.lexing.IndexedSourceBuffer
import cjdoc.source.model.{OrphanDocComment, SourceDeclaration}
import std.ast.*
import std.collection.*

protected class RawDocComment {
    protected let raw: String
    protected let source: SourceLocation
    protected var bound = false

    init(raw: String, source: SourceLocation) {
        this.raw = raw
        this.source = source
    }
}

protected func positionLess(lineA: Int64, columnA: Int64, lineB: Int64, columnB: Int64): Bool {
    return lineA < lineB || (lineA == lineB && columnA < columnB)
}

protected func positionLessOrEqual(lineA: Int64, columnA: Int64,
    lineB: Int64, columnB: Int64): Bool {
    !positionLess(lineB, columnB, lineA, columnA)
}

protected func makeSourceDeclarationKey(source: SourceLocation, kind: String, name: String): String {
    "${source.path}:${source.startLine}:${source.startColumn}:${kind}:${name}"
}

protected func rangeContains(outer: SourceLocation, inner: SourceLocation): Bool {
    if (outer.path != inner.path) { return false }
    let startsBefore = !positionLess(inner.startLine, inner.startColumn, outer.startLine, outer.startColumn)
    let endsAfter = !positionLess(outer.endLine, outer.endColumn, inner.endLine, inner.endColumn)
    return startsBefore && endsAfter
}

internal func commentLocation(path: String, token: Token, index: IndexedSourceBuffer): SourceLocation {
    let lines = token.value.split("\n")
    let rawStart = index.byteOffsetFromLexerPosition(Int64(token.pos.line),
        Int64(token.pos.column))
    let (startLine, startColumn) = index.position(rawStart)
    let endLine = startLine + lines.size - 1
    let endColumn = if (lines.size == 1) {
        startColumn + lines[0].toArray().size
    } else {
        lines[lines.size - 1].toArray().size + 1
    }
    SourceLocation(path, startLine, startColumn, endLine, endColumn)
}

protected func collectDocComments(path: String, tokens: Tokens,
    index: IndexedSourceBuffer): ArrayList<RawDocComment> {
    let comments = ArrayList<RawDocComment>()
    for (token in tokens) {
        if (token.kind == COMMENT && token.value.startsWith("/**")) {
            comments.add(RawDocComment(token.value, commentLocation(path, token, index)))
        }
    }
    comments
}


protected func isFunctionLike(symbol: SourceDeclaration): Bool {
    symbol.kind == "function" || symbol.kind == "constructor" || symbol.kind == "macro"
}

protected func sourceOrderLess(left: SourceDeclaration, right: SourceDeclaration): Bool {
    if (left.source.path != right.source.path) { return left.source.path < right.source.path }
    if (left.source.startLine != right.source.startLine) {
        return left.source.startLine < right.source.startLine
    }
    if (left.source.startColumn != right.source.startColumn) {
        return left.source.startColumn < right.source.startColumn
    }
    if (left.source.endLine != right.source.endLine) { return left.source.endLine > right.source.endLine }
    left.source.endColumn > right.source.endColumn
}

internal func removeLocalDeclarations(symbols: ArrayList<SourceDeclaration>,
    extraScopes: ArrayList<SourceLocation>): Unit {
    let activeFunctions = ArrayList<SourceLocation>()
    var index: Int64 = 0
    while (index < symbols.size) {
        var inExtraScope = false
        for (scope in extraScopes) {
            if (rangeContains(scope, symbols[index].source)) {
                inExtraScope = true
                break
            }
        }
        if (inExtraScope) {
            symbols.remove(at: index)
            continue
        }
        while (!activeFunctions.isEmpty() &&
            !rangeContains(activeFunctions[activeFunctions.size - 1], symbols[index].source)) {
            activeFunctions.remove(at: activeFunctions.size - 1)
        }
        if (!activeFunctions.isEmpty() && symbols[index].kind != "variable") {
            symbols.remove(at: index)
        } else {
            if (isFunctionLike(symbols[index])) { activeFunctions.add(symbols[index].source) }
            index++
        }
    }
}

internal func assignOwners(symbols: ArrayList<SourceDeclaration>): Unit {
    let containers = ArrayList<Int64>()
    var index: Int64 = 0
    while (index < symbols.size) {
        while (!containers.isEmpty() &&
            !rangeContains(symbols[containers[containers.size - 1]].source, symbols[index].source)) {
            containers.remove(at: containers.size - 1)
        }
        let best = if (containers.isEmpty()) { -1 } else { containers[containers.size - 1] }
        symbols[index].ownerIndex = best
        if (best >= 0) { symbols[index].ownerSourceKey = Some(symbols[best].sourceKey) }
        if (best >= 0 && symbols[best].kind == "interface" && symbols[index].visibility == "internal") {
            symbols[index].visibility = "public"
        }
        if (symbols[index].isContainer) { containers.add(index) }
        index++
    }
}

protected func onlyWhitespaceBetween(source: IndexedSourceBuffer, left: SourceLocation,
    right: SourceLocation): Bool {
    let start = source.byteOffset(left.endLine, left.endColumn)
    let end = source.byteOffset(right.startLine, right.startColumn)
    if (start < 0 || end < start) { return false }
    var index = start
    while (index < end && index < source.bytes.size) {
        match (source.bytes[index]) {
            case 9u8 | 10u8 | 13u8 | 32u8 => ()
            case _ => return false
        }
        index++
    }
    index == end
}

protected func sameSourceRange(left: SourceLocation, right: SourceLocation): Bool {
    left.path == right.path && left.startLine == right.startLine &&
        left.startColumn == right.startColumn && left.endLine == right.endLine &&
        left.endColumn == right.endColumn
}

internal func bindComments(symbols: ArrayList<SourceDeclaration>,
    comments: ArrayList<RawDocComment>, source: IndexedSourceBuffer): ArrayList<OrphanDocComment> {
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    var symbolIndex: Int64 = 0
    while (symbolIndex < symbols.size) {
        let symbol = symbols[symbolIndex]
        while (commentIndex < comments.size &&
            positionLessOrEqual(comments[commentIndex].source.endLine,
                comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        if (let Some(comment) <- candidate) {
            if (!comment.bound && onlyWhitespaceBetween(source, comment.source, symbol.source)) {
                var groupedIndex = symbolIndex
                while (groupedIndex < symbols.size &&
                    sameSourceRange(symbols[groupedIndex].source, symbol.source)) {
                    symbols[groupedIndex].documentation = parseDocCommentAt(comment.raw, Some(comment.source))
                    groupedIndex++
                }
                comment.bound = true
            }
            candidate = None
        }
        var nextIndex = symbolIndex + 1
        while (nextIndex < symbols.size && sameSourceRange(symbols[nextIndex].source, symbol.source)) {
            nextIndex++
        }
        symbolIndex = nextIndex
    }
    let orphans = ArrayList<OrphanDocComment>()
    for (comment in comments where !comment.bound) {
        orphans.add(OrphanDocComment(comment.raw, comment.source))
    }
    orphans
}

