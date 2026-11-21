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

private func sourceAnnotationSpace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n'
}

// The marker is an annotation name, not a prefix: `@DeprecatedSoon` and any
// provider spelling stay ordinary annotations rather than deprecation evidence.
// `None` means "not the marker"; `Some(open)` is the bracket position, or the
// spelling size when the annotation has no argument list. Both the status test
// and the message reader share this single boundary scan.
private func sourceDeprecatedOpen(spelling: String): ?Int64 {
    let value = spelling.trimAscii()
    if (!value.startsWith("@Deprecated")) { return None }
    var index: Int64 = 11
    if (index < value.size && value[index] != b'[' && !sourceAnnotationSpace(value[index])) {
        return None
    }
    while (index < value.size && sourceAnnotationSpace(value[index])) { index++ }
    if (index < value.size && value[index] != b'[') { return None }
    Some(index)
}

private func sourceAnnotationIdentifierStart(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || byte == b'_'
}

private func sourceAnnotationIdentifierByte(byte: Byte): Bool {
    sourceAnnotationIdentifierStart(byte) || (byte >= b'0' && byte <= b'9')
}

private func skipSourceAnnotationSpace(value: String, start: Int64, end: Int64): Int64 {
    var index = start
    while (index < end && sourceAnnotationSpace(value[index])) { index++ }
    index
}

private func sourceAnnotationHexDigit(byte: Byte): Int64 {
    if (byte >= b'0' && byte <= b'9') { return Int64(byte - b'0') }
    if (byte >= b'a' && byte <= b'f') { return Int64(byte - b'a') + 10 }
    if (byte >= b'A' && byte <= b'F') { return Int64(byte - b'A') + 10 }
    -1
}

private func sourceAnnotationUnicodeEscape(value: String, start: Int64): ?(Rune, Int64) {
    if (start + 1 >= value.size || value[start + 1] != b'{') { return None }
    var index = start + 2
    var code: Int64 = 0
    var digits: Int64 = 0
    while (index < value.size && value[index] != b'}') {
        let digit = sourceAnnotationHexDigit(value[index])
        if (digit < 0 || digits >= 8) { return None }
        code = code * 16 + digit
        digits++
        index++
    }
    if (index >= value.size || digits == 0) { return None }
    if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) { return None }
    Some((Rune(UInt32(code)), index + 1))
}

private func sourceAnnotationEscape(value: String, start: Int64): ?(Rune, Int64) {
    if (start + 1 >= value.size) { return None }
    let escape = value[start + 1]
    if (escape == b'u') { return sourceAnnotationUnicodeEscape(value, start + 1) }
    let decoded: Rune = match (escape) {
        case b't' => Rune(9u32)
        case b'b' => Rune(8u32)
        case b'r' => Rune(13u32)
        case b'n' => Rune(10u32)
        case b'\'' => Rune(39u32)
        case b'"' => Rune(34u32)
        case b'\\' => Rune(92u32)
        case b'f' => Rune(12u32)
        case b'v' => Rune(11u32)
        case b'0' => Rune(0u32)
        // The lexer accepts `\\$` in a string; it is not interpolation evidence.
        case b'$' => Rune(36u32)
        case _ => return None
    }
    Some((decoded, start + 2))
}

// A deprecation reason is prose, not a payload. A longer annotation stays
// source spelling and keeps the status rather than spending render time on it.
private let SOURCE_ANNOTATION_MESSAGE_LIMIT: Int64 = 64 * 1024

// Both ordinary string delimiters are literals. Triple-quoted (multiline/raw)
// forms are not, and the caller never sees their content as a reason.
private func sourceAnnotationQuote(value: String, start: Int64): ?Byte {
    if (start >= value.size) { return None }
    let delimiter = value[start]
    if (delimiter != b'"' && delimiter != b'\'') { return None }
    if (start + 2 < value.size && value[start + 1] == delimiter && value[start + 2] == delimiter) {
        return None
    }
    Some(delimiter)
}

// Only one ordinary string literal is readable. Multiline, raw, interpolated,
// concatenated and nested forms stay source spelling rather than inferred prose.
private func sourceAnnotationStringLiteral(value: String, start: Int64): ?(String, Int64) {
    let delimiter = match (sourceAnnotationQuote(value, start)) {
        case Some(value) => value
        case None => return None
    }
    var index = start + 1
    var segmentStart = index
    var decoded: ?StringBuilder = None
    while (index < value.size) {
        let byte = value[index]
        if (byte == delimiter) {
            if (let Some(out) <- decoded) {
                if (segmentStart < index) { out.append(value[segmentStart..index]) }
                return Some((out.toString(), index + 1))
            }
            return Some((value[start + 1..index], index + 1))
        }
        if (byte == b'\n' || byte == b'\r') { return None }
        if (byte == b'\\') {
            let (rune, next) = match (sourceAnnotationEscape(value, index)) {
                case Some(escape) => escape
                case None => return None
            }
            let out = match (decoded) {
                case Some(builder) => builder
                case None =>
                    let builder = StringBuilder()
                    decoded = Some(builder)
                    builder
            }
            if (segmentStart < index) { out.append(value[segmentStart..index]) }
            out.append(rune)
            index = next
            segmentStart = index
            continue
        }
        // An unescaped interpolation is code, not a literal reason.
        if (byte == b'$' && index + 1 < value.size && value[index + 1] == b'{') { return None }
        index++
    }
    None
}

private func sourceAnnotationLiteralTail(value: String, start: Int64,
    bodyEnd: Int64): ?String {
    let (message, next) = match (sourceAnnotationStringLiteral(value, start)) {
        case Some(parsed) => parsed
        case None => return None
    }
    if (skipSourceAnnotationSpace(value, next, bodyEnd) != bodyEnd) { return None }
    if (message.trimAscii().isEmpty()) { return None }
    Some(message)
}

// Read the annotation's own single literal argument, either positional or the
// explicitly named `message`. Names, brackets, quotes and separators must pair;
// a variable, expression, extra argument or trailing text is not prose.
private func sourceAnnotationMessage(value: String, open: Int64): ?String {
    if (value.size > SOURCE_ANNOTATION_MESSAGE_LIMIT) { return None }
    let bodyEnd = value.size - 1
    if (open >= value.size || value[bodyEnd] != b']') { return None }
    var cursor = skipSourceAnnotationSpace(value, open + 1, bodyEnd)
    if (cursor >= bodyEnd) { return None }
    if (value[cursor] == b'"' || value[cursor] == b'\'') {
        return sourceAnnotationLiteralTail(value, cursor, bodyEnd)
    }
    let nameStart = cursor
    if (!sourceAnnotationIdentifierStart(value[cursor])) { return None }
    while (cursor < bodyEnd && sourceAnnotationIdentifierByte(value[cursor])) { cursor++ }
    if (value[nameStart..cursor] != "message") { return None }
    cursor = skipSourceAnnotationSpace(value, cursor, bodyEnd)
    if (cursor >= bodyEnd || value[cursor] != b':') { return None }
    cursor = skipSourceAnnotationSpace(value, cursor + 1, bodyEnd)
    sourceAnnotationLiteralTail(value, cursor, bodyEnd)
}

// Only annotations captured on this declaration count; provider assertions,
// inherited members and prose mentioning the marker are not source evidence.
protected func declarationIsDeprecated(symbol: SymbolDoc): Bool {
    for (annotation in symbol.annotations where annotation.provenance == "source") {
        if (sourceDeprecatedOpen(annotation.spelling).isSome()) { return true }
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

/**
 * The readable message carried by this declaration's own source `@Deprecated`
 * annotation, or `None` when no annotation has an unambiguous literal reason.
 *
 * Author Markdown prose is preferred elsewhere; this only supplies the
 * annotation's own text when it can be restored without guessing.
 */
protected func sourceDeprecationMessage(symbol: SymbolDoc): ?String {
    var selected: ?String = None
    for (annotation in symbol.annotations where annotation.provenance == "source") {
        let value = annotation.spelling.trimAscii()
        let open = match (sourceDeprecatedOpen(value)) {
            case Some(index) => index
            case None => continue
        }
        let message = match (sourceAnnotationMessage(value, open)) {
            case Some(reason) => reason
            case None => continue
        }
        // Conflicting readable reasons are not a single fact.
        if (let Some(previous) <- selected) {
            if (previous != message) { return None }
            continue
        }
        selected = Some(message)
    }
    selected
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
