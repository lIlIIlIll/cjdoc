package cjdoc.render

import cjdoc.model.*
import yjson.*

protected func capturedDeclarationClassification(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): DeclarationClassification {
    match (symbol) {
        case Some(value) =>
            let captured = match (context.findDeclaration(value.id)) {
                case Some(found) => found
                case None => throw IllegalArgumentException(
                    "classification target is absent from the captured publication")
            }
            context.projection.catalog.classificationFor(captured)
        case None => EMPTY_DECLARATION_CLASSIFICATION
    }
}

/** JSON-object consumers reuse the captured values without a serialize/parse copy. */
protected func declarationClassificationJsonNode(value: DeclarationClassification): JsonObject {
    let result = JsonObject()
    match (value.group) {
        case Some(group) =>
            let node = JsonObject()
            node.put("id", JsonNode.string(group.id))
            node.put("packageName", JsonNode.string(group.packageName))
            node.put("ownerId", match (group.ownerId) {
                case Some(id) => JsonNode.string(id)
                case None => JsonNode.nullValue
            })
            node.put("title", JsonNode.string(group.title))
            node.put("order", match (group.order) {
                case Some(order) => JsonNode.int64(order)
                case None => JsonNode.nullValue
            })
            result.put("group", node)
        case None => result.put("group", JsonNode.nullValue)
    }
    let tags = JsonArray()
    for (tag in value.tags) {
        let node = JsonObject()
        node.put("id", JsonNode.string(tag.id))
        node.put("title", JsonNode.string(tag.title))
        tags.add(node)
    }
    result.put("tags", tags)
    result
}

protected func capturedDeclarationClassificationNode(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): JsonObject {
    declarationClassificationJsonNode(capturedDeclarationClassification(context, symbol))
}

internal func appendDeclarationClassificationMarkdown(out: RenderTextBuffer,
    value: DeclarationClassification, locale: String): Unit {
    if (let Some(group) <- value.group) {
        out.append(label(locale, "API group: ", "接口分组："))
        appendMarkdownCodeSpan(out, group.id)
        out.append(" · ")
        appendEscapedMarkdownText(out, group.title)
        out.append("\n\n")
    }
    if (value.tags.isEmpty()) { return }
    out.append(label(locale, "Tags: ", "标签："))
    var first = true
    for (tag in value.tags) {
        if (!first) { out.append(", ") }
        first = false
        appendMarkdownCodeSpan(out, tag.id)
        if (tag.title != tag.id) {
            out.append(" · ")
            appendEscapedMarkdownText(out, tag.title)
        }
    }
    out.append("\n\n")
}

protected func capturedDeclarationClassificationMarkdown(context: DocumentationReadSnapshot,
    symbol: ?SymbolDoc): String {
    let out = RenderTextBuffer()
    appendDeclarationClassificationMarkdown(out,
        capturedDeclarationClassification(context, symbol), context.locale)
    out.toString()
}
