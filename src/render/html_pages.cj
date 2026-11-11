package cjdoc.render

import cjdoc.model.*
import std.collection.*

/**
 * A generated site route. Values that already satisfy the strict route check are
 * passed through unchanged; author page routes may contain characters such as a
 * space, so those fall back to percent encoding of the rejected bytes instead of
 * dropping the destination.
 */
internal func documentationRouteHref(value: String): SafeUrl {
    match (SafeUrl.site(value)) {
        case Some(url) => url
        case None => SafeUrl.siteRoute(percentEncodeRoute(value))
    }
}

/** A captured documentation link: absolute `http(s)`/fragment first, then a site route. */
internal func documentationLinkHref(value: String): ?SafeUrl {
    match (SafeUrl.external(value)) {
        case Some(url) => Some(url)
        case None => match (SafeUrl.site(value)) {
            case Some(url) => Some(url)
            case None =>
                // Author routes may contain characters a URL attribute cannot
                // carry; percent encoding keeps the same destination reachable.
                if (value.split("/")[0].contains(":")) { None }
                else { SafeUrl.site(percentEncodeRoute(value)) }
        }
    }
}

private func routeByteAllowed(byte: Byte, extra: String): Bool {
    if ((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'.' ||
        byte == b'_' || byte == b'~' || byte == b'/') { return true }
    for (candidate in extra.toArray()) {
        if (candidate == byte) { return true }
    }
    false
}

private func percentEncodeRouteComponent(value: String, allowedExtra: String): String {
    let digits = "0123456789ABCDEF"
    let out = RenderTextBuffer()
    for (byte in value.toArray()) {
        let allowed = routeByteAllowed(byte, allowedExtra)
        if (allowed) {
            out.append(String.fromUtf8([byte]))
        } else {
            let high = Int64((byte >> 4) & 0x0F)
            let low = Int64(byte & 0x0F)
            out.append("%")
            out.append(digits[high..high + 1])
            out.append(digits[low..low + 1])
        }
    }
    out.toString()
}

private func percentEncodeRoute(value: String): String {
    let out = RenderTextBuffer()
    var rest = value
    while (rest.startsWith("../")) {
        out.append("../")
        rest = rest["../".size..]
    }
    var fragment = ""
    let fragmentParts = rest.split("#", 2)
    if (fragmentParts.size == 2) {
        rest = fragmentParts[0]
        fragment = "#" + fragmentParts[1]
    }
    var query = ""
    let queryParts = rest.split("?", 2)
    if (queryParts.size == 2) {
        rest = queryParts[0]
        query = "?" + queryParts[1]
    }
    out.append(percentEncodeRouteComponent(rest, ""))
    if (!query.isEmpty()) {
        out.append("?")
        out.append(percentEncodeRouteComponent(query[1..], "&=%,;:@"))
    }
    if (!fragment.isEmpty()) {
        out.append("#")
        out.append(percentEncodeRouteComponent(fragment[1..], "%,;:@?&="))
    }
    out.toString()
}

/** Page header holding the document title; content pages only add their own body. */
internal func appendPageTitleHeader(w: HtmlWriter, variant: String, body: (HtmlWriter) -> Unit): Unit {
    let headerClass = if (variant.isEmpty()) { "cj-page-header" } else { "cj-page-header cj-page-header--" + variant }
    w.element("header", [htmlClass(headerClass)]) { header =>
        header.element("div", [htmlClass("cj-page-header__title-row")]) { row =>
            row.open("h1", attrs: [htmlClass("cj-page-header__title")])
            body(row)
            row.close("h1")
        }
    }
    w.newline()
}

/** Breadcrumb trail; `current` renders the aria-current item itself. */
internal func appendBreadcrumbs(w: HtmlWriter, ariaLabel: String,
    links: Array<(String, SafeUrl)>, current: (HtmlWriter) -> Unit): Unit {
    w.element("nav", [htmlClass("cj-breadcrumbs"), htmlAttr("aria-label", ariaLabel)]) { nav =>
        nav.element("ol", [htmlClass("cj-breadcrumbs__list")]) { list =>
            for ((breadcrumbText, url) in links) {
                list.element("li", [htmlClass("cj-breadcrumbs__item")]) { item =>
                    item.element("a", [htmlHref(url)]) { link => link.text(breadcrumbText) }
                }
            }
            list.element("li", [htmlClass("cj-breadcrumbs__item"), htmlAttr("aria-current", "page")]) { item =>
                current(item)
            }
        }
    }
}

internal func renderHtmlIndex(documentation: DocumentationSet, projection: RenderProjection,
    locale!: String = "en", docVersion!: ?String = None): String {
    let w = HtmlWriter()
    let pageTitle = documentation.project.name + " " + label(locale, "API documentation", "API 文档")
    appendPageStart(w, pageTitle, "", documentation, projection, locale: locale,
        docVersion: docVersion, agentReadable: true, alternateMarkdown: Some("agent/pages/index.md"),
        currentPagePath: Some("index.html"))
    appendPageTitleHeader(w, "home") { title => title.text(documentation.project.name) }
    appendHomeIntroduction(w, documentation, projection, locale)
    appendHomePackageIndex(w, projection, locale)
    appendHomeGenerationDetails(w, documentation, projection, locale)
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}

internal func renderUtilityHtmlPage(documentation: DocumentationSet, title: String, body: TrustedHtml,
    rootPrefix: String, locale!: String = "en", docVersion!: ?String = None,
    agentReadable!: Bool = false): String {
    let projection = RenderProjection(documentation)
    let w = HtmlWriter()
    appendPageStart(w, title, rootPrefix, documentation, projection, locale: locale,
        currentRoute: "utility", docVersion: docVersion, agentReadable: agentReadable,
        currentPagePath: None)
    appendBreadcrumbs(w, label(locale, "Breadcrumb", "面包屑导航"),
        [(label(locale, "Home", "首页"), documentationRouteHref(rootPrefix + "index.html"))]) { item =>
        item.text(title)
    }
    appendPageTitleHeader(w, "") { heading => heading.text(title) }
    w.trusted(body)
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}

internal func renderConceptualHtmlPage(documentation: DocumentationSet, title: String, body: TrustedHtml,
    rootPrefix: String, source!: ?String = None, locale!: String = "en",
    docVersion!: ?String = None, pageRoute!: ?String = None,
    agentMarkdown!: ?String = None): String {
    let projection = RenderProjection(documentation)
    let w = HtmlWriter()
    appendPageStart(w, title, rootPrefix, documentation, projection, locale: locale,
        currentRoute: "concept", docVersion: docVersion, agentReadable: agentMarkdown.isSome(),
        alternateMarkdown: agentMarkdown, currentPagePath: pageRoute)
    appendBreadcrumbs(w, label(locale, "Breadcrumb", "面包屑导航"),
        [(label(locale, "API reference", "API 参考"), documentationRouteHref(rootPrefix + "index.html")),
         (label(locale, "Concepts", "概念文档"), documentationRouteHref(rootPrefix + "concepts/index.html"))]) { item =>
        item.text(title)
    }
    appendPageTitleHeader(w, "guide") { heading => heading.text(title) }
    w.trusted(body)
    appendConceptualPackageReturn(w, documentation, projection, pageRoute, source, rootPrefix, locale)
    if (let Some(value) <- source) {
        appendSourceDisclosure(w, value, label(locale, "Source", "来源"))
    }
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}

/** A secondary `<details>` holding one captured source path. */
internal func appendSourceDisclosure(w: HtmlWriter, source: String, summary: String): Unit {
    w.element("details", [htmlClass("cj-page-source cj-disclosure")]) { details =>
        details.textElement("summary", summary, attrs: [htmlClass("cj-disclosure__summary")])
        details.textElement("code", source)
    }
    w.newline()
}

internal func renderPackagePage(documentation: DocumentationSet, projection: RenderProjection,
    index: HashMap<String, SymbolDoc>, typeLinkIndex: HtmlTypeLinkIndex,
    pkg: ProjectedPackage, locale!: String = "en", docVersion!: ?String = None): String {
    let packageDoc = pkg.source
    let pagePath = packagePagePath(packageDoc.moduleId, packageDoc.name)
    let w = HtmlWriter()
    appendPageStart(w, "${label(locale, "Package", "包")} ${packageDoc.name}", "../",
        documentation, projection, locale: locale, docVersion: docVersion,
        currentPackagePath: Some(pagePath), currentRoute: "api", agentReadable: true,
        currentPagePath: Some(pagePath),
        alternateMarkdown: Some(agentPackageMarkdownPath(packageDoc.moduleId, packageDoc.name)))
    appendBreadcrumbs(w, label(locale, "Breadcrumb", "面包屑导航"),
        [(label(locale, "Home", "首页"), documentationRouteHref("../index.html"))]) { item =>
        item.text(label(locale, "Package", "包") + " ")
        item.element("code", []) { code => code.text(packageDoc.name) }
    }
    appendPageTitleHeader(w, "") { heading =>
        heading.text(label(locale, "Package", "包") + " ")
        heading.element("code", []) { code => code.text(packageDoc.name) }
    }
    appendPackageConceptualOverview(w, documentation, projection, packageDoc, locale)
    // The declaration groups own the "Declarations" heading: one visible category
    // becomes the section itself, several keep an umbrella H2 above category H3s.
    var wroteDeclaration = false
    match (projection.topLevelByPackage.get(routeKey(packageDoc.moduleId, packageDoc.name))) {
        case Some(symbols) =>
            if (!symbols.isEmpty()) {
                appendPackageDeclarationGroups(w, projection, packageDoc.moduleId,
                    packageDoc.name, symbols, locale)
                wroteDeclaration = true
            }
        case None => ()
    }
    if (!wroteDeclaration) {
        w.open("section", attrs: [htmlClass("cj-decl-group")])
        w.textElement("h2", label(locale, "Declarations", "声明"),
            attrs: [htmlAttr("id", "declarations"), htmlAttr("data-cjdoc-toc-role", "group")])
        w.textElement("p", label(locale, "No declarations are visible for this audience.",
            "此受众范围内没有直接声明。"), attrs: [htmlClass("cj-empty")])
        w.close("section")
        w.newline()
    }
    appendPackageMetadata(w, pkg, index, locale, projection.sourceReferences)
    appendPageEnd(w, documentation, locale: locale)
    w.toString()
}
