package cjdoc.render

import cjdoc.model.*
import cjdoc.render.agent.{DocumentationReadSnapshot, DocumentationReportAttachment, appendAgentReadableArtifacts,
    appendSymbolIndexArtifacts, buildDocumentationSearchProjection, reportAttachmentViews}
import cjdoc.render.foundation.ReportAttachmentView
import cjdoc.render.codec.{docIrFitsEncodedBudget, validateTypedDocumentationSet}
import cjdoc.render.foundation.{RenderArtifact, RenderArtifactCollector, RenderArtifactStore, RenderResourceLimitException}
import cjdoc.render.html.{HtmlFontOptions, RenderProjection, appendCapturedPageArtifacts, appendHtmlArtifacts,
    renderValidationHtml}
import cjdoc.render.markdown.site.appendMarkdownSiteArtifacts
import cjdoc.render.publication.projectDocumentationLanguage
import cjdoc.render.search.searchStaticProfileName
import std.collection.*

public class HtmlDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "html" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)
    }
}

internal func appendApiSurfaceArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet): Unit {
    let _ = artifacts.addText("api-surface/api-surface.json", "application/json",
        renderApiContractSnapshot(documentation))
}

internal func coveragePercent(documented: Int64, total: Int64): Int64 {
    if (total == 0) { 100 } else { documented * 100 / total }
}

public func documentationCoverageCounts(documentation: DocumentationSet):
    (Int64, Int64, Int64, Int64) {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    var symbols: Int64 = 0
    var documentedSymbols: Int64 = 0
    var parameters: Int64 = 0
    var documentedParameters: Int64 = 0
    for (symbol in projection.visibleSymbols) {
        symbols++
        if (symbol.documentation.isSome()) { documentedSymbols++ }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
            parameters++
            if (parameter.documentation.isSome()) { documentedParameters++ }
        }
    }
    (symbols, documentedSymbols, parameters, documentedParameters)
}

internal func appendCoverageArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet): Unit {
    let _ = artifacts.addText("coverage/coverage.json", "application/json",
        renderDocumentationCoverageV2(documentation))
    appendDocumentationQualityArtifact(artifacts, documentation)
    appendTranslationCoverageArtifact(artifacts, documentation)
}

public class ApiSurfaceDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "api-surface" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendApiSurfaceArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

public class DocumentationCoverageRenderer <: DocumentationRenderer {
    public prop format: String { get() { "coverage" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendCoverageArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

/**
 * Render every requested format into the caller's artifact store. This is the
 * single renderer chain: the public array entry points wrap it with an in-memory
 * collector, and the CLI hands it a rooted spool store.
 */
protected func renderDocumentationInto(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, formats: Array<String>,
    locale!: String = "zh-CN", docVersion!: ?String = None,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = [],
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()): Unit {
    if (allLanguages) {
        renderAllDocumentationLanguagesInto(artifacts, documentation, formats, docVersion,
            agentFull: agentFull, reports: reports, htmlFonts: htmlFonts)
        return
    }
    renderDocumentationLocaleInto(artifacts, documentation, formats, locale, docVersion,
        agentFull, reports, htmlFonts)
}

internal func renderDocumentationLocaleInto(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, formats: Array<String>, locale: String, docVersion: ?String,
    agentFull: Bool, reports: Array<DocumentationReportAttachment>, htmlFonts: HtmlFontOptions,
    mountedApi!: ?LanguageArtifactStore = None): Unit {
    if (locale != "zh-CN" && locale != "en") {
        throw IllegalArgumentException("locale must be zh-CN or en")
    }
    let localized = projectDocumentationLanguage(documentation, locale)
    if (!docIrFitsEncodedBudget(localized, DOC_IR_MAX_JSON_DOCUMENT_BYTES)) {
        throw RenderResourceLimitException(
            "selected documentation exceeds the existing Doc IR budget")
    }
    let htmlSnapshot: ?DocumentationReadSnapshot = if (formats.contains("html")) {
        Some(DocumentationReadSnapshot(localized, locale: Some(locale), version: docVersion))
    } else { None }
    // Search and Agent companions share one captured reader snapshot. HTML keeps
    // the source view: publication pruning removes asset and hidden-target context.
    let htmlProjection = htmlSnapshot.map({ snapshot =>
        RenderProjection(localized, snapshotId: snapshot.snapshotId, apiRoutes: snapshot.htmlRoutes(),
            unprefixedApiLocale: if (mountedApi.isSome()) { locale } else { "" })
    })
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => appendMarkdownSiteArtifacts(artifacts, localized, locale)
            case "html" => match (htmlSnapshot) {
                case Some(context) =>
                    let mountPage = mountedApi.map({ store => { file: String, content: String => store.addMountedApiPage(file, content) } })
                    appendHtmlArtifacts(artifacts, localized,
                        { => buildDocumentationSearchProjection(context, searchStaticProfileName()) },
                        htmlProjection.getOrThrow(),
                        locale: locale, docVersion: docVersion, htmlFonts: htmlFonts, mountPage: mountPage)
                case None => throw IllegalArgumentException(
                    "HTML rendering requires its captured reader snapshot")
            }
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" =>
                appendCoverageArtifacts(artifacts, documentation)
            case "symbol-index" => appendSymbolIndexArtifacts(artifacts, localized, version: docVersion)
            case _ => throw IllegalArgumentException(
                "unsupported documentation format '${format}'")
        }
    }
    let capturedFormats = ArrayList<String>()
    for (format in formats) {
        if (format == "html" || format == "markdown") {
            capturedFormats.add(format)
        }
    }
    if (!capturedFormats.isEmpty()) {
        appendCapturedPageArtifacts(artifacts, localized, capturedFormats.toArray(), locale, docVersion,
            htmlProjection)
    }
    if (formats.contains("html")) {
        // The evidence page and the machine manifest read one attachment model,
        // so a report the manifest lists is the report the page links.
        let attachmentViews = match (htmlSnapshot) {
            case Some(context) => reportAttachmentViews(context.snapshotId, reports)
            case None => Array<ReportAttachmentView>()
        }
        let _ = artifacts.addText("html/validation.html", "text/html; charset=utf-8",
            renderValidationHtml(localized, htmlProjection.getOrThrow(), docVersion, locale,
                reports: attachmentViews))
        // Machine companions are emitted at their original position, after the
        // validation page, through the same store instead of a second collector.
        match (htmlSnapshot) {
            case Some(context) => appendAgentReadableArtifacts(artifacts, context,
                includeFull: agentFull, version: docVersion, includeValidation: true,
                reports: reports)
            case None => ()
        }
    }
}

public func renderDocumentationFormatsWithOptions(documentation: DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", docVersion!: ?String = None,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = [],
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()):
    Array<RenderArtifact> {
    let collected = RenderArtifactCollector()
    renderDocumentationInto(collected, documentation, formats, locale: locale,
        docVersion: docVersion, allLanguages: allLanguages, agentFull: agentFull,
        reports: reports, htmlFonts: htmlFonts)
    collected.toArray()
}


/** Render all author variants through the same selection used by the CLI. */
public func renderDocumentationWithLanguageOptions(documentation: DocumentationSet,
    formats: Array<String>, options: LanguageRenderOptions): Array<RenderArtifact> {
    renderDocumentationFormatsWithOptions(documentation, formats,
        locale: options.locale, allLanguages: options.allLanguages)
}

public func rendererFor(format: String): DocumentationRenderer {
    match (format) {
        case "json" => JsonDocumentationRenderer()
        case "markdown" => MarkdownDocumentationRenderer()
        case "html" => HtmlDocumentationRenderer()
        case "api-surface" => ApiSurfaceDocumentationRenderer()
        case "coverage" => DocumentationCoverageRenderer()
        case "symbol-index" => SymbolIndexDocumentationRenderer()
        case _ => throw IllegalArgumentException("unsupported documentation format '${format}'")
    }
}
