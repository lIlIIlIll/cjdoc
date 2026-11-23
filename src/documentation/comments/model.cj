protected package cjdoc.documentation.comments

import cjdoc.source.SourceLocation
import std.collection.ArrayList

protected class DocTag {
    protected let name: String
    protected let subject: String
    protected var description: String
    protected var entryId: ?String
    protected var source: ?SourceLocation
    // Populated for @see tags by the declaration-index resolution pass.
    protected var referenceState: String = "unresolved"
    protected var targetSymbolId: ?String = None
    // Verbatim trailing `{...}` directive block for @example tags; empty when absent.
    protected var directives: String = ""

    protected init(name: String, subject: String, description: String,
        entryId!: ?String = None, source!: ?SourceLocation = None) {
        this.name = name
        this.subject = subject
        this.description = description
        this.entryId = entryId
        this.source = source
    }
}

protected class DocComment {
    protected let raw: String
    protected let summaryMarkdown: String
    protected let descriptionMarkdown: String
    protected let params = ArrayList<DocTag>()
    protected let examples = ArrayList<DocTag>()
    protected let admonitions = ArrayList<DocTag>()
    protected var returns: ?DocTag = None
    protected var returnTagCount: Int64 = 0
    protected let throwsTags = ArrayList<DocTag>()
    protected let see = ArrayList<DocTag>()
    protected let replacements = ArrayList<DocTag>()
    protected let contracts = ArrayList<DocTag>()
    protected var since: ?String = None
    protected var deprecated: ?String = None
    protected let authors = ArrayList<String>()
    protected var version: ?String = None
    protected var commentSource: ?SourceLocation = None
    protected var defaultLanguage: ?String = None
    protected var localizationScope: String = "all"
    protected let languageItems = ArrayList<LocalizedCommentItem>()

    protected init(raw: String, summaryMarkdown: String, descriptionMarkdown: String) {
        this.raw = raw
        this.summaryMarkdown = summaryMarkdown
        this.descriptionMarkdown = descriptionMarkdown
    }
}

protected class LocalizedCommentItem {
    protected let tag: DocTag
    protected let language: ?String
    protected let entryId: ?String
    protected var source: ?SourceLocation
    protected var state = "valid"
    protected var fieldId = ""
    // Recomputed from the owning input profile; not source/API identity or IR.
    protected var highlightEligible: Bool = true
    protected init(tag: DocTag, language: ?String, source: ?SourceLocation,
        entryId!: ?String = None) {
        this.tag = tag; this.language = language; this.source = source
        this.entryId = entryId
    }
}
