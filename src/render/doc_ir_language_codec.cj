package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

internal func appendDocumentationLanguageOptions(out: StringBuilder, value: DocumentationLanguageOptions): Unit {
    out.append("{\"defaultLanguage\":${escapeJsonString(value.defaultLanguage)},\"languages\":")
    appendStrings(out, value.languages)
    out.append(",\"missingTranslation\":${escapeJsonString(value.missingTranslation)}}")
}

internal func appendDocumentationTexts(out: StringBuilder, values: ReadOnlyList<DocumentationText>): Unit {
    out.append("[")
    var first = true
    for (value in values) {
        if (!first) { out.append(",") }; first = false
        out.append("{\"fieldId\":${escapeJsonString(value.fieldId)},\"kind\":${escapeJsonString(value.kind)},\"subject\":${escapeJsonString(value.subject)},")
        out.append("\"language\":${nullableString(value.language)},\"text\":${escapeJsonString(value.text)},\"markdown\":")
        appendMarkdown(out, value.markdown)
        out.append(",\"source\":")
        match (value.source) { case Some(source) => appendRange(out, source); case None => out.append("null") }
        out.append(",\"state\":${escapeJsonString(value.state)},\"referenceState\":${escapeJsonString(value.referenceState)},")
        out.append("\"targetSymbolId\":${nullableString(value.targetSymbolId)},\"directives\":${escapeJsonString(value.directives)}}")
    }
    out.append("]")
}

internal func optionalDocumentationLanguage(node: ?JsonNode, path: String): ?String {
    match (node) {
        case None => None
        case Some(value) => if (value.isNull) { None } else {
            let language = value.asString()
            if (documentationLanguage(language) != language) { fail(path, "language must be normalized") }
            Some(language)
        }
    }
}

internal func decodeDocumentationLanguageOptions(node: ?JsonNode, path: String): ?DocumentationLanguageOptions {
    match (node) {
        case None => None
        case Some(value) =>
            let object = strictObject(value, path, ["defaultLanguage", "languages", "missingTranslation"])
            Some(DocumentationLanguageOptions(stringAt(object, "defaultLanguage", path),
                languages: stringsAt(object, "languages", path),
                missingTranslation: stringAt(object, "missingTranslation", path)))
    }
}

internal func decodeOptionalDocumentationMarkdown(node: ?JsonNode, path: String,
    assets: HashMap<String, String>): ?MarkdownNode {
    match (node) {
        case None => None
        case Some(value) => Some(decodeMarkdown(value, path + ".descriptionMarkdown", 0, false, assets))
    }
}

internal func decodeDocumentationTexts(node: ?JsonNode, path: String,
    assets: HashMap<String, String>): Array<DocumentationText> {
    if (node.isNone()) { return [] }
    let result = ArrayList<DocumentationText>()
    var index: Int64 = 0
    for (value in jsonArrayValues(node.getOrThrow().asArray())) {
        let field = path + ".localizedTexts[" + index.toString() + "]"
        let object = strictObject(value, field, ["fieldId", "kind", "subject", "language", "text",
            "markdown", "source", "state", "referenceState", "targetSymbolId", "directives"])
        let sourceNode = required(object, "source", field)
        result.add(DocumentationText(stringAt(object, "fieldId", field), stringAt(object, "kind", field),
            stringAt(object, "subject", field), optionalDocumentationLanguage(Some(required(object, "language", field)), field),
            stringAt(object, "text", field), decodeMarkdown(required(object, "markdown", field), field + ".markdown", 0, false, assets),
            source: if (sourceNode.isNull) { None } else { Some(decodeRange(sourceNode, field + ".source")) },
            state: stringAt(object, "state", field), referenceState: stringAt(object, "referenceState", field),
            targetSymbolId: nullableStringAt(object, "targetSymbolId", field), directives: stringAt(object, "directives", field)))
        index++
    }
    result.toArray()
}

internal func consumeDocumentationTexts(value: DocComment, path: String, depth: Int64,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeOptionalString(value.defaultLanguage, path + ".defaultLanguage")
    budget.consumeCollection(value.localizedTexts.size, path + ".localizedTexts", depth: depth + 1)
    for (field in value.localizedTexts) {
        let prefix = path + ".localizedTexts"
        budget.consumeObject(prefix, depth: depth + 2, fields: 12)
        for ((key, text) in [("fieldId", field.fieldId), ("kind", field.kind), ("subject", field.subject),
            ("text", field.text), ("state", field.state), ("referenceState", field.referenceState), ("directives", field.directives)]) {
            budget.consumeString(text, prefix + "." + key)
        }
        budget.consumeOptionalString(field.language, prefix + ".language")
        budget.consumeOptionalString(field.targetSymbolId, prefix + ".targetSymbolId")
        match (field.source) {
            case Some(source) => consumeRangeEncoding(source, prefix + ".source", budget)
            case None => budget.consumeBytes(4, prefix + ".source")
        }
        consumeMarkdownEncoding(field.markdown, prefix + ".markdown", 0, depth + 3, budget)
    }
}
