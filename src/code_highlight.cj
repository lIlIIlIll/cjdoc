package cjdoc

import cjdoc.model as public_model
import std.collection.*

internal let MAX_HIGHLIGHT_BLOCK_BYTES: Int64 = 256 * 1024
internal let MAX_HIGHLIGHT_SPANS_PER_BLOCK: Int64 = 65536
internal let MAX_HIGHLIGHT_TOTAL_SPANS: Int64 = 8192
internal let MAX_HIGHLIGHT_TOTAL_BYTES: Int64 = 4 * 1024 * 1024
internal let MAX_HIGHLIGHT_TOTAL_PREPARED_BYTES: Int64 = 4 * 1024 * 1024
internal let CANGJIE_HIGHLIGHT_ENGINE = "cjdoc-cangjie-lexer"
internal let CANGJIE_HIGHLIGHT_REVISION = "2"

// Shared by signatures, comment fences and @example trees in projection order.
// Charge conservative codec/pretty-JSON overhead, not just source or compact JSON.
internal class HighlightGenerationBudget {
    private let byteLimit: Int64
    private var preparedBytes: Int64 = 0
    private var metadataBytes: Int64 = 0
    private var spans: Int64 = 0
    private var exhausted: Bool = false

    init(byteLimit!: Int64 = MAX_HIGHLIGHT_TOTAL_BYTES) {
        let capped = if (byteLimit < 0) { 0 } else if (byteLimit > MAX_HIGHLIGHT_TOTAL_BYTES) {
            MAX_HIGHLIGHT_TOTAL_BYTES
        } else { byteLimit }
        this.byteLimit = if (capped > public_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES) {
            public_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES
        } else { capped }
    }

    func prepare(source: String, language: String): ?public_model.CodeHighlight {
        if (exhausted) { return None }
        if (byteLimit == 0 || source.size > MAX_HIGHLIGHT_TOTAL_PREPARED_BYTES - preparedBytes) {
            exhausted = true
            return None
        }
        preparedBytes += source.size
        let value = publicCodeHighlight(source, language)
        // Bound object/key/number and pretty-indent costs even at the maximum
        // generated Markdown depth; language includes worst-case JSON escaping.
        let bytes = 4096 + 6 * value.language.size + 2048 * value.spans.size
        if (value.spans.size > MAX_HIGHLIGHT_TOTAL_SPANS - spans ||
            bytes > byteLimit - metadataBytes) {
            exhausted = true
            return None
        }
        spans += value.spans.size
        metadataBytes += bytes
        Some(value)
    }

    func diagnostics(): Array<public_model.Diagnostic> {
        if (!exhausted) { return [] }
        [public_model.Diagnostic("warning", "CJDOC3028",
            "highlight metadata was omitted after the total resource budget was exhausted; code text was preserved")]
    }
}

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
