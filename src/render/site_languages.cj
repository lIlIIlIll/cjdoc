package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func languagePageIdentity(documentation: DocumentationSet, route: String, locale: String): String {
    for (page in selectedDocumentationPages(documentation, locale)) {
        if (page.route == route) { return "page:" + page.id }
    }
    route
}

private func appendLanguageSwitcherStart(out: RenderTextBuffer, locale: String): Unit {
    let current = if (locale == "zh-CN") { "中文" } else { "English" }
    let title = label(locale, "Documentation language", "文档语言")
    out.append("<details class=\"language-switcher\"><summary class=\"language-label\" aria-label=\"" + title + ": " + current + "\">" + current)
    out.append("<svg width=\"12\" height=\"12\" viewBox=\"0 0 12 12\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" aria-hidden=\"true\"><path d=\"m3 4.5 3 3 3-3\"/></svg></summary>")
    out.append("<nav class=\"language-options\" aria-label=\"" + title + "\">")
}

private func replaceLanguageLabel(content: String, locale: String, switcher: String): String {
    let placeholder = "<span class=\"language-label\" lang=\"" + escapeHtml(locale) + "\">" +
        label(locale, "English", "中文") + "</span>"
    content.replace(placeholder, switcher)
}


internal func renderAllDocumentationLanguages(documentation: DocumentationSet, formats: Array<String>,
    version: ?String, agentFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = []): Array<RenderArtifact> {
    let options = match (documentation.languageOptions) {
        case Some(value) => value
        case None => throw IllegalArgumentException("--all-languages requires explicit [i18n] languages")
    }
    let artifacts = RenderArtifactCollector()
    let routes = HashMap<String, String>()
    let rendered = HashMap<String, Array<RenderArtifact>>()
    for (language in options.languages) {
        let values = renderDocumentationFormatsWithOptions(documentation, formats, locale: language,
            docVersion: version, agentFull: agentFull, reports: reports)
        rendered[language] = values
        for (artifact in values) {
            if (artifact.path.startsWith("html/") && artifact.path.endsWith(".html")) {
                let route = artifact.path.removePrefix("html/")
                routes[language + ":" + languagePageIdentity(documentation, route, language)] = route
            }
        }
    }
    let publishedRoutes = publishedLanguageRoutes(documentation, options.languages.toArray(), rendered)
    var firstLanguage = true
    for (language in options.languages) {
        for (artifact in rendered[language]) {
            let parts = artifact.path.split("/", 2)
            let reading = parts.size == 2 && ["html", "markdown", "symbol-index"].contains(parts[0])
            if (!reading) {
                if (firstLanguage) {
                    if (artifact.isBinary) { artifacts.addOwnedBytes(artifact.path, artifact.mediaType, artifact.bytes) }
                    else { artifacts.addText(artifact.path, artifact.mediaType, artifact.content) }
                }
                continue
            }
            let path = parts[0] + "/" + language + "/" + parts[1]
            var content = artifact.content
            if (parts[0] == "html" && path.endsWith(".html") && content.contains("id=\"cjdoc-main\"")) {
                let route = parts[1]
                let identity = languagePageIdentity(documentation, route, language)
                let nav = RenderTextBuffer()
                appendLanguageSwitcherStart(nav, language)
                for (target in options.languages) {
                    let same = routes.get(target + ":" + identity)
                    let destination = same.getOrDefault({ => "index.html" })
                    let href = pageRootPrefix(route) + "../" + target + "/" + destination
                    nav.append("<a href=\"" + escapeHtml(href) + "\" hreflang=\"" + target + "\" lang=\"" + target + "\"")
                    nav.append(" data-language-routes=\"" + escapeHtml(languagePositionRoutes(publishedRoutes, language, route, target)) + "\"")
                    if (target == language) { nav.append(" aria-current=\"page\"") }
                    if (same.isNone()) { nav.append(" data-switch-state=\"language-home\" title=\"" + label(language, "This page is unavailable; open the language home", "该语言无此页面，打开语言首页") + "\"") }
                    nav.append(">" + if (target == "zh-CN") { "中文" } else { "English" } + "</a>")
                }
                nav.append("</nav></details>")
                content = replaceLanguageLabel(content, language, nav.toString())
            }
            if (artifact.isBinary) { artifacts.addOwnedBytes(path, artifact.mediaType, artifact.bytes) }
            else { artifacts.addText(path, artifact.mediaType, content) }
        }
        firstLanguage = false
    }
    if (formats.contains("html")) { appendSiteLanguageManifest(artifacts, documentation, publishedRoutes, version) }
    artifacts.toArray()
}

internal func appendSiteLanguageManifest(artifacts: RenderArtifactCollector, documentation: DocumentationSet,
    routes: ArrayList<PublishedLanguageRoute>, version: ?String): Unit {
    let out = RenderTextBuffer()
    let defaultLanguage: ?String = documentation.languageOptions.map({ profile =>
        if (profile.languages.toArray().contains(profile.defaultLanguage)) { profile.defaultLanguage }
        else { profile.languages[0] }
    })
    out.append("{\"schemaVersion\":\"cjdoc.site-manifest/1\",\"project\":${escapeJsonString(documentation.project.name)},\"version\":${nullableString(version)},\"defaultLanguage\":${nullableString(defaultLanguage)},\"routes\":[")
    var first = true
    for (route in routes) {
        if (!first) { out.append(",") }; first = false
        let href = "html/" + route.language + "/" + route.href
        out.append("{\"language\":${escapeJsonString(route.language)},\"pageId\":${nullableString(route.pageId)},\"symbolId\":${nullableString(route.symbolId)},\"sectionId\":${nullableString(route.sectionId)},\"ownerSymbolId\":${nullableString(route.ownerSymbolId)},\"href\":${escapeJsonString(href)}}")
    }
    out.append("]}\n")
    artifacts.addText("site-manifest.json", "application/json", out.toString())
}

/** Include CLI utility pages in the final, actual publication inventory. */
public func finalizeDocumentationLanguageArtifacts(documentation: DocumentationSet,
    values: Array<RenderArtifact>, docVersion!: ?String = None): Array<RenderArtifact> {
    let languages = documentation.languageOptions.getOrThrow().languages.toArray()
    let rendered = HashMap<String, Array<RenderArtifact>>()
    let routes = HashMap<String, String>()
    for (language in languages) {
        let selected = ArrayList<RenderArtifact>()
        let prefix = "html/" + language + "/"
        for (artifact in values where artifact.path.startsWith(prefix)) {
            let route = artifact.path.removePrefix(prefix)
            selected.add(RenderArtifact("html/" + route, artifact.mediaType, artifact.content))
            if (route.endsWith(".html")) { routes[language + ":" + languagePageIdentity(documentation, route, language)] = route }
        }
        rendered[language] = selected.toArray()
    }
    let published = publishedLanguageRoutes(documentation, languages, rendered)
    let artifacts = RenderArtifactCollector()
    for (artifact in values) {
        if (artifact.path == "site-manifest.json") { continue }
        var content = artifact.content
        if (artifact.path.endsWith(".html") && content.contains("id=\"cjdoc-main\"") &&
            !content.contains("class=\"language-switcher\"")) {
            for (language in languages) {
                let prefix = "html/" + language + "/"
                if (!artifact.path.startsWith(prefix)) { continue }
                let route = artifact.path.removePrefix(prefix)
                let identity = languagePageIdentity(documentation, route, language)
                let nav = RenderTextBuffer()
                appendLanguageSwitcherStart(nav, language)
                for (target in languages) {
                    if (let Some(destination) <- routes.get(target + ":" + identity)) {
                        let href = pageRootPrefix(route) + "../" + target + "/" + destination
                        nav.append("<a href=\"" + escapeHtml(href) + "\" lang=\"" + target + "\" hreflang=\"" + target + "\"")
                        nav.append(" data-language-routes=\"" + escapeHtml(languagePositionRoutes(published, language, route, target)) + "\"")
                        if (target == language) { nav.append(" aria-current=\"page\"") }
                        nav.append(">" + if (target == "zh-CN") { "中文" } else { "English" } + "</a>")
                    }
                }
                nav.append("</nav></details>")
                content = replaceLanguageLabel(content, language, nav.toString())
            }
        }
        if (artifact.isBinary) { artifacts.addOwnedBytes(artifact.path, artifact.mediaType, artifact.bytes) }
        else { artifacts.addText(artifact.path, artifact.mediaType, content) }
    }
    appendSiteLanguageManifest(artifacts, documentation, published, docVersion)
    artifacts.toArray()
}
