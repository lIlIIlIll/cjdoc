package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal class AgentPageMarkdownProjection {
    let pages: Array<DocumentationPage>
    private let documentation: DocumentationSet
    private let locale: String
    private let assets: ArrayList<AssetDoc>
    private let rootAssets: HashMap<String, String>
    private let nestedAssets: HashMap<String, String>
    private let symbolIndex: HashMap<String, SymbolDoc>

    init(documentation: DocumentationSet, projection: RenderProjection, locale: String) {
        this.documentation = documentation
        this.locale = locale
        symbolIndex = projection.visibleIndex
        pages = selectedDocumentationPages(documentation, locale)
        assets = projectAssets(documentation, projection, pages: pages)
        rootAssets = buildAssetLookup(assets)
        nestedAssets = buildAssetLookup(assets, prefix: "../../")
    }

    func render(page: DocumentationPage, outputPath: String): String {
        let prefix = pageRootPrefix(outputPath)
        let lookup = if (prefix.isEmpty()) { rootAssets } else if (prefix == "../../") { nestedAssets }
            else { buildAssetLookup(assets, prefix: prefix) }
        let links = capturedPageSourceLinks(documentation, page, pages, outputPath: Some(outputPath))
        let (tree, _) = capturedPageMarkdownWithoutMarkers(page.markdown, page)
        let out = RenderTextBuffer()
        appendMarkdownNodeMarkdown(out, tree.getOrThrow(), lookup, 1, pagePath: outputPath,
            symbolIndex: Some(symbolIndex), canonicalHtml: true, capturedLinks: Some(links))
        appendCapturedPageBindingsMarkdown(out, page, documentation, locale,
            pagePath: Some(outputPath), canonicalHtml: true)
        out.append("\n\n" + label(locale, "Content language: ", "内容语言：") +
            page.language.getOrDefault({ => "unknown" }) + "\n")
        out.toString()
    }
}

private func agentPageEnvelope(context: DocumentationReadSnapshot, id: String, kind: String,
    moduleId: ?String, html: String, markdownPath: String, jsonPath: String,
    markdown: String, pageJson!: String = "null", packageJson!: String = "null"): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.page/1\",\"id\":${escapeJsonString(id)},\"kind\":${escapeJsonString(kind)},\"scope\":")
    appendAgentReadingScope(out, context, moduleId)
    out.append(",\"page\":${pageJson},\"package\":${packageJson},\"representations\":{\"pathBase\":\"document-root\"," +
        "\"html\":${escapeJsonString(html)},\"markdown\":${escapeJsonString(markdownPath)},\"json\":${escapeJsonString(jsonPath)}}," +
        "\"markdown\":${escapeJsonString(markdown)}}\n")
    out.toString()
}

private func agentPackageMarkdown(context: DocumentationReadSnapshot, pkg: PackageDoc): String {
    let out = RenderTextBuffer()
    out.append("# Package ")
    appendEscapedMarkdownText(out, pkg.name)
    out.append("\n\nSnapshot: " + context.snapshotId + "\n\nThis is a declaration directory; each linked declaration is independently readable.\n\n")
    for (symbol in context.projection.visibleSymbols where symbol.moduleId == pkg.moduleId && symbol.packageName == pkg.name) {
        out.append("- [")
        appendEscapedMarkdownText(out, symbol.qualifiedName)
        out.append("](" + encodeMarkdownDestination("../../" + symbolPagePath(symbol)) + ") — [Markdown](" +
            encodeMarkdownDestination("../../" + agentDeclarationMarkdownPath(symbol)) + ")\n")
    }
    out.toString()
}

internal func appendAgentPageArtifacts(artifacts: RenderArtifactCollector,
    context: DocumentationReadSnapshot): Unit {
    for (page in context.selectedPages()) {
        let markdownPath = agentPageMarkdownPath(page)
        let jsonPath = agentPageJsonPath(page)
        let markdown = context.renderPageMarkdown(page.id, pagePath: markdownPath).getOrThrow()
        let raw = StringBuilder()
        appendDocumentationPages(raw, ArrayList<DocumentationPage>([page]))
        let array = raw.toString()
        artifacts.addText("html/" + markdownPath, "text/markdown; charset=utf-8", markdown)
        artifacts.addText("html/" + jsonPath, "application/json",
            agentPageEnvelope(context, page.id, "concept", None, page.route, markdownPath, jsonPath,
                markdown, pageJson: array[1..array.size - 1]))
    }
    for (pkg in context.projection.packages) {
        let source = pkg.source
        let id = "cjdoc:package:${source.moduleId}:${source.name}"
        let markdownPath = agentPackageMarkdownPath(source.moduleId, source.name)
        let jsonPath = agentPackageJsonPath(source.moduleId, source.name)
        let markdown = agentPackageMarkdown(context, source)
        let raw = StringBuilder()
        appendPackage(raw, source)
        artifacts.addText("html/" + markdownPath, "text/markdown; charset=utf-8", markdown)
        artifacts.addText("html/" + jsonPath, "application/json",
            agentPageEnvelope(context, id, "package", Some(source.moduleId), packagePagePath(source.moduleId, source.name),
                markdownPath, jsonPath, markdown, packageJson: raw.toString()))
    }
    let markdown = "# " + context.documentation.project.name + "\n\nSnapshot: " + context.snapshotId +
        "\n\n- [API reference](../../index.html)\n- [Navigation and continuation](../../navigation-index.json)\n" +
        "- [Representations and machine data](../manifest.json)\n"
    artifacts.addText("html/agent/pages/index.md", "text/markdown; charset=utf-8", markdown)
    artifacts.addText("html/agent/pages/index.json", "application/json",
        agentPageEnvelope(context, "cjdoc:page:index", "project", None, "index.html",
            "agent/pages/index.md", "agent/pages/index.json", markdown))
}
