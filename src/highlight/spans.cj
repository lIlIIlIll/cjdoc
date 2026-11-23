protected package cjdoc.highlight

import std.collection.*

protected let MAX_HIGHLIGHT_BLOCK_BYTES: Int64 = 256 * 1024
protected let MAX_HIGHLIGHT_SPANS_PER_BLOCK: Int64 = 65536
protected let MAX_HIGHLIGHT_TOTAL_SPANS: Int64 = 8192
protected let MAX_HIGHLIGHT_TOTAL_BYTES: Int64 = 4 * 1024 * 1024
protected let MAX_HIGHLIGHT_TOTAL_PREPARED_BYTES: Int64 = 4 * 1024 * 1024
protected let CANGJIE_HIGHLIGHT_ENGINE = "cjdoc-cangjie-lexer"
protected let CANGJIE_HIGHLIGHT_REVISION = "2"

protected enum CodeKind {
    Keyword | Type | StringLiteral | Number | Literal | Comment | Operator |
    Punctuation | Function | Property | Meta
}

protected func codeKindName(kind: CodeKind): String {
    match (kind) {
        case CodeKind.Keyword => "keyword"
        case CodeKind.Type => "type"
        case CodeKind.StringLiteral => "string"
        case CodeKind.Number => "number"
        case CodeKind.Literal => "literal"
        case CodeKind.Comment => "comment"
        case CodeKind.Operator => "operator"
        case CodeKind.Punctuation => "punctuation"
        case CodeKind.Function => "function"
        case CodeKind.Property => "property"
        case CodeKind.Meta => "meta"
    }
}

protected class CodeSpan {
    protected let startByte: Int64
    protected let endByte: Int64
    protected let kind: CodeKind
    protected init(startByte: Int64, endByte: Int64, kind: CodeKind) {
        this.startByte = startByte; this.endByte = endByte; this.kind = kind
    }
}

// Complete describes the presentation flow, never compilation or program validity.
protected enum CodeHighlightState { Complete | Partial | Plain }

protected func highlightByteBoundary(source: String, offset: Int64): Bool {
    offset >= 0 && offset <= source.size &&
        (offset == source.size || (source[offset] & 0xC0) != 0x80)
}

protected class CodeHighlight {
    protected let language: String
    protected let engineId: String
    protected let engineRevision: String
    protected let state: CodeHighlightState
    protected let reason: ?String
    protected let byteLength: Int64
    private let spansStorage: ArrayList<CodeSpan>

    protected init(source: String, language: String, spans: Array<CodeSpan>,
        state: CodeHighlightState, reason: ?String, engineId!: String = CANGJIE_HIGHLIGHT_ENGINE,
        engineRevision!: String = CANGJIE_HIGHLIGHT_REVISION) {
        this.engineId = engineId; this.engineRevision = engineRevision
        var previousEnd: Int64 = 0
        if (spans.size > MAX_HIGHLIGHT_SPANS_PER_BLOCK) {
            throw IllegalArgumentException("resource-limit")
        }
        for (span in spans) {
            if (span.startByte < previousEnd || span.endByte <= span.startByte ||
                !highlightByteBoundary(source, span.startByte) ||
                !highlightByteBoundary(source, span.endByte)) {
                throw IllegalArgumentException("invalid-spans")
            }
            previousEnd = span.endByte
        }
        this.language = language; this.state = state; this.reason = reason
        this.byteLength = source.size; this.spansStorage = ArrayList<CodeSpan>(spans)
    }

    protected func spans(): ReadOnlyList<CodeSpan> { spansStorage }
}

