protected package cjdoc.documentation.comments

import cjdoc.model.{DocumentationTitle, isDocumentationFieldId, isDocumentationMetadataTitle}
import cjdoc.source.SourceLocation
import std.collection.*

// Built once: aliases and fields are validated against this closed set, so the
// hot classifier path never rebuilds it.
private func buildCommentTagVocabulary(): HashSet<String> {
    let names = HashSet<String>()
    for (name in LOCALIZED_TAG_NAMES) { let _ = names.add(name) }
    // Admonition prompts share the tag position but not the localized list.
    for (name in ["note", "warning", "danger"]) { let _ = names.add(name) }
    names
}

private let COMMENT_TAG_VOCABULARY_SET: HashSet<String> = buildCommentTagVocabulary()

/** Every builtin tag spelling a project alias or field may not redefine. */
protected func isBuiltinCommentTagName(value: String): Bool {
    COMMENT_TAG_VOCABULARY_SET.contains(value)
}

/** One published field definition, independent of any declaration. */
protected class CommentFieldDefinition {
    protected let id: String
    protected let title: String
    private let titlesStorage: ArrayList<DocumentationTitle>
    protected let repeatable: Bool

    protected init(id: String, title: String, titles!: Array<DocumentationTitle> = [],
        repeatable!: Bool = false) {
        if (!isDocumentationFieldId(id)) {
            throw IllegalArgumentException("comment field id must match [a-z][a-z0-9-]{0,63}")
        }
        if (!isDocumentationMetadataTitle(title)) {
            throw IllegalArgumentException(
                "comment field title must be nonblank, single-line text of 1-256 UTF-8 bytes")
        }
        let languages = HashSet<String>()
        for (entry in titles) {
            if (!languages.add(entry.language)) {
                throw IllegalArgumentException("comment field title language must not be duplicated")
            }
        }
        this.id = id
        this.title = title
        this.titlesStorage = ArrayList<DocumentationTitle>(titles)
        this.repeatable = repeatable
    }

    protected prop titles: ReadOnlyList<DocumentationTitle> { get() { titlesStorage } }

    /** Title for one page language, falling back to the declared default title. */
    protected func titleFor(language: String): String {
        for (entry in titlesStorage) {
            if (entry.language == language) { return entry.title }
        }
        title
    }
}

/** One module rule over authored, explicitly tagged documentation. */
protected class CommentRule {
    protected let required: String
    protected let whenPresent: ?String
    protected let severity: String

    protected init(required: String, whenPresent: ?String, severity: String) {
        if (severity != "error" && severity != "warning") {
            throw IllegalArgumentException("comment rule severity must be error or warning")
        }
        this.required = required
        this.whenPresent = whenPresent
        this.severity = severity
    }
}

/**
 * One module's captured comment policy.
 *
 * Aliases resolve to the formal name once, at capture time; they are never
 * chained. The empty policy leaves the historical parser path untouched.
 */
protected class CommentSpec {
    private let aliasesStorage: HashMap<String, String>
    private let fieldIndex: HashMap<String, CommentFieldDefinition>
    private let orderedFields: ArrayList<CommentFieldDefinition>
    private let ruleList: ArrayList<CommentRule>
    private let requiredNames = HashSet<String>()

    protected init(aliases!: HashMap<String, String> = HashMap<String, String>(),
        fields!: Array<CommentFieldDefinition> = [], rules!: Array<CommentRule> = []) {
        this.aliasesStorage = aliases
        this.fieldIndex = HashMap<String, CommentFieldDefinition>()
        this.orderedFields = ArrayList<CommentFieldDefinition>(fields)
        this.ruleList = ArrayList<CommentRule>(rules)
        for (field in orderedFields) { fieldIndex[field.id] = field }
        for (rule in ruleList) { let _ = requiredNames.add(rule.required) }
    }

    protected func isEmpty(): Bool {
        aliasesStorage.isEmpty() && orderedFields.isEmpty() && ruleList.isEmpty()
    }

    /** Formal name for an authored spelling; names without an alias are unchanged. */
    protected func resolve(authored: String): String {
        match (aliasesStorage.get(authored)) {
            case Some(value) => value
            case None => authored
        }
    }

    protected func hasAlias(authored: String): Bool {
        aliasesStorage.contains(authored)
    }

    protected func field(id: String): ?CommentFieldDefinition {
        fieldIndex.get(id)
    }

    protected prop fields: ReadOnlyList<CommentFieldDefinition> { get() { orderedFields } }

    protected prop rules: ReadOnlyList<CommentRule> { get() { ruleList } }

    protected func requires(name: String): Bool { requiredNames.contains(name) }
}


/** A normalized, bounded custom field value with the line it was authored on. */
protected class DocFieldValue {
    protected let fieldId: String
    protected let value: String
    protected let authored: String
    protected let source: ?SourceLocation
    protected let order: Int64

    protected init(fieldId: String, value: String, authored: String,
        source: ?SourceLocation, order: Int64) {
        this.fieldId = fieldId
        this.value = value
        this.authored = authored
        this.source = source
        this.order = order
    }
}
