package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendHomeIntroduction(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, locale: String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    let paths = homeReadingPaths(pages, locale)
    for (page in pages where page.kind == "project" && capturedPageHasContent(page)) {
        let assets = buildAssetLookup(projectAssets(documentation, projection, pages: pages))
        out.append("<article class=\"home-introduction prose\" data-conceptual-entry>")
        appendPageContentLanguage(out, page, locale)
        out.append(capturedPageBodyHtml(documentation, page, locale, "index.html", assets, afterFirstCode: paths))
        out.append("</article>\n")
        return
    }
    out.append(paths)
}

private func homeReadingPaths(pages: Array<DocumentationPage>, locale: String): String {
    let out = RenderTextBuffer()
    out.append("<nav class=\"reading-paths\" aria-labelledby=\"reading-paths-heading\"><h2 id=\"reading-paths-heading\">" +
        label(locale, "Continue reading", "继续阅读") + "</h2><ul>")
    var first = true
    let resources = RenderTextBuffer()
    for (page in pages where page.kind == "guide" && capturedPageHasContent(page)) {
        let item = "<li><a href=\"" + escapeHtml(page.route) + "\">" + escapeHtml(page.title) + "</a></li>"
        if (first || !page.targetSymbolIds.isEmpty()) { out.append(item) } else { resources.append(item) }
        first = false
    }
    out.append("<li><a href=\"#packages\">" + label(locale, "API reference", "API 参考") + "</a></li></ul>")
    if (resources.size > 0) {
        out.append("<details class=\"reading-resources\"><summary>" + label(locale, "More resources", "其他资料") +
            "</summary><ul>" + resources.toString() + "</ul></details>")
    }
    out.append("</nav>\n")
    out.toString()
}

internal func appendHomePackageIndex(out: RenderTextBuffer, projection: RenderProjection,
    locale: String): Unit {
    out.append("<h2 id=\"packages\">" + label(locale, "Packages", "包") + "</h2><ul class=\"package-index\">\n")
    for (pkg in projection.packages) {
        out.append("<li><a href=\"${escapeHtml(packagePagePath(pkg.source.moduleId, pkg.source.name))}\"><code>${escapeHtml(pkg.source.name)}</code></a><span class=\"meta\">")
        var sameName: Int64 = 0
        for (other in projection.packages where other.source.name == pkg.source.name) { sameName++ }
        if (sameName > 1) {
            if (let Some(module) <- findProjectedModule(projection, pkg.source.moduleId)) {
                out.append(escapeHtml(module.name) + " · ")
            }
        }
        out.append("${pkg.symbols.size} ${label(locale, "declarations", "个声明")}</span></li>\n")
    }
    out.append("</ul>\n")
    if (projection.visibleSymbols.isEmpty()) {
        out.append("<p class=\"empty-state\">${label(locale, "No API declarations are available for this audience.", "当前受众范围内没有可用的 API 声明。")}</p>\n")
    } else {
        out.append("<details class=\"home-api-index\"><summary>" +
            label(locale, "Complete declaration index", "全部声明索引") + "</summary>")
        appendApiOverview(out, projection, locale)
        out.append("</details>")
    }
}

internal func appendHomeGenerationDetails(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, locale: String): Unit {
    if (!projection.modules.isEmpty()) {
        out.append("<details class=\"project-metadata\"><summary>" + label(locale, "Modules and sources", "模块与来源") + "</summary><ul class=\"record-list\">")
        for (projected in projection.modules) {
            let module = projected.source
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            out.append("<li><code>${escapeHtml(module.name)}</code> · ${escapeHtml(htmlKindLabel(module.role, locale))} · <code>${escapeHtml(prefix)}</code></li>")
        }
        out.append("</ul></details>\n")
    }
    if (documentation.status != "complete") {
        out.append("<details class=\"generation-metadata\" open><summary>${label(locale, "Generation status", "生成状态")}</summary><p>${escapeHtml(htmlStateLabel(documentation.status, locale))}</p></details>\n")
    }
    if (documentation.diagnostics.isEmpty()) { return }
    var hasErrors = false
    for (diagnostic in documentation.diagnostics where diagnostic.severity == "error") { hasErrors = true }
    let openAttribute = if (hasErrors) { " open" } else { "" }
    out.append("<details id=\"diagnostics\" class=\"build-details\"" + openAttribute +
        "><summary>" + label(locale, "Build status and diagnostics", "构建状态与诊断") + "</summary><ul class=\"diagnostics-list\">")
    for (diagnostic in documentation.diagnostics) {
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!projection.visibleIndex.contains(symbolId)) { continue }
        }
        out.append("<li><strong>${escapeHtml(htmlStateLabel(diagnostic.severity, locale))}[${escapeHtml(diagnostic.code)}]</strong>: ${escapeHtml(diagnostic.message)}")
        if (let Some(source) <- diagnostic.source) {
            out.append(" <code>${escapeHtml(source.path)}:${source.start.line}:${source.start.column}</code>")
        }
        out.append("</li>\n")
    }
    out.append("</ul></details>\n")
}
