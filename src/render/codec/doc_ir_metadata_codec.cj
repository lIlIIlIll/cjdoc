protected package cjdoc.render.codec

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
    out.append("],\"fields\":[")
    first = true
    for (field in value.fields) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"moduleId\":${escapeJsonString(field.moduleId)},")
        out.append("\"id\":${escapeJsonString(field.id)},")
        out.append("\"title\":${escapeJsonString(field.title)},")
        out.append("\"titles\":")
        appendDocumentationMetadataTitles(out, field.titles)
        out.append(",\"repeatable\":${field.repeatable},")
        out.append("\"uses\":[")
        var firstUse = true
        for (use in field.uses) {
            if (!firstUse) { out.append(",") }
            firstUse = false
            out.append("{\"symbolId\":${escapeJsonString(use.symbolId)},\"values\":[")
            var firstValue = true
            for (item in use.values) {
                if (!firstValue) { out.append(",") }
                firstValue = false
                out.append(escapeJsonString(item))
            }
            out.append("]}")
        }
        out.append("]}")
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
    let value = strictObject(node, path, ["groups", "tags", "fields"])
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
    let fieldNodes = try { arrayAt(value, "fields", path) } catch (_: Exception) {
        fail("${path}.fields", "expected array")
    }
    if (fieldNodes.size() > 2048) { fail("${path}.fields", "metadata definition limit exceeded") }
    let fields = ArrayList<DocumentationFieldDefinition>()
    for (item in jsonArrayValues(fieldNodes)) {
        let itemPath = "${path}.fields[${fields.size}]"
        let field = strictObject(item, itemPath,
            ["moduleId", "id", "title", "titles", "repeatable", "uses"])
        let titles = decodeDocumentationMetadataTitles(required(field, "titles", itemPath),
            "${itemPath}.titles")
        let repeatableNode = required(field, "repeatable", itemPath)
        let repeatable = try {
            repeatableNode.asBool()
        } catch (_: Exception) {
            fail("${itemPath}.repeatable", "expected boolean")
        }
        let useNodes = try { arrayAt(field, "uses", itemPath) } catch (_: Exception) {
            fail("${itemPath}.uses", "expected array")
        }
        let uses = ArrayList<DocumentationFieldUse>()
        for (useItem in jsonArrayValues(useNodes)) {
            let usePath = "${itemPath}.uses[${uses.size}]"
            let use = strictObject(useItem, usePath, ["symbolId", "values"])
            let valueNodes = try { arrayAt(use, "values", usePath) } catch (_: Exception) {
                fail("${usePath}.values", "expected array")
            }
            let values = ArrayList<String>()
            for (valueNode in jsonArrayValues(valueNodes)) {
                let valuePath = "${usePath}.values[${values.size}]"
                if (valueNode.kind() != JsonKind.String) { fail(valuePath, "expected string") }
                values.add(valueNode.asString())
            }
            try {
                uses.add(DocumentationFieldUse(stringAt(use, "symbolId", usePath), values.toArray()))
            } catch (error: IllegalArgumentException) {
                fail(usePath, error.message)
            }
        }
        try {
            fields.add(DocumentationFieldDefinition(stringAt(field, "moduleId", itemPath),
                stringAt(field, "id", itemPath), stringAt(field, "title", itemPath),
                titles: titles, repeatable: repeatable, uses: uses.toArray()))
        } catch (error: IllegalArgumentException) {
            fail(itemPath, error.message)
        }
    }
    try {
        DocumentationMetadata(groups: groups.toArray(), tags: tags.toArray(),
            fields: fields.toArray())
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
