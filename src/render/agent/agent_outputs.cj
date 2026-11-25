protected package cjdoc.render.agent

import cjdoc.render.foundation.RenderArtifact
import cjdoc.render.routes.selectedDocumentationPages
import cjdoc.render.foundation.{RenderArtifactCollector, RenderTextBuffer, RenderArtifactStore}
import cjdoc.model.*
import std.collection.*
import std.sort.*

internal let AGENT_NAVIGATION_LIMIT: Int64 = 16 * 1024 * 1024
internal let AGENT_LLMS_LIMIT: Int64 = 256 * 1024
internal let AGENT_FULL_LIMIT: Int64 = 16 * 1024 * 1024
internal let AGENT_FIELD_LIMIT: Int64 = 16 * 1024
internal let AGENT_LLMS_LIST_LIMIT: Int64 = 512


internal class AgentNavigationPage {
    let id: String
    let kind: String
    // Where the page came from: a captured concept page, a generated API
    // package, the project index, or a machine/validation companion. `kind`
    // keeps its published navigation-index meaning; `source` keeps discovery
    // categories apart when two origins reuse one kind name.
    let source: String
    let title: String
    let href: String
    let summary: ?String
    let symbolId: ?String
    let moduleId: ?String
    let packageName: ?String
    let semanticState: ?String

    init(id: String, kind: String, title: String, href: String, source!: String,
        summary!: ?String = None, symbolId!: ?String = None,
        moduleId!: ?String = None, packageName!: ?String = None,
        semanticState!: ?String = None) {
        this.id = id
        this.kind = kind
        this.source = source
        this.title = title
        this.href = href
        this.summary = summary
        this.symbolId = symbolId
        this.moduleId = moduleId
        this.packageName = packageName
        this.semanticState = semanticState
    }
}

private func agentRuneWidth(rune: Rune): Int64 {
    let code = UInt32(rune)
    if (code <= 0x7Fu32) { 1 } else if (code <= 0x7FFu32) { 2 }
    else if (code <= 0xFFFFu32) { 3 } else { 4 }
}

internal func agentTruncate(value: String, limit: Int64): String {
    if (limit <= 0) { return "" }
    if (value.size <= limit) { return value }
    let contentLimit = if (limit > 3) { limit - 3 } else { limit }
    let out = StringBuilder()
    var written: Int64 = 0
    for (rune in value.runes()) {
        let width = agentRuneWidth(rune)
        if (written > contentLimit - width) { break }
        out.append(rune)
        written += width
    }
    if (limit > 3) { out.append("...") }
    out.toString()
}

private func agentOneLine(value: String, limit!: Int64 = AGENT_FIELD_LIMIT): String {
    agentTruncate(value.replace("\r", " ").replace("\n", " ").replace("\t", " ").trimAscii(), limit)
}

private func agentAppendLimited(out: RenderTextBuffer, value: String, limit: Int64,
    reserve!: Int64 = 0): Unit {
    let remaining = limit - out.size - reserve
    if (remaining <= 0) { return }
    let selected = agentTruncate(value, remaining)
    if (!selected.isEmpty()) { out.append(selected) }
}

private func agentAppendFixed(out: RenderTextBuffer, value: String, limit: Int64): Bool {
    if (value.size > limit - out.size) { return false }
    out.append(value)
    true
}


private func agentSymbolSummary(symbol: SymbolDoc): ?String {
    match (symbol.documentation) {
        case Some(comment) => Some(comment.summary)
        case None => None
    }
}

internal func agentNavigationPages(context: DocumentationReadSnapshot,
    conceptualPages: Array<DocumentationPage>, includeValidation: Bool): ArrayList<AgentNavigationPage> {
    let documentation = context.documentation
    let projection = context.projection
    let pages = ArrayList<AgentNavigationPage>()
    pages.add(AgentNavigationPage("cjdoc:page:index", "project", documentation.project.name,
        "index.html", source: "project"))
    pages.add(AgentNavigationPage("cjdoc:page:navigation-index", "machine",
        "Navigation index", "navigation-index.json", source: "machine"))
    pages.add(AgentNavigationPage("cjdoc:page:symbol-index", "machine",
        "Symbol index", "symbol-index.json", source: "machine"))
    pages.add(AgentNavigationPage("cjdoc:page:search-index", "machine",
        "Search index", "search-index.json", source: "machine"))
    if (includeValidation) {
        pages.add(AgentNavigationPage("cjdoc:page:validation", "validation",
            "Validation results", "validation.html", source: "validation"))
    }
    // Captured pages keep their own kind (project/module/package/guide) and are
    // never counted as generated API packages, which share the `package` kind.
    for (page in conceptualPages) {
        pages.add(AgentNavigationPage("cjdoc:concept:${page.route}", page.kind, page.title,
            page.route, source: "concept"))
    }
    for (pkg in projection.packages) {
        let packageName = pkg.source.name
        pages.add(AgentNavigationPage("cjdoc:package:${pkg.source.moduleId}:${packageName}",
            "package", packageName, projection.packageFile(pkg.source.moduleId, packageName),
            source: "api-package", packageName: Some(packageName),
            moduleId: Some(pkg.source.moduleId)))
    }
    let routes = projection.apiRoutes.getOrThrow()
    for (symbol in projection.visibleSymbols) {
        pages.add(AgentNavigationPage(symbol.id, "symbol", symbol.qualifiedName,
            routes.filePath(symbol.id).getOrThrow(), source: "symbol",
            summary: agentSymbolSummary(symbol),
            symbolId: Some(symbol.id), moduleId: Some(symbol.moduleId),
            packageName: Some(symbol.packageName), semanticState: Some(symbol.semantic.state)))
    }
    sort(pages, lessThan: { left, right =>
        if (left.href == right.href) { left.id < right.id } else { left.href < right.href }
    }, stable: true)
    pages
}


private func agentMarkdownLabel(value: String): String {
    agentOneLine(value).replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]")
}

private func agentMarkdownDestination(value: String): String {
    let selected = value
    let safe = selected.replace("\\", "%5C").replace("<", "%3C").replace(">", "%3E")
    "<${safe}>"
}
private func agentLinkText(title: String, href: String): String {
    "- [${agentMarkdownLabel(title)}](${agentMarkdownDestination(href)})\n"
}

// Discovery groups follow the captured page kind. The fallback exists so a
// future authored kind is still listed instead of vanishing from llms.txt.
private func agentLlmsGroupLabel(kind: String): String {
    match (kind) {
        case "project" => "Project overview"
        case "module" => "Modules"
        case "package" => "Package overviews"
        case "guide" => "Guides"
        case _ => "Other conceptual pages"
    }
}

internal func renderAgentLlms(context: DocumentationReadSnapshot,
    pages: ArrayList<AgentNavigationPage>, version: ?String, includeFull: Bool): String {
    let documentation = context.documentation
    let out = RenderTextBuffer(limit: AGENT_LLMS_LIMIT)
    if (!agentAppendFixed(out, "# ", AGENT_LLMS_LIMIT)) { return out.toString() }
    agentAppendLimited(out, agentOneLine(documentation.project.name), AGENT_LLMS_LIMIT, reserve: 2)
    if (!agentAppendFixed(out, "\n\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    if (!agentAppendFixed(out, "Generated by cjdoc. Audience: ", AGENT_LLMS_LIMIT)) {
        return out.toString()
    }
    agentAppendLimited(out, documentation.configuration.audience, AGENT_LLMS_LIMIT, reserve: 2)
    if (!agentAppendFixed(out, ".\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    match (version) {
        case Some(value) =>
            if (!agentAppendFixed(out, "Version: ", AGENT_LLMS_LIMIT)) { return out.toString() }
            agentAppendLimited(out, agentOneLine(value), AGENT_LLMS_LIMIT, reserve: 2)
            if (!agentAppendFixed(out, ".\n", AGENT_LLMS_LIMIT)) { return out.toString() }
        case None => ()
    }
    if (!agentAppendFixed(out, "\n## Start here\n\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    if (!agentAppendFixed(out, "- [API reference](index.html)\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    if (!agentAppendFixed(out, "- [Navigation index](navigation-index.json)\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    if (!agentAppendFixed(out, "- [Symbol index](symbol-index.json)\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    if (!agentAppendFixed(out, "- [Search index](search-index.json)\n", AGENT_LLMS_LIMIT)) { return out.toString() }
    out.append("- [Machine manifest and independent declarations](agent/manifest.json)\n")
    out.append("\nThis is a selected directory, not a complete enumeration. Follow navigation-index.json and its actual continuation files. Snapshot: " +
        context.snapshotId + ".\n")
    if (includeFull) {
        out.append("- [Full reference and continuation](llms-full.txt)\n")
        out.append("- [Full reference part manifest](agent-full-index.json)\n")
    }

    // Captured pages are classified by their own kind; generated API packages
    // are a separate origin even though navigation gives both the kind
    // `package`. A shared list would put a conceptual overview among the API
    // surface it merely describes.
    var conceptCount: Int64 = 0
    var conceptsStarted = false
    var conceptsTruncated = false
    for (groupLabel in ["Project overview", "Modules", "Package overviews", "Guides",
        "Other conceptual pages"]) {
        if (conceptsTruncated) { break }
        var groupCount: Int64 = 0
        for (page in pages where page.source == "concept" &&
            agentLlmsGroupLabel(page.kind) == groupLabel) {
            if (conceptCount >= AGENT_LLMS_LIST_LIMIT) {
                conceptsTruncated = true
                break
            }
            let link = agentLinkText(page.title, page.href)
            let sectionHeading = if (!conceptsStarted) { "\n## Concepts and guides\n\n" } else { "" }
            let groupHeading = if (groupCount == 0) {
                sectionHeading + "### " + groupLabel + "\n\n"
            } else { "" }
            if (groupHeading.size + link.size > AGENT_LLMS_LIMIT - out.size) {
                conceptsTruncated = true
                break
            }
            out.append(groupHeading)
            if (!agentAppendFixed(out, link, AGENT_LLMS_LIMIT)) {
                conceptsTruncated = true
                break
            }
            conceptsStarted = true
            conceptCount++
            groupCount++
        }
    }
    // Only reports a continuation when a page actually stayed unlisted.
    if (conceptsTruncated) {
        if (!agentAppendFixed(out,
            "- Additional conceptual pages are listed in navigation-index.json and its continuation parts.\n",
            AGENT_LLMS_LIMIT)) { return out.toString() }
    }
    var packageCount: Int64 = 0
    for (page in pages where page.source == "api-package") {
        if (packageCount >= AGENT_LLMS_LIST_LIMIT) { continue }
        let link = agentLinkText(page.title, page.href)
        if (packageCount == 0) {
            let heading = "\n## API packages\n\n"
            if (heading.size + link.size > AGENT_LLMS_LIMIT - out.size) { break }
            out.append(heading)
        }
        if (!agentAppendFixed(out, link, AGENT_LLMS_LIMIT)) { break }
        packageCount++
    }
    if (packageCount >= AGENT_LLMS_LIST_LIMIT) {
        if (!agentAppendFixed(out, "- Additional packages are listed in navigation-index.json.\n",
            AGENT_LLMS_LIMIT)) { return out.toString() }
    }
    if (!agentAppendFixed(out,
        "\nUse symbol-index.json to resolve a stable symbol id to its canonical HTML page; use navigation-index.json to enumerate all pages without parsing HTML.\n",
        AGENT_LLMS_LIMIT)) { return out.toString() }
    out.toString()
}

/**
 * Render the machine-readable companions deployed inside an HTML document root.
 * Independent declarations and continuations are actual bounded artifacts;
 * callers publishing these companions also publish the corresponding HTML site.
 */
public func renderAgentReadableArtifacts(documentation: DocumentationSet,
    includeFull!: Bool = false, version!: ?String = None,
    includeValidation!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = []): Array<RenderArtifact> {
    let context = DocumentationReadSnapshot(documentation, version: version)
    let artifacts = RenderArtifactCollector()
    appendAgentReadableArtifacts(artifacts, context, includeFull: includeFull,
        version: version, includeValidation: includeValidation, reports: reports)
    artifacts.toArray()
}

protected func appendAgentReadableArtifacts(artifacts: RenderArtifactStore,
    context: DocumentationReadSnapshot, includeFull!: Bool = false,
    version!: ?String = None, includeValidation!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = []): Unit {
    let concepts = selectedDocumentationPages(context.documentation, context.locale)
    let pages = agentNavigationPages(context, concepts, includeValidation)
    appendAgentNavigationArtifacts(artifacts, context, pages, version,
        includeValidation: includeValidation)
    appendAgentDeclarationArtifacts(artifacts, context, includeFull: includeFull, reports: reports)
    let _ = artifacts.addText("html/llms.txt", "text/plain; charset=utf-8",
        renderAgentLlms(context, pages, version, includeFull))
    if (includeFull) { appendAgentFullArtifacts(artifacts, context, concepts) }
}
