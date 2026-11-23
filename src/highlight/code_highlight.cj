protected package cjdoc.highlight

import cjdoc.digest.Sha256Digest
import cjdoc.model as public_model
import std.collection.*

private func highlightBackendFailureDiagnostic(strict: Bool): public_model.Diagnostic {
    let diagnostic = if (strict) {
        public_model.Diagnostic("error", "CJDOC4027",
            "highlighting backend failed and [highlight].on-error is \"error\"; code text was preserved")
    } else {
        public_model.Diagnostic("warning", "CJDOC3120",
            "highlighting backend unavailable or invalid; code text was preserved")
    }
    diagnostic.markHighlightFailure()
    diagnostic
}

protected func highlightCacheKey(source: String, language: String, disabled: Bool,
    builtinRevision!: String = CANGJIE_HIGHLIGHT_REVISION): String {
    Sha256Digest.digest(source) + ":" + language + ":" + CANGJIE_HIGHLIGHT_ENGINE + ":" +
        builtinRevision + ":" + EXTERNAL_HIGHLIGHT_PROTOCOL + ":" +
        EXTERNAL_HIGHLIGHT_REVISION + ":ignoreIllegals=true:" + disabled.toString()
}

// Shared by signatures, comment fences and @example trees in projection order.
// Charge conservative codec/pretty-JSON overhead, not just source or compact JSON.
protected class HighlightGenerationBudget {
    private let byteLimit: Int64
    private var preparedBytes: Int64 = 0
    private var metadataBytes: Int64 = 0
    private var spans: Int64 = 0
    private var exhausted: Bool = false
    private var backendFailed: Bool = false
    private var builtinRevision: String = ""
    private let cache = HashMap<String, public_model.CodeHighlight>()
    private let externalOptions: ?HighlightExternalOptions
    private let allowLanguage: ?(String) -> Bool
    private let onError: String

    protected init(byteLimit!: Int64 = MAX_HIGHLIGHT_TOTAL_BYTES,
        allowLanguage!: ?(String) -> Bool = None,
        onError!: String = "warn",
        externalOptions!: ?HighlightExternalOptions = None) {
        this.onError = onError
        this.externalOptions = externalOptions
        this.allowLanguage = allowLanguage
        let capped = if (byteLimit < 0) { 0 } else if (byteLimit > MAX_HIGHLIGHT_TOTAL_BYTES) {
            MAX_HIGHLIGHT_TOTAL_BYTES
        } else { byteLimit }
        this.byteLimit = if (capped > public_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES) {
            public_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES
        } else { capped }
    }

    protected func prepare(source: String, language: String, witness!: Array<String> = []): ?public_model.CodeHighlight {
        if (exhausted) { return None }
        let normalized = public_model.normalizeCodeLanguage(language)
        let disabled = match (allowLanguage) {
            case Some(allows) => !allows(normalized)
            case None => false
        }
        if (byteLimit == 0 || source.size > MAX_HIGHLIGHT_TOTAL_PREPARED_BYTES - preparedBytes) {
            exhausted = true
            return None
        }
        preparedBytes += source.size
        // Lexical data only: no owner, routes, audience identifiers or semantic links.
        // This cache lives only for this projected generation and is never exported.
        let needsLexer = !disabled && public_model.codeLanguageBackend(normalized) == "builtin" &&
            source.size <= MAX_HIGHLIGHT_BLOCK_BYTES
        if (needsLexer && builtinRevision.isEmpty()) {
            builtinRevision = try { cangjieLexerBehaviorRevision() }
                catch (_: Exception) { CANGJIE_HIGHLIGHT_REVISION + "/lexer-witness-unavailable" }
        }
        let revision = if (needsLexer) { builtinRevision } else { CANGJIE_HIGHLIGHT_REVISION }
        let key = highlightCacheKey(source, normalized, disabled, builtinRevision: revision)
        let value = match (cache.get(key)) {
            case Some(found) => found
            case None =>
                let prepared = publicCodeHighlight(source, normalized, externalOptions: externalOptions,
                    disabledReason: if (disabled) { Some("disabled") }
                        else if (revision.endsWith("/lexer-witness-unavailable")) { Some("lexer-failed") }
                        else { None }, witness: witness, builtinRevision: Some(revision))
                if (prepared.state == "complete" || prepared.state == "partial" ||
                    ["disabled", "no-language", "unsupported"].contains(
                        prepared.reason.getOrDefault({ => "" }))) { cache[key] = prepared }
                prepared
        }
        // A completed backend attempt remains observable even when its optional colors do not fit.
        recordBackendFailure(value)
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

    // Only a failed backend counts as a highlight error. A language that is
    // unsupported, switched off, or missing metadata is an intended plain result,
    // and genuinely unterminated source is a property of the code, not of the
    // highlighting pipeline, so `on-error = "error"` must not fail those runs.
    private func recordBackendFailure(value: public_model.CodeHighlight): Unit {
        if (value.state != "plain") { return }
        match (value.reason) {
            case Some("backend-unavailable") | Some("lexer-failed") | Some("invalid-spans") =>
                backendFailed = true
            case _ => ()
        }
    }

    protected func close(): Unit {
        if (let Some(options) <- externalOptions) { options.close() }
        cache.clear()
    }

    protected func onErrorName(): String { onError }

    // Escalation for `[highlight].on-error = "error"`: the same failure that is a
    // warning by default must be able to fail the run explicitly.
    protected func escalationDiagnostics(): Array<public_model.Diagnostic> {
        if (onError != "error" || !backendFailed) { return [] }
        [highlightBackendFailureDiagnostic(true)]
    }

    protected func diagnostics(): Array<public_model.Diagnostic> {
        let result = ArrayList<public_model.Diagnostic>()
        if (exhausted) { result.add(public_model.Diagnostic("warning", "CJDOC3028",
            "highlight metadata was omitted after the total resource budget was exhausted; code text was preserved")) }
        if (backendFailed && onError == "warn") { result.add(highlightBackendFailureDiagnostic(false)) }
        result.toArray()
    }
}

// Retain only diagnostics produced by the highlighter, never code/message guesses.
protected func retainedHighlightBackendDiagnostics(source: public_model.DocumentationSet):
    Array<public_model.Diagnostic> {
    let result = ArrayList<public_model.Diagnostic>()
    for (diagnostic in source.diagnostics) {
        if (diagnostic.isHighlightFailure) { result.add(diagnostic) }
    }
    result.toArray()
}

protected func publicCodeHighlight(source: String, language: String,
    externalOptions!: ?HighlightExternalOptions = None,
    disabledReason!: ?String = None, witness!: Array<String> = [],
    builtinRevision!: ?String = None): public_model.CodeHighlight {
    let normalized = public_model.normalizeCodeLanguage(language)
    let value = highlightCode(source, normalized, public_model.codeLanguageBackend(normalized),
        externalOptions: externalOptions, disabledReason: disabledReason, witness: witness)
    let spans = ArrayList<public_model.CodeSpan>()
    for (span in value.spans()) {
        spans.add(public_model.CodeSpan(span.startByte, span.endByte, codeKindName(span.kind)))
    }
    let state = match (value.state) {
        case CodeHighlightState.Complete => "complete"
        case CodeHighlightState.Partial => "partial"
        case CodeHighlightState.Plain => "plain"
    }
    let revision = if (value.engineId == CANGJIE_HIGHLIGHT_ENGINE) {
        builtinRevision.getOrDefault({ => value.engineRevision })
    } else { value.engineRevision }
    public_model.CodeHighlight(normalized, public_model.contractFingerprint(source), source.size,
        value.engineId, revision, state, value.reason, spans.toArray())
}

protected func highlightCode(source: String, language: String, backend: String,
    externalOptions!: ?HighlightExternalOptions = None,
    disabledReason!: ?String = None, witness!: Array<String> = []): CodeHighlight {
    if (source.size > MAX_HIGHLIGHT_BLOCK_BYTES) {
        return CodeHighlight(source, language, [], CodeHighlightState.Plain, Some("resource-limit"))
    }
    // A configured-off language outranks the backend vocabulary: the block is not
    // colored because the project said so, not because a backend was missing.
    if (let Some(reason) <- disabledReason) {
        if (!language.isEmpty()) {
            return CodeHighlight(source, language, [], CodeHighlightState.Plain, Some(reason))
        }
    }
    try {
        if (backend == "builtin") {
            let (spans, state, reason) = if (witness.isEmpty()) { cangjieHighlightSpans(source) }
                else { cangjieSignatureHighlightSpans(source, witness) }
            return CodeHighlight(source, language, spans, state, reason)
        }
        if (backend == "external") {
            if (let Some(options) <- externalOptions) { return externalCodeHighlight(source, language, options) }
        }
        let reason = if (backend == "external") { "backend-unavailable" }
            else if (language.isEmpty()) { "no-language" } else { "unsupported" }
        CodeHighlight(source, language, [], CodeHighlightState.Plain, Some(reason))
    } catch (_: Exception) {
        CodeHighlight(source, language, [], CodeHighlightState.Plain, Some("invalid-spans"))
    }
}
