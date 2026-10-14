package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal class PublishedLanguageRoute {
    let language: String
    let pageId: ?String
    let symbolId: ?String
    let sectionId: ?String
    let href: String
    let ownerSymbolId: ?String
    init(language: String, href: String, pageId!: ?String = None, symbolId!: ?String = None,
        sectionId!: ?String = None, ownerSymbolId!: ?String = None) {
        this.language = language; this.href = href; this.pageId = pageId; this.symbolId = symbolId; this.sectionId = sectionId
        this.ownerSymbolId = ownerSymbolId
    }
    func identity(): String {
        pageId.getOrDefault({ => "" }) + "\u{0}" + symbolId.getOrDefault({ => "" }) + "\u{0}" + sectionId.getOrDefault({ => "" })
    }
}

private func addPublishedLanguageRoute(routes: ArrayList<PublishedLanguageRoute>,
    files: HashMap<String, String>, route: PublishedLanguageRoute): Unit {
    let parts = route.href.split("#", 2)
    let file = files.get(route.language + ":" + parts[0])
    if (file.isNone()) { return }
    if (parts.size == 2 && !file.getOrThrow().contains("id=\"" + escapeHtml(parts[1]) + "\"")) { return }
    routes.add(route)
}

protected func documentationHtmlAnchors(content: String): Array<String> {
    let result = ArrayList<String>()
    var start: Int64 = 0
    while (start < content.size) {
        if (start + 5 >= content.size || content[start] != b' ' || content[start + 1] != b'i' ||
            content[start + 2] != b'd' || content[start + 3] != b'=' || content[start + 4] != b'"') {
            start++; continue
        }
        let valueStart = start + 5
        var valueEnd = valueStart
        while (valueEnd < content.size && content[valueEnd] != b'"') { valueEnd++ }
        if (valueEnd == content.size) { break }
        if (result.size >= 100000) { throw IllegalArgumentException("HTML fragment limit exceeded") }
        result.add(content[valueStart..valueEnd])
        start = valueEnd + 1
    }
    result.toArray()
}

internal func publishedLanguageRoutes(documentation: DocumentationSet, languages: Array<String>,
    rendered: HashMap<String, Array<RenderArtifact>>): ArrayList<PublishedLanguageRoute> {
    let routes = ArrayList<PublishedLanguageRoute>()
    let files = HashMap<String, String>()
    for (language in languages) {
        for (artifact in rendered[language] where artifact.path.startsWith("html/") && artifact.path.endsWith(".html")) {
            files[language + ":" + artifact.path.removePrefix("html/")] = artifact.content
        }
    }
    for (language in languages) {
        let view = projectDocumentationLanguage(documentation, language)
        let projection = RenderProjection(view)
        addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, "index.html", pageId: Some("api-home")))
        for (pkg in projection.packages) {
            addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, packagePagePath(pkg.source.moduleId, pkg.source.name),
                pageId: Some("package:" + pkg.source.moduleId + ":" + pkg.source.name)))
        }
        for (symbol in projection.visibleSymbols) {
            let href = symbolUrl(projection.visibleIndex, symbol)
            addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, href, symbolId: Some(symbol.id), ownerSymbolId: symbol.ownerId))
            let page = href.split("#", 2)[0]
            for (kind in ["parameters", "return", "throws"]) {
                addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, page + "#" + docBlockAnchor(symbol, kind),
                    symbolId: Some(symbol.id), sectionId: Some(kind), ownerSymbolId: Some(symbol.id)))
            }
            if (let Some(comment) <- symbol.documentation) {
                for (tag in comment.tags where !tag.fieldId.isEmpty()) {
                    addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, page + "#" + documentationFieldAnchor(tag.fieldId),
                        symbolId: Some(symbol.id), sectionId: Some(tag.fieldId), ownerSymbolId: Some(symbol.id)))
                }
            }
        }
        for (page in selectedDocumentationPages(view, language)) {
            // Keep author ids distinct from generated pages and identity delimiters.
            let pageId = "conceptual:" + htmlStableSlug(page.id)
            addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, page.route, pageId: Some(pageId)))
            for (section in page.sections) {
                if (let Some(anchor) <- documentationSectionAnchor(page.markdown, section.anchor)) {
                    addPublishedLanguageRoute(routes, files, PublishedLanguageRoute(language, page.route + "#" + anchor,
                        pageId: Some(pageId), sectionId: Some(section.id)))
                }
            }
        }
        let anchors = HashMap<String, (String, ?String)>()
        let contexts = HashMap<String, String>()
        for (symbol in projection.visibleSymbols) {
            contexts[symbolPagePath(symbol)] = symbol.id
            anchors[symbolAnchor(symbol)] = (symbol.id, None<String>)
            for (kind in ["parameters", "return", "throws"]) { anchors[docBlockAnchor(symbol, kind)] = (symbol.id, Some(kind)) }
            if (let Some(comment) <- symbol.documentation) {
                for (tag in comment.tags where !tag.fieldId.isEmpty()) { anchors[documentationFieldAnchor(tag.fieldId)] = (symbol.id, Some(tag.fieldId)) }
            }
        }
        for (artifact in rendered[language] where artifact.path.startsWith("html/symbols/") && artifact.path.endsWith(".html")) {
            let page = artifact.path.removePrefix("html/")
            let owner = contexts.get(page)
            if (owner.isNone()) { continue }
            for (anchor in documentationHtmlAnchors(artifact.content)) {
                if (let Some((symbolId, sectionId)) <- anchors.get(anchor)) {
                    routes.add(PublishedLanguageRoute(language, page + "#" + anchor,
                        pageId: Some("context:" + owner.getOrThrow()), symbolId: Some(symbolId), sectionId: sectionId,
                        ownerSymbolId: Some(symbolId)))
                }
            }
        }
    }
    routes
}

internal func languagePositionRoutes(routes: ArrayList<PublishedLanguageRoute>, fromLanguage: String,
    fromPage: String, targetLanguage: String): String {
    let out = RenderTextBuffer(); out.append("{")
    var first = true
    let anchors = ArrayList<String>()
    let destinations = HashMap<String, String>()
    let targetById = HashMap<String, PublishedLanguageRoute>()
    for (route in routes where route.language == targetLanguage) { targetById[route.identity()] = route }
    for (route in routes where route.language == fromLanguage) {
        let parts = route.href.split("#", 2)
        if (parts.size != 2 || parts[0] != fromPage) { continue }
        if (let Some(target) <- targetById.get(route.identity())) {
            let href = pageRootPrefix(fromPage) + "../" + targetLanguage + "/" + target.href
            if (!destinations.contains(parts[1])) { anchors.add(parts[1]) }
            destinations[parts[1]] = href
        }
    }
    for (anchor in anchors) {
        if (!first) { out.append(",") }; first = false
        out.append(escapeJsonString(anchor) + ":[" + escapeJsonString(destinations[anchor]) + ",false]")
    }
    out.append("}"); out.toString()
}
