package cjdoc.model

import std.collection.*
import std.sort.*

/** Normalize a supported documentation language without inferring aliases. */
public func documentationLanguage(value: String): String {
    let lowered = value.toAsciiLower()
    match (lowered) {
        case "en" => "en"
        case "zh-cn" => "zh-CN"
        case _ => throw IllegalArgumentException("unsupported documentation language '" + value + "'")
    }
}

/** Input language metadata and the independent publication set. */
public class DocumentationLanguageOptions {
    public let defaultLanguage: String
    public let missingTranslation: String
    private let languagesStorage: ArrayList<String>

    public init(defaultLanguage: String, languages!: Array<String> = [],
        missingTranslation!: String = "warn") {
        this.defaultLanguage = documentationLanguage(defaultLanguage)
        if (missingTranslation != "warn" && missingTranslation != "deny") {
            throw IllegalArgumentException("missing-translation must be warn or deny")
        }
        this.missingTranslation = missingTranslation
        this.languagesStorage = ArrayList<String>()
        let configured = if (languages.isEmpty()) { [this.defaultLanguage] } else { languages }
        if (configured.size > 2) { throw IllegalArgumentException("at most two publication languages are supported") }
        for (value in configured) {
            let language = documentationLanguage(value)
            if (languagesStorage.contains(language)) {
                throw IllegalArgumentException("duplicate publication language '" + language + "'")
            }
            languagesStorage.add(language)
        }
        sort(languagesStorage)
    }

    public prop languages: ReadOnlyList<String> { get() { languagesStorage } }
}

/** A renderer selects one language or all explicitly configured publications. */
public class LanguageRenderOptions {
    public let locale: String
    public let allLanguages: Bool

    public init(locale!: String = "zh-CN", allLanguages!: Bool = false) {
        this.locale = documentationLanguage(locale)
        this.allLanguages = allLanguages
    }
}

/**
 * One author-provided field, retaining its language and captured source.
 * Valid, empty and conflicting paired fields require a field identity.
 * Independent and invalid entries may retain an empty identity.
 */
public class DocumentationText {
    public let fieldId: String
    public let kind: String
    public let subject: String
    public let language: ?String
    public let text: String
    public let markdown: MarkdownNode
    public let source: ?SourceRange
    public let state: String
    public let referenceState: String
    public let targetSymbolId: ?String
    public let directives: String
    public let navigation: ?TypeNavigation

    public init(fieldId: String, kind: String, subject: String, language: ?String,
        text: String, markdown: MarkdownNode, source!: ?SourceRange = None,
        state!: String = "valid", referenceState!: String = "unavailable",
        targetSymbolId!: ?String = None, directives!: String = "", navigation!: ?TypeNavigation = None) {
        if (let Some(value) <- language) {
            if (documentationLanguage(value) != value) {
                throw IllegalArgumentException("documentation language must be normalized")
            }
        }
        if (markdown.kind != "document" || !["valid", "empty", "conflict", "unpaired", "invalid"].contains(state)) {
            throw IllegalArgumentException("invalid localized documentation field")
        }
        if (fieldId.isEmpty() && ["valid", "empty", "conflict"].contains(state)) {
            throw IllegalArgumentException("paired localized documentation requires a field identity")
        }
        if (!["summary", "description", "param", "return", "throws", "see", "deprecated", "example",
            "precondition", "postcondition", "invariant", "performance", "state", "concurrency", "platform", "compatibility", "error"].contains(kind)) {
            throw IllegalArgumentException("invalid localized documentation kind")
        }
        if (!isSemanticState(referenceState)) {
            throw IllegalArgumentException("invalid localized reference state")
        }
        if (referenceState == "resolved" && targetSymbolId.isNone()) {
            throw IllegalArgumentException("resolved localized reference requires a target")
        }
        if (["see", "throws"].contains(kind) && referenceState != "resolved" && targetSymbolId.isSome()) {
            throw IllegalArgumentException("unresolved localized reference cannot carry a target")
        }
        this.fieldId = fieldId; this.kind = kind; this.subject = subject
        this.language = language; this.text = text; this.markdown = markdown
        this.source = source; this.state = state; this.referenceState = referenceState
        this.targetSymbolId = targetSymbolId; this.directives = directives
        this.navigation = navigation
    }
}

/** Proof belongs to an authored origin and exact example, never its title. */
public func documentationExampleKey(symbolId: String, text: DocumentationText): String {
    let out = StringBuilder()
    for (value in [symbolId, text.language.getOrDefault({ => "unknown" }), text.text, text.directives]) {
        out.append(value.size.toString() + ":" + value)
    }
    if (let Some(source) <- text.source) {
        out.append(source.path + ":" + source.start.byteOffset.toString() + ":" + source.end.byteOffset.toString())
    }
    "example:" + contractFingerprint(out.toString())
}
