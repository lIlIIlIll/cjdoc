protected package cjdoc.documentation.markdown

import cjdoc.highlight.{HighlightExternalOptions, HighlightGenerationBudget, MAX_HIGHLIGHT_TOTAL_BYTES}
import cjdoc.model as public_model
import std.collection.*

internal let MAX_GENERATED_MARKDOWN_DEPTH: Int64 = 48
internal let MAX_GENERATED_MARKDOWN_NODES: Int64 = 100000
internal let MAX_GENERATED_MARKDOWN_STRING_BYTES: Int64 = 1024 * 1024
internal let MAX_GENERATED_MARKDOWN_TOTAL_BYTES: Int64 = 16 * 1024 * 1024
protected let MARKDOWN_FALLBACK_TEXT = "Documentation omitted because Markdown resource limits were exceeded."

protected class MarkdownGenerationContext {
    private let highlightMode: String
    protected let highlightBudget: HighlightGenerationBudget

    protected init(highlightMode!: String = "auto", allowLanguage!: Option<(String) -> Bool> = None,
        onError!: String = "warn",
        highlightBytes!: Int64 = MAX_HIGHLIGHT_TOTAL_BYTES,
        externalOptions!: ?HighlightExternalOptions = None) {
        this.highlightMode = highlightMode
        this.highlightBudget = HighlightGenerationBudget(byteLimit: highlightBytes,
            allowLanguage: allowLanguage, onError: onError,
            externalOptions: externalOptions)
    }
    private var nodes: Int64 = 0
    private var textBytes: Int64 = 0
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let retainedHighlightFailures = ArrayList<public_model.Diagnostic>()
    private let failedSymbols = HashSet<String>()
    protected var incomplete: Bool = false

    func consumeNode(depth: Int64): Unit {
        if (depth < 0 || depth > MAX_GENERATED_MARKDOWN_DEPTH || nodes >= MAX_GENERATED_MARKDOWN_NODES) {
            throw IllegalArgumentException("generated Markdown exceeds node/depth budget")
        }
        nodes++
    }

    protected func consumeText(value: String): Unit {
        let size = value.size
        if (size > MAX_GENERATED_MARKDOWN_STRING_BYTES || size > MAX_GENERATED_MARKDOWN_TOTAL_BYTES - textBytes) {
            throw IllegalArgumentException("generated Markdown exceeds text budget")
        }
        textBytes += size
    }

    protected func requireBodySize(summary: String, description: String): Unit {
        let separator: Int64 = if (description.isEmpty()) {
            0
        } else {
            2
        }
        if (summary.size > MAX_GENERATED_MARKDOWN_STRING_BYTES || description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES ||
            description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES - separator || summary.size >
            MAX_GENERATED_MARKDOWN_STRING_BYTES - description.size - separator) {
            throw IllegalArgumentException("generated Markdown input exceeds comment budget")
        }
    }

    protected func fail(source: public_model.SourceRange, symbolId: String): Unit {
        incomplete = true
        if (!failedSymbols.add(symbolId)) {
            return
        }
        diagnosticsStorage.add(
            public_model.Diagnostic("warning", "CJDOC3026",
                "documentation Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
                source: Some(source), symbolId: Some(symbolId)))
    }
    protected func admonitionWithoutBody(symbolId: String, source!: ?public_model.SourceRange = None): Unit {
        diagnosticsStorage.add(public_model.Diagnostic("error", "CJDOC3117",
            "Markdown admonition marker has no body", source: source,
            symbolId: if (symbolId.isEmpty()) { None } else { Some(symbolId) }))
    }

    protected func retainHighlightFailures(diagnostics: Array<public_model.Diagnostic>): Unit {
        for (diagnostic in diagnostics) {
            if (diagnostic.isHighlightFailure) { retainedHighlightFailures.add(diagnostic) }
        }
    }

    protected func highlightDiagnostics(): Array<public_model.Diagnostic> {
        let result = ArrayList<public_model.Diagnostic>(retainedHighlightFailures.toArray())
        result.add(all: highlightBudget.diagnostics())
        result.add(all: highlightBudget.escalationDiagnostics())
        result.toArray()
    }

    protected func collectionDiagnostics(): Array<public_model.Diagnostic> { diagnosticsStorage.toArray() }

    protected func diagnostics(): Array<public_model.Diagnostic> {
        let result = ArrayList<public_model.Diagnostic>(diagnosticsStorage.toArray())
        result.add(all: highlightDiagnostics())
        result.toArray()
    }

    protected func highlight(source: String, language: String, witness!: Array<String> = []): ?public_model.CodeHighlight {
        if (highlightMode == "off") { return None }
        highlightBudget.prepare(source, language, witness: witness)
    }
}

protected func fallbackPublicMarkdown(): public_model.MarkdownNode {
    public_model.MarkdownNode("document",
        children: [public_model.MarkdownNode("paragraph",
            children: [public_model.MarkdownNode("text", literal: MARKDOWN_FALLBACK_TEXT)])])
}
