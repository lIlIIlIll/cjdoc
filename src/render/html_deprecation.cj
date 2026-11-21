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
    let attrs = ArrayList<HtmlAttr>(documentationHrefAttrs(url, cssClass: "cj-replacement"))
    if (let Some(navigation) <- action.navigation) {
        attrs.add(htmlAttr("data-doc-match", navigation.matchLevel))
    } else { attrs.add(htmlFlag("data-cjdoc-api-link")) }
    w.element("a", attrs.toArray()) { link =>
        link.text(label(locale, "Use ", "改用 "))
        link.textElement("code", action.name)
    }
}

// Author prose wins over the annotation's own message; the message is plain
// text, never Markdown, a link or a translated sentence.
private func appendSourceDeprecationMessage(w: HtmlWriter, message: String, locale: String): Unit {
    w.open("p", attrs: [htmlClass("cj-deprecation-note__source")])
    w.textElement("span", label(locale, "Source annotation: ", "源码说明："),
        attrs: [htmlClass("cj-deprecation-note__source-label")])
    w.text(message)
    w.close("p")
}

// The caller resolves the selected author prose, the source message and the
// verified action once for this occurrence; this only renders that decision.
internal func appendApiDeprecationNote(w: HtmlWriter, projection: RenderProjection,
    symbol: SymbolDoc, explanation: ?DocTag, sourceMessage: ?String, action: ?DeprecationAction,
    rootPrefix: String, locale: String, assets: HashMap<String, String>): Unit {
    let reason = if (explanation.isNone()) { sourceMessage } else { None<String> }
    if (explanation.isNone() && reason.isNone() && action.isNone()) { return }
    w.element("aside", [htmlClass(if (explanation.isNone() && reason.isSome()) {
        "cj-deprecation-note cj-deprecation-note--source"
    } else { "cj-deprecation-note" })]) { note =>
        note.element("div", [htmlClass("cj-deprecation-note__label")]) { status =>
            appendDeprecationBadge(status, locale)
        }
        note.element("div", [htmlClass("cj-deprecation-note__body cj-prose")]) { body =>
            if (let Some(choice) <- action) {
                appendReplacementLink(body, choice, projection, rootPrefix, locale)
            }
            if (let Some(tag) <- explanation) {
                appendDocumentationTagHtml(body, tag, locale, assets, rootPrefix,
                    markdownHtmlContext(symbol.documentation.getOrThrow(), symbol, 4, locale: locale))
            } else if (let Some(message) <- reason) {
                appendSourceDeprecationMessage(body, message, locale)
            }
        }
    }
}
