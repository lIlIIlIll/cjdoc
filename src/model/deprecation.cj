package cjdoc.model

import std.collection.*

// Shared with source binding so frozen Doc IR checks use the same selector grammar.
protected class ParsedDocReference {
    public let name: String
    public let hasSignature: Bool
    public let parameterTypes: ArrayList<String>

    init(name: String, hasSignature: Bool) {
        this.name = name
        this.hasSignature = hasSignature
        this.parameterTypes = ArrayList<String>()
    }
}

protected func normalizeTypeSpelling(value: String): String {
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

protected func parseDocReference(reference: String): ParsedDocReference {
    let trimmed = reference.trimAscii()
    if (trimmed.size < 3 || trimmed[trimmed.size - 1] != b')') { return ParsedDocReference(trimmed, false) }
    let open = trimmed.indexOf("(").getOrDefault({ => -1 })
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

protected func referenceKindTakesSignature(kind: String): Bool {
    kind == "function" || kind == "constructor" || kind == "macro" || kind == "enumCase"
}

protected func docReferenceScopeHead(reference: String): String {
    let value = reference.trimAscii()
    var end = value.size
    for (separator in [".", "(", "<"]) {
        if (let Some(position) <- value.indexOf(separator)) { end = min(end, position) }
    }
    value[..end]
}

protected func scopedGenericParameter(owner: SymbolDoc, name: String,
    index: HashMap<String, SymbolDoc>): Bool {
    var current: ?SymbolDoc = Some(owner)
    while (let Some(value) <- current) {
        for (parameter in value.genericParameters) { if (parameter == name) { return true } }
        current = value.ownerId.flatMap({ id => index.get(id) })
    }
    false
}

protected func scopedGenericReference(owner: SymbolDoc, target: String, index: HashMap<String, SymbolDoc>): Bool {
    scopedGenericParameter(owner, docReferenceScopeHead(target), index)
}

// Only annotations captured on this declaration count; provider assertions,
// inherited members and prose mentioning the marker are not source evidence.
protected func declarationIsDeprecated(symbol: SymbolDoc): Bool {
    for (annotation in symbol.annotations where annotation.provenance == "source") {
        let spelling = annotation.spelling.trimAscii()
        if (spelling == "@Deprecated" || spelling.startsWith("@Deprecated[") ||
            (spelling.startsWith("@Deprecated") && spelling[11..].trimAsciiStart().startsWith("["))) {
            return true
        }
    }
    if (let Some(comment) <- symbol.documentation) {
        for (tag in comment.tags where tag.name == "deprecated" && tag.translationState != "missing") {
            return true
        }
        for (text in comment.localizedTexts where text.kind == "deprecated" &&
            (text.state == "valid" || text.state == "empty" || text.state == "conflict")) {
            return true
        }
    }
    false
}

protected func sharedReplacementTag(tag: DocTag): Bool {
    tag.name == "replacement" && !tag.subject.isEmpty() && tag.subject == tag.subject.trimAscii() &&
        !tag.subject.contains("\n") && !tag.subject.contains("\r") &&
        tag.description.isEmpty() && tag.directives.isEmpty() && tag.entryId.isNone() &&
        tag.contentLanguage.isNone() && tag.translationState.isEmpty() && tag.fieldId.isEmpty() &&
        tag.exampleMarkdown.isNone() && tag.descriptionMarkdown.isNone()
}

// An external selection must carry its canonical, portable selector. Import
// alias expansions and manual links cannot be checked from v18 alone.
protected func replacementMatchesExternalKey(subject: String, key: String): Bool {
    let separator = key.indexOf("|").getOrDefault({ => key.size })
    if (separator == key.size) { return false }
    let name = key[..separator]
    if (!name.contains(".")) { return false }
    let selector = subject.indexOf("(").getOrDefault({ => subject.size })
    if (subject[..selector] != name) { return false }
    if (selector == subject.size) { return true }
    let signature = key.indexOf("(").getOrDefault({ => key.size })
    signature < key.size &&
        normalizeTypeSpelling(subject[selector..]) == normalizeTypeSpelling(key[signature..])
}

protected func replacementUrlWithinDocumentSet(url: String, set: DocumentSetIdentity): Bool {
    !set.baseUrl.isEmpty() && url.startsWith(set.baseUrl.removeSuffix("/") + "/")
}

// v18 does not embed the inventory rows. Retain a consistency witness for
// this occurrence's selected row and scope in the existing reason field.
// It detects conflicting persisted evidence, not a forged Doc IR producer.
protected func externalReplacementSelection(owner: SymbolDoc, subject: String, navigation: TypeNavigation): String {
    let fields = [owner.id, subject, navigation.matchLevel, navigation.dependencyInstanceId,
        navigation.documentSetId, navigation.indexIdentity, navigation.symbolKey, navigation.url,
        navigation.apiIdentity, navigation.language]
    let input = StringBuilder()
    for (field in fields) { input.append("${field.size}:${field}") }
    "selected replacement inventory entry: sha256:" + contractFingerprint(input.toString())
}
