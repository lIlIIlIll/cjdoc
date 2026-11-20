package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendDeprecationBadge(w: HtmlWriter, locale: String, partial!: Bool = false): Unit {
    w.textElement("span", if (partial) {
        label(locale, "Some overloads deprecated", "部分重载已弃用")
    } else { label(locale, "Deprecated", "已弃用") }, attrs: [htmlClass("cj-deprecation")])
}

internal func appendDeprecationBadgeFor(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, locale: String): Unit {
    if (projection.deprecations().contains(symbol.id)) { appendDeprecationBadge(w, locale) }
}

internal func appendReplacementLink(w: HtmlWriter, action: DeprecationAction,
    projection: RenderProjection, rootPrefix: String, locale: String): Unit {
    let url: String = match (action.navigation) {
        case Some(_) => navigationHref(rootPrefix, action.href).getOrThrow()
        case None => projection.publicApiPrefix(rootPrefix) + action.href
    }
    let attrs = ArrayList<HtmlAttr>(documentationHrefAttrs(url, cssClass: "cj-replacement", navigation: action.navigation))
    if (action.navigation.isNone()) { attrs.add(htmlFlag("data-cjdoc-api-link")) }
    w.element("a", attrs.toArray()) { link =>
        link.text(label(locale, "Use ", "改用 "))
        link.textElement("code", action.name)
    }
}

internal func appendReplacementLinkFor(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, rootPrefix: String, locale: String): Unit {
    if (let Some(action) <- projection.deprecations().action(symbol.id)) {
        appendReplacementLink(w, action, projection, rootPrefix, locale)
    }
}

internal func appendApiDeprecationNote(w: HtmlWriter, projection: RenderProjection, symbol: SymbolDoc,
    explanation: ?DocTag, rootPrefix: String, locale: String, assets: HashMap<String, String>,
    standalone!: Bool = false): Unit {
    if (!projection.deprecations().contains(symbol.id)) { return }
    let action: ?DeprecationAction = if (standalone) { projection.deprecations().action(symbol.id) } else { None }
    if (explanation.isNone() && action.isNone()) { return }
    w.element("aside", [htmlClass("cj-deprecation-note")]) { note =>
        note.element("div", [htmlClass("cj-deprecation-note__label")]) { status =>
            appendDeprecationBadge(status, locale)
        }
        note.element("div", [htmlClass("cj-deprecation-note__body cj-prose")]) { body =>
            if (let Some(choice) <- action) { appendReplacementLink(body, choice, projection, rootPrefix, locale) }
            if (let Some(tag) <- explanation) {
                appendDocumentationTagHtml(body, tag, locale, assets, rootPrefix,
                    markdownHtmlContext(symbol.documentation.getOrThrow(), symbol, 4, locale: locale))
            }
        }
    }
}
