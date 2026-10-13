package cjdoc

import std.collection.*
import cjdoc.model.codeBuiltinIdentifierKind

// Provenance: STS 1.2.0 include/cangjie/Lex/Tokens.inc (keyword/type table),
// plus lexer-ground-truth.txt for std.ast literal spellings and decoded payloads.
// String/Array/Char are the closed compatibility exception: the STS 1.2.0
// builtin-name probe confirms IDENTIFIER (highlight-builtin-identifiers.txt).
// model.codeBuiltinIdentifierKind shares that list with signature presentation.
private func cangjieCodeKind(kind: String, spelling: String): ?CodeKind {
    if (codeBuiltinIdentifierKind(kind, spelling) == "type") { return Some(CodeKind.Type) }
    match (kind) {
        case "STRING_LITERAL" | "MULTILINE_RAW_STRING" | "SINGLE_QUOTED_STRING_LITERAL" => Some(CodeKind.StringLiteral)
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
