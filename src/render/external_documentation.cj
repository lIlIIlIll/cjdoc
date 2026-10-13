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

internal func externalDocumentationHtml(documentation: DocumentationSet, symbol: SymbolDoc,
    locale: String): String {
    let out = RenderTextBuffer()
    var opened = false
    for (value in documentation.externalDocumentation where value.symbolId == symbol.id) {
        if (!opened) { out.append("<section class=\"external-documentation\"><h2>" + label(locale, "External documentation", "外部文档") + "</h2><ul>"); opened = true }
        out.append("<li><strong>" + escapeHtml(value.name) + "</strong> ")
        if (value.state == "available") {
            let url = if (value.url.startsWith("./")) { "../" + value.url.removePrefix("./") } else { value.url }
            out.append("<a rel=\"noreferrer\" href=\"" + escapeHtml(url) + "\">" + label(locale, "Open external reference", "打开外部参考") + "</a>")
        } else {
            let status = if (value.state == "ambiguous") {
                label(locale, "Ambiguous reference", "引用不明确")
            } else { label(locale, "No external reference", "无外部参考") }
            out.append("<span class=\"badge\" data-state=\"" + value.state + "\">" + status + "</span> " + escapeHtml(value.reason))
        }
        for ((key, text) in [("version", value.version), ("index", value.index), ("format", value.format), ("fingerprint", value.fingerprint)]) {
            if (!text.isEmpty()) { out.append(" <span class=\"binding-meta\">" + key + ": " + escapeHtml(text) + "</span>") }
        }
        out.append("</li>")
    }
    if (opened) { out.append("</ul></section>") }
    out.toString()
}
