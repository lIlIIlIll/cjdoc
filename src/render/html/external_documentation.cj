protected package cjdoc.render.html

import cjdoc.render.markdown.markdownRelativeDestination
import cjdoc.render.routes.{navigationHref, label}
import cjdoc.render.foundation.{
    RenderTextBuffer, appendEscapedMarkdownText, markdownLinkDestination, encodeMarkdownDestination,
    appendMarkdownCodeSpan}
import cjdoc.model.*
import std.collection.*
import cjdoc.render.codec.appendExternalDocumentation

internal func appendSearchExternalDocumentation(out: RenderTextBuffer, documentation: DocumentationSet,
    symbolId: String): Unit {
    let references = ArrayList<ExternalDocumentationReference>()
    for (value in documentation.externalDocumentation where value.symbolId == symbolId) { references.add(value) }
    if (references.isEmpty()) { return }
    let data = StringBuilder()
    appendExternalDocumentation(data, references, includeSymbolId: false)
    out.append(", \"externalDocs\": " + data.toString())
}

private func externalReferenceIdentity(value: ExternalDocumentationReference): String {
    value.name + "|" + value.state + "|" + value.reason + "|" + value.version + "|" +
        value.index + "|" + value.format + "|" + value.fingerprint
}

private func externalReferenceStatus(value: ExternalDocumentationReference, locale: String): String {
    if (value.state == "ambiguous") { label(locale, "Ambiguous reference", "引用不明确") }
    else { label(locale, "No external reference", "无外部参考") }
}

private func appendExternalReference(w: HtmlWriter, value: ExternalDocumentationReference,
    rootPrefix: String, locale: String): Unit {
    w.open("li", attrs: [htmlClass("cj-external__item")])
    w.textElement("strong", value.name, attrs: [htmlClass("cj-external__name")])
    w.text(" ")
    if (value.state == "available") {
        let destination = match (SafeUrl.external(value.url)) {
            case Some(external) => Some(external)
            case None => navigationHref(rootPrefix, value.url).flatMap(SafeUrl.site)
        }
        match (destination) {
            case Some(safe) =>
                w.open("a", attrs: [htmlClass("cj-external__link"), htmlAttr("rel", "noreferrer"),
                    htmlHref(safe)])
                w.text(label(locale, "Open external reference", "打开外部参考"))
                w.close("a")
            case None => ()
        }
    } else {
        w.textElement("span", externalReferenceStatus(value, locale),
            attrs: [htmlClass("cj-badge cj-badge--state"), htmlAttr("data-state", value.state)])
        w.text(" " + value.reason)
    }
    for ((key, text) in [("version", value.version), ("index", value.index),
        ("format", value.format), ("fingerprint", value.fingerprint)]) {
        if (!text.isEmpty()) {
            w.text(" ")
            w.textElement("span", key + ": " + text, attrs: [htmlClass("cj-bindings__meta")])
        }
    }
    w.close("li")
}

private func externalDocumentationHeading(headingLevel: Int64, compactUnavailable: Bool): Int64 {
    if (headingLevel > 0) { return min(6, headingLevel) }
    if (compactUnavailable) { return 3 }
    2
}

internal func appendExternalDocumentationHtml(w: HtmlWriter, documentation: DocumentationSet,
    symbol: SymbolDoc, rootPrefix: String, locale: String,
    relatedSymbolIds!: HashSet<String> = HashSet<String>(),
    compactUnavailable!: Bool = false, headingLevel!: Int64 = 0): Unit {
    let failures = ArrayList<ExternalDocumentationReference>()
    let seen = HashSet<String>()
    var opened = false
    for (value in documentation.externalDocumentation) {
        let local = value.symbolId == symbol.id
        if (!local && !relatedSymbolIds.contains(value.symbolId)) { continue }
        if (value.state != "available") {
            if (!seen.add(externalReferenceIdentity(value))) { continue }
            failures.add(value)
            continue
        }
        if (!local) { continue }
        if (!opened) {
            let heading = "h${externalDocumentationHeading(headingLevel, compactUnavailable)}"
            w.open("section", attrs: [htmlClass("cj-external")])
            w.textElement(heading, label(locale, "External documentation", "外部文档"),
                attrs: [htmlClass("cj-external__title")])
            w.open("ul", attrs: [htmlClass("cj-external__list")])
            opened = true
        }
        appendExternalReference(w, value, rootPrefix, locale)
    }
    if (opened) {
        w.close("ul")
        w.close("section")
    }
    appendExternalFailures(w, failures, rootPrefix, locale, compactUnavailable)
}

private func appendExternalFailures(w: HtmlWriter,
    failures: ArrayList<ExternalDocumentationReference>, rootPrefix: String, locale: String,
    compactUnavailable: Bool): Unit {
    if (failures.isEmpty()) { return }
    if (!compactUnavailable) {
        w.open("details", attrs: [htmlClass("cj-external__status cj-disclosure"),
            htmlAttr("id", "external-reference-status")])
        w.textElement("summary", label(locale, "External reference status", "外部参考状态"),
            attrs: [htmlClass("cj-disclosure__summary")])
        w.open("ul", attrs: [htmlClass("cj-external__list")])
        for (value in failures) { appendExternalReference(w, value, rootPrefix, locale) }
        w.close("ul")
        w.close("details")
        return
    }
    for (value in failures) {
        w.open("p", attrs: [htmlClass("cj-external__note")])
        w.textElement("strong", value.name)
        w.text(" · " + externalReferenceStatus(value, locale) + " · ")
        w.open("a", attrs: [htmlClass("cj-external__note-link"),
            htmlHref(SafeUrl.fragment("external-reference-status"))])
        w.text(label(locale, "Reference details", "参考详情"))
        w.close("a")
        w.close("p")
    }
}

protected func appendExternalDocumentationMarkdown(out: RenderTextBuffer,
    documentation: DocumentationSet, symbol: SymbolDoc, locale: String, pagePath: String,
    headingPrefix!: String = "####"): Unit {
    var opened = false
    for (value in documentation.externalDocumentation where value.symbolId == symbol.id) {
        if (!opened) {
            out.append(headingPrefix + " " + label(locale, "External documentation", "外部文档") + "\n\n")
            opened = true
        }
        out.append("- **")
        appendEscapedMarkdownText(out, value.name.replace("\r", " ").replace("\n", " ").replace("\t", " "))
        out.append("** ")
        if (value.state == "available") {
            if (let Some(encoded) <- markdownLinkDestination(value.url, allowRelative: true)) {
                let destination = if (value.url.startsWith("./")) {
                    encodeMarkdownDestination(markdownRelativeDestination(value.url.removePrefix("./"), pagePath))
                } else { encoded }
                out.append("[" + label(locale, "Open external reference", "打开外部参考") + "](" + destination + ")")
            }
        } else {
            out.append(if (value.state == "ambiguous") {
                label(locale, "Ambiguous reference", "引用不明确")
            } else { label(locale, "No external reference", "无外部参考") })
            out.append(" — ")
            appendEscapedMarkdownText(out, value.reason.replace("\r", " ").replace("\n", " ").replace("\t", " "))
        }
        for ((key, text) in [("version", value.version), ("index", value.index),
            ("format", value.format), ("fingerprint", value.fingerprint)]) {
            if (!text.isEmpty()) {
                out.append("; " + key + ": ")
                appendMarkdownCodeSpan(out, text.replace("\r", " ").replace("\n", " ").replace("\t", " "))
            }
        }
        out.append("\n")
    }
    if (opened) { out.append("\n") }
}
