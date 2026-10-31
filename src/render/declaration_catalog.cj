package cjdoc.render

import cjdoc.model.*
import std.collection.*

protected class DeclarationTagClassification {
    let id: String
    let title: String

    init(id: String, title: String) { this.id = id; this.title = title }
}

protected class DeclarationGroupClassification {
    let id: String
    let packageName: String
    let ownerId: ?String
    let title: String
    let order: ?Int64
    let scopeKey: String
    let defined: Bool

    init(symbol: SymbolDoc, id: String, title: String, order: ?Int64, defined: Bool) {
        this.id = id
        this.packageName = symbol.packageName
        this.ownerId = symbol.ownerId
        this.title = title
        this.order = order
        this.defined = defined
        this.scopeKey = documentationMetadataGroupKey(symbol.moduleId, symbol.packageName,
            symbol.ownerId, id)
    }
}

protected class DeclarationClassification {
    let group: ?DeclarationGroupClassification
    let tags: Array<DeclarationTagClassification>
    let text: String

    init(group: ?DeclarationGroupClassification, tags: Array<DeclarationTagClassification>) {
        this.group = group
        this.tags = tags
        if (group.isNone() && tags.isEmpty()) {
            this.text = ""
        } else {
            let out = StringBuilder()
            if (let Some(value) <- group) { out.append(value.id + " " + value.title + " ") }
            for (tag in tags) { out.append(tag.id + " " + tag.title + " ") }
            this.text = out.toString()
        }
    }
}

internal let EMPTY_DECLARATION_CLASSIFICATION = DeclarationClassification(None, [])

private func selectedMetadataTitle(title: String, titles: ReadOnlyList<DocumentationTitle>,
    locale: String): String {
    for (entry in titles where entry.language == locale) { return entry.title }
    title
}

/** Captured definitions and membership; the caller supplies its existing visible set. */
internal class DeclarationGroupCatalog {
    private let definitions = HashMap<String, DocumentationGroupDefinition>()
    private let tagLabels = HashMap<String, DeclarationTagClassification>()
    private let groupLabels = HashMap<String, DeclarationGroupClassification>()
    private let classifications = HashMap<String, DeclarationClassification>()
    private let locale: String

    init(metadata: DocumentationMetadata, symbols: ArrayList<SymbolDoc>, locale: String) {
        this.locale = locale
        for (definition in metadata.groups) {
            let key = documentationMetadataGroupKey(definition.moduleId, definition.packageName,
                definition.ownerId, definition.id)
            if (definitions.contains(key)) {
                throw IllegalArgumentException("duplicate documentation group scope")
            }
            definitions[key] = definition
        }
        for (definition in metadata.tags) {
            let key = documentationMetadataTagKey(definition.moduleId, definition.id)
            if (tagLabels.contains(key)) {
                throw IllegalArgumentException("duplicate documentation tag scope")
            }
            tagLabels[key] = DeclarationTagClassification(definition.id,
                selectedMetadataTitle(definition.title, definition.titles, locale))
        }
        for (symbol in symbols) { classifications[symbol.id] = classify(symbol) }
    }

    func classificationFor(symbol: SymbolDoc): DeclarationClassification {
        classifications.get(symbol.id).getOrDefault({ => EMPTY_DECLARATION_CLASSIFICATION })
    }

    func groupFor(symbol: SymbolDoc): ?DeclarationGroupClassification {
        classificationFor(symbol).group
    }

    private func groupForComment(symbol: SymbolDoc): ?DeclarationGroupClassification {
        let comment = match (symbol.documentation) {
            case Some(value) => value
            case None => return None
        }
        let tag = match (canonicalDocumentationGroupTag(comment)) {
            case Some(value) => value
            case None => return None
        }
        let scopeKey = documentationMetadataGroupKey(symbol.moduleId, symbol.packageName,
            symbol.ownerId, tag.subject)
        let definition = definitions.get(scopeKey)
        var title = tag.description
        var order: ?Int64 = None
        if (let Some(value) <- definition) {
            title = selectedMetadataTitle(value.title, value.titles, locale)
            order = value.order
        } else if (title.isEmpty()) {
            return None
        }
        let labelKey = scopeKey + ":" + title.size.toString() + ":" + title
        match (groupLabels.get(labelKey)) {
            case Some(value) => Some(value)
            case None =>
                let value = DeclarationGroupClassification(symbol, tag.subject, title, order,
                    definition.isSome())
                groupLabels[labelKey] = value
                Some(value)
        }
    }

    private func tagFor(moduleId: String, id: String): DeclarationTagClassification {
        let key = documentationMetadataTagKey(moduleId, id)
        match (tagLabels.get(key)) {
            case Some(value) => value
            case None =>
                let value = DeclarationTagClassification(id, id)
                tagLabels[key] = value
                value
        }
    }

    private func classify(symbol: SymbolDoc): DeclarationClassification {
        let ids = documentationTagIds(symbol.documentation)
        let group = groupForComment(symbol)
        if (ids.isEmpty() && group.isNone()) { return EMPTY_DECLARATION_CLASSIFICATION }
        let tags = Array<DeclarationTagClassification>(ids.size, { index =>
            tagFor(symbol.moduleId, ids[index])
        })
        DeclarationClassification(group, tags)
    }
}

protected func appendDeclarationClassificationJson(out: StringBuilder,
    value: DeclarationClassification): Unit {
    out.append("{\"group\":")
    match (value.group) {
        case Some(group) =>
            out.append("{\"id\":" + escapeJsonString(group.id) +
                ",\"packageName\":" + escapeJsonString(group.packageName) +
                ",\"ownerId\":" + nullableString(group.ownerId) +
                ",\"title\":" + escapeJsonString(group.title) + ",\"order\":")
            match (group.order) {
                case Some(order) => out.append(order.toString())
                case None => out.append("null")
            }
            out.append("}")
        case None => out.append("null")
    }
    out.append(",\"tags\":[")
    var first = true
    for (tag in value.tags) {
        if (!first) { out.append(",") }
        first = false
        out.append("{\"id\":" + escapeJsonString(tag.id) + ",\"title\":" +
            escapeJsonString(tag.title) + "}")
    }
    out.append("]}")
}
