protected package cjdoc.render.codec

import cjdoc.model.ExternalDocumentationReference
import std.collection.*
import yjson.*

protected func appendExternalDocumentation(out: StringBuilder,
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
