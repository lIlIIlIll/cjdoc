protected package cjdoc.render.publication

import yjson.*

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
