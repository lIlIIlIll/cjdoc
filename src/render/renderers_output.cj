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
    documentation: DocumentationSet, locale!: String = "en"): Unit {
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
            renderHtmlIndex(documentation, projection, locale: locale))
        artifacts.addText("html/search-index.json", "application/json", searchIndex)
        artifacts.addText("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex))
        artifacts.addText("html/theme-bootstrap.js", "text/javascript; charset=utf-8", HTML_THEME_BOOTSTRAP_SCRIPT)
        artifacts.addText("html/search.js", "text/javascript; charset=utf-8", HTML_SEARCH_SCRIPT)
        artifacts.addText("html/style.css", "text/css; charset=utf-8",
            HTML_STYLE + HTML_RETURN_LAYOUT_STYLE + HTML_TYPE_LINK_STYLE + HTML_NAVIGATION_STYLE +
                HTML_TOC_STYLE + HTML_LAYOUT_HARDENING_STYLE + HTML_EXAMPLE_STYLE)
        for (pkg in projection.packages) {
            artifacts.addText("html/${packagePagePath(pkg.source.moduleId, pkg.source.name)}",
                "text/html; charset=utf-8",
                renderPackagePage(documentation, projection, index, topLevelByPackage, pkg, assetLookup,
                    typeLinkIndex, locale: locale))
        }
        for (symbol in projection.visibleSymbols) {
            if (isContainerDeclaration(symbol)) {
                artifacts.addText("html/${symbolPagePath(symbol)}", "text/html; charset=utf-8",
                    renderSymbolPage(documentation, projection, index, membersByOwner, symbol, assetLookup,
                        typeLinkIndex, locale: locale))
            }
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
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.api-surface/1\",\n  \"project\": ")
    appendSearchJsonString(out, documentation.project.name)
    out.append(",\n  \"audience\": ")
    appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"declarations\": [")
    var first = true
    for (symbol in projection.visibleSymbols) {
        if (!first) { out.append(",") }
        first = false
        out.append("\n    {\"id\": "); appendSearchJsonString(out, symbol.id)
        out.append(", \"moduleId\": "); appendSearchJsonString(out, symbol.moduleId)
        out.append(", \"packageName\": "); appendSearchJsonString(out, symbol.packageName)
        out.append(", \"ownerId\": ")
        match (symbol.ownerId) {
            case Some(ownerId) => appendSearchJsonString(out, ownerId)
            case None => out.append("null")
        }
        out.append(", \"kind\": "); appendSearchJsonString(out, symbol.kind)
        out.append(", \"name\": "); appendSearchJsonString(out, symbol.name)
        out.append(", \"visibility\": "); appendSearchJsonString(out, symbol.visibility)
        out.append(", \"sourceApiSignature\": {\"state\": ")
        appendSearchJsonString(out, symbol.sourceApiSignature.state)
        out.append(", \"tokens\": ")
        appendJsonStringArray(out, symbol.sourceApiSignature.tokens)
        out.append("}}")
    }
    if (!first) { out.append("\n  ") }
    out.append("],\n  \"exposures\": [")
    first = true
    for (pkg in documentation.packages) {
        for (reExport in pkg.reExports) {
            for (binding in reExport.bindings) {
                if (!first) { out.append(",") }
                first = false
                out.append("\n    {\"reExportId\": "); appendSearchJsonString(out, reExport.id)
                out.append(", \"moduleId\": "); appendSearchJsonString(out, pkg.moduleId)
                out.append(", \"packageName\": "); appendSearchJsonString(out, pkg.name)
                out.append(", \"exposedName\": "); appendSearchJsonString(out, binding.exposedName)
                out.append(", \"targetSymbolIds\": ")
                appendJsonStringArray(out, binding.targetSymbolIds)
                out.append("}")
            }
        }
    }
    if (!first) { out.append("\n  ") }
    out.append("]\n}\n")
    artifacts.addText("api-surface/api-surface.json", "application/json", out.toString())
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
    let (symbols, documentedSymbols, parameters, documentedParameters) =
        documentationCoverageCounts(documentation)
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.documentation-coverage/1\",\n")
    out.append("  \"audience\": "); appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"symbols\": {\"total\": ${symbols}, \"documented\": ${documentedSymbols}, \"percent\": ${coveragePercent(documentedSymbols, symbols)}},\n")
    out.append("  \"parameters\": {\"total\": ${parameters}, \"documented\": ${documentedParameters}, \"percent\": ${coveragePercent(documentedParameters, parameters)}}\n}\n")
    artifacts.addText("coverage/coverage.json", "application/json", out.toString())
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
    assetLookup: HashMap<String, String>, heading: String, locale: String): Unit {
    out.append("${heading} "); appendMarkdownCodeSpan(out, symbol.qualifiedName); out.append("\n\n")
    appendMarkdownCodeBlock(out, symbol.headerSpelling, "cj", "`", 3)
    match (symbol.documentation) {
        case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup, locale: locale)
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
                    appendMarkdownSiteSymbol(out, symbol, assetLookup, "###", locale)
                }
            }
            case None => out.append("${label(locale, "No direct declarations.", "没有直接声明。")}\n")
        }
        artifacts.addText("markdown/${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)}",
            "text/markdown; charset=utf-8", out.toString())
    }
    for (symbol in projection.visibleSymbols where isContainerDeclaration(symbol)) {
        let out = RenderTextBuffer()
        out.append("# "); appendMarkdownCodeSpan(out, symbol.qualifiedName)
        out.append("\n\n[${label(locale, "Package", "包")} ")
        appendMarkdownCodeSpan(out, symbol.packageName)
        out.append("](../${markdownPackagePagePath(symbol.moduleId, symbol.packageName)})\n\n")
        appendMarkdownCodeBlock(out, symbol.headerSpelling, "cj", "`", 3)
        match (symbol.documentation) {
            case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup, locale: locale)
            case None => ()
        }
        match (membersByOwner.get(symbol.id)) {
            case Some(members) => if (!members.isEmpty()) {
                out.append("## ${label(locale, "Members", "成员")}\n\n")
                for (member in members) {
                    appendMarkdownSiteSymbol(out, member, assetLookup, "###", locale)
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
    formats: Array<String>, locale!: String = "zh-CN", markdownLayout!: String = "site"):
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
            case "html" => appendHtmlArtifacts(artifacts, documentation, locale: locale)
            case "api-surface" => appendApiSurfaceArtifacts(artifacts, documentation)
            case "coverage" => appendCoverageArtifacts(artifacts, documentation)
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
        case _ => throw IllegalArgumentException("unsupported documentation format '${format}'")
    }
}
