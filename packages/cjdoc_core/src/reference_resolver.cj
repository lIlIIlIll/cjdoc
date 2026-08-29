package cjdoc_core

import std.collection.*

private class ParsedDocReference {
    let name: String
    let hasSignature: Bool
    let parameterTypes: ArrayList<String>

    init(name: String, hasSignature: Bool) {
        this.name = name
        this.hasSignature = hasSignature
        this.parameterTypes = ArrayList<String>()
    }
}

func normalizeTypeSpelling(value: String): String {
    value.replace(" ", "").replace("\n", "").replace("\r", "").replace("\t", "")
}

private func splitReferenceParameters(value: String): ?ArrayList<String> {
    let parameters = ArrayList<String>()
    if (value.trimAscii().isEmpty()) { return Some(parameters) }
    let bytes = value.toArray()
    var start: Int64 = 0
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    var angleDepth: Int64 = 0
    var index: Int64 = 0
    while (index < bytes.size) {
        match (bytes[index]) {
            case b'(' => roundDepth++
            case b')' =>
                roundDepth--
                if (roundDepth < 0) { return None }
            case b'[' => squareDepth++
            case b']' =>
                squareDepth--
                if (squareDepth < 0) { return None }
            case b'<' => angleDepth++
            case b'>' =>
                if (index == 0 || bytes[index - 1] != b'-') {
                    angleDepth--
                    if (angleDepth < 0) { return None }
                }
            case b',' =>
                if (roundDepth == 0 && squareDepth == 0 && angleDepth == 0) {
                    let parameter = value[start..index].trimAscii()
                    if (parameter.isEmpty()) { return None }
                    parameters.add(normalizeTypeSpelling(parameter))
                    start = index + 1
                }
            case _ => ()
        }
        index++
    }
    if (roundDepth != 0 || squareDepth != 0 || angleDepth != 0) { return None }
    let parameter = value[start..value.size].trimAscii()
    if (parameter.isEmpty()) { return None }
    parameters.add(normalizeTypeSpelling(parameter))
    Some(parameters)
}

private func parseDocReference(reference: String): ParsedDocReference {
    let trimmed = reference.trimAscii()
    let bytes = trimmed.toArray()
    if (bytes.size < 3 || bytes[bytes.size - 1] != b')') { return ParsedDocReference(trimmed, false) }
    var open: Int64 = -1
    var index: Int64 = 0
    while (index < bytes.size) {
        if (bytes[index] == b'(') { open = index; break }
        index++
    }
    if (open <= 0) { return ParsedDocReference(trimmed, false) }
    let name = trimmed[..open].trimAscii()
    if (name.isEmpty()) { return ParsedDocReference(trimmed, false) }
    match (splitReferenceParameters(trimmed[open + 1..trimmed.size - 1])) {
        case Some(parameters) =>
            let parsed = ParsedDocReference(name, true)
            parsed.parameterTypes.add(all: parameters)
            parsed
        case None => ParsedDocReference(trimmed, false)
    }
}

private func supportsSignatureReference(symbol: SymbolDoc): Bool {
    symbol.kind == "function" || symbol.kind == "constructor" || symbol.kind == "enumCase"
}

private func referenceSignatureMatches(symbol: SymbolDoc, parameterTypes: ArrayList<String>): Bool {
    if (!supportsSignatureReference(symbol) || symbol.parameters.size != parameterTypes.size) { return false }
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
public class DeclarationIndex {
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

public func docReferenceMatches(documentation: DocumentationSet, reference: String): ArrayList<SymbolDoc> {
    DeclarationIndex(documentation).matches(reference)
}

public func resolveDocReference(documentation: DocumentationSet, reference: String): ?SymbolDoc {
    let matches = docReferenceMatches(documentation, reference)
    if (matches.size == 1) { Some(matches[0]) } else { None }
}

public func resolveDocumentationReferences(documentation: DocumentationSet): Unit {
    let index = DeclarationIndex(documentation)
    for (symbol in documentation.symbols) {
        if (let Some(comment) <- symbol.documentation) {
            for (reference in comment.see) {
                reference.targetSymbolId = None
                if (reference.subject.isEmpty()) {
                    reference.referenceState = "broken"
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
    }
}

public func resolvedReferenceTarget(documentation: DocumentationSet, reference: DocTag): ?SymbolDoc {
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
