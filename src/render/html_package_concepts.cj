package cjdoc.render

import cjdoc.model.*
import std.collection.*

// The snapshot is the only content source. A package name alone cannot choose
// between modules; explicit visible bindings can prove a unique module instead.
private func conceptualPackageOwner(documentation: DocumentationSet,
    projection: RenderProjection, page: DocumentationPage): ?PackageDoc {
    if (page.packageName.isEmpty() || !capturedPageHasContent(page)) { return None }
    for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3026") {
        if (let Some(source) <- diagnostic.source) {
            if (source.path == page.source) { return None }
        }
    }
    var moduleId: ?String = None
    for (binding in page.bindings) {
        if (binding.state != "resolved") { return None }
        if (let Some(id) <- binding.targetSymbolId) {
            if (!projection.visibleIndex.contains(id)) { return None }
        }
    }
    for (id in page.targetSymbolIds) {
        let target = projection.visibleIndex.get(id)
        if (target.isNone()) { return None }
        let symbol = target.getOrThrow()
        // Related APIs from other packages are not evidence of this package's module.
        if (symbol.packageName != page.packageName) { continue }
        if (moduleId.isSome() && moduleId != Some(symbol.moduleId)) { return None }
        moduleId = Some(symbol.moduleId)
    }
    var owner: ?PackageDoc = None
    for (pkg in documentation.packages where pkg.name == page.packageName) {
        if (moduleId.isSome() && moduleId != Some(pkg.moduleId)) { continue }
        if (owner.isSome()) { return None }
        owner = Some(pkg)
    }
    if (let Some(pkg) <- owner) {
        for (visible in projection.packages) {
            if (visible.source.moduleId == pkg.moduleId && visible.source.name == pkg.name) { return owner }
        }
    }
    None
}

// At most one paragraph and 240 Unicode scalar values: examples, imports and
// guide sections remain at their one authoritative conceptual-page location.
private func packagePageExcerpt(page: DocumentationPage): String {
    for (node in page.markdown.children where node.kind == "paragraph") {
        let text = markdownNodeText(node).trimAscii().replace("\n", " ").replace("\r", " ").replace("\t", " ")
        if (text.isEmpty()) { continue }
        let out = RenderTextBuffer()
        var count: Int64 = 0
        for (rune in text.runes()) {
            if (count == 240) { out.append("…"); break }
            out.append(rune.toString())
            count++
        }
        return out.toString()
    }
    ""
}


internal func appendPackageConceptualOverview(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, pkg: PackageDoc, locale: String): Unit {
    var selected: ?DocumentationPage = None
    let pages = selectedDocumentationPages(documentation, locale)
    for (page in pages) {
        if (let Some(owner) <- conceptualPackageOwner(documentation, projection, page)) {
            if (owner.moduleId != pkg.moduleId || owner.name != pkg.name) { continue }
            // The first configured guide is the entry when no dedicated overview
            // exists. All other related guides remain explicit links below.
            if (selected.isNone() || (selected.getOrThrow().kind != "package" && page.kind == "package")) {
                selected = Some(page)
            }
        }
    }
    if (let Some(page) <- selected) {
        out.append("<section class=\"package-overview\" aria-label=\"" + label(locale, "Package overview", "包概述") + "\">")
        let excerpt = packagePageExcerpt(page)
        if (!excerpt.isEmpty()) {
            out.append("<p")
            if (let Some(language) <- page.language) {
                out.append(" lang=\"")
                out.append(escapeHtml(language))
                out.append("\"")
            }
            out.append(">")
            out.append(escapeHtml(excerpt))
            out.append("</p>")
        }
        let state = if (page.language.isNone()) { "unknown" } else if (page.language == Some(locale)) { "complete" } else { "fallback" }
        appendContentLanguageHtml(out, DocTag("description", "", "", contentLanguage: page.language, translationState: state), locale)
        out.append("<nav class=\"package-reading-paths\" aria-label=\"" + label(locale, "Read next", "接下来阅读") + "\"><ul><li><a class=\"package-overview-link\" href=\"../" + escapeHtml(page.route) + "\">" +
            label(locale, "Read package overview", "阅读完整包概述") + "</a></li>")
        let linkedSources = HashSet<String>()
        let _ = linkedSources.add(page.source)
        for (related in pages where related.id != page.id) {
            if (linkedSources.contains(related.source)) { continue }
            if (let Some(owner) <- conceptualPackageOwner(documentation, projection, related)) {
                if (owner.moduleId == pkg.moduleId && owner.name == pkg.name) {
                    let _ = linkedSources.add(related.source)
                    out.append("<li><a href=\"../" + escapeHtml(related.route) + "\">" + escapeHtml(related.title) + "</a></li>")
                }
            }
        }
        out.append("</ul></nav>")
        out.append("<details class=\"page-source\"><summary>" + label(locale, "Source", "来源") +
            "</summary><code>" + escapeHtml(page.source) + "</code></details></section>\n")
    }
}

internal func appendConceptualPackageReturn(out: RenderTextBuffer, documentation: DocumentationSet,
    projection: RenderProjection, route: ?String, source: ?String, prefix: String, locale: String): Unit {
    if (source.isNone() && route.isNone()) { return }
    var selected: ?DocumentationPage = None
    for (page in selectedDocumentationPages(documentation, locale)) {
        if (if (route.isSome()) { Some(page.route) != route } else { Some(page.source) != source }) { continue }
        if (selected.isSome()) { return }
        selected = Some(page)
    }
    if (let Some(page) <- selected) {
        if (let Some(pkg) <- conceptualPackageOwner(documentation, projection, page)) {
            out.append("<p class=\"package-api-return\"><a href=\"" + prefix +
                escapeHtml(packagePagePath(pkg.moduleId, pkg.name)) + "#declarations\">" +
                label(locale, "Package API", "包 API") + " <code>" + escapeHtml(pkg.name) + "</code></a></p>\n")
        }
    }
}
