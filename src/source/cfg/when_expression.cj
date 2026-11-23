protected package cjdoc.source.cfg

import std.collection.ArrayList

// Shared with binding so annotations such as `@Whenever` never acquire
// conditional-compilation semantics merely because their names share a prefix.
protected func isExactWhenAnnotation(annotation: String): Bool {
    let value = annotation.trimAscii()
    if (!value.startsWith("@When")) { return false }
    if (value.size == "@When".size) { return true }
    let next = value["@When".size]
    next == b'[' || next == b' ' || next == b'\t' || next == b'\r' || next == b'\n'
}

private func whenExpression(annotation: String): ?String {
    if (!isExactWhenAnnotation(annotation)) { return None }
    let value = annotation.trimAscii()
    var open = "@When".size
    while (open < value.size && (value[open] == b' ' || value[open] == b'\t' ||
        value[open] == b'\r' || value[open] == b'\n')) { open++ }
    if (open >= value.size || value[open] != b'[') { return Some("") }
    var close: Int64 = -1
    var index = open + 1
    var delimiter: UInt8 = 0u8
    var escaped = false
    while (index < value.size) {
        let byte = value[index]
        if (delimiter != 0u8) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == delimiter) {
                delimiter = 0u8
            }
        } else if (byte == b'\'' || byte == b'"') {
            delimiter = byte
        } else if (byte == b']') {
            close = index
            break
        }
        index++
    }
    if (close <= open || delimiter != 0u8) { return Some("") }
    index = close + 1
    while (index < value.size && (value[index] == b' ' || value[index] == b'\t' ||
        value[index] == b'\r' || value[index] == b'\n')) { index++ }
    if (index != value.size) { return Some("") }
    Some(value[open + 1..close].trimAscii())
}

private func cfgAnd(left: ?Bool, right: ?Bool): ?Bool {
    if (left == Some(false) || right == Some(false)) { return Some(false) }
    if (left == Some(true) && right == Some(true)) { return Some(true) }
    None
}

private func cfgOr(left: ?Bool, right: ?Bool): ?Bool {
    if (left == Some(true) || right == Some(true)) { return Some(true) }
    if (left == Some(false) && right == Some(false)) { return Some(false) }
    None
}

private class CfgExpressionParser {
    let bytes: Array<UInt8>
    let profile: CfgProfile
    var offset: Int64 = 0
    var valid = true

    init(expression: String, profile: CfgProfile) {
        this.bytes = expression.toArray()
        this.profile = profile
    }

    func skipSpaces(): Unit {
        while (offset < bytes.size && (bytes[offset] == b' ' || bytes[offset] == b'\t' ||
            bytes[offset] == b'\r' || bytes[offset] == b'\n')) { offset++ }
    }

    func consume(first: UInt8, second: UInt8): Bool {
        skipSpaces()
        if (offset + 1 < bytes.size && bytes[offset] == first && bytes[offset + 1] == second) {
            offset += 2
            return true
        }
        false
    }

    func identifier(): String {
        skipSpaces()
        let start = offset
        while (offset < bytes.size) {
            let byte = bytes[offset]
            if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
                (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'.' || byte == b'-') {
                offset++
            } else {
                break
            }
        }
        if (offset == start) {
            valid = false
            return ""
        }
        String.fromUtf8(bytes[start..offset])
    }

    func expectedValue(): ?String {
        skipSpaces()
        if (offset >= bytes.size) { return None }
        if (bytes[offset] == b'"' || bytes[offset] == b'\'') {
            let delimiter = bytes[offset]
            offset++
            let value = ArrayList<UInt8>()
            while (offset < bytes.size && bytes[offset] != delimiter) {
                if (bytes[offset] == b'\\' && offset + 1 < bytes.size) {
                    offset++
                }
                value.add(bytes[offset])
                offset++
            }
            if (offset >= bytes.size) {
                valid = false
                return None
            }
            offset++
            return Some(String.fromUtf8(value.toArray()))
        }
        let value = identifier()
        if (value == "true" || value == "false") { Some(value) } else { None }
    }

    func primary(): ?Bool {
        skipSpaces()
        if (offset < bytes.size && bytes[offset] == b'(') {
            offset++
            let value = parseOr()
            skipSpaces()
            if (offset >= bytes.size || bytes[offset] != b')') {
                valid = false
                return None
            }
            offset++
            return value
        }
        let name = identifier()
        if (!valid) { return None }
        var equals = true
        let hasComparison = if (consume(b'=', b'=')) {
            true
        } else if (consume(b'!', b'=')) {
            equals = false
            true
        } else {
            false
        }
        if (!hasComparison) {
            return match (profile.value(name)) {
                case Some(value) => if (value == "true") { Some(true) } else if (value == "false") {
                    Some(false)
                } else {
                    None
                }
                case None => None
            }
        }
        let expected = expectedValue()
        if (expected.isNone()) {
            valid = false
            return None
        }
        return match (profile.value(name)) {
            case Some(actual) => Some(if (equals) { actual == expected.getOrThrow() } else {
                actual != expected.getOrThrow()
            })
            case None => None
        }
    }

    func unary(): ?Bool {
        skipSpaces()
        if (offset < bytes.size && bytes[offset] == b'!' &&
            !(offset + 1 < bytes.size && bytes[offset + 1] == b'=')) {
            offset++
            return match (unary()) {
                case Some(value) => Some(!value)
                case None => None
            }
        }
        primary()
    }

    func parseAnd(): ?Bool {
        var value = unary()
        while (consume(b'&', b'&')) { value = cfgAnd(value, unary()) }
        value
    }

    func parseOr(): ?Bool {
        var value = parseAnd()
        while (consume(b'|', b'|')) { value = cfgOr(value, parseAnd()) }
        value
    }

    func parse(): ?Bool {
        if (bytes.isEmpty()) { return None }
        let value = parseOr()
        skipSpaces()
        if (!valid || offset != bytes.size) { return None }
        value
    }
}

// true/false are proven selections; None means the expression is malformed or
// references configuration that the selected profile does not define.
private func evaluateWhenExpression(expression: String, profile: CfgProfile): ?Bool {
    CfgExpressionParser(expression, profile).parse()
}
// Evaluate a raw @When annotation for compiler-side source rewriting. Unlike
// provider-neutral documentation filtering, executable example generation must
// know the native os/arch and default release debug selector when not supplied.
protected func compilerWhenSelection(annotation: String, profile: CfgProfile): ?Bool {
    match (whenExpression(annotation)) {
        case Some(expression) =>
            if (expression.isEmpty()) { None } else {
                evaluateWhenExpression(expression, compilerCfgProfile(profile))
            }
        case None => None
    }
}

protected func cfgSelection(annotations: ArrayList<String>, profile: CfgProfile): ?Bool {
    var selected: ?Bool = Some(true)
    for (annotation in annotations) {
        if (let Some(expression) <- whenExpression(annotation)) {
            selected = cfgAnd(selected, evaluateWhenExpression(expression, profile))
        }
    }
    selected
}
