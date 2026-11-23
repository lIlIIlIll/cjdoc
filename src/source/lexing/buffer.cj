protected package cjdoc.source.lexing

import cjdoc.source.SourceLocation
import std.ast.*
import std.collection.*

protected func sourceLexerTokens(source: String): Tokens {
    cangjieLex(source)
}

// Store the exact source spelling for each lexer token in the existing
// kind:byteLength:spelling witness. Token.value is the decoded payload for
// string literals (and can be empty), not the raw spelling with delimiters.
// The next *lexer* token, including comments/newlines, bounds the slice;
// only inter-token whitespace is removed from its end.
protected func sourceApiSignatureTokens(signature: String): Array<String> {
    let result = ArrayList<String>()
    try {
        let sourceIndex = IndexedSourceBuffer(signature)
        let tokens = cangjieLex(signature)
        var previousEnd: Int64 = 0
        for (position in 0..tokens.size) {
            let token = tokens[position]
            if (token.kind == COMMENT || token.kind == NL ||
                (token.value.isEmpty() && token.kind != STRING_LITERAL)) { continue }
            let start = sourceIndex.byteOffsetFromLexerPosition(
                Int64(token.pos.line), Int64(token.pos.column))
            let limit = if (position + 1 < tokens.size) {
                let following = tokens[position + 1]
                sourceIndex.byteOffsetFromLexerPosition(
                    Int64(following.pos.line), Int64(following.pos.column))
            } else { signature.size }
            if (start < previousEnd || start < 0 || limit <= start ||
                limit > signature.size) { return [] }
            var end = limit
            while (end > start && (signature[end - 1] == b' ' ||
                signature[end - 1] == b'\t' || signature[end - 1] == b'\r' ||
                signature[end - 1] == b'\n')) { end-- }
            if (end == start) { return [] }
            let spelling = signature[start..end]
            result.add("${token.kind}:${spelling.size}:${spelling}")
            previousEnd = end
        }
    } catch (_: Exception) {
        return []
    }
    result.toArray()
}

// One immutable source buffer is shared by declaration extraction and comment
// binding. Line starts make source-position conversion logarithmic instead of
// rescanning and reallocating the complete file for every declaration.
protected class IndexedSourceBuffer {
    protected let source: String
    protected let bytes: Array<UInt8>
    private let lineStarts = ArrayList<Int64>()

    protected init(source: String) {
        this.source = source
        this.bytes = source.toArray()
        lineStarts.add(0)
        var index: Int64 = 0
        while (index < bytes.size) {
            if (bytes[index] == b'\n') { lineStarts.add(index + 1) }
            index++
        }
    }

    protected func byteOffsetFromLexerPosition(line: Int64, column: Int64): Int64 {
        if (line < 1 || column < 1 || line > lineStarts.size) { return -1 }
        let lineIndex = line - 1
        let start = lineStarts[lineIndex]
        let lineEnd = if (lineIndex + 1 < lineStarts.size) {
            lineStarts[lineIndex + 1] - 1
        } else {
            bytes.size
        }
        let offset = start + column - 1
        if (offset < start || offset > lineEnd) { return -1 }
        offset
    }

    protected func byteOffset(line: Int64, column: Int64): Int64 {
        byteOffsetFromLexerPosition(line, column)
    }

    // Public SourcePosition columns are 1-based UTF-8 byte columns.
    protected func position(offset: Int64): (Int64, Int64) {
        if (offset < 0 || offset > bytes.size) { return (1, 1) }
        var low: Int64 = 0
        var high: Int64 = lineStarts.size
        while (low + 1 < high) {
            let middle = low + (high - low) / 2
            if (lineStarts[middle] <= offset) {
                low = middle
            } else {
                high = middle
            }
        }
        (low + 1, offset - lineStarts[low] + 1)
    }

    protected func slice(location: SourceLocation): String {
        let start = byteOffset(location.startLine, location.startColumn)
        let end = byteOffset(location.endLine, location.endColumn)
        if (start < 0 || end < start || end > bytes.size) { return "" }
        String.fromUtf8(bytes[start..end])
    }
}

protected func enumCaseStart(source: IndexedSourceBuffer, line: Int64, column: Int64): (Int64, Int64) {
    let start = source.byteOffset(line, column)
    if (start <= 0) { return (line, column) }
    var cursor = start - 1
    while (cursor >= 0 && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor-- }
    if (cursor < 0 || source.bytes[cursor] != b'|') { return (line, column) }
    source.position(cursor)
}

protected func headerEndOffset(source: String): Int64 {
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    for (token in cangjieLex(source)) {
        match (token.kind) {
            case LPAREN => roundDepth++
            case RPAREN => roundDepth--
            case LSQUARE => squareDepth++
            case RSQUARE => squareDepth--
            case LCURL =>
                if (roundDepth == 0 && squareDepth == 0) {
                    return IndexedSourceBuffer(source).byteOffsetFromLexerPosition(
                        Int64(token.pos.line), Int64(token.pos.column))
                }
            case _ => ()
        }
    }
    return source.size
}
