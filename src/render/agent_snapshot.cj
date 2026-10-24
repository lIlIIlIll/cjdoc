package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func publicationForReading(documentation: DocumentationSet, locale: String,
    audience: ?String): DocumentationSet {
    let selected = if (documentation.readingLanguage.getOrDefault({ => "" }) == locale) {
        documentation
    } else {
        projectDocumentationLanguage(documentation, locale)
    }
    projectPublicationDocumentation(selected, audience: audience)
}

private func readSnapshotContentId(encoded: String, revision: String): String {
    let configuration = "\n{\"projection\":\"cjdoc.read/1\",\"publicationRevision\":" + escapeJsonString(revision) + "}"
    "cjdoc:snapshot:v1:" + contractFingerprint(encoded + configuration)
}

/**
 * An immutable, audience-safe reading projection of captured documentation.
 *
 * Construction validates captured data; it never scans source, selects an SDK,
 * downloads dependencies or executes examples. The content identity is not
 * publisher authentication or proof of a consumer compilation.
 */
public class DocumentationReadSnapshot {
    protected let documentation: DocumentationSet
    public let locale: String
    public let snapshotId: String
    public let encodedDocumentation: String
    public let publicationRevision: String
    internal let projection: RenderProjection
    internal let identity: SymbolInventoryIdentity
    internal let modulesById = HashMap<String, ModuleDoc>()
    private let markdown: DeclarationMarkdownProjection
    private let pageMarkdown: AgentPageMarkdownProjection
    private let dependencyStates: HashMap<String, (?DependencyInstance, String)>

    public init(documentation: DocumentationSet, locale!: ?String = None,
        audience!: ?String = None, version!: ?String = None) {
        if (version == Some("")) { throw IllegalArgumentException("publication revision must not be empty when specified") }
        this.locale = locale.getOrDefault({ => documentation.readingLanguage.getOrDefault({ => "en" }) })
        this.publicationRevision = version.getOrDefault({ => documentation.documentationRevision })
        this.documentation = publicationForReading(documentation, this.locale, audience)
        for (module in this.documentation.modules) { modulesById[module.id] = module }
        dependencyStates = capturedDependencyProjection(this.documentation)
        projection = RenderProjection(this.documentation)
        identity = SymbolInventoryIdentity(this.documentation, publicationRevision: Some(publicationRevision))
        encodedDocumentation = encodeDocIr(this.documentation)
        snapshotId = readSnapshotContentId(encodedDocumentation, publicationRevision)
        markdown = DeclarationMarkdownProjection(this.documentation, projection, this.locale)
        pageMarkdown = AgentPageMarkdownProjection(this.documentation, projection, this.locale)
    }

    /** Return a detached model; caller diagnostics cannot mutate this frozen snapshot. */
    public func readDocumentation(): DocumentationSet {
        decodeDocIr(encodedDocumentation)
    }

    /** Reuse captured inventory identity; absent modules have no synthesized identity. */
    public func documentSetForModule(moduleId: String): ?DocumentSetIdentity {
        identity.byModule.get(moduleId)
    }

    protected func moduleFor(moduleId: String): ?ModuleDoc {
        modulesById.get(moduleId)
    }

    protected func moduleDependencyState(moduleId: String): (?DependencyInstance, String) {
        dependencyStates.get(moduleId).getOrDefault({ => (Option<DependencyInstance>.None, "unrecorded") })
    }

    /** Versioned inventory whose links use the containing publication's document root. */
    public func renderSymbolInventory(): String {
        renderSymbolIndex(documentation, hrefPrefix: "",
            version: if (publicationRevision.isEmpty()) { None } else { Some(publicationRevision) })
    }

    /** Trusted projection access; mutable Markdown metadata must not escape the snapshot. */
    protected func selectedPages(): Array<DocumentationPage> {
        pageMarkdown.pages
    }

    /** Render a captured page through the same Markdown AST and binding routes. */
    public func renderPageMarkdown(pageId: String, pagePath!: String = "llms-full.txt"): ?String {
        validateRenderArtifactPath(pagePath)
        for (page in pageMarkdown.pages where page.id == pageId) {
            return Some(pageMarkdown.render(page, pagePath))
        }
        None
    }

    /** Find only a declaration included in the captured audience/cfg boundary. */
    internal func findDeclaration(symbolId: String): ?SymbolDoc {
        projection.visibleIndex.get(symbolId)
    }

    /** Render intact selected chapters with links relative to an actual artifact path. */
    public func renderDeclarationMarkdown(symbolId: String,
        pagePath!: String = "llms-full.txt", sections!: Array<String> = []): ?String {
        validateRenderArtifactPath(pagePath)
        match (findDeclaration(symbolId)) {
            case Some(symbol) => Some(markdown.renderSelected(symbol, pagePath, sections))
            case None => None
        }
    }

    /** Render one semantic chapter directly, without parsing generated Markdown. */
    protected func renderDeclarationChapter(symbolId: String, section: String,
        pagePath!: String = "llms-full.txt"): ?String {
        validateRenderArtifactPath(pagePath)
        match (findDeclaration(symbolId)) {
            case Some(symbol) => Some(markdown.renderSection(symbol, pagePath, section))
            case None => None
        }
    }

    /** Read the complete versioned structured declaration, without field clipping. */
    public func renderDeclarationJson(symbolId: String): ?String {
        match (findDeclaration(symbolId)) {
            case Some(symbol) => Some(renderAgentDeclarationJson(this, symbol))
            case None => None
        }
    }
}

/** Return content identity for the same selected publication projection as reading. */
public func documentationSnapshotId(documentation: DocumentationSet, locale!: ?String = None,
    audience!: ?String = None, version!: ?String = None): String {
    if (version == Some("")) { throw IllegalArgumentException("publication revision must not be empty when specified") }
    let selectedLocale = locale.getOrDefault({ => documentation.readingLanguage.getOrDefault({ => "en" }) })
    let selected = publicationForReading(documentation, selectedLocale, audience)
    readSnapshotContentId(encodeDocIr(selected), version.getOrDefault({ => documentation.documentationRevision }))
}
