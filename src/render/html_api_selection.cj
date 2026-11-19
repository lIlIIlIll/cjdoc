package cjdoc.render

import cjdoc.model.*

internal func renderApiSelectionPage(documentation: DocumentationSet, projection: RenderProjection,
    choice: ApiHtmlChoice, locale: String, docVersion: ?String, mounted!: Bool = false): String {
    let routes = projection.apiRoutes.getOrThrow()
    let w = HtmlWriter()
    let prefix = projection.apiPageResourcePrefix(choice.file, mounted)
    let apiPrefix = projection.publicApiPrefix(prefix)
    let title = readerQualifiedName(choice.symbols[0])
    appendPageStart(w, title, prefix, documentation, projection, locale: locale,
        currentRoute: "api-choice", docVersion: docVersion, currentPagePath: Some(apiHtmlFileHref(choice.file)),
        canonical: Some(apiPrefix + apiHtmlWebPath(choice.file)), generatedPageId: Some(choice.id))
    appendPageTitleHeader(w, "api") { heading => heading.textElement("code", title) }
    w.element("section", [htmlClass("cj-prose"), htmlAttr("aria-labelledby", "api-options")]) { section =>
        section.textElement("h2", label(locale, "Choose a declaration", "选择一个声明"),
            attrs: [htmlAttr("id", "api-options")])
        section.element("ul", []) { list =>
            for (symbol in choice.symbols) {
                list.element("li", []) { item =>
                    let destination = apiPrefix + routes.fileHref(symbol.id)
                    item.element("a", [htmlHref(SafeUrl.siteRoute(destination)), htmlFlag("data-cjdoc-api-link")]) { link =>
                        let signature = symbol.headerSpelling
                        link.textElement("code", if (signature.isEmpty()) { htmlContextLabel(symbol) } else { signature })
                    }
                    let moduleName = findProjectedModule(projection, symbol.moduleId).map({ module => module.name })
                        .getOrDefault({ => symbol.moduleId })
                    item.text(" · " + moduleName + " · " + htmlKindLabel(symbol.kind, locale))
                }
            }
        }
    }
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}
