package cjdoc.render

import cjdoc.model.*
import std.collection.*

/**
 * Optional CSS font-family lists for the generated HTML site. Each value is a
 * comma-separated list of family names (letters, digits, spaces, `_`, `-`,
 * optionally double-quoted), at most 256 bytes; anything else is rejected so
 * the value can never break out of its declaration.
 */
public struct HtmlFontOptions {
    public let sans: ?String
    public let mono: ?String

    public init(sans!: ?String = None, mono!: ?String = None) {
        for ((value, option) in [(sans, "--html-font-sans"), (mono, "--html-font-mono")]) {
            if (let Some(list) <- value) {
                if (!isValidHtmlFontFamilyList(list)) {
                    throw IllegalArgumentException("invalid ${option} value")
                }
            }
        }
        this.sans = sans
        this.mono = mono
    }
}

private let HTML_FONT_FAMILY_LIST_LIMIT: Int64 = 256

private func htmlFontNameByte(byte: Byte): Bool {
    (byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
        (byte >= b'0' && byte <= b'9') || byte == b' ' || byte == b'_' || byte == b'-'
}

private func validHtmlFontFamily(family: String): Bool {
    let quoted = family.size >= 2 && family.startsWith("\"") && family.endsWith("\"")
    let name = if (quoted) { family[1..family.size - 1] } else { family }
    if (name.isEmpty() || name.startsWith(" ") || name.endsWith(" ")) { return false }
    for (byte in name.toArray()) {
        if (!htmlFontNameByte(byte)) { return false }
    }
    true
}

// Only the space character may separate list items; other whitespace (tabs,
// newlines) is rejected rather than silently trimmed into the stylesheet.
private func trimSpaces(value: String): String {
    var start: Int64 = 0
    var end = value.size
    while (start < end && value[start] == b' ') { start++ }
    while (end > start && value[end - 1] == b' ') { end-- }
    value[start..end]
}

public func isValidHtmlFontFamilyList(value: String): Bool {
    if (value.isEmpty() || value.size > HTML_FONT_FAMILY_LIST_LIMIT) { return false }
    for (part in value.split(",")) {
        if (!validHtmlFontFamily(trimSpaces(part))) { return false }
    }
    true
}

// Appended last so it overrides the default stacks, while the reader's own
// data-cj-font preference (higher specificity) still wins in the browser.
internal func renderHtmlStylesheet(fonts: HtmlFontOptions): String {
    let out = RenderTextBuffer()
    out.append(HTML_TOKENS_STYLE)
    out.append(HTML_LAYOUT_STYLE)
    out.append(HTML_COMPONENT_STYLE)
    if (let Some(sans) <- fonts.sans) { out.append(":root{--cj-font-sans:${sans};}\n") }
    if (let Some(mono) <- fonts.mono) { out.append(":root{--cj-font-mono:${mono};}\n") }
    out.toString()
}

public class HtmlDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "html" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)
    }
}

internal func appendHtmlArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, snapshot: DocumentationReadSnapshot,
    locale!: String = "en", docVersion!: ?String = None,
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()): Unit {
        // Keep the original localized HTML view for asset and hidden-target
        // context; links bind to the one captured reader snapshot.
        let projection = RenderProjection(documentation, snapshotId: snapshot.snapshotId)
        let index = projection.visibleIndex
        let typeLinkIndex = HtmlTypeLinkIndex(documentation, projection)
        let projectedAssets = projectAssets(documentation, projection,
            pages: selectedDocumentationPages(documentation, locale))
        let assetLookup = buildAssetLookup(projectedAssets)
        validateHtmlRouting(projection, projectedAssets)
        let searchIndex = renderSearchIndex(snapshot)
        let searchSignatures = renderSearchSignatureIndex(documentation, projection)
        artifacts.addText("html/index.html", "text/html; charset=utf-8",
            renderHtmlIndex(documentation, projection, locale: locale, docVersion: docVersion))
        artifacts.addText("html/search-index.json", "application/json", searchIndex)
        artifacts.addText("html/search-index.js", "text/javascript; charset=utf-8",
            renderSearchIndexScript(searchIndex, searchSignatures))
        artifacts.addText("html/sidebar-index.js", "text/javascript; charset=utf-8",
            renderSidebarIndexScript(projection, locale))
        artifacts.addText("html/theme-bootstrap.js", "text/javascript; charset=utf-8", HTML_THEME_BOOTSTRAP_SCRIPT)
        artifacts.addText("html/search.js", "text/javascript; charset=utf-8",
            HTML_SIDEBAR_SCRIPT + HTML_SEARCH_SCRIPT + LANGUAGE_NAVIGATION_SCRIPT)
        artifacts.addText("html/symbol-alias.js", "text/javascript; charset=utf-8", HTML_SYMBOL_ALIAS_SCRIPT)
        artifacts.addText("html/style.css", "text/css; charset=utf-8", renderHtmlStylesheet(htmlFonts))
        for (pkg in projection.packages) {
            artifacts.addText("html/${packagePagePath(pkg.source.moduleId, pkg.source.name)}",
                "text/html; charset=utf-8",
                renderPackagePage(documentation, projection, index, typeLinkIndex, pkg, locale: locale, docVersion: docVersion))
        }
        for (symbol in projection.visibleSymbols) {
            artifacts.addText("html/${symbolReadablePagePath(symbol)}", "text/html; charset=utf-8",
                renderSymbolAlias(symbol, locale))
            let rendered = renderSymbolPage(documentation, projection, index, symbol, assetLookup,
                    typeLinkIndex, locale: locale, docVersion: docVersion)
            artifacts.addText("html/${symbolPagePath(symbol)}", "text/html; charset=utf-8",
                rendered)
        }
        appendAssetArtifacts(artifacts, projectedAssets, "html")
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

internal func markdownPackagePagePath(moduleId: String, name: String): String {
    "packages/package-${boundedHtmlSlug(routeKey(moduleId, name))}.md"
}

/**
 * Partition member declarations by their rendered section title, in the same
 * reading order the HTML member page uses, so both surfaces pick the same
 * heading depth for a role.
 */
internal func memberSectionCategories(symbols: ArrayList<SymbolDoc>):
    ArrayList<(String, ArrayList<SymbolDoc>)> {
    let groups = HashMap<String, ArrayList<SymbolDoc>>()
    for (symbol in symbols) {
        let title = memberSectionTitle(symbol)
        match (groups.get(title)) {
            case Some(values) => values.add(symbol)
            case None => groups[title] = ArrayList<SymbolDoc>([symbol])
        }
    }
    let ordered = ArrayList<(String, ArrayList<SymbolDoc>)>()
    for (title in MEMBER_SECTION_TITLES) {
        match (groups.get(title)) {
            case Some(values) => ordered.add((title, values))
            case None => continue
        }
    }
    ordered
}

internal func markdownSymbolPagePath(symbol: SymbolDoc): String {
    "symbols/symbol-${boundedHtmlSlug(symbol.id)}.md"
}

internal func appendMarkdownSiteSymbol(out: RenderTextBuffer, symbol: SymbolDoc,
    assetLookup: HashMap<String, String>, heading: String, locale: String,
    pagePath: String, symbolIndex: HashMap<String, SymbolDoc>,
    projection: RenderProjection): Unit {
    let anchor = symbolAnchor(symbol)
    out.append("<a id=\"${anchor}\"></a>\n")
    out.append("${heading} ")
    if (isContainerDeclaration(symbol)) { out.append("[") }
    appendMarkdownCodeSpan(out, symbol.qualifiedName)
    if (isContainerDeclaration(symbol)) {
        out.append("](${markdownRelativeDestination(markdownSymbolPagePath(symbol), pagePath)})")
    }
    out.append("\n\n")
    appendMarkdownCodeBlock(out, symbol.headerSpelling, "cangjie", "`", 3)
    appendDeclarationClassificationMarkdown(out, projection.catalog.classificationFor(symbol), locale)
    appendMarkdownTypeDetails(out, symbol, pagePath, symbolIndex, locale)
    match (symbol.documentation) {
        case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup,
            locale: locale, pagePath: pagePath, symbolIndex: Some(symbolIndex),
            headingPrefix: heading + "#", headingBase: heading.size + 1,
            headingAnchorPrefix: anchor)
        case None => ()
    }
    out.append("- "); appendEscapedMarkdownText(out, "${symbol.kind} · ${symbol.visibility}")
    out.append("\n- "); appendMarkdownCodeSpan(out,
        "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
    out.append("\n")
    appendSourceReferenceEvidenceMarkdown(out,
        projection.sourceReferences.project(symbol.moduleId, symbol.source), locale)
    out.append("\n")
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

private func appendMarkdownExposureSource(out: RenderTextBuffer,
    sourceReferences: SourceReferenceProjection, moduleId: String,
    source: SourceRange, locale: String): Unit {
    match (sourceReferences.project(moduleId, source).url) {
        case Some(url) =>
            match (markdownLinkDestination(url)) {
                case Some(destination) =>
                    out.append(" · [")
                    appendEscapedMarkdownText(out,
                        label(locale, "Exposure source", "暴露位置"))
                    out.append("](${destination})")
                case None => ()
            }
        case None => ()
    }
}

internal func appendMarkdownSiteArtifacts(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet, locale: String): Unit {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let projectedAssets = projectAssets(documentation, projection,
        pages: selectedDocumentationPages(documentation, locale))
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
    appendCapturedPageMarkdownNavigation(index, documentation, locale)
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
                    appendMarkdownExposureSource(out, projection.sourceReferences,
                        pkg.source.moduleId, reExport.source, locale)
                    out.append("\n")
                    continue
                }
                if (reExport.bindings.isEmpty()) {
                    out.append("- "); appendMarkdownCodeSpan(out, reExport.targetPackageName)
                    out.append(" · "); appendEscapedMarkdownText(out,
                        "${reExport.kind} · ${reExport.state}")
                    appendMarkdownExposureSource(out, projection.sourceReferences,
                        pkg.source.moduleId, reExport.source, locale)
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
                    appendMarkdownExposureSource(out, projection.sourceReferences,
                        pkg.source.moduleId, reExport.source, locale)
                    out.append("\n")
                }
            }
            out.append("\n")
        }
        out.append("## ${label(locale, "Declarations", "声明")}\n\n")
        match (topLevelByPackage.get(routeKey(pkg.source.moduleId, pkg.source.name))) {
            case Some(symbols) =>
                let roles = partitionDeclarationGroups(symbols, projection.catalog)
                let grouped = hasGroupedDeclarations(roles)
                if (grouped) {
                    prepareDeclarationGroupAnchors(roles, pkg.source.moduleId,
                        pkg.source.name, None)
                    let kindAliases = HashSet<String>()
                    for (symbol in symbols) {
                        let (alias, _) = packageDeclarationHeading(
                            packageDeclarationCategory(symbol.kind), locale)
                        if (kindAliases.add(alias)) {
                            out.append("<a id=\"${escapeHtml(alias)}\"></a>\n")
                        }
                    }
                }
                for (role in roles) {
                    if (grouped) { appendGroupedDeclarationMarkdown(out, role, "###", locale) }
                    let categories = packageDeclarationCategories(role.symbols)[0]
                    let layout = declarationGroupLayout(categories.size, 3)
                    let mixed = grouped && layout.showKindHeading
                    let entryLevel = if (!grouped) { "###" }
                        else if (layout.entryParentLevel == 3) { "####" } else { "#####" }
                    let pagePath = markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)
                    for (category in categories) {
                        let kindId = packageDeclarationHeading(category[0], locale)[0]
                        if (grouped) {
                            let kindAnchor = role.kindPrefix + kindId
                            out.append("<a id=\"${escapeHtml(kindAnchor)}\"></a>\n")
                        }
                        if (mixed) {
                            // The kind heading is the parent of each
                            // declaration heading, mirroring the HTML tree.
                            out.append("#### ")
                            appendEscapedMarkdownText(out,
                                packageDeclarationHeading(category[0], locale)[1])
                            out.append("\n\n")
                        }
                        for (symbol in category[1]) {
                            if (!grouped && isContainerDeclaration(symbol)) {
                                out.append("- ["); appendMarkdownCodeSpan(out, symbol.qualifiedName)
                                out.append("](../${markdownSymbolPagePath(symbol)})\n")
                                continue
                            }
                            appendMarkdownSiteSymbol(out, symbol, assetLookup, entryLevel, locale,
                                pagePath, projection.visibleIndex, projection)
                            appendExternalDocumentationMarkdown(out, documentation, symbol, locale,
                                pagePath, headingPrefix: entryLevel + "#")
                        }
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
        appendDeclarationClassificationMarkdown(out,
            projection.catalog.classificationFor(symbol), locale)
        appendMarkdownTypeDetails(out, symbol, markdownSymbolPagePath(symbol),
            projection.visibleIndex, locale)
        match (symbol.documentation) {
            case Some(comment) => appendDocumentationMarkdown(out, comment, assetLookup,
                locale: locale, pagePath: markdownSymbolPagePath(symbol),
                symbolIndex: Some(projection.visibleIndex), headingAnchorPrefix: symbolAnchor(symbol))
            case None => ()
        }
        out.append("- ${label(locale, "Location", "位置")}: ")
        appendMarkdownCodeSpan(out, "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
        out.append("\n")
        appendSourceReferenceEvidenceMarkdown(out,
            projection.sourceReferences.project(symbol.moduleId, symbol.source), locale)
        out.append("\n")
        appendExternalDocumentationMarkdown(out, documentation, symbol, locale, markdownSymbolPagePath(symbol))
        match (membersByOwner.get(symbol.id)) {
            case Some(members) => if (!members.isEmpty()) {
                out.append("## ${label(locale, "Members", "成员")}\n\n")
                let roles = partitionDeclarationGroups(members, projection.catalog)
                let grouped = hasGroupedDeclarations(roles)
                if (grouped) {
                    prepareDeclarationGroupAnchors(roles, symbol.moduleId, symbol.packageName,
                        Some(symbol.id))
                }
                let kindIdsByGroup = HashMap<String, HashSet<String>>()
                for (role in roles) {
                    for (category in memberSectionCategories(role.symbols)) {
                        let kindId = memberSectionAnchor(category[0])
                        match (kindIdsByGroup.get(role.id)) {
                            case Some(values) => let _ = values.add(kindId)
                            case None =>
                                let values = HashSet<String>()
                                let _ = values.add(kindId)
                                kindIdsByGroup[role.id] = values
                        }
                    }
                }
                let kindAliases = HashSet<String>()
                for (role in roles) {
                    if (grouped) { appendGroupedDeclarationMarkdown(out, role, "###", locale) }
                    let categories = memberSectionCategories(role.symbols)
                    let ownKindIds = HashSet<String>()
                    for (category in categories) {
                        let _ = ownKindIds.add(memberSectionAnchor(category[0]))
                    }
                    if (grouped && (role.isPrimary || role.id.isEmpty())) {
                        match (kindIdsByGroup.get(role.id)) {
                            case Some(values) =>
                                for (title in MEMBER_SECTION_TITLES) {
                                    let kindId = memberSectionAnchor(title)
                                    if (!values.contains(kindId)) { continue }
                                    if (role.isPrimary && !ownKindIds.contains(kindId)) {
                                        out.append("<a id=\"${escapeHtml(role.kindPrefix + kindId)}\"></a>\n")
                                    }
                                    if (kindAliases.add(kindId)) {
                                        out.append("<a id=\"${escapeHtml(kindId)}\"></a>\n")
                                    }
                                }
                            case None => ()
                        }
                    }
                    let layout = declarationGroupLayout(categories.size, 3)
                    let mixed = grouped && layout.showKindHeading
                    let entryLevel = if (!grouped) { "###" }
                        else if (layout.entryParentLevel == 3) { "####" } else { "#####"}
                    for (category in categories) {
                        let kindId = memberSectionAnchor(category[0])
                        if (grouped) {
                            let kindAnchor = role.kindPrefix + kindId
                            out.append("<a id=\"${escapeHtml(kindAnchor)}\"></a>\n")
                        }
                        if (mixed) {
                            out.append("#### ")
                            appendEscapedMarkdownText(out, memberSectionLabel(category[0], locale))
                            out.append("\n\n")
                        }
                        for (member in category[1]) {
                            appendMarkdownSiteSymbol(out, member, assetLookup,
                                entryLevel, locale,
                                markdownSymbolPagePath(symbol), projection.visibleIndex,
                                projection)
                            appendExternalDocumentationMarkdown(out, documentation, member, locale,
                                markdownSymbolPagePath(symbol), headingPrefix: entryLevel + "#")
                        }
                    }
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
    formats: Array<String>, locale!: String = "zh-CN", docVersion!: ?String = None,
    allLanguages!: Bool = false, agentFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = [],
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()):
    Array<RenderArtifact> {
    if (allLanguages) {
        return renderAllDocumentationLanguages(documentation, formats, docVersion,
            agentFull: agentFull, reports: reports, htmlFonts: htmlFonts)
    }
    if (locale != "zh-CN" && locale != "en") {
        throw IllegalArgumentException("locale must be zh-CN or en")
    }
    let localized = projectDocumentationLanguage(documentation, locale)
    if (!docIrFitsEncodedBudget(localized, DOC_IR_MAX_JSON_DOCUMENT_BYTES)) {
        throw RenderResourceLimitException(
            "selected documentation exceeds the existing Doc IR budget")
    }
    let artifacts = RenderArtifactCollector()
    let htmlSnapshot: ?DocumentationReadSnapshot = if (formats.contains("html")) {
        Some(DocumentationReadSnapshot(localized, locale: Some(locale), version: docVersion))
    } else { None }
    // Search and Agent companions share one captured reader snapshot. HTML keeps
    // the source view: publication pruning removes asset and hidden-target context.
    let machineArtifacts: Array<RenderArtifact> = match (htmlSnapshot) {
        case Some(context) =>
            let machine = RenderArtifactCollector()
            appendAgentReadableArtifacts(machine, context, includeFull: agentFull,
                version: docVersion, includeValidation: true, reports: reports)
            machine.toArray()
        case None => []
    }
    for (format in formats) {
        match (format) {
            case "json" => appendJsonArtifacts(artifacts, documentation)
            case "markdown" => appendMarkdownSiteArtifacts(artifacts, localized, locale)
            case "html" => match (htmlSnapshot) {
                case Some(context) => appendHtmlArtifacts(artifacts, localized, context,
                    locale: locale, docVersion: docVersion, htmlFonts: htmlFonts)
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
        appendCapturedPageArtifacts(artifacts, localized, capturedFormats.toArray(), locale, docVersion)
    }
    if (formats.contains("html")) {
        artifacts.addText("html/validation.html", "text/html; charset=utf-8",
            renderValidationHtml(localized, docVersion, locale))
        for (artifact in machineArtifacts) { artifacts.add(artifact) }
    }
    artifacts.toArray()
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
