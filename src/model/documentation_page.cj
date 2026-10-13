package cjdoc.model

import std.collection.*

/** A captured explicit page association; it does not merge an API contract. */
public class DocumentationPageBinding {
    public let target: String
    public let selector: String
    public let provenance: String
    public let version: String
    public let sourceLine: Int64
    public let language: String
    public let state: String
    public let targetSymbolId: ?String
    public init(target: String, selector: String, provenance: String, version: String,
        sourceLine: Int64, language!: String = "markdown", state!: String = "unresolved",
        targetSymbolId!: ?String = None) {
        if (sourceLine < 1 || !["resolved", "unresolved", "ambiguous", "unavailable", "conflict"].contains(state) ||
            (state == "resolved") != targetSymbolId.isSome()) {
            throw IllegalArgumentException("invalid captured page binding")
        }
        this.target = target; this.selector = selector; this.provenance = provenance
        this.version = version; this.sourceLine = sourceLine; this.language = language
        this.state = state; this.targetSymbolId = targetSymbolId
    }
}

/** An explicit logical section mapping to a captured Markdown heading. */
public class DocumentationSection {
    public let id: String
    public let anchor: String
    public init(id: String, anchor: String) {
        if (id.isEmpty() || anchor.isEmpty() || id.contains("#") || anchor.contains("#")) {
            throw IllegalArgumentException("invalid documentation section mapping")
        }
        this.id = id; this.anchor = anchor
    }
}

/** A source-independent guide or overview variant. Id, never title, pairs pages. */
public class DocumentationPage {
    public let id: String
    public let language: ?String
    public let defaultLanguage: ?String
    public let source: String
    public let route: String
    public let title: String
    public let kind: String
    public let packageName: String
    public let text: String
    public let markdown: MarkdownNode
    private let sectionsStorage: ArrayList<DocumentationSection>
    private let targetsStorage: ArrayList<String>
    private let bindingsStorage: ArrayList<DocumentationPageBinding>
    public init(id: String, source: String, route: String, title: String, kind: String,
        text: String, markdown: MarkdownNode, language!: ?String = None,
        defaultLanguage!: ?String = None, packageName!: String = "",
        sections!: Array<DocumentationSection> = [], targetSymbolIds!: Array<String> = [],
        bindings!: Array<DocumentationPageBinding> = []) {
        if (id.isEmpty() || markdown.kind != "document" || !["project", "package", "module", "guide"].contains(kind)) {
            throw IllegalArgumentException("invalid documentation page")
        }
        for (value in [language, defaultLanguage]) {
            if (let Some(selected) <- value) {
                if (documentationLanguage(selected) != selected) { throw IllegalArgumentException("page language must be normalized") }
            }
        }
        let targets = HashSet<String>()
        for (target in targetSymbolIds) {
            if (!targets.add(target)) { throw IllegalArgumentException("duplicate documentation page target") }
        }
        this.id = id; this.source = source; this.route = route; this.title = title; this.kind = kind
        this.text = text; this.markdown = markdown; this.language = language; this.defaultLanguage = defaultLanguage
        this.packageName = packageName; this.sectionsStorage = ArrayList<DocumentationSection>(sections)
        this.targetsStorage = ArrayList<String>(targetSymbolIds)
        this.bindingsStorage = ArrayList<DocumentationPageBinding>(bindings)
    }
    public prop sections: ReadOnlyList<DocumentationSection> { get() { sectionsStorage } }
    public prop targetSymbolIds: ReadOnlyList<String> { get() { targetsStorage } }
    public prop bindings: ReadOnlyList<DocumentationPageBinding> { get() { bindingsStorage } }
}
