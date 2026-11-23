protected package cjdoc.render.html

import cjdoc.render.routes.{ApiHtmlChoice, apiHtmlFileHref, apiHtmlWebPath, symbolAnchor}
import cjdoc.render.reading.htmlKindLabel
import cjdoc.render.routes.label
import cjdoc.model.*
import std.collection.*

// A choice page lists real candidate declarations. Each option names itself by
// its structured label, and carries the same page-local identity the table rows
// use, so the outline points at the visible candidate rather than at the source
// header or a source-only signature.
protected func renderApiSelectionPage(documentation: DocumentationSet, projection: RenderProjection,
    choice: ApiHtmlChoice, locale: String, docVersion: ?String, mounted!: Bool = false): String {
    let routes = projection.apiRoutes.getOrThrow()
    let w = HtmlWriter()
    let prefix = projection.apiPageResourcePrefix(choice.file, mounted)
    let apiPrefix = projection.publicApiPrefix(prefix)
    let title = readerQualifiedName(choice.symbols[0])
    appendPageStart(w, title, prefix, documentation, projection, locale: locale,
        currentRoute: "api-choice", docVersion: docVersion, currentPagePath: Some(apiHtmlFileHref(choice.file)),
        canonical: Some(apiPrefix + apiHtmlWebPath(choice.file)), generatedPageId: Some(choice.id))
    let deprecations = projection.deprecations()
    var deprecatedCount: Int64 = 0
    if (choice.overloads) {
        for (symbol in choice.symbols where deprecations.contains(symbol.id)) { deprecatedCount++ }
    }
    let statusCount = deprecatedCount
    appendPageTitleHeader(w, "api") { heading =>
        heading.textElement("code", title)
        if (statusCount > 0) {
            appendDeprecationBadge(heading, locale, partial: statusCount < choice.symbols.size)
        }
    }
    // A same-name candidate from another module needs that module stated at the
    // point of choice; a single-module page keeps the compact label alone.
    let modules = HashSet<String>()
    for (symbol in choice.symbols) { let _ = modules.add(symbol.moduleId) }
    w.element("section", [htmlClass("cj-prose"), htmlAttr("aria-labelledby", "api-options")]) { section =>
        section.textElement("h2", label(locale, "Choose a declaration", "选择一个声明"),
            attrs: [htmlAttr("id", "api-options"), htmlAttr("data-cjdoc-toc-role", "group")])
        section.element("ul", []) { list =>
            let seen = HashMap<String, Int64>()
            for (symbol in choice.symbols) {
                let baseLabel = htmlContextLabel(symbol)
                let choiceLabel = if (modules.size > 1) {
                    let moduleName = findProjectedModule(projection, symbol.moduleId)
                        .map({ module => module.name }).getOrDefault({ => symbol.moduleId })
                    baseLabel + " · " + moduleName
                } else { baseLabel }
                let ordinal = seen.get(choiceLabel).getOrDefault({ => 0 }) + 1
                seen[choiceLabel] = ordinal
                // Candidates whose structured labels coincide (same parameter
                // types, different defaults) stay distinguishable.
                let entryLabel = if (ordinal > 1) { choiceLabel + " · #" + ordinal.toString() }
                    else { choiceLabel }
                let entryAttrs = [htmlAttr("id", symbolAnchor(symbol)),
                    htmlAttr("data-cjdoc-toc-role", "entry")]
                list.element("li", entryAttrs) { item =>
                    let destination = apiPrefix + routes.fileHref(symbol.id)
                    item.element("a", [htmlHref(SafeUrl.siteRoute(destination)),
                        htmlFlag("data-cjdoc-api-link")]) { link =>
                        link.element("code", []) { code => appendSoftWrappedLabel(code, entryLabel) }
                    }
                    appendDeprecationBadgeFor(item, projection, symbol, locale)
                    item.text(" · " + htmlKindLabel(symbol.kind, locale))
                    if (let Some(action) <- deprecations.action(symbol.id)) {
                        item.text(" · ")
                        appendReplacementLink(item, action, projection, prefix, locale)
                    }
                }
            }
        }
    }
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}
