package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func appendDocumentationMetadata(out: StringBuilder, value: DocumentationMetadata): Unit {
    out.append("{\"groups\":[")
    var first = true
    for (group in value.groups) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"moduleId\":${escapeJsonString(group.moduleId)},")
        out.append("\"packageName\":${escapeJsonString(group.packageName)},")
        out.append("\"ownerId\":${nullableString(group.ownerId)},")
        out.append("\"id\":${escapeJsonString(group.id)},\"title\":${escapeJsonString(group.title)},")
        out.append("\"titles\":")
        appendDocumentationMetadataTitles(out, group.titles)
        out.append(",\"order\":")
        match (group.order) {
            case Some(order) => out.append(order.toString())
            case None => out.append("null")
        }
        out.append("}")
    }
    out.append("],\"tags\":[")
    first = true
    for (tag in value.tags) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"moduleId\":${escapeJsonString(tag.moduleId)},")
        out.append("\"id\":${escapeJsonString(tag.id)},\"title\":${escapeJsonString(tag.title)},")
        out.append("\"titles\":")
        appendDocumentationMetadataTitles(out, tag.titles)
        out.append("}")
    }
    out.append("]}")
}

private func appendDocumentationMetadataTitles(out: StringBuilder,
    titles: ReadOnlyList<DocumentationTitle>): Unit {
    out.append("[")
    var first = true
    for (title in titles) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"language\":${escapeJsonString(title.language)},")
        out.append("\"title\":${escapeJsonString(title.title)}}")
    }
    out.append("]")
}

internal func decodeDocumentationMetadata(node: JsonNode, path: String): DocumentationMetadata {
    let value = strictObject(node, path, ["groups", "tags"])
    let groupNodes = try { arrayAt(value, "groups", path) } catch (_: Exception) {
        fail("${path}.groups", "expected array")
    }
    if (groupNodes.size() > 2048) { fail("${path}.groups", "metadata definition limit exceeded") }
    let groups = ArrayList<DocumentationGroupDefinition>()
    for (item in jsonArrayValues(groupNodes)) {
        let itemPath = "${path}.groups[${groups.size}]"
        let group = strictObject(item, itemPath,
            ["moduleId", "packageName", "ownerId", "id", "title", "titles", "order"])
        let ownerId = nullableStringAt(group, "ownerId", itemPath)
        let orderNode = required(group, "order", itemPath)
        let order: ?Int64 = if (orderNode.isNull) { None } else {
            try { Some(orderNode.asInt64()) } catch (_: Exception) {
                fail("${itemPath}.order", "expected integer or null")
            }
        }
        let titles = decodeDocumentationMetadataTitles(required(group, "titles", itemPath),
            "${itemPath}.titles")
        try {
            groups.add(DocumentationGroupDefinition(stringAt(group, "moduleId", itemPath),
                stringAt(group, "packageName", itemPath), stringAt(group, "id", itemPath),
                stringAt(group, "title", itemPath), ownerId: ownerId, titles: titles, order: order))
        } catch (error: IllegalArgumentException) {
            fail(itemPath, error.message)
        }
    }

    let tagNodes = try { arrayAt(value, "tags", path) } catch (_: Exception) {
        fail("${path}.tags", "expected array")
    }
    if (tagNodes.size() > 2048) { fail("${path}.tags", "metadata definition limit exceeded") }
    let tags = ArrayList<DocumentationTagDefinition>()
    for (item in jsonArrayValues(tagNodes)) {
        let itemPath = "${path}.tags[${tags.size}]"
        let tag = strictObject(item, itemPath, ["moduleId", "id", "title", "titles"])
        let titles = decodeDocumentationMetadataTitles(required(tag, "titles", itemPath),
            "${itemPath}.titles")
        try {
            tags.add(DocumentationTagDefinition(stringAt(tag, "moduleId", itemPath),
                stringAt(tag, "id", itemPath), stringAt(tag, "title", itemPath), titles: titles))
        } catch (error: IllegalArgumentException) {
            fail(itemPath, error.message)
        }
    }
    try {
        DocumentationMetadata(groups: groups.toArray(), tags: tags.toArray())
    } catch (error: IllegalArgumentException) {
        fail(path, error.message)
    }
}

private func decodeDocumentationMetadataTitles(node: JsonNode, path: String): Array<DocumentationTitle> {
    let values = try { node.asArray() } catch (_: Exception) { fail(path, "expected array") }
    if (values.size() > 2) { fail(path, "at most two translated titles are permitted") }
    let titles = ArrayList<DocumentationTitle>()
    for (item in jsonArrayValues(values)) {
        let itemPath = "${path}[${titles.size}]"
        let value = strictObject(item, itemPath, ["language", "title"])
        try {
            titles.add(DocumentationTitle(stringAt(value, "language", itemPath),
                stringAt(value, "title", itemPath)))
        } catch (error: IllegalArgumentException) {
            fail(itemPath, error.message)
        }
    }
    titles.toArray()
}
