protected package cjdoc.binding

import cjdoc.model as api_model
import std.collection.*
import std.sort.*

private func commentFieldSymbolLess(left: String, right: String): Bool {
    var index: Int64 = 0
    while (index < left.size && index < right.size) {
        if (left[index] != right[index]) { return left[index] < right[index] }
        index++
    }
    left.size < right.size
}

// moduleId -> (symbolId -> (fieldId -> author-ordered values)); one pass over the
// captured declarations, so publishing many fields never rescans the set.
private func commentValuesByModule(documentation: DocumentationSet,
    visibleIds: HashSet<String>): HashMap<String, HashMap<String, HashMap<String, Array<String>>>> {
    let byModule = HashMap<String, HashMap<String, HashMap<String, Array<String>>>>()
    for (symbol in documentation.symbols) {
        if (!visibleIds.contains(symbol.id)) { continue }
        let comment = match (symbol.documentation) {
            case Some(value) => value
            case None => continue
        }
        if (comment.fieldValues.isEmpty()) { continue }
        let perField = HashMap<String, ArrayList<String>>()
        for (entry in comment.fieldValues) {
            match (perField.get(entry.fieldId)) {
                case Some(values) => values.add(entry.value)
                case None =>
                    let values = ArrayList<String>()
                    values.add(entry.value)
                    perField[entry.fieldId] = values
            }
        }
        if (perField.isEmpty()) { continue }
        let symbols = match (byModule.get(symbol.moduleId)) {
            case Some(value) => value
            case None =>
                let created = HashMap<String, HashMap<String, Array<String>>>()
                byModule[symbol.moduleId] = created
                created
        }
        let fields = HashMap<String, Array<String>>()
        for (fieldId in perField.keys()) {
            fields[fieldId] = perField[fieldId].toArray()
        }
        symbols[symbol.id] = fields
    }
    byModule
}

/**
 * Freeze captured comment field values for the declarations this publication renders.
 *
 * Values stay in author order. A definition keeps only uses by visible
 * declarations, so narrowing the audience cannot leak a private declaration's
 * value through a field two modules or two visibilities share.
 */
protected func capturedCommentFields(documentation: DocumentationSet,
    visibleIds: HashSet<String>): Array<api_model.DocumentationFieldDefinition> {
    let result = ArrayList<api_model.DocumentationFieldDefinition>()
    let byModule = commentValuesByModule(documentation, visibleIds)
    for (module in documentation.modules) {
        let spec = match (documentation.commentSpecs.get(module.id)) {
            case Some(value) => value
            case None => continue
        }
        let symbols = match (byModule.get(module.id)) {
            case Some(value) => value
            case None => continue
        }
        for (field in spec.fields) {
            let uses = ArrayList<api_model.DocumentationFieldUse>()
            for (symbolId in symbols.keys()) {
                let fields = symbols[symbolId]
                match (fields.get(field.id)) {
                    case Some(values) => uses.add(api_model.DocumentationFieldUse(symbolId, values))
                    case None => ()
                }
            }
            if (uses.isEmpty()) { continue }
            sort(uses, lessThan: { left, right =>
                commentFieldSymbolLess(left.symbolId, right.symbolId)
            }, stable: true)
            result.add(api_model.DocumentationFieldDefinition(module.id, field.id,
                field.title, titles: field.titles.toArray(), repeatable: field.repeatable,
                uses: uses.toArray()))
        }
    }
    result.toArray()
}
