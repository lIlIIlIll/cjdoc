package cjdoc

import cjdoc.model.{docReferenceScopeHead, normalizeTypeSpelling, parseDocReference, referenceKindTakesSignature}
import std.collection.*

private func referenceSignatureMatches(symbol: SymbolDoc, parameterTypes: ArrayList<String>): Bool {
    if (!referenceKindTakesSignature(symbol.kind) || symbol.parameters.size != parameterTypes.size) { return false }
    var index: Int64 = 0
    while (index < parameterTypes.size) {
        let typeRef = symbol.parameters[index].typeRef
        let expected = parameterTypes[index]
        let displayMatches = normalizeTypeSpelling(typeRef.display) == expected
        let canonicalMatches = match (typeRef.canonical) {
            case Some(canonical) => typeRef.state == "resolved" && normalizeTypeSpelling(canonical) == expected
            case None => false
        }
        if (!displayMatches && !canonicalMatches) { return false }
        index++
    }
    true
}

private func addToIndex(index: HashMap<String, ArrayList<SymbolDoc>>, key: String,
    symbol: SymbolDoc): Unit {
    match (index.get(key)) {
        case Some(values) => values.add(symbol)
        case None =>
            let values = ArrayList<SymbolDoc>()
            values.add(symbol)
            index[key] = values
    }
}

// Exact index only: no import expansion, alias expansion, implicit conversion,
// or compiler overload-resolution behavior is reimplemented here.
class DeclarationIndex {
    private let byId = HashMap<String, ArrayList<SymbolDoc>>()
    private let byQualifiedName = HashMap<String, ArrayList<SymbolDoc>>()
    private let bySimpleName = HashMap<String, ArrayList<SymbolDoc>>()

    public init(documentation: DocumentationSet) {
        for (symbol in documentation.symbols) {
            addToIndex(byId, symbol.id, symbol)
            addToIndex(byQualifiedName, symbol.qualifiedName, symbol)
            addToIndex(bySimpleName, symbol.name, symbol)
        }
    }

    public func genericReference(owner: SymbolDoc, reference: String): Bool {
        let name = docReferenceScopeHead(reference)
        var current: ?SymbolDoc = Some(owner)
        while (let Some(value) <- current) {
            for (parameter in value.genericParameters) { if (parameter == name) { return true } }
            current = None
            if (let Some(id) <- value.ownerId) {
                if (let Some(parents) <- byId.get(id)) {
                    if (parents.size == 1) { current = Some(parents[0]) }
                }
            }
        }
        false
    }

    public func matches(reference: String): ArrayList<SymbolDoc> {
        if (let Some(exact) <- byId.get(reference)) {
            let result = ArrayList<SymbolDoc>()
            result.add(all: exact)
            return result
        }
        let parsed = parseDocReference(reference)
        let candidates = match (byQualifiedName.get(parsed.name)) {
            case Some(values) => values
            case None =>
                match (bySimpleName.get(parsed.name)) {
                    case Some(values) => values
                    case None => return ArrayList<SymbolDoc>()
                }
        }
        let result = ArrayList<SymbolDoc>()
        for (symbol in candidates) {
            if (!parsed.hasSignature || referenceSignatureMatches(symbol, parsed.parameterTypes)) {
                result.add(symbol)
            }
        }
        result
    }
}

func docReferenceMatches(documentation: DocumentationSet, reference: String): ArrayList<SymbolDoc> {
    DeclarationIndex(documentation).matches(reference)
}

func resolveDocReference(documentation: DocumentationSet, reference: String): ?SymbolDoc {
    let matches = docReferenceMatches(documentation, reference)
    if (matches.size == 1) { Some(matches[0]) } else { None }
}

private func resolveDocTagReferences(tags: ArrayList<DocTag>, owner: SymbolDoc, index: DeclarationIndex): Unit {
    for (reference in tags) {
        reference.targetSymbolId = None
        if (reference.subject.isEmpty()) {
            reference.referenceState = "broken"
            continue
        }
        if (index.genericReference(owner, reference.subject)) {
            reference.referenceState = "unresolved"
            continue
        }
        let matches = index.matches(reference.subject)
        if (matches.size == 1) {
            reference.referenceState = "resolved"
            reference.targetSymbolId = Some(matches[0].id)
        } else if (matches.isEmpty()) {
            reference.referenceState = "unresolved"
        } else {
            reference.referenceState = "ambiguous"
        }
    }
}

private func resolveReplacementReference(comment: DocComment, owner: SymbolDoc, index: DeclarationIndex): Unit {
    if (comment.replacements.size != 1) { return }
    let tag = comment.replacements[0]
    if (tag.subject.isEmpty() || !tag.description.isEmpty()) { return }
    resolveDocTagReferences(comment.replacements, owner, index)
    if (tag.targetSymbolId == Some(owner.id)) {
        tag.referenceState = "broken"
        tag.targetSymbolId = None
    }
}

func resolveDocumentationReferences(documentation: DocumentationSet): Unit {
    let index = DeclarationIndex(documentation)
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            resolveReplacementReference(comment, symbol, index)
            if (comment.languageItems.isEmpty()) {
                resolveDocTagReferences(comment.see, symbol, index)
                resolveDocTagReferences(comment.throwsTags, symbol, index)
            }
            let localized = ArrayList<DocTag>()
            for (item in comment.languageItems) {
                if (item.tag.name == "see" || item.tag.name == "throws") { localized.add(item.tag) }
            }
            resolveDocTagReferences(localized, symbol, index)
        }
    }
}

func resolvedReferenceTarget(documentation: DocumentationSet, reference: DocTag): ?SymbolDoc {
    if (reference.referenceState != "resolved") { return None }
    if (let Some(targetId) <- reference.targetSymbolId) {
        var found: ?SymbolDoc = None
        for (symbol in documentation.symbols) {
            if (symbol.id != targetId) { continue }
            if (found.isSome()) { return None }
            found = Some(symbol)
        }
        return found
    }
    None
}
