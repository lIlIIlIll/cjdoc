package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// Structured chapters retain the frozen Doc IR records. In particular, binding
// syntax stays in sourceApiSignature rather than being guessed from a header.
internal func queryChapters(symbol: query_model.SymbolDoc, selected: ArrayList<String>,
    input: QuerySnapshotInput, mandatory: ArrayList<String>): ArrayList<QueryChapter> {
    let chapters = ArrayList<QueryChapter>()
    let raw = input.symbolNodes[symbol.id]
    for (name in selected) {
        let (state, value) = queryCapturedChapter(name, symbol, raw, input)
        let chapter = QueryChapter(name, state, value, mandatory.contains(name))
        if (name == "diagnostics") { chapter.rendered = queryDiagnosticText(value.asArray()) }
        chapters.add(chapter)
    }
    chapters
}

private func queryDiagnosticText(values: JsonArray): String {
    let out = StringBuilder()
    out.append("## Diagnostics\n\n")
    for (index in 0..values.size()) {
        let node = values[index].asObject()
        out.append("- " + queryString(node, "severity") + " [" + queryString(node, "code") +
            "]: " + queryString(node, "message") + "\n")
    }
    if (values.size() == 0) { out.append("No captured diagnostic is bound to this declaration.\n") }
    out.append("\n")
    out.toString()
}

private func queryCapturedChapter(name: String, symbol: query_model.SymbolDoc,
    raw: JsonObject, input: QuerySnapshotInput): (String, JsonNode) {
    match (name) {
        case "signature" =>
            let node = queryCopyCapturedFields(raw,
                ["headerSpelling", "sourceApiSignature", "genericParameters", "semantic"])
            (if (symbol.headerSpelling.trimAscii().isEmpty()) { "missing" } else { "available" }, node)
        case "parameters" =>
            let node = queryCopyCapturedFields(raw, ["parameters"])
            let tags = queryCapturedTags(raw, "parameters")
            node.put("documentationTags", tags)
            (if (!symbol.parameters.isEmpty() || tags.size() > 0) { "available" } else { "missing" }, node)
        case "returns" =>
            let node = queryCopyCapturedFields(raw, ["returnType"])
            let tags = queryCapturedTags(raw, "returns")
            node.put("documentationTags", tags)
            (if (symbol.returnType.isSome() || tags.size() > 0) { "available" } else { "missing" }, node)
        case "contracts" | "examples" =>
            let tags = queryCapturedTags(raw, name)
            (if (tags.size() > 0) { "available" } else { "missing" }, tags)
        case "description" => queryCapturedDescription(raw)
        case "relations" =>
            let value = queryCapturedRelations(input, symbol)
            let references = queryCapturedTags(raw, "relations")
            value.put("documentationReferences", references)
            let any = symbol.ownerId.isSome() || !symbol.typeRelationships.isEmpty() ||
                !symbol.symbolRelationships.isEmpty() || input.importContexts.size() > 0 || references.size() > 0
            (if (any) { "available" } else { "missing" }, value)
        case "source" => ("available", querySymbolSource(input, symbol))
        case "diagnostics" => queryCapturedDiagnostics(input, symbol.id)
        case "validation" | "diff" =>
            let kind = if (name == "validation") { "validation" } else { "api-diff" }
            let report = queryEvidenceReport(input, kind)
            let state = match (queryString(report, "state")) {
                case "attached" => "available"
                case "not_attached" => "missing"
                case _ => "unavailable"
            }
            (state, report)
        case _ => ("missing", JsonNode.nullValue)
    }
}

private func queryCopyCapturedFields(raw: JsonObject, fields: Array<String>): JsonObject {
    let node = JsonNode.object()
    for (field in fields) {
        node.put(field, raw.get(field).getOrDefault({ => JsonNode.nullValue }))
    }
    node
}

private func queryCapturedTags(raw: JsonObject, section: String): JsonArray {
    let values = JsonNode.array()
    let comment = raw.get("documentation").getOrDefault({ => JsonNode.nullValue })
    if (comment.isNull) { return values }
    let tags = comment.asObject().get("tags").getOrDefault({ => JsonNode.array() }).asArray()
    for (index in 0..tags.size()) {
        let tag = tags[index].asObject()
        let name = queryString(tag, "name")
        let selected = match (section) {
            case "parameters" => name == "param"
            case "returns" => name == "return" || name == "returns"
            case "contracts" => query_render.isCallContractTag(name)
            case "examples" => name == "example"
            case "relations" => name == "see" ||
                !tag.get("navigation").getOrDefault({ => JsonNode.nullValue }).isNull
            case _ => false
        }
        if (selected) { values.add(tag) }
    }
    values
}

private func queryCapturedDescription(raw: JsonObject): (String, JsonNode) {
    let comment = raw.get("documentation").getOrDefault({ => JsonNode.nullValue })
    if (comment.isNull) { return ("missing", JsonNode.nullValue) }
    let captured = comment.asObject()
    let node = queryCopyCapturedFields(captured,
        ["summary", "description", "markdown", "defaultLanguage"])
    let localized = JsonNode.array()
    let texts = captured.get("localizedTexts").getOrDefault({ => JsonNode.array() }).asArray()
    for (index in 0..texts.size()) {
        let kind = queryString(texts[index].asObject(), "kind")
        if (kind == "summary" || kind == "description") { localized.add(texts[index]) }
    }
    node.put("localizedTexts", localized)
    var available = !queryString(captured, "summary").trimAscii().isEmpty() ||
        !queryString(captured, "description").trimAscii().isEmpty()
    if (let Some(markdown) <- captured.get("markdown")) {
        if (!markdown.isNull) {
            let children = markdown.asObject().get("children")
            if (let Some(values) <- children) { available = available || values.asArray().size() > 0 }
        }
    }
    if (available) { ("available", node) } else { ("missing", JsonNode.nullValue) }
}

private func queryCapturedDiagnostics(input: QuerySnapshotInput, symbolId: String): (String, JsonNode) {
    let values = JsonNode.array()
    let diagnostics = input.raw.get("diagnostics").getOrDefault({ => JsonNode.array() }).asArray()
    for (index in 0..diagnostics.size()) {
        let diagnostic = diagnostics[index].asObject()
        if (queryString(diagnostic, "symbolId") == symbolId) { values.add(diagnostic) }
    }
    (if (values.size() > 0) { "available" } else { "missing" }, values)
}
