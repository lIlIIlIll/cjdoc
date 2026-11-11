package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func appendLanguageSwitcherStart(w: HtmlWriter, locale: String): Unit {
    let current = if (locale == "zh-CN") { "中文" } else { "English" }
    let title = label(locale, "Documentation language", "文档语言")
    w.open("details", attrs: [htmlClass("cj-lang-toggle")])
    w.open("summary", attrs: [htmlClass("cj-lang-toggle__summary"),
        htmlAttr("aria-label", title + ": " + current)])
    w.icon("language")
    w.textElement("span", current, attrs: [htmlClass("cj-lang-toggle__current")])
    w.close("summary")
    w.open("nav", attrs: [htmlClass("cj-lang-toggle__menu"), htmlAttr("aria-label", title)])
}

private func appendLanguageSwitcherEnd(w: HtmlWriter): Unit {
    w.close("nav")
    w.close("details")
}

internal func languagePageIdentity(documentation: DocumentationSet, route: String,
    locale: String): String {
    for (page in selectedDocumentationPages(documentation, locale)) {
        if (page.route == route) { return "page:" + page.id }
    }
    route
}

private func languageHomeNotice(locale: String): String {
    label(locale, "This page is unavailable; open the language home", "该语言无此页面，打开语言首页")
}

private func replaceLanguageLabel(content: String, locale: String, switcher: String): String {
    let marker = "<span class=\"language-label\" lang=\"" + escapeHtml(locale) + "\">" +
        label(locale, "English", "中文") + "</span>"
    content.replace(marker, switcher)
}

private func appendLanguageOption(w: HtmlWriter, locale: String, target: String,
    href: String, routes: String, current!: Bool, homeFallback!: Bool): Unit {
    let name = if (target == "zh-CN") { "中文" } else { "English" }
    let notice = languageHomeNotice(locale)
    let attrs = ArrayList<HtmlAttr>([htmlClass("cj-lang-toggle__option")])
    // Language routes are generated page routes; characters an attribute
    // cannot carry are percent-encoded so the same page stays the target.
    attrs.add(htmlHref(documentationRouteHref(href)))
    attrs.add(htmlAttr("hreflang", target))
    attrs.add(htmlAttr("lang", target))
    attrs.add(htmlAttr("data-language-routes", routes))
    if (current) { attrs.add(htmlAttr("aria-current", "page")) }
    if (homeFallback) {
        attrs.add(htmlAttr("data-switch-state", "language-home"))
        attrs.add(htmlAttr("data-position-state", "language-home"))
        attrs.add(htmlAttr("title", notice))
    }
    w.open("a", attrs: attrs.toArray())
    w.textElement("span", name, attrs: [htmlClass("cj-lang-toggle__name"),
        htmlAttr("lang", target)])
    let noticeAttrs = ArrayList<HtmlAttr>([htmlClass("cj-lang-toggle__notice"),
        htmlAttr("lang", locale)])
    if (!homeFallback) { noticeAttrs.add(htmlFlag("hidden")) }
    w.open("span", attrs: noticeAttrs.toArray())
    if (homeFallback) { w.text(notice) }
    w.close("span")
    w.close("a")
}

internal func appendLanguageToggle(w: HtmlWriter, locale: String, languages: Array<String>,
    routes: HashMap<String, String>, route: String, identity: String,
    published: ArrayList<PublishedLanguageRoute>): Unit {
    appendLanguageSwitcherStart(w, locale)
    for (target in languages) {
        let same = routes.get(target + ":" + identity)
        let destination = same.getOrDefault({ => "index.html" })
        let href = pageRootPrefix(route) + "../" + target + "/" + destination
        appendLanguageOption(w, locale, target, href,
            languagePositionRoutes(published, locale, route, target),
            current: target == locale, homeFallback: same.isNone())
    }
    appendLanguageSwitcherEnd(w)
}

internal func languageToggleHtml(locale: String, languages: Array<String>,
    routes: HashMap<String, String>, route: String, identity: String,
    published: ArrayList<PublishedLanguageRoute>): String {
    TrustedHtml.capture({ w =>
        appendLanguageToggle(w, locale, languages, routes, route, identity, published)
    }).value
}

internal func renderAllDocumentationLanguages(documentation: DocumentationSet, formats: Array<String>,
    version: ?String, agentFull!: Bool = false,
    reports!: Array<DocumentationReportAttachment> = [],
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()): Array<RenderArtifact> {
    let options = match (documentation.languageOptions) {
        case Some(value) => value
        case None => throw IllegalArgumentException("--all-languages requires explicit [i18n] languages")
    }
    let artifacts = RenderArtifactCollector()
    let routes = HashMap<String, String>()
    let rendered = HashMap<String, Array<RenderArtifact>>()
    for (language in options.languages) {
        let values = renderDocumentationFormatsWithOptions(documentation, formats,
            locale: language, docVersion: version, agentFull: agentFull, reports: reports,
            htmlFonts: htmlFonts)
        rendered[language] = values
        for (artifact in values) {
            if (artifact.path.startsWith("html/") && artifact.path.endsWith(".html")) {
                let route = artifact.path.removePrefix("html/")
                routes[language + ":" + languagePageIdentity(documentation, route, language)] = route
            }
        }
    }
    let languages = options.languages.toArray()
    let publishedRoutes = publishedLanguageRoutes(documentation, languages, rendered)
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
                let switcher = languageToggleHtml(language, languages, routes, route,
                    identity, publishedRoutes)
                content = replaceLanguageLabel(content, language, switcher)
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
            !content.contains("class=\"cj-lang-toggle\"")) {
            for (language in languages) {
                let prefix = "html/" + language + "/"
                if (!artifact.path.startsWith(prefix)) { continue }
                let route = artifact.path.removePrefix(prefix)
                let identity = languagePageIdentity(documentation, route, language)
                let switcher = languageToggleHtml(language, languages, routes, route,
                    identity, published)
                content = replaceLanguageLabel(content, language, switcher)
            }
        }
        if (artifact.isBinary) { artifacts.addOwnedBytes(artifact.path, artifact.mediaType, artifact.bytes) }
        else { artifacts.addText(artifact.path, artifact.mediaType, content) }
    }
    appendSiteLanguageManifest(artifacts, documentation, published, docVersion)
    artifacts.toArray()
}
