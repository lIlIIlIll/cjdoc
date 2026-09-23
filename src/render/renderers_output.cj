package cjdoc.render

import cjdoc.model.*
import std.collection.*

public class HtmlDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "html" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendHtmlArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}

internal func appendHtmlArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, locale!: String = "en", docVersion!: ?String = None): Unit {
        validateTypedDocumentationSet(documentation)
        let projection = RenderProjection(documentation)
        let index = projection.visibleIndex
        let typeLinkIndex = HtmlTypeLinkIndex(documentation, projection)
        let projectedAssets = projectAssets(documentation, projection)
        let assetLookup = buildAssetLookup(projectedAssets)
        validateHtmlRouting(projection, projectedAssets)
        let topLevelByPackage = groupTopLevelByPackage(projection)
        let membersByOwner = groupMembersByOwner(projection)
        let searchIndex = renderSearchIndex(documentation, projection)
        artifacts.addText("html/index.html", "text/html; charset=utf-8",
            renderHtmlIndex(documentation, projection, locale: locale, docVersion: docVersion))
        artifacts.addText("html/search-index.json", "application/json", searchIndex)
        artifacts.addText("html/symbol-index.json", "application/json",
            renderSymbolIndex(documentation, hrefPrefix: "", version: docVersion))
        artifacts.addText("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex))
        artifacts.addText("html/theme-bootstrap.js", "text/javascript; charset=utf-8", HTML_THEME_BOOTSTRAP_SCRIPT)
        artifacts.addText("html/search.js", "text/javascript; charset=utf-8", HTML_SEARCH_SCRIPT)
        artifacts.addText("html/style.css", "text/css; charset=utf-8",
            HTML_STYLE + HTML_RETURN_LAYOUT_STYLE + HTML_TYPE_LINK_STYLE + HTML_NAVIGATION_STYLE +
                HTML_TOC_STYLE + HTML_LAYOUT_HARDENING_STYLE + HTML_EXAMPLE_STYLE + HTML_REFERENCE_BROWSER_STYLE)
        for (pkg in projection.packages) {
            artifacts.addText("html/${packagePagePath(pkg.source.moduleId, pkg.source.name)}",
                "text/html; charset=utf-8",
                renderPackagePage(documentation, projection, index, topLevelByPackage, pkg, locale: locale, docVersion: docVersion))
        }
        for (symbol in projection.visibleSymbols) {
            artifacts.addText("html/${symbolPagePath(symbol)}", "text/html; charset=utf-8",
                renderSymbolPage(documentation, projection, index, membersByOwner, symbol, assetLookup,
                    typeLinkIndex, locale: locale, docVersion: docVersion))
        }
        appendAssetArtifacts(artifacts, projectedAssets, "html")
}

internal func appendJsonStringArray(out: RenderTextBuffer, values: ReadOnlyList<String>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }
        first = false
        appendSearchJsonString(out, value)
    }
    out.append("]")
}

internal func appendApiSurfaceArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    artifacts.addText("api-surface/api-surface.json", "application/json",
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

internal func appendCoverageArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    artifacts.addText("coverage/coverage.json", "application/json",
        renderDocumentationCoverageV2(documentation))
    appendDocumentationQualityArtifact(artifacts, documentation)
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

internal func markdownPackagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.md"
}

internal func markdownSymbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.md"
}

internal func appendMarkdownSiteSymbol(out: RenderTextBuffer, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, heading: String, locale: String,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>): Unit {
    out.append("<a id=\"${symbolAnchor(symbol)}\"></a>\n")
    out.append("${heading} "); appendMarkdownCodeSpan(out, symbol.qualifiedName); out.append("\n\n")
    appendMarkdownCodeBlock(out, symbol.headerSpelling, "cangjie", "`", 3)
    match (symbol.documentation) {
        case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup,
            locale: locale, pagePath: pagePath, symbolIndex: Some(symbolIndex))
        case None => ()
    }
    out.append("- "); appendEscapedMarkdownText(out, "${symbol.kind} · ${symbol.visibility}")
    out.append("\n- "); appendMarkdownCodeSpan(out,
        "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
    out.append("\n\n")
}

internal func nestedAssetLookup(assets: ArrayList<AssetDoc>): HashMap<String, String> {
    let lookup = HashMap<String, String>()
    for (asset in assets) {
        let path = "../${assetOutputPath(asset)}"
        lookup["id:${asset.id}"] = path
        lookup["path:${asset.sourcePath}"] = path
    }
    lookup
}

internal func appendMarkdownSiteArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, locale: String): Unit {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let projectedAssets = projectAssets(documentation, projection)
    let assetLookup = nestedAssetLookup(projectedAssets)
    let topLevelByPackage = groupTopLevelByPackage(projection)
    let membersByOwner = groupMembersByOwner(projection)
    let index = RenderTextBuffer()
    index.append("# "); appendEscapedMarkdownText(index, documentation.project.name)
    index.append(" "); appendEscapedMarkdownText(index, label(locale, "API documentation", "API 文档"))
    index.append("\n\n## ${label(locale, "Packages", "包")}\n\n")
    for (pkg in projection.packages) {
        index.append("- ["); appendEscapedMarkdownText(index, pkg.source.name)
        index.append("](${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)})\n")
    }
    artifacts.addText("markdown/index.md", "text/markdown; charset=utf-8", index.toString())
    for (pkg in projection.packages) {
        let out = RenderTextBuffer()
        out.append("# ${label(locale, "Package", "包")} "); appendMarkdownCodeSpan(out, pkg.source.name)
        out.append("\n\n[${label(locale, "Home", "首页")}](../index.md)\n\n")
        if (!pkg.source.reExports.isEmpty()) {
            out.append("## ${label(locale, "Re-exports", "公开重导出")}\n\n")
            for (reExport in pkg.source.reExports) {
                if (reExport.kind == "packageAlias") {
                    out.append("- "); appendMarkdownCodeSpan(out, reExport.alias.getOrThrow())
                    if (reExport.state == "resolved") {
                        out.append(" → ${label(locale, "package", "包")} ")
                    } else { out.append(" · ") }
                    appendMarkdownCodeSpan(out, reExport.targetPackageName)
                    out.append(" · "); appendEscapedMarkdownText(out,
                        "${reExport.kind} · ${reExport.state}")
                    out.append("\n")
                    continue
                }
                if (reExport.bindings.isEmpty()) {
                    out.append("- "); appendMarkdownCodeSpan(out, reExport.targetPackageName)
                    out.append(" · "); appendEscapedMarkdownText(out,
                        "${reExport.kind} · ${reExport.state}")
                    out.append("\n")
                    continue
                }
                for (binding in reExport.bindings) {
                    out.append("- "); appendMarkdownCodeSpan(out, binding.exposedName)
                    out.append(" → ")
                    var firstTarget = true
                    for (targetId in binding.targetSymbolIds) {
                        if (!firstTarget) { out.append(", ") }; firstTarget = false
                        match (projection.visibleIndex.get(targetId)) {
                            case Some(target) =>
                                out.append("["); appendMarkdownCodeSpan(out, target.qualifiedName)
                                let targetPath = if (isContainerDeclaration(target)) {
                                    "../${markdownSymbolPagePath(target)}"
                                } else {
                                    "../${markdownPackagePagePath(target.moduleId, target.packageName)}"
                                }
                                out.append("](${targetPath})")
                            case None => appendMarkdownCodeSpan(out, targetId)
                        }
                    }
                    out.append(" · "); appendEscapedMarkdownText(out, reExport.state)
                    out.append("\n")
                }
            }
            out.append("\n")
        }
        out.append("## ${label(locale, "Declarations", "声明")}\n\n")
        match (topLevelByPackage.get(routeKey(pkg.source.moduleId, pkg.source.name))) {
            case Some(symbols) => for (symbol in symbols) {
                if (isContainerDeclaration(symbol)) {
                    out.append("- ["); appendMarkdownCodeSpan(out, symbol.qualifiedName)
                    out.append("](../${markdownSymbolPagePath(symbol)})\n")
                } else {
                    appendMarkdownSiteSymbol(out, symbol, assetLookup, "###", locale,
                        markdownPackagePagePath(pkg.source.moduleId, pkg.source.name),
                        projection.visibleIndex)
                }
            }
            case None => out.append("${label(locale, "No direct declarations.", "没有直接声明。")}\n")
        }
        artifacts.addText("markdown/${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)}",
            "text/markdown; charset=utf-8", out.toString())
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let out = RenderTextBuffer()
        out.append("<a id=\"${symbolAnchor(symbol)}\"></a>\n")
        out.append("# "); appendMarkdownCodeSpan(out, symbol.qualifiedName)
        out.append("\n\n[${label(locale, "Package", "包")} ")
        appendMarkdownCodeSpan(out, symbol.packageName)
        out.append("](../${markdownPackagePagePath(symbol.moduleId, symbol.packageName)})\n\n")
        appendMarkdownCodeBlock(out, symbol.headerSpelling, "cangjie", "`", 3)
        match (symbol.documentation) {
            case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup,
                locale: locale, pagePath: markdownSymbolPagePath(symbol),
                symbolIndex: Some(projection.visibleIndex))
            case None => ()
        }
        match (membersByOwner.get(symbol.id)) {
            case Some(members) => if (!members.isEmpty()) {
                out.append("## ${label(locale, "Members", "成员")}\n\n")
                for (member in members) {
                    appendMarkdownSiteSymbol(out, member, assetLookup, "###", locale,
                        markdownSymbolPagePath(symbol), projection.visibleIndex)
                }
            }
            case None => ()
        }
        artifacts.addText("markdown/${markdownSymbolPagePath(symbol)}",
            "text/markdown; charset=utf-8", out.toString())
    }
    appendAssetArtifacts(artifacts, projectedAssets, "markdown")
}

public func renderDocumentationFormatsWithOptions(documentation: DocumentationSet,
    formats: Array<String>, locale!: String = "zh-CN", markdownLayout!: String = "site", docVersion!: ?String = None):
    Array<RenderArtifact> {
    if (locale != "zh-CN" && locale != "en") {
        throw IllegalArgumentException("locale must be zh-CN or en")
    }
    if (markdownLayout != "site" && markdownLayout != "single") {
        throw IllegalArgumentException("Markdown layout must be site or single")
    }
    let artifacts = RenderArtifactCollector()
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => if (markdownLayout == "single") {
                appendMarkdownArtifacts(artifacts, documentation)
            } else {
                appendMarkdownSiteArtifacts(artifacts, documentation, locale)
            }
            case "html" => appendHtmlArtifacts(artifacts, documentation, locale: locale, docVersion: docVersion)
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" => appendCoverageArtifacts(artifacts, documentation)
            case "symbol-index" => appendSymbolIndexArtifacts(artifacts, documentation, version: docVersion)
            case _ => throw IllegalArgumentException(
                "unsupported documentation format '${format}'")
        }
    }
    artifacts.toArray()
}

public func renderDocumentationFormats(documentation: DocumentationSet,
    formats: Array<String>): Array<RenderArtifact> {
    let artifacts = RenderArtifactCollector()
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => appendMarkdownArtifacts(artifacts, documentation)
            case "html" => appendHtmlArtifacts(artifacts, documentation)
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" => appendCoverageArtifacts(artifacts, documentation)
            case "symbol-index" => appendSymbolIndexArtifacts(artifacts, documentation)
            case _ => throw IllegalArgumentException(
                "unsupported documentation format '${format}'")
        }
    }
    artifacts.toArray()
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
