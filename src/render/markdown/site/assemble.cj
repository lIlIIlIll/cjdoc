protected package cjdoc.render.markdown.site

import cjdoc.model.*
import cjdoc.render.agent.appendDeclarationClassificationMarkdown
import cjdoc.render.codec.validateTypedDocumentationSet
import cjdoc.render.foundation.{
    RenderArtifactStore, RenderTextBuffer, appendEscapedMarkdownText, appendMarkdownCodeBlock,
    appendMarkdownCodeSpan, escapeHtml, markdownLinkDestination}
import cjdoc.render.html.{
    MEMBER_SECTION_TITLES, RenderProjection, appendAssetArtifacts, appendCapturedPageMarkdownNavigation,
    appendExternalDocumentationMarkdown, appendGroupedDeclarationMarkdown, assetOutputPath,
    declarationGroupLayout, groupMembersByOwner, groupTopLevelByPackage, hasGroupedDeclarations,
    memberSectionAnchor, memberSectionLabel, memberSectionTitle, packageDeclarationCategories,
    packageDeclarationCategory, packageDeclarationHeading, partitionDeclarationGroups,
    prepareDeclarationGroupAnchors, projectAssets}
import cjdoc.render.markdown.{appendDocumentationMarkdown, appendMarkdownTypeDetails, markdownRelativeDestination}
import cjdoc.render.publication.{SourceReferenceProjection, appendSourceReferenceEvidenceMarkdown, isContainerDeclaration}
import cjdoc.render.routes.{label, markdownPackagePagePath, markdownSymbolPagePath, routeKey, selectedDocumentationPages, symbolAnchor}
import std.collection.*

/**
 * Partition member declarations by their rendered section title, in the same
 * reading order the HTML member page uses, so both surfaces pick the same
 * heading depth for a role.
 */
private func memberSectionCategories(symbols: ArrayList<SymbolDoc>):
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

private func appendCommentFieldsMarkdown(out: RenderTextBuffer, projection: RenderProjection,
    symbol: SymbolDoc, locale: String): Unit {
    let rows = match (projection.commentFields(symbol.id)) {
        case Some(values) => values
        case None => return
    }
    out.append("**${label(locale, "Comment fields", "注释字段")}**\n\n")
    for (row in rows) {
        out.append("- ")
        appendEscapedMarkdownText(out, row.titleFor(locale).replace("&", "&amp;"))
        out.append("\n")
        for (value in row.values()) {
            out.append("  - ")
            appendMarkdownCodeSpan(out, value)
            out.append("\n")
        }
    }
    out.append("\n")
}

private func appendMarkdownSiteSymbol(out: RenderTextBuffer, symbol: SymbolDoc,
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
            headingAnchorPrefix: anchor, payloadKind: symbol.kind)
        case None => ()
    }
    appendCommentFieldsMarkdown(out, projection, symbol, locale)
    out.append("- "); appendEscapedMarkdownText(out, "${symbol.kind} · ${symbol.visibility}")
    out.append("\n- "); appendMarkdownCodeSpan(out,
        "${symbol.source.path}:${symbol.source.start.line}:${symbol.source.start.column}")
    out.append("\n")
    appendSourceReferenceEvidenceMarkdown(out,
        projection.sourceReferences.project(symbol.moduleId, symbol.source), locale)
    out.append("\n")
}

private func nestedAssetLookup(assets: ArrayList<AssetDoc>): HashMap<String, String> {
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

protected func appendMarkdownSiteArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, locale: String): Unit {
    validateTypedDocumentationSet(documentation)
    let projection = RenderProjection(documentation)
    let projectedAssets = projectAssets(documentation, projection,
        pages: selectedDocumentationPages(documentation, locale))
    let assetLookup = nestedAssetLookup(projectedAssets)
    let index = RenderTextBuffer()
    index.append("# "); appendEscapedMarkdownText(index, documentation.project.name)
    index.append(" "); appendEscapedMarkdownText(index, label(locale, "API documentation", "API 文档"))
    index.append("\n\n## ${label(locale, "Packages", "包")}\n\n")
    for (pkg in projection.packages) {
        index.append("- ["); appendEscapedMarkdownText(index, pkg.source.name)
        index.append("](${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)})\n")
    }
    appendCapturedPageMarkdownNavigation(index, documentation, locale)
    let _ = artifacts.addText("markdown/index.md", "text/markdown; charset=utf-8", index.toString())
    appendMarkdownPackageArtifacts(artifacts, documentation, locale, projection, assetLookup)
    appendMarkdownContainerArtifacts(artifacts, documentation, locale, projection, assetLookup)
    appendAssetArtifacts(artifacts, projectedAssets, "markdown")
}

private func appendMarkdownPackageArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, locale: String,
    projection: RenderProjection, assetLookup: HashMap<String, String>): Unit {
    let topLevelByPackage = groupTopLevelByPackage(projection)
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
        let _ = artifacts.addText("markdown/${markdownPackagePagePath(pkg.source.moduleId, pkg.source.name)}",
            "text/markdown; charset=utf-8", out.toString())
    }
}

private func appendMarkdownContainerArtifacts(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, locale: String,
    projection: RenderProjection, assetLookup: HashMap<String, String>): Unit {
    let membersByOwner = groupMembersByOwner(projection)
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
                symbolIndex: Some(projection.visibleIndex), headingAnchorPrefix: symbolAnchor(symbol),
                payloadKind: symbol.kind)
            case None => ()
        }
        appendCommentFieldsMarkdown(out, projection, symbol, locale)
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
        let _ = artifacts.addText("markdown/${markdownSymbolPagePath(symbol)}",
            "text/markdown; charset=utf-8", out.toString())
    }
}
