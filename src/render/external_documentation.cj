package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func appendExternalDocumentation(out: StringBuilder,
    values: ReadOnlyList<ExternalDocumentationReference>, includeSymbolId!: Bool = true): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }; first = false
        out.append("{")
        if (includeSymbolId) { out.append("\"symbolId\":${escapeJsonString(value.symbolId)},") }
        out.append("\"name\":${escapeJsonString(value.name)},\"state\":${escapeJsonString(value.state)},\"url\":${escapeJsonString(value.url)},")
        out.append("\"reason\":${escapeJsonString(value.reason)},\"version\":${escapeJsonString(value.version)},\"index\":${escapeJsonString(value.index)},\"format\":${escapeJsonString(value.format)},\"fingerprint\":${escapeJsonString(value.fingerprint)}}")
    }
    out.append("]")
}

internal func appendSearchExternalDocumentation(out: RenderTextBuffer, documentation: DocumentationSet,
    symbolId: String): Unit {
    let references = ArrayList<ExternalDocumentationReference>()
    for (value in documentation.externalDocumentation where value.symbolId == symbolId) { references.add(value) }
    if (references.isEmpty()) { return }
    let data = StringBuilder()
    appendExternalDocumentation(data, references, includeSymbolId: false)
    out.append(", \"externalDocs\": " + data.toString())
}

internal func decodeExternalDocumentation(node: ?JsonNode): Array<ExternalDocumentationReference> {
    if (node.isNone()) { return [] }
    let values = ArrayList<ExternalDocumentationReference>()
    for (item in jsonArrayValues(node.getOrThrow().asArray())) {
        let path = "$.externalDocumentation[]"
        let object = strictObject(item, path, ["symbolId", "name", "state", "url", "reason", "version", "index", "format", "fingerprint"])
        values.add(ExternalDocumentationReference(stringAt(object, "symbolId", path), stringAt(object, "name", path),
            stringAt(object, "state", path), stringAt(object, "url", path), reason: stringAt(object, "reason", path),
            version: stringAt(object, "version", path), index: stringAt(object, "index", path),
            format: stringAt(object, "format", path), fingerprint: stringAt(object, "fingerprint", path)))
    }
    values.toArray()
}

private func externalReferenceIdentity(value: ExternalDocumentationReference): String {
    value.name + "|" + value.state + "|" + value.reason + "|" + value.version + "|" +
        value.index + "|" + value.format + "|" + value.fingerprint
}

private func externalReferenceStatus(value: ExternalDocumentationReference, locale: String): String {
    if (value.state == "ambiguous") { label(locale, "Ambiguous reference", "引用不明确") }
    else { label(locale, "No external reference", "无外部参考") }
}

private func appendExternalReference(out: RenderTextBuffer, value: ExternalDocumentationReference,
    locale: String): Unit {
    out.append("<li><strong>" + escapeHtml(value.name) + "</strong> ")
    if (value.state == "available") {
        let url = if (value.url.startsWith("./")) { "../" + value.url.removePrefix("./") } else { value.url }
        out.append("<a rel=\"noreferrer\" href=\"" + escapeHtml(url) + "\">" +
            label(locale, "Open external reference", "打开外部参考") + "</a>")
    } else {
        out.append("<span class=\"badge\" data-state=\"" + value.state + "\">" +
            externalReferenceStatus(value, locale) + "</span> " + escapeHtml(value.reason))
    }
    for ((key, text) in [("version", value.version), ("index", value.index),
        ("format", value.format), ("fingerprint", value.fingerprint)]) {
        if (!text.isEmpty()) { out.append(" <span class=\"binding-meta\">" + key + ": " + escapeHtml(text) + "</span>") }
    }
    out.append("</li>")
}

internal func externalDocumentationHtml(documentation: DocumentationSet, symbol: SymbolDoc,
    locale: String, relatedSymbolIds!: HashSet<String> = HashSet<String>(),
    compactUnavailable!: Bool = false): String {
    let out = RenderTextBuffer()
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
            let heading = if (compactUnavailable) { "h3" } else { "h2" }
            out.append("<section class=\"external-documentation\"><" + heading + ">" +
                label(locale, "External documentation", "外部文档") + "</" + heading + "><ul>")
            opened = true
        }
        appendExternalReference(out, value, locale)
    }
    if (opened) { out.append("</ul></section>") }
    if (compactUnavailable) {
        for (value in failures) {
            out.append("<p class=\"external-reference-note\"><strong>" + escapeHtml(value.name) + "</strong> · " +
                externalReferenceStatus(value, locale) + " · <a href=\"#external-reference-status\">" +
                label(locale, "Reference details", "参考详情") + "</a></p>")
        }
    } else if (!failures.isEmpty()) {
        out.append("<details class=\"external-reference-status\" id=\"external-reference-status\"><summary>" +
            label(locale, "External reference status", "外部参考状态") + "</summary><ul>")
        for (value in failures) { appendExternalReference(out, value, locale) }
        out.append("</ul></details>")
    }
    out.toString()
}

internal func appendExternalDocumentationMarkdown(out: RenderTextBuffer,
    documentation: DocumentationSet, symbol: SymbolDoc, locale: String, pagePath: String): Unit {
    var opened = false
    for (value in documentation.externalDocumentation where value.symbolId == symbol.id) {
        if (!opened) {
            out.append("#### " + label(locale, "External documentation", "外部文档") + "\n\n")
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
