package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendHomeIntroduction(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, locale: String): Unit {
    let pages = selectedDocumentationPages(documentation, locale)
    for (page in pages where page.kind == "project" && capturedPageHasContent(page)) {
        let assets = buildAssetLookup(projectAssets(documentation, projection, pages: pages))
        w.open("article", attrs: [htmlClass("cj-home-intro cj-prose"), htmlFlag("data-conceptual-entry")])
        appendPageContentLanguage(w, page, locale)
        appendCapturedPageBodyHtml(w, documentation, page, locale, "index.html", assets,
            afterFirstCode: Some(homeReadingPaths(pages, locale)))
        w.close("article")
        w.newline()
        return
    }
    w.trusted(homeReadingPaths(pages, locale))
}

private func appendReadingPathItem(w: HtmlWriter, linkText: String, url: SafeUrl): Unit {
    w.element("li", []) { item =>
        item.element("a", [htmlHref(url)]) { link => link.text(linkText) }
    }
}

private func appendHomeReadingResourceItem(w: HtmlWriter, page: DocumentationPage): Unit {
    appendReadingPathItem(w, page.title, documentationRouteHref(page.route))
}

private func homeReadingPaths(pages: Array<DocumentationPage>, locale: String): TrustedHtml {
    TrustedHtml.capture { w =>
        w.element("nav", [htmlClass("cj-reading-paths"), htmlAttr("aria-labelledby", "reading-paths-heading")]) { nav =>
            nav.textElement("h2", label(locale, "Continue reading", "继续阅读"),
                attrs: [htmlAttr("id", "reading-paths-heading")])
            nav.open("ul")
            var first = true
            let resources = ArrayList<DocumentationPage>()
            for (page in pages where page.kind == "guide" && capturedPageHasContent(page)) {
                if (first || !page.targetSymbolIds.isEmpty()) {
                    appendHomeReadingResourceItem(nav, page)
                } else {
                    resources.add(page)
                }
                first = false
            }
            appendReadingPathItem(nav, label(locale, "API reference", "API 参考"),
                SafeUrl.fragment("packages"))
            nav.close("ul")
            if (!resources.isEmpty()) {
                nav.element("details", [htmlClass("cj-reading-paths cj-disclosure")]) { details =>
                    details.textElement("summary", label(locale, "More resources", "其他资料"),
                        attrs: [htmlClass("cj-disclosure__summary")])
                    details.element("ul", []) { list =>
                        for (page in resources) { appendHomeReadingResourceItem(list, page) }
                    }
                }
            }
        }
    }
}

private func homePackageModuleSuffix(projection: RenderProjection, pkg: ProjectedPackage): String {
    var sameName: Int64 = 0
    for (other in projection.packages where other.source.name == pkg.source.name) { sameName++ }
    if (sameName <= 1) { return "" }
    match (findProjectedModule(projection, pkg.source.moduleId)) {
        case Some(module) => module.name + " · "
        case None => ""
    }
}

internal func appendHomePackageIndex(w: HtmlWriter, projection: RenderProjection,
    locale: String): Unit {
    w.element("h2", [htmlAttr("id", "packages")]) { heading =>
        heading.text(label(locale, "Packages", "包"))
    }
    w.open("ul", attrs: [htmlClass("cj-package-index")])
    for (pkg in projection.packages) {
        w.element("li", []) { item =>
            item.element("a", [htmlHref(documentationRouteHref(
                packagePagePath(pkg.source.moduleId, pkg.source.name)))]) { link =>
                link.textElement("code", pkg.source.name)
            }
            item.element("span", [htmlClass("cj-meta")]) { meta =>
                meta.text(homePackageModuleSuffix(projection, pkg))
                meta.text("${pkg.symbols.size} ${label(locale, "declarations", "个声明")}")
            }
        }
    }
    w.close("ul")
    w.newline()
    if (projection.visibleSymbols.isEmpty()) {
        w.textElement("p", label(locale, "No API declarations are available for this audience.",
            "当前受众范围内没有可用的 API 声明。"), attrs: [htmlClass("cj-empty")])
        w.newline()
        return
    }
    w.open("details", attrs: [htmlClass("cj-package-index cj-disclosure")])
    w.textElement("summary", label(locale, "Complete declaration index", "全部声明索引"),
        attrs: [htmlClass("cj-disclosure__summary")])
    appendApiOverview(w, projection, locale)
    w.close("details")
}

private func appendDiagnosticEntry(w: HtmlWriter, diagnostic: Diagnostic, locale: String): Unit {
    w.element("li", []) { item =>
        item.open("strong")
        item.text(htmlStateLabel(diagnostic.severity, locale) + "[" + diagnostic.code + "]")
        item.close("strong")
        item.text(": " + diagnostic.message)
        if (let Some(source) <- diagnostic.source) {
            item.text(" ")
            item.textElement("code", "${source.path}:${source.start.line}:${source.start.column}")
        }
    }
    w.newline()
}

private func hasErrorDiagnostic(documentation: DocumentationSet): Bool {
    for (diagnostic in documentation.diagnostics where diagnostic.severity == "error") { return true }
    false
}

private func appendGenerationDiagnostics(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, locale: String): Unit {
    let openAttrs = ArrayList<HtmlAttr>([htmlAttr("id", "diagnostics"),
        htmlClass("cj-disclosure cj-generation")])
    if (hasErrorDiagnostic(documentation)) { openAttrs.add(htmlFlag("open")) }
    w.open("details", attrs: openAttrs.toArray())
    w.textElement("summary", label(locale, "Build status and diagnostics", "构建状态与诊断"),
        attrs: [htmlClass("cj-disclosure__summary")])
    w.open("ul", attrs: [htmlClass("cj-diagnostics")])
    for (diagnostic in documentation.diagnostics) {
        if (let Some(symbolId) <- diagnostic.symbolId) {
            if (!projection.visibleIndex.contains(symbolId)) { continue }
        }
        appendDiagnosticEntry(w, diagnostic, locale)
    }
    w.close("ul")
    w.close("details")
    w.newline()
}

internal func appendHomeGenerationDetails(w: HtmlWriter, documentation: DocumentationSet,
    projection: RenderProjection, locale: String): Unit {
    if (!projection.modules.isEmpty()) {
        w.open("details", attrs: [htmlClass("cj-disclosure cj-generation")])
        w.textElement("summary", label(locale, "Modules and sources", "模块与来源"),
            attrs: [htmlClass("cj-disclosure__summary")])
        w.open("ul", attrs: [htmlClass("cj-record-list")])
        for (projected in projection.modules) {
            let module = projected.source
            let prefix = if (module.sourcePrefix.isEmpty()) { "." } else { module.sourcePrefix }
            w.element("li", []) { item =>
                item.textElement("code", module.name)
                item.text(" · " + htmlKindLabel(module.role, locale) + " · ")
                item.textElement("code", prefix)
            }
        }
        w.close("ul")
        w.close("details")
        w.newline()
    }
    if (documentation.status != "complete") {
        w.open("details", attrs: [htmlClass("cj-disclosure cj-generation"), htmlFlag("open")])
        w.textElement("summary", label(locale, "Generation status", "生成状态"),
            attrs: [htmlClass("cj-disclosure__summary")])
        w.textElement("p", htmlStateLabel(documentation.status, locale))
        w.close("details")
        w.newline()
    }
    if (documentation.diagnostics.isEmpty()) { return }
    appendGenerationDiagnostics(w, documentation, projection, locale)
}
