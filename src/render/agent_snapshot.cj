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

internal let CJDOC_READ_PROJECTION = "cjdoc.read/2"
private let LEGACY_READ_PROJECTION = "cjdoc.read/1"

private func readSnapshotContentId(encoded: String, revision: String, readProjection: String): String {
    let configuration = "\n{\"projection\":" + escapeJsonString(readProjection) +
        ",\"publicationRevision\":" + escapeJsonString(revision) + "}"
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
        this(documentation, locale, audience, version, CJDOC_READ_PROJECTION)
    }

    protected static func readPackaged(documentation: DocumentationSet, version: ?String,
        readProjection: String): DocumentationReadSnapshot {
        if (readProjection != LEGACY_READ_PROJECTION && readProjection != CJDOC_READ_PROJECTION) {
            throw IllegalArgumentException("unsupported documentation reading projection")
        }
        DocumentationReadSnapshot(documentation, None, None, version, readProjection)
    }

    private init(documentation: DocumentationSet, locale: ?String, audience: ?String,
        version: ?String, readProjection: String) {
        if (version == Some("")) { throw IllegalArgumentException("publication revision must not be empty when specified") }
        this.locale = locale.getOrDefault({ => documentation.readingLanguage.getOrDefault({ => "en" }) })
        this.publicationRevision = version.getOrDefault({ => documentation.documentationRevision })
        this.documentation = publicationForReading(documentation, this.locale, audience)
        for (module in this.documentation.modules) { modulesById[module.id] = module }
        dependencyStates = capturedDependencyProjection(this.documentation)
        identity = SymbolInventoryIdentity(this.documentation, publicationRevision: Some(publicationRevision))
        encodedDocumentation = encodeDocIr(this.documentation)
        snapshotId = readSnapshotContentId(encodedDocumentation, publicationRevision, readProjection)
        projection = RenderProjection(this.documentation, snapshotId: snapshotId, buildApiRoutes: true,
            legacyApiRoutes: readProjection == LEGACY_READ_PROJECTION)
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

    /** Resolve captured file evidence without consulting source files or receipts. */
    public func sourceReference(moduleId: String, range: SourceRange): SourceReference {
        projection.sourceReferences.project(moduleId, range)
    }

    /** The published HTML file for a declaration in this snapshot's audience. */
    public func symbolHtmlPath(symbolId: String): ?String {
        projection.apiRoutes.getOrThrow().filePath(symbolId)
    }

    protected func moduleFor(moduleId: String): ?ModuleDoc {
        modulesById.get(moduleId)
    }

    protected func moduleDependencyState(moduleId: String): (?DependencyInstance, String) {
        dependencyStates.get(moduleId).getOrDefault({ => (Option<DependencyInstance>.None, "unrecorded") })
    }

    /**
     * Versioned inventory whose links use the containing publication's document root.
     *
     * The snapshot already holds one projection of this model and proved its
     * typed validity by encoding it at construction, so the inventory is
     * serialized without building a second index or re-decoding a temporary
     * copy of the whole document.
     */
    public func renderSymbolInventory(): String {
        renderSymbolIndexProjected(documentation, projection, hrefPrefix: "",
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
    readSnapshotContentId(encodeDocIr(selected), version.getOrDefault({ => documentation.documentationRevision }),
        CJDOC_READ_PROJECTION)
}
