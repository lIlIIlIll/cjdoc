package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal let AGENT_NAVIGATION_LIMIT: Int64 = 16 * 1024 * 1024
internal let AGENT_LLMS_LIMIT: Int64 = 256 * 1024
internal let AGENT_FULL_LIMIT: Int64 = 16 * 1024 * 1024
internal let AGENT_FIELD_LIMIT: Int64 = 16 * 1024
internal let AGENT_CONCEPT_LIMIT: Int64 = 64 * 1024
internal let AGENT_LLMS_LIST_LIMIT: Int64 = 512

public class AgentConceptualPage {
    public let route: String
    public let title: String
    public let kind: String
    public let markdown: String

    public init(route: String, title: String, kind: String, markdown!: String = "") {
        this.route = route
        this.title = title
        this.kind = kind
        this.markdown = markdown
    }
}

internal class AgentNavigationPage {
    let id: String
    let kind: String
    let title: String
    let href: String
    let summary: ?String
    let symbolId: ?String
    let moduleId: ?String
    let packageName: ?String
    let semanticState: ?String

    init(id: String, kind: String, title: String, href: String,
        summary!: ?String = None, symbolId!: ?String = None,
        moduleId!: ?String = None, packageName!: ?String = None,
        semanticState!: ?String = None) {
        this.id = id
        this.kind = kind
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

private func agentTruncate(value: String, limit: Int64): String {
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

private func agentAppendLimited(out: RenderTextBuffer, value: String, limit: Int64): Unit {
    let remaining = limit - out.size
    if (remaining <= 0) { return }
    let selected = agentTruncate(value, remaining)
    if (!selected.isEmpty()) { out.append(selected) }
}

private func appendAgentJsonText(out: RenderTextBuffer, value: String,
    limit!: Int64 = AGENT_FIELD_LIMIT): Unit {
    appendSearchJsonString(out, agentTruncate(value, limit))
}

private func appendAgentJsonNullable(out: RenderTextBuffer, value: ?String,
    limit!: Int64 = AGENT_FIELD_LIMIT): Unit {
    match (value) {
        case Some(text) => appendAgentJsonText(out, text, limit: limit)
        case None => out.append("null")
    }
}

private func agentSymbolSummary(symbol: SymbolDoc): ?String {
    match (symbol.documentation) {
        case Some(comment) => Some(comment.summary)
        case None => None
    }
}

private func agentNavigationPages(documentation: DocumentationSet,
    conceptualPages: Array<AgentConceptualPage>): ArrayList<AgentNavigationPage> {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let pages = ArrayList<AgentNavigationPage>()
    pages.add(AgentNavigationPage("cjdoc:page:index", "project", documentation.project.name,
        "index.html"))
    pages.add(AgentNavigationPage("cjdoc:page:navigation-index", "machine",
        "Navigation index", "navigation-index.json"))
    pages.add(AgentNavigationPage("cjdoc:page:symbol-index", "machine",
        "Symbol index", "symbol-index.json"))
    pages.add(AgentNavigationPage("cjdoc:page:search-index", "machine",
        "Search index", "search-index.json"))
    for (page in conceptualPages) {
        pages.add(AgentNavigationPage("cjdoc:concept:${page.route}", "concept", page.title,
            page.route))
    }
    for (pkg in projection.packages) {
        let packageName = pkg.source.name
        pages.add(AgentNavigationPage("cjdoc:package:${pkg.source.moduleId}:${packageName}",
            "package", packageName, packagePagePath(pkg.source.moduleId, packageName),
            packageName: Some(packageName), moduleId: Some(pkg.source.moduleId)))
    }
    for (symbol in projection.visibleSymbols) {
        pages.add(AgentNavigationPage(symbol.id, "symbol", symbol.qualifiedName,
            symbolUrl(projection.visibleIndex, symbol), summary: agentSymbolSummary(symbol),
            symbolId: Some(symbol.id), moduleId: Some(symbol.moduleId),
            packageName: Some(symbol.packageName), semanticState: Some(symbol.semantic.state)))
    }
    sort(pages, lessThan: { left, right =>
        if (left.href == right.href) { left.id < right.id } else { left.href < right.href }
    }, stable: true)
    pages
}

private func agentJsonStringBound(value: String, limit: Int64): Int64 {
    let selected = agentTruncate(value, limit)
    2 + 6 * selected.size
}

private func agentJsonNullableBound(value: ?String): Int64 {
    match (value) {
        case Some(text) => agentJsonStringBound(text, AGENT_FIELD_LIMIT)
        case None => 4
    }
}

private func agentNavigationPageBound(page: AgentNavigationPage): Int64 {
    "{\"id\":".size + agentJsonStringBound(page.id, AGENT_FIELD_LIMIT) +
        ",\"kind\":".size + agentJsonStringBound(page.kind, AGENT_FIELD_LIMIT) +
        ",\"title\":".size + agentJsonStringBound(page.title, AGENT_FIELD_LIMIT) +
        ",\"href\":".size + agentJsonStringBound(page.href, AGENT_FIELD_LIMIT) +
        ",\"summary\":".size + agentJsonNullableBound(page.summary) +
        ",\"symbolId\":".size + agentJsonNullableBound(page.symbolId) +
        ",\"moduleId\":".size + agentJsonNullableBound(page.moduleId) +
        ",\"packageName\":".size + agentJsonNullableBound(page.packageName) +
        ",\"semanticState\":".size + agentJsonNullableBound(page.semanticState) +
        1
}

private func renderAgentNavigationIndex(documentation: DocumentationSet,
    pages: ArrayList<AgentNavigationPage>, version: ?String): String {
    let out = RenderTextBuffer(limit: AGENT_NAVIGATION_LIMIT)
    out.append("{\n  \"schemaVersion\":\"cjdoc.navigation-index/1\",\n  \"project\":{")
    out.append("\"name\":"); appendAgentJsonText(out, documentation.project.name)
    out.append(",\"audience\":"); appendAgentJsonText(out, documentation.configuration.audience)
    out.append(",\"version\":"); appendAgentJsonNullable(out, version)
    out.append("},\n  \"pages\":[")
    let closing = "\n  ]\n}\n"
    var first = true
    for (page in pages) {
        let separator = if (first) { "\n    " } else { ",\n    " }
        if (out.size + separator.size + agentNavigationPageBound(page) + closing.size >
            AGENT_NAVIGATION_LIMIT) { break }
        out.append(separator)
        out.append("{\"id\":"); appendAgentJsonText(out, page.id)
        out.append(",\"kind\":"); appendAgentJsonText(out, page.kind)
        out.append(",\"title\":"); appendAgentJsonText(out, page.title)
        out.append(",\"href\":"); appendAgentJsonText(out, page.href)
        out.append(",\"summary\":"); appendAgentJsonNullable(out, page.summary)
        out.append(",\"symbolId\":"); appendAgentJsonNullable(out, page.symbolId)
        out.append(",\"moduleId\":"); appendAgentJsonNullable(out, page.moduleId)
        out.append(",\"packageName\":"); appendAgentJsonNullable(out, page.packageName)
        out.append(",\"semanticState\":"); appendAgentJsonNullable(out, page.semanticState)
        out.append("}")
        first = false
    }
    out.append(closing)
    out.toString()
}

private func agentAppendLink(out: RenderTextBuffer, title: String, href: String): Unit {
    out.append("- [")
    agentAppendLimited(out, agentOneLine(title), AGENT_LLMS_LIMIT)
    out.append("](")
    agentAppendLimited(out, href, AGENT_LLMS_LIMIT)
    out.append(")\n")
}

private func renderAgentLlms(documentation: DocumentationSet,
    pages: ArrayList<AgentNavigationPage>, version: ?String): String {
    let out = RenderTextBuffer(limit: AGENT_LLMS_LIMIT)
    out.append("# "); agentAppendLimited(out, agentOneLine(documentation.project.name), AGENT_LLMS_LIMIT)
    out.append("\n\n")
    out.append("Generated by cjdoc. Audience: ")
    agentAppendLimited(out, documentation.configuration.audience, AGENT_LLMS_LIMIT)
    out.append(".\n")
    match (version) {
        case Some(value) => out.append("Version: "); agentAppendLimited(out, agentOneLine(value), AGENT_LLMS_LIMIT); out.append(".\n")
        case None => ()
    }
    out.append("\n## Start here\n\n")
    out.append("- [API reference](index.html)\n")
    out.append("- [Navigation index](navigation-index.json)\n")
    out.append("- [Symbol index](symbol-index.json)\n")
    out.append("- [Search index](search-index.json)\n")

    var conceptCount: Int64 = 0
    for (page in pages) {
        if (page.kind != "concept") { continue }
        if (conceptCount == 0) { out.append("\n## Concepts and guides\n\n") }
        if (conceptCount >= AGENT_LLMS_LIST_LIMIT) { continue }
        agentAppendLink(out, page.title, page.href)
        conceptCount++
    }
    if (conceptCount >= AGENT_LLMS_LIST_LIMIT) {
        out.append("- Additional conceptual pages are listed in navigation-index.json.\n")
    }

    var packageCount: Int64 = 0
    for (page in pages) {
        if (page.kind != "package") { continue }
        if (packageCount == 0) { out.append("\n## API packages\n\n") }
        if (packageCount >= AGENT_LLMS_LIST_LIMIT) { continue }
        agentAppendLink(out, page.title, page.href)
        packageCount++
    }
    if (packageCount >= AGENT_LLMS_LIST_LIMIT) {
        out.append("- Additional packages are listed in navigation-index.json.\n")
    }
    out.append("\nUse symbol-index.json to resolve a stable symbol id to its canonical HTML page; use navigation-index.json to enumerate all pages without parsing HTML.\n")
    out.toString()
}

private func agentAppendDocumentation(out: RenderTextBuffer, symbol: SymbolDoc): Unit {
    match (symbol.documentation) {
        case Some(comment) =>
            if (!comment.description.trimAscii().isEmpty()) {
                out.append("\n")
                agentAppendLimited(out, agentTruncate(comment.description, AGENT_CONCEPT_LIMIT), AGENT_FULL_LIMIT)
                out.append("\n")
            }
            for (tag in comment.tags) {
                if (tag.name != "return" && tag.name != "returns" && tag.name != "throws" &&
                    tag.name != "example" && tag.name != "deprecated" && tag.name != "since") {
                    continue
                }
                out.append("- @")
                agentAppendLimited(out, agentOneLine(tag.name), AGENT_FULL_LIMIT)
                if (!tag.subject.isEmpty()) {
                    out.append(" "); agentAppendLimited(out, agentOneLine(tag.subject), AGENT_FULL_LIMIT)
                }
                if (!tag.description.isEmpty()) {
                    out.append(": "); agentAppendLimited(out, agentOneLine(tag.description, limit: AGENT_CONCEPT_LIMIT), AGENT_FULL_LIMIT)
                }
                out.append("\n")
            }
        case None => ()
    }
}

private func renderAgentFull(documentation: DocumentationSet,
    conceptualPages: Array<AgentConceptualPage>, version: ?String): String {
    let out = RenderTextBuffer(limit: AGENT_FULL_LIMIT)
    out.append("# "); agentAppendLimited(out, agentOneLine(documentation.project.name), AGENT_FULL_LIMIT)
    out.append("\n\nAudience: "); agentAppendLimited(out, documentation.configuration.audience, AGENT_FULL_LIMIT)
    match (version) {
        case Some(value) => out.append("\nVersion: "); agentAppendLimited(out, agentOneLine(value), AGENT_FULL_LIMIT)
        case None => ()
    }
    out.append("\n\n")
    if (!conceptualPages.isEmpty()) {
        out.append("## Conceptual documentation\n\n")
        for (page in conceptualPages) {
            out.append("### "); agentAppendLimited(out, agentOneLine(page.title), AGENT_FULL_LIMIT)
            out.append("\n\nStable page: "); agentAppendLimited(out, page.route, AGENT_FULL_LIMIT)
            if (!page.markdown.trimAscii().isEmpty()) {
                out.append("\n\n")
                agentAppendLimited(out, agentTruncate(page.markdown, AGENT_CONCEPT_LIMIT), AGENT_FULL_LIMIT)
            }
            out.append("\n\n")
        }
    }

    let projection = RenderProjection(documentation)
    let symbols = ArrayList<SymbolDoc>(projection.visibleSymbols.toArray())
    sort(symbols, lessThan: { left, right => left.id < right.id }, stable: true)
    let packages = ArrayList<ProjectedPackage>(projection.packages.toArray())
    sort(packages, lessThan: { left, right => left.source.name < right.source.name }, stable: true)
    out.append("## API packages\n\n")
    for (pkg in packages) {
        out.append("### "); agentAppendLimited(out, agentOneLine(pkg.source.name), AGENT_FULL_LIMIT)
        out.append("\n\nStable page: ")
        agentAppendLimited(out, packagePagePath(pkg.source.moduleId, pkg.source.name), AGENT_FULL_LIMIT)
        out.append("\n\n")
    }
    out.append("## Public symbols\n\n")
    for (symbol in symbols) {
        out.append("### "); agentAppendLimited(out, agentOneLine(symbol.qualifiedName), AGENT_FULL_LIMIT)
        out.append("\n\nStable id: "); agentAppendLimited(out, symbol.id, AGENT_FULL_LIMIT)
        out.append("\nPage: "); agentAppendLimited(out, symbolUrl(projection.visibleIndex, symbol), AGENT_FULL_LIMIT)
        out.append("\nKind: "); agentAppendLimited(out, agentOneLine(symbol.kind), AGENT_FULL_LIMIT)
        out.append("\nSemantic state: "); agentAppendLimited(out, symbol.semantic.state, AGENT_FULL_LIMIT)
        if (!symbol.headerSpelling.trimAscii().isEmpty()) {
            out.append("\n\n```cj\n")
            agentAppendLimited(out, agentTruncate(symbol.headerSpelling, AGENT_FIELD_LIMIT), AGENT_FULL_LIMIT)
            out.append("\n```\n")
        }
        match (symbol.documentation) {
            case Some(comment) =>
                if (!comment.summary.trimAscii().isEmpty()) {
                    out.append("\nSummary: "); agentAppendLimited(out, agentOneLine(comment.summary), AGENT_FULL_LIMIT)
                    out.append("\n")
                }
            case None => ()
        }
        for (parameter in symbol.parameters) {
            out.append("- Parameter `"); agentAppendLimited(out, agentOneLine(parameter.name), AGENT_FULL_LIMIT)
            out.append("`: "); agentAppendLimited(out, agentOneLine(parameter.typeRef.spelling), AGENT_FULL_LIMIT)
            match (parameter.documentation) {
                case Some(text) =>
                    if (!text.trimAscii().isEmpty()) {
                        out.append(" — "); agentAppendLimited(out, agentOneLine(text, limit: AGENT_CONCEPT_LIMIT), AGENT_FULL_LIMIT)
                    }
                case None => ()
            }
            out.append("\n")
        }
        match (symbol.returnType) {
            case Some(returnType) =>
                out.append("Return: "); agentAppendLimited(out, agentOneLine(returnType.spelling), AGENT_FULL_LIMIT); out.append("\n")
            case None => ()
        }
        agentAppendDocumentation(out, symbol)
        out.append("\n")
    }
    out.toString()
}

public func renderAgentReadableArtifacts(documentation: DocumentationSet,
    conceptualPages!: Array<AgentConceptualPage> = [], includeFull!: Bool = false,
    version!: ?String = None): Array<RenderArtifact> {
    let pages = agentNavigationPages(documentation, conceptualPages)
    let artifacts = ArrayList<RenderArtifact>()
    artifacts.add(RenderArtifact("html/navigation-index.json", "application/json",
        renderAgentNavigationIndex(documentation, pages, version)))
    artifacts.add(RenderArtifact("html/llms.txt", "text/plain; charset=utf-8",
        renderAgentLlms(documentation, pages, version)))
    if (includeFull) {
        artifacts.add(RenderArtifact("html/llms-full.txt", "text/plain; charset=utf-8",
            renderAgentFull(documentation, conceptualPages, version)))
    }
    artifacts.toArray()
}
