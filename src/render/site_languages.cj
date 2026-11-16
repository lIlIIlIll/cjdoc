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

internal func renderAllDocumentationLanguagesInto(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, formats: Array<String>, version: ?String,
    agentFull!: Bool = false, reports!: Array<DocumentationReportAttachment> = [],
    htmlFonts!: HtmlFontOptions = HtmlFontOptions()): Unit {
    let options = match (documentation.languageOptions) {
        case Some(value) => value
        case None => throw IllegalArgumentException("--all-languages requires explicit [i18n] languages")
    }
    let inventory = LanguageHtmlInventory()
    var firstLanguage = true
    for (language in options.languages) {
        let localized = LanguageArtifactStore(artifacts, documentation, language,
            firstLanguage, inventory)
        renderDocumentationInto(localized, documentation, formats, locale: language,
            docVersion: version, agentFull: agentFull, reports: reports, htmlFonts: htmlFonts)
        firstLanguage = false
    }
    if (formats.contains("html")) {
        finalizeLanguageStore(artifacts, documentation, options.languages.toArray(), inventory, version)
    }
}

private func finalizeLanguageStore(artifacts: RenderArtifactStore,
    documentation: DocumentationSet, languages: Array<String>,
    inventory: LanguageHtmlInventory, version: ?String): Unit {
    let published = publishedLanguageRoutes(documentation, languages, inventory)
    for (page in inventory.pages where page.needsToggle) {
        let identity = languagePageIdentity(documentation, page.route, page.language)
        let switcher = languageToggleHtml(page.language, languages, inventory.routes,
            page.route, identity, published)
        let content = artifacts.readText(page.entry, RENDER_ARTIFACT_LIMIT)
        artifacts.replaceText(page.entry, replaceLanguageLabel(content, page.language, switcher))
    }
    appendSiteLanguageManifest(artifacts, documentation, published, version)
}

internal func appendSiteLanguageManifest(artifacts: RenderArtifactStore, documentation: DocumentationSet,
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
    let _ = artifacts.addText("site-manifest.json", "application/json", out.toString())
}

/** Include caller-appended utility HTML in the actual publication inventory. */
public func finalizeDocumentationLanguageArtifacts(documentation: DocumentationSet,
    values: Array<RenderArtifact>, docVersion!: ?String = None): Array<RenderArtifact> {
    let languages = documentation.languageOptions.getOrThrow().languages.toArray()
    let inventory = LanguageHtmlInventory()
    let artifacts = RenderArtifactCollector()
    for (artifact in values) {
        if (artifact.path == "site-manifest.json") { continue }
        let entry = if (artifact.hasBinaryPayload) {
            artifacts.addOwnedBytes(artifact.path, artifact.mediaType, artifact.ownedBytes)
        } else {
            artifacts.addText(artifact.path, artifact.mediaType, artifact.content)
        }
        for (language in languages) {
            let prefix = "html/" + language + "/"
            if (artifact.path.startsWith(prefix)) {
                inventory.capture(documentation, language, artifact.path.removePrefix(prefix),
                    entry, artifact.content)
                break
            }
        }
    }
    finalizeLanguageStore(artifacts, documentation, languages, inventory, docVersion)
    artifacts.toArray()
}
