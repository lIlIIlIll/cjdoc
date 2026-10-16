package cjdoc

import std.collection.*
import std.convert.*
import cjdoc.model.codeBuiltinIdentifierKind

// Provenance: STS 1.2.0 include/cangjie/Lex/Tokens.inc (keyword/type table),
// plus lexer-ground-truth.txt for std.ast literal spellings and decoded payloads.
// String/Array/Char are the closed compatibility exception: the STS 1.2.0
// builtin-name probe confirms IDENTIFIER (highlight-builtin-identifiers.txt).
// model.codeBuiltinIdentifierKind shares that list with signature presentation.
private func cangjieCodeKind(kind: String, spelling: String): ?CodeKind {
    if (codeBuiltinIdentifierKind(kind, spelling) == "type") { return Some(CodeKind.Type) }
    match (kind) {
        case "STRING_LITERAL" | "MULTILINE_RAW_STRING" | "SINGLE_QUOTED_STRING_LITERAL" |
            "RUNE_BYTE_LITERAL" | "MULTILINE_STRING" | "JSTRING_LITERAL" => Some(CodeKind.StringLiteral)
        case "INTEGER_LITERAL" | "FLOAT_LITERAL" => Some(CodeKind.Number)
        case "BOOL_LITERAL" => Some(CodeKind.Literal)
        case "COMMENT" => Some(CodeKind.Comment)
        case "IS" | "AS" | "STRUCT" | "ENUM" | "PACKAGE" | "IMPORT" |
            "CLASS" | "INTERFACE" | "FUNC" | "MACRO" | "QUOTE" | "LET" |
            "VAR" | "CONST" | "TYPE" | "INIT" | "THIS" | "SUPER" |
            "IF" | "ELSE" | "CASE" | "TRY" | "CATCH" | "FINALLY" |
            "FOR" | "DO" | "WHILE" | "THROW" | "RETURN" | "CONTINUE" |
            "BREAK" | "IN" | "MATCH" | "WHERE" | "EXTEND" | "WITH" |
            "PROP" | "STATIC" | "PUBLIC" | "PRIVATE" | "INTERNAL" | "PROTECTED" |
            "OVERRIDE" | "REDEF" | "ABSTRACT" | "SEALED" | "OPEN" | "FOREIGN" |
            "INOUT" | "MUT" | "UNSAFE" | "OPERATOR" | "SPAWN" | "SYNCHRONIZED" |
            "MAIN" | "COMMON" | "SPECIFIC" | "FEATURES" => Some(CodeKind.Keyword)
        case "INT8" | "INT16" | "INT32" | "INT64" | "INTNATIVE" | "UINT8" |
            "UINT16" | "UINT32" | "UINT64" | "UINTNATIVE" | "FLOAT16" | "FLOAT32" |
            "FLOAT64" | "RUNE" | "BOOLEAN" | "NOTHING" | "UNIT" | "VARRAY" |
            "THISTYPE" => Some(CodeKind.Type)
        case "DOT" | "COMMA" | "LPAREN" | "RPAREN" | "LSQUARE" | "RSQUARE" |
            "LCURL" | "RCURL" | "COLON" | "SEMI" | "ELLIPSIS" | "HASH" |
            "AT" | "DOLLAR" | "WILDCARD" | "AT_EXCL" => Some(CodeKind.Punctuation)
        case "EXP" | "MUL" | "MOD" | "DIV" | "ADD" | "SUB" |
            "INCR" | "DECR" | "AND" | "OR" | "COALESCING" | "PIPELINE" |
            "COMPOSITION" | "NOT" | "BITAND" | "BITOR" | "BITXOR" | "BITNOT" |
            "LSHIFT" | "RSHIFT" | "ASSIGN" | "ADD_ASSIGN" | "SUB_ASSIGN" | "MUL_ASSIGN" |
            "EXP_ASSIGN" | "DIV_ASSIGN" | "MOD_ASSIGN" | "AND_ASSIGN" | "OR_ASSIGN" | "BITAND_ASSIGN" |
            "BITOR_ASSIGN" | "BITXOR_ASSIGN" | "LSHIFT_ASSIGN" | "RSHIFT_ASSIGN" | "ARROW" | "BACKARROW" |
            "DOUBLE_ARROW" | "RANGEOP" | "CLOSEDRANGEOP" | "QUEST" | "LT" | "GT" |
            "LE" | "GE" | "NOTEQ" | "EQUAL" | "NOT_IN" | "UPPERBOUND" |
            "DOUBLE_COLON" => Some(CodeKind.Operator)
        case _ => None
    }
}

// A bounded behavioral witness of the actually linked Lexer, not an SDK build ID.
// The corpus/version is fixed; generation computes it lazily once, never render/off.
internal func cangjieLexerBehaviorRevision(): String {
    let corpus = "// comment\n/* a /* b */ c */ let 名称: String = \"\"\r\n" +
        "let raw = ##\"a #\" b\"##\nlet rune = 'x'\n" +
        "let n = 0xFF + 0b1010 + 1_000 + 1.5e-3 + 10i8 + 1.0f32\n" +
        "f<Int64>(x: 1) { a: true, b: false }\n@M\npublic macro m() { 0 }\n"
    let tokens = sourceLexerTokens(corpus)
    if (tokens.size == 0 || tokens.size > 512) { throw IllegalArgumentException("invalid Lexer witness") }
    let index = IndexedSourceBuffer(corpus)
    let descriptor = StringBuilder()
    descriptor.append("lexer-behavior-v1:" + Sha256Digest.digest(corpus) + ";")
    var previous: Int64 = -1
    for (position in 0..tokens.size) {
        let token = tokens[position]
        let start = index.byteOffsetFromLexerPosition(Int64(token.pos.line), Int64(token.pos.column))
        let limit = if (position + 1 < tokens.size) {
            let next = tokens[position + 1]
            index.byteOffsetFromLexerPosition(Int64(next.pos.line), Int64(next.pos.column))
        } else { corpus.size }
        if (start <= previous || limit <= start || !highlightByteBoundary(corpus, start) ||
            !highlightByteBoundary(corpus, limit)) { throw IllegalArgumentException("invalid Lexer witness") }
        previous = start
        descriptor.append(token.kind.toString())
        descriptor.append(":" + start.toString() + ":" + limit.toString() + ";")
    }
    CANGJIE_HIGHLIGHT_REVISION + "/lexer-behavior-v1/" + Sha256Digest.digest(descriptor.toString())
}

internal func cangjieHighlightSpans(source: String): (Array<CodeSpan>, CodeHighlightState, ?String) {
    if (source.size > MAX_HIGHLIGHT_BLOCK_BYTES) { return ([], CodeHighlightState.Plain, Some("resource-limit")) }
    let spans = ArrayList<CodeSpan>()
    try {
        let tokens = sourceLexerTokens(source)
        let index = IndexedSourceBuffer(source)
        var previousStart: Int64 = -1
        for (position in 0..tokens.size) {
            let token = tokens[position]
            let start = index.byteOffsetFromLexerPosition(Int64(token.pos.line), Int64(token.pos.column))
            let limit = if (position + 1 < tokens.size) {
                let next = tokens[position + 1]
                index.byteOffsetFromLexerPosition(Int64(next.pos.line), Int64(next.pos.column))
            } else { source.size }
            if (start <= previousStart || limit <= start ||
                !highlightByteBoundary(source, start) || !highlightByteBoundary(source, limit)) {
                return ([], CodeHighlightState.Plain, Some("invalid-spans"))
            }
            previousStart = start
            var end = limit
            while (end > start && (source[end - 1] == b' ' || source[end - 1] == b'\t' ||
                source[end - 1] == b'\r' || source[end - 1] == b'\n')) { end-- }
            match (cangjieCodeKind(token.kind.toString(), token.value)) {
                case Some(kind) =>
                    if (end <= start || !highlightByteBoundary(source, end)) {
                        return ([], CodeHighlightState.Plain, Some("invalid-spans"))
                    }
                    if (spans.size >= MAX_HIGHLIGHT_SPANS_PER_BLOCK) {
                        return ([], CodeHighlightState.Plain, Some("resource-limit"))
                    }
                    spans.add(CodeSpan(start, end, kind))
                case None => ()
            }
        }
        (spans.toArray(), CodeHighlightState.Complete, None)
    } catch (_: IllegalArgumentException) {
        ([], CodeHighlightState.Plain, Some("unterminated-token"))
    } catch (_: Exception) {
        ([], CodeHighlightState.Plain, Some("lexer-failed"))
    }
}

// SourceApiSignature remains the identity witness. Reuse its token kind/spelling;
// only trivia omitted by that witness needs an independent Lexer pass.
internal func cangjieSignatureHighlightSpans(source: String, witness: Array<String>):
    (Array<CodeSpan>, CodeHighlightState, ?String) {
    let spans = ArrayList<CodeSpan>()
    var cursor: Int64 = 0
    try {
        for (encoded in witness) {
            let parts = encoded.split(":", 3)
            if (parts.size != 3 || parts[2].isEmpty()) { throw IllegalArgumentException("invalid witness") }
            let size = Int64.parse(parts[1])
            let start = signatureHighlightTriviaEnd(source, cursor)
            if (size != parts[2].size || size > source.size - start ||
                source[start..start + size] != parts[2]) { throw IllegalArgumentException("stale witness") }
            appendSignatureTriviaHighlight(source, cursor, start, spans)
            if (let Some(kind) <- cangjieCodeKind(parts[0], parts[2])) {
                spans.add(CodeSpan(start, start + size, kind))
            }
            if (spans.size > MAX_HIGHLIGHT_SPANS_PER_BLOCK) {
                return ([], CodeHighlightState.Plain, Some("resource-limit"))
            }
            cursor = start + size
        }
        let end = signatureHighlightTriviaEnd(source, cursor)
        if (end != source.size) { throw IllegalArgumentException("incomplete witness") }
        appendSignatureTriviaHighlight(source, cursor, end, spans)
        (spans.toArray(), CodeHighlightState.Complete, None)
    } catch (_: Exception) { ([], CodeHighlightState.Plain, Some("invalid-spans")) }
}

private func appendSignatureTriviaHighlight(source: String, start: Int64, end: Int64,
    spans: ArrayList<CodeSpan>): Unit {
    if (end <= start) { return }
    let trivia = source[start..end]
    if (!trivia.contains("/")) { return }
    let (comments, state, _) = cangjieHighlightSpans(trivia)
    match (state) { case CodeHighlightState.Complete => ()
        case _ => throw IllegalArgumentException("invalid signature trivia") }
    for (comment in comments) {
        spans.add(CodeSpan(start + comment.startByte, start + comment.endByte, comment.kind))
    }
}

// This aligns already captured tokens; it does not classify declaration syntax.
// Same nested-comment trivia rule as the existing signature renderer alignment.
private func signatureHighlightTriviaEnd(raw: String, from: Int64): Int64 {
    var cursor = from
    while (cursor < raw.size) {
        if (raw[cursor] == b' ' || raw[cursor] == b'\t' || raw[cursor] == b'\r' || raw[cursor] == b'\n') {
            cursor++; continue
        }
        if (cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'/') {
            while (cursor < raw.size && raw[cursor] != b'\n') { cursor++ }
        } else if (cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'*') {
            var depth: Int64 = 1
            cursor += 2
            while (cursor < raw.size && depth > 0) {
                if (cursor + 1 < raw.size && raw[cursor] == b'/' && raw[cursor + 1] == b'*') { depth++; cursor += 2 }
                else if (cursor + 1 < raw.size && raw[cursor] == b'*' && raw[cursor + 1] == b'/') { depth--; cursor += 2 }
                else { cursor++ }
            }
            if (depth != 0) { throw IllegalArgumentException("unterminated signature comment") }
        } else { break }
    }
    cursor
}

