package cjdoc.render

import cjdoc.model.*
import std.collection.*

/** Coverage counts author-provided text; fallbacks never count as translations. */
public class TranslationCoverageReport {
    public let language: String
    public var total: Int64 = 0
    public var translated: Int64 = 0
    public var fallback: Int64 = 0
    public var missing: Int64 = 0
    public var empty: Int64 = 0
    public var unknown: Int64 = 0
    public var conflict: Int64 = 0
    public var unpaired: Int64 = 0
    private let entriesStorage = ArrayList<TranslationCoverageEntry>()
    init(language: String) { this.language = language }
    public prop entries: ReadOnlyList<TranslationCoverageEntry> { get() { entriesStorage } }
    public prop percent: Int64 { get() { coveragePercent(translated, total) } }
    func add(entry: TranslationCoverageEntry): Unit {
        entriesStorage.add(entry); total++
        match (entry.state) {
            case "complete" => translated++
            case "fallback" => fallback++
            case "empty" => empty++
            case "unknown" => unknown++
            case "conflict" => conflict++
            case "unpaired" => unpaired++
            case _ => missing++
        }
    }
}

public class TranslationCoverageEntry {
    public let symbolId: ?String
    public let fieldId: String
    public let kind: String
    public let subject: String
    public let state: String
    public let actualLanguage: ?String
    public let source: ?SourceRange
    init(symbolId: String, fieldId: String, kind: String, subject: String,
        state: String, actualLanguage: ?String, source: ?SourceRange) {
        this.symbolId = if (symbolId.isEmpty()) { None } else { Some(symbolId) }
        this.fieldId = fieldId; this.kind = kind; this.subject = subject
        this.state = state; this.actualLanguage = actualLanguage; this.source = source
    }
}

private func translationFieldEntry(symbol: SymbolDoc, fieldId: String, kind: String,
    subject: String, locale: String): TranslationCoverageEntry {
    let comment = symbol.documentation
    var source: ?SourceRange = Some(symbol.source)
    var state = "missing"
    var actual: ?String = None
    if (let Some(value) <- comment) {
        for (text in value.localizedTexts) {
            if (text.fieldId != fieldId) { continue }
            if (text.source.isSome()) { source = text.source }
            if (text.language != Some(locale)) { continue }
            if (text.state == "valid" && !text.text.trimAscii().isEmpty()) {
                return TranslationCoverageEntry(symbol.id, fieldId, kind, subject, "complete", text.language, text.source)
            }
            state = if (text.state == "conflict" || text.state == "invalid") { "conflict" }
                else if (text.state == "unpaired") { "unpaired" } else { "empty" }
        }
        let original = localizedTextFor(value, fieldId, value.defaultLanguage)
        if (let Some(text) <- original) {
            actual = text.language
            if (state == "missing") { state = if (actual.isNone()) { "unknown" } else { "fallback" } }
        }
        if (value.localizedTexts.isEmpty()) {
            var exists = if (kind == "summary") { !value.summary.trimAscii().isEmpty() }
                else if (kind == "description") { !value.description.trimAscii().isEmpty() } else { false }
            for (tag in value.tags) {
                if (tag.name == kind && tag.subject == subject && !tag.description.trimAscii().isEmpty()) { exists = true }
            }
            if (exists) { state = "unknown" }
        }
    }
    TranslationCoverageEntry(symbol.id, fieldId, kind, subject, state, actual, source)
}

/** The denominator uses shared signatures and original documentation entries. */
public func translationCoverageFor(documentation: DocumentationSet, language: String): TranslationCoverageReport {
    let locale = documentationLanguage(language)
    let report = TranslationCoverageReport(locale)
    for (symbol in RenderProjection(documentation).visibleSymbols) {
        let prefix = symbol.id + ":doc:"
        report.add(translationFieldEntry(symbol, prefix + "summary:", "summary", "", locale))
        let authoredParameters = HashSet<String>()
        if (let Some(comment) <- symbol.documentation) {
            for (text in comment.localizedTexts where text.kind == "param") { let _ = authoredParameters.add(text.subject) }
            for (tag in comment.tags where tag.name == "param") { let _ = authoredParameters.add(tag.subject) }
        }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_") ||
            parameter.documentation.isSome() || authoredParameters.contains(parameter.name)) {
            report.add(translationFieldEntry(symbol, prefix + "param:" + parameter.name, "param", parameter.name, locale))
        }
        if (symbol.returnType.isSome() && !isUnitType(symbol.returnType.getOrThrow())) {
            report.add(translationFieldEntry(symbol, prefix + "return:", "return", "", locale))
        }
        if (let Some(comment) <- symbol.documentation) {
            let seen = HashSet<String>()
            for (text in comment.localizedTexts) {
                if (["summary", "param", "return"].contains(text.kind)) { continue }
                if (text.state == "unpaired") {
                    let originalComplete = text.language == Some(locale) && text.language == comment.defaultLanguage && !text.text.trimAscii().isEmpty()
                    report.add(TranslationCoverageEntry(symbol.id, "", text.kind, text.subject,
                        if (originalComplete) { "complete" } else { "unpaired" }, text.language, text.source))
                } else if (seen.add(text.fieldId)) {
                    report.add(translationFieldEntry(symbol, text.fieldId, text.kind, text.subject, locale))
                }
            }
        }
    }
    let pageIds = HashSet<String>()
    for (page in documentation.pages) {
        if (!pageIds.add(page.id)) { continue }
        var selected: ?DocumentationPage = None
        var original: ?DocumentationPage = None
        for (variant in documentation.pages where variant.id == page.id) {
            if (variant.language == Some(locale)) { selected = Some(variant) }
            if (variant.language == variant.defaultLanguage || variant.language.isNone()) { original = Some(variant) }
        }
        let chosen = if (selected.isSome()) { selected } else { original }
        var state = "missing"
        var actual: ?String = None
        if (let Some(value) <- chosen) {
            actual = value.language
            state = if (value.text.trimAscii().isEmpty()) { "empty" }
                else if (value.language.isNone()) { "unknown" }
                else if (selected.isSome()) { "complete" } else { "fallback" }
        }
        report.add(TranslationCoverageEntry("", "page:" + page.id, "page", page.id, state, actual, None<SourceRange>))
    }
    report
}

internal func appendTranslationCoverageArtifact(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    let languages = match (documentation.languageOptions) {
        case Some(options) => options.languages.toArray()
        case None => return
    }
    let out = RenderTextBuffer()
    out.append("{\"schemaVersion\":\"cjdoc.translation-coverage/1\",\"languages\":[")
    var first = true
    for (language in languages) {
        if (!first) { out.append(",") }; first = false
        let report = translationCoverageFor(documentation, language)
        out.append("{\"language\":${escapeJsonString(language)},\"total\":${report.total},\"translated\":${report.translated},\"percent\":${report.percent},")
        out.append("\"fallback\":${report.fallback},\"missing\":${report.missing},\"empty\":${report.empty},\"unknown\":${report.unknown},\"conflict\":${report.conflict},\"unpaired\":${report.unpaired},\"entries\":[")
        var firstEntry = true
        for (entry in report.entries) {
            if (!firstEntry) { out.append(",") }; firstEntry = false
            out.append("{\"symbolId\":${nullableString(entry.symbolId)},\"fieldId\":${escapeJsonString(entry.fieldId)},\"kind\":${escapeJsonString(entry.kind)},")
            out.append("\"subject\":${escapeJsonString(entry.subject)},\"state\":${escapeJsonString(entry.state)},\"actualLanguage\":${nullableString(entry.actualLanguage)}}")
        }
        out.append("]}")
    }
    out.append("]}\n")
    artifacts.addText("coverage/translations.json", "application/json", out.toString())
}
