package cjdoc

import cjdoc.model as public_model
import std.collection.*

internal let MAX_HIGHLIGHT_BLOCK_BYTES: Int64 = 256 * 1024
internal let MAX_HIGHLIGHT_SPANS_PER_BLOCK: Int64 = 65536
internal let CANGJIE_HIGHLIGHT_ENGINE = "cjdoc-cangjie-lexer"
internal let CANGJIE_HIGHLIGHT_REVISION = "2"

internal enum CodeKind {
    Keyword | Type | StringLiteral | Number | Literal | Comment | Operator |
    Punctuation | Function | Property | Meta
}

internal func codeKindName(kind: CodeKind): String {
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

internal class CodeSpan {
    let startByte: Int64
    let endByte: Int64
    let kind: CodeKind
    init(startByte: Int64, endByte: Int64, kind: CodeKind) {
        this.startByte = startByte; this.endByte = endByte; this.kind = kind
    }
}

// Complete describes the presentation flow, never compilation or program validity.
internal enum CodeHighlightState { Complete | Partial | Plain }

internal func highlightByteBoundary(source: String, offset: Int64): Bool {
    offset >= 0 && offset <= source.size &&
        (offset == source.size || (source[offset] & 0xC0) != 0x80)
}

internal class CodeHighlight {
    let language: String
    let engineId: String = CANGJIE_HIGHLIGHT_ENGINE
    let engineRevision: String = CANGJIE_HIGHLIGHT_REVISION
    let state: CodeHighlightState
    let reason: ?String
    let byteLength: Int64
    private let spansStorage: ArrayList<CodeSpan>

    init(source: String, language: String, spans: Array<CodeSpan>,
        state: CodeHighlightState, reason: ?String) {
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

    func spans(): ReadOnlyList<CodeSpan> { spansStorage }
}

internal func publicCodeHighlight(source: String, language: String): public_model.CodeHighlight {
    let normalized = public_model.normalizeCodeLanguage(language)
    let value = highlightCode(source, normalized, public_model.codeLanguageBackend(normalized))
    let spans = ArrayList<public_model.CodeSpan>()
    for (span in value.spans()) {
        spans.add(public_model.CodeSpan(span.startByte, span.endByte, codeKindName(span.kind)))
    }
    let state = match (value.state) {
        case CodeHighlightState.Complete => "complete"
        case CodeHighlightState.Partial => "partial"
        case CodeHighlightState.Plain => "plain"
    }
    public_model.CodeHighlight(normalized, public_model.contractFingerprint(source), source.size,
        value.engineId, value.engineRevision, state, value.reason, spans.toArray())
}

internal func highlightCode(source: String, language: String, backend: String): CodeHighlight {
    if (source.size > MAX_HIGHLIGHT_BLOCK_BYTES) {
        return CodeHighlight(source, language, [], CodeHighlightState.Plain, Some("resource-limit"))
    }
    try {
        if (backend == "builtin") {
            let (spans, state, reason) = cangjieHighlightSpans(source)
            return CodeHighlight(source, language, spans, state, reason)
        }
        let reason = if (backend == "external") { "backend-unavailable" }
            else if (language.isEmpty()) { "no-language" } else { "unsupported" }
        CodeHighlight(source, language, [], CodeHighlightState.Plain, Some(reason))
    } catch (_: Exception) {
        CodeHighlight(source, language, [], CodeHighlightState.Plain, Some("invalid-spans"))
    }
}
