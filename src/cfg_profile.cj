package cjdoc

import std.collection.*
import std.sort.*

public class CfgValue {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

class CfgProfile {
    public let values = ArrayList<CfgValue>()

    public init(values!: Array<CfgValue> = []) {
        this.values.add(all: values)
        sort(this.values, lessThan: { left, right =>
            if (left.name == right.name) { left.value < right.value } else { left.name < right.name }
        }, stable: true)
    }

    public func isEmpty(): Bool { values.isEmpty() }

    public func value(name: String): ?String {
        for (entry in values) {
            if (entry.name == name) { return Some(entry.value) }
        }
        None
    }
}

// A named, explicit configuration used by matrix generation. The name is a
// stable document key; the values remain the same provider-neutral cfg facts
// used by a single DocumentationSet.
class NamedCfgProfile {
    public let name: String
    public let profile: CfgProfile

    public init(name: String, values: Array<CfgValue>) {
        this.name = name
        this.profile = CfgProfile(values: values)
    }
}

func isCfgProfileNameValid(name: String): Bool {
    if (name.isEmpty() || name == "." || name == "..") { return false }
    for (byte in name.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

private func whenExpression(annotation: String): ?String {
    if (!annotation.startsWith("@When")) { return None }
    var open: Int64 = -1
    var close: Int64 = -1
    var index: Int64 = 0
    while (index < annotation.size) {
        if (annotation[index] == b'[' && open < 0) { open = index }
        if (annotation[index] == b']') { close = index }
        index++
    }
    if (open < 0 || close <= open) { return Some("") }
    Some(annotation[open + 1..close].trimAscii())
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

private func cfgSelection(declaration: SourceDeclaration, profile: CfgProfile): ?Bool {
    var sawWhen = false
    for (annotation in declaration.annotations) {
        if (let Some(expression) <- whenExpression(annotation)) {
            sawWhen = true
            match (evaluateWhenExpression(expression, profile)) {
                case Some(true) => ()
                case Some(false) => return Some(false)
                case None => return None
            }
        }
    }
    if (sawWhen) { Some(true) } else { Some(true) }
}

func filterSourceForCfg(source: SourceSnapshot, profile: CfgProfile): Unit {
    if (profile.isEmpty()) { return }
    let includedByKey = HashMap<String, Bool>()
    let included = ArrayList<Bool>()
    for (declaration in source.declarations) {
        var keep = match (cfgSelection(declaration, profile)) {
            case Some(selected) => selected
            case None =>
                source.diagnostics.add(Diagnostic("warning", "CJDOC1019",
                    "conditional declaration omitted because its @When expression is unsupported or unresolved",
                    source: declaration.source))
                source.unsupportedDeclarations.add(UnsupportedDeclaration(declaration.kind,
                    declaration.name,
                    "conditional compilation expression is unsupported or unresolved",
                    declaration.source))
                false
        }
        if (let Some(ownerKey) <- declaration.ownerSourceKey) {
            if (let Some(ownerIncluded) <- includedByKey.get(ownerKey)) {
                if (!ownerIncluded) { keep = false }
            }
        }
        included.add(keep)
        includedByKey[declaration.sourceKey] = keep
    }
    var index = source.declarations.size - 1
    while (index >= 0) {
        if (!included[index]) { source.declarations.remove(at: index) }
        index--
    }
}
