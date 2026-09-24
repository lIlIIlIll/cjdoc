package cjdoc

import std.ast.*
import std.collection.*

private func syntaxRecoverySignificant(token: Token): Bool {
    token.kind != COMMENT && token.kind != NL && !token.value.isEmpty()
}

private func syntaxRecoveryOffset(index: IndexedSourceBuffer, token: Token): Int64 {
    index.byteOffsetFromLexerPosition(Int64(token.pos.line), Int64(token.pos.column))
}

private func syntaxRecoveryMatchingBrace(tokens: Tokens, opening: Int64): Int64 {
    var depth: Int64 = 1
    var index = opening + 1
    while (index < tokens.size) {
        let token = tokens[index]
        if (syntaxRecoverySignificant(token)) {
            if (token.value == "{") {
                depth++
            } else if (token.value == "}") {
                depth--
                if (depth == 0) { return index }
            }
        }
        index++
    }
    -1
}

// std.ast parses function bodies eagerly. A body can fail on an expression
// that declaration collection does not need; preserve original offsets by
// replacing only those bodies with same-length whitespace.
internal func syntaxRecoverySource(source: String): String {
    let tokens = cangjieLex(source)
    let sourceIndex = IndexedSourceBuffer(source)
    let bytes = source.toArray()
    let ranges = ArrayList<(Int64, Int64)>()
    var braceDepth: Int64 = 0
    var functionCandidate = false
    var index: Int64 = 0
    while (index < tokens.size) {
        let token = tokens[index]
        if (!syntaxRecoverySignificant(token)) {
            index++
            continue
        }
        let value = token.value
        if (value == "func" || value == "init" || value == "get" ||
            value == "set" || value == "mut" || value == "remove" ||
            value == "operator" || (braceDepth == 0 && value == "main")) {
            functionCandidate = true
        } else if (value == "{") {
            if (functionCandidate) {
                let closing = syntaxRecoveryMatchingBrace(tokens, index)
                if (closing >= 0) {
                    let start = syntaxRecoveryOffset(sourceIndex, token) + 1
                    let end = syntaxRecoveryOffset(sourceIndex, tokens[closing])
                    if (start >= 0 && end >= start && end <= bytes.size) {
                        ranges.add((start, end))
                    }
                    functionCandidate = false
                    index = closing + 1
                    continue
                }
            }
            braceDepth++
        } else if (value == "}") {
            if (braceDepth > 0) { braceDepth-- }
            functionCandidate = false
        }
        index++
    }
    if (ranges.isEmpty()) { return source }
    for (range in ranges) {
        let (start, end) = range
        var cursor = start
        while (cursor < end) {
            if (bytes[cursor] != b'\n' && bytes[cursor] != b'\r') {
                bytes[cursor] = b' '
            }
            cursor++
        }
    }
    String.fromUtf8(bytes)
}
