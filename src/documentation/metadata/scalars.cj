protected package cjdoc.documentation.metadata

import cjdoc.manifest.decodeTomlString
import cjdoc.model as public_model
import std.collection.ArrayList

private func metadataHasTriple(value: String, offset: Int64, marker: Byte): Bool {
    offset + 2 < value.size && value[offset] == marker && value[offset + 1] == marker &&
        value[offset + 2] == marker
}

private func metadataEscapedAt(value: String, offset: Int64): Bool {
    var cursor = offset
    var slashes: Int64 = 0
    while (cursor > 0 && value[cursor - 1] == b'\\') {
        slashes++
        cursor--
    }
    slashes % 2 == 1
}

private func metadataFirstUnescapedTriple(value: String, start: Int64, marker: Byte): ?Int64 {
    var index = start
    while (index < value.size) {
        if (metadataHasTriple(value, index, marker) &&
            (marker == b'\'' || !metadataEscapedAt(value, index))) {
            return Some(index)
        }
        index++
    }
    None
}

/* Track multiline values and containers separately from the comment scanner so
 * table-looking lines inside strings, arrays, or inline tables are never syntax. */
class MetadataMultilineState {
    private var delimiter: ?Byte = None
    private var arrayDepth: Int64 = 0
    private var inlineDepth: Int64 = 0

    func isInside(): Bool { delimiter.isSome() || arrayDepth > 0 || inlineDepth > 0 }

    func advance(line: String): Unit {
        var activeDelimiter = delimiter
        var basic: Bool = false
        var literal: Bool = false
        var escaped: Bool = false
        var index: Int64 = 0
        while (index < line.size) {
            match (activeDelimiter) {
                case Some(marker) =>
                    let closing = metadataFirstUnescapedTriple(line, index, marker)
                    match (closing) {
                        case Some(offset) =>
                            activeDelimiter = None
                            index = offset + 3
                        case None => index = line.size
                    }
                case None =>
                    let byte = line[index]
                    if (basic) {
                        if (escaped) {
                            escaped = false
                        } else if (byte == b'\\') {
                            escaped = true
                        } else if (byte == b'\"') {
                            basic = false
                        }
                        index++
                    } else if (literal) {
                        if (byte == b'\'') { literal = false }
                        index++
                    } else if (byte == b'#') {
                        index = line.size
                    } else if ((byte == b'\"' || byte == b'\'') &&
                        metadataHasTriple(line, index, byte)) {
                        let closing = metadataFirstUnescapedTriple(line, index + 3, byte)
                        match (closing) {
                            case Some(offset) => index = offset + 3
                            case None =>
                                activeDelimiter = Some(byte)
                                index = line.size
                        }
                    } else if (byte == b'\"') {
                        basic = true
                        escaped = false
                        index++
                    } else if (byte == b'\'') {
                        literal = true
                        index++
                    } else if (byte == b'[') {
                        arrayDepth++
                        index++
                    } else if (byte == b']') {
                        if (arrayDepth > 0) { arrayDepth-- }
                        index++
                    } else if (byte == b'{') {
                        inlineDepth++
                        index++
                    } else if (byte == b'}') {
                        if (inlineDepth > 0) { inlineDepth-- }
                        index++
                    } else {
                        index++
                    }
            }
        }
        delimiter = activeDelimiter
    }
}


func metadataStripComment(value: String): String {
    var basic: Bool = false
    var literal: Bool = false
    var escaped: Bool = false
    var multilineBasic: Bool = false
    var multilineLiteral: Bool = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (multilineBasic) {
            if (byte == b'\\' && !escaped) {
                escaped = true
                index++
                continue
            }
            if (metadataHasTriple(value, index, b'"') && !metadataEscapedAt(value, index)) {
                multilineBasic = false
                index += 3
                continue
            }
            escaped = false
        } else if (multilineLiteral) {
            if (metadataHasTriple(value, index, b'\'')) {
                multilineLiteral = false
                index += 3
                continue
            }
        } else if (basic) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == b'"') {
                basic = false
            }
        } else if (literal) {
            if (byte == b'\'') { literal = false }
        } else if (byte == b'#') {
            return value[..index].trimAscii()
        } else if (byte == b'"' && metadataHasTriple(value, index, b'"')) {
            multilineBasic = true
            index += 3
            continue
        } else if (byte == b'\'' && metadataHasTriple(value, index, b'\'')) {
            multilineLiteral = true
            index += 3
            continue
        } else if (byte == b'"') {
            basic = true
            escaped = false
        } else if (byte == b'\'') {
            literal = true
        }
        index++
    }
    value.trimAscii()
}

func metadataEqualsAt(value: String): ?Int64 {
    var basic: Bool = false
    var literal: Bool = false
    var escaped: Bool = false
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if (basic) {
            if (escaped) {
                escaped = false
            } else if (byte == b'\\') {
                escaped = true
            } else if (byte == b'"') {
                basic = false
            }
        } else if (literal) {
            if (byte == b'\'') { literal = false }
        } else if (byte == b'"') {
            basic = true
        } else if (byte == b'\'') {
            literal = true
        } else if (byte == b'=') {
            return Some(index)
        }
        index++
    }
    None
}

private func metadataDecodeKeyToken(value: String, offset: Int64, line: Int64): (String, Int64) {
    if (offset >= value.size) { throw metadataConfigFailure(line, "expected a TOML key") }
    if (value[offset] == b'"' || value[offset] == b'\'') {
        if (metadataHasTriple(value, offset, value[offset])) {
            throw metadataConfigFailure(line, "multiline metadata keys are not supported")
        }
        let decoded = decodeTomlString(value, offset)
        if (decoded.invalid || decoded.value.isNone()) {
            throw metadataConfigFailure(line, "invalid quoted TOML key")
        }
        return (decoded.value.getOrThrow(), decoded.nextOffset)
    }
    let start = offset
    var cursor = offset
    while (cursor < value.size) {
        let byte = value[cursor]
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-') {
            cursor++
        } else {
            break
        }
    }
    if (cursor == start) { throw metadataConfigFailure(line, "invalid TOML key") }
    (value[start..cursor], cursor)
}

func metadataKeyPath(value: String, line: Int64, allowDotted: Bool): Array<String> {
    let result = ArrayList<String>()
    var cursor: Int64 = 0
    while (cursor < value.size) {
        while (cursor < value.size && (value[cursor] == b' ' || value[cursor] == b'\t')) { cursor++ }
        if (cursor >= value.size) { break }
        let (key, next) = metadataDecodeKeyToken(value, cursor, line)
        result.add(key)
        cursor = next
        while (cursor < value.size && (value[cursor] == b' ' || value[cursor] == b'\t')) { cursor++ }
        if (cursor == value.size) { break }
        if (value[cursor] != b'.' || !allowDotted) {
            throw metadataConfigFailure(line, "dotted or malformed metadata keys are not supported")
        }
        cursor++
        if (cursor == value.size) { throw metadataConfigFailure(line, "empty dotted metadata key") }
    }
    if (result.isEmpty()) { throw metadataConfigFailure(line, "empty TOML key") }
    result.toArray()
}

func metadataScalarString(value: String, line: Int64, key: String): String {
    let scalar = value.trimAscii()
    if (scalar.startsWith("\"\"\"") || scalar.startsWith("'''")) {
        throw metadataConfigFailure(line, "multiline TOML strings are not supported for metadata '${key}'")
    }
    if (scalar.isEmpty() || (scalar[0] != b'"' && scalar[0] != b'\'')) {
        throw metadataConfigFailure(line, "metadata '${key}' must be a quoted TOML string")
    }
    let decoded = decodeTomlString(scalar, 0)
    if (decoded.invalid || decoded.value.isNone() || decoded.nextOffset != scalar.size) {
        throw metadataConfigFailure(line, "metadata '${key}' must be one valid TOML string scalar")
    }
    decoded.value.getOrThrow()
}

func metadataIdentityText(value: String, line: Int64, key: String): String {
    let bytes = value.toArray()
    if (value.trimAscii().isEmpty()) {
        throw metadataConfigFailure(line, "metadata '${key}' must not be blank")
    }
    for (byte in bytes) {
        if (byte <= 0x1Fu8 || byte == 0x7Fu8) {
            throw metadataConfigFailure(line, "metadata '${key}' must be single-line text without C0 or DEL controls")
        }
    }
    value
}

func metadataTitleText(value: String, line: Int64, key: String): String {
    if (!public_model.isDocumentationMetadataTitle(value)) {
        throw metadataConfigFailure(line,
            "metadata '${key}' must be nonblank, single-line text of 1-256 UTF-8 bytes without C0 or DEL controls")
    }
    value
}

private func metadataIntegerDigit(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value) - Int64(b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value) - Int64(b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value) - Int64(b'A') + 10 }
    -1
}

func metadataOrder(value: String, line: Int64): Int64 {
    let raw = value.trimAscii()
    let bytes = raw.toArray()
    if (bytes.isEmpty()) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }

    var cursor: Int64 = 0
    var negative: Bool = false
    var signed: Bool = false
    if (bytes[cursor] == b'+' || bytes[cursor] == b'-') {
        signed = true
        negative = bytes[cursor] == b'-'
        cursor++
        if (cursor >= bytes.size) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }
    }

    var base: Int64 = 10
    if (!signed && cursor + 1 < bytes.size && bytes[cursor] == b'0') {
        if (bytes[cursor + 1] == b'x') { base = 16; cursor += 2 }
        else if (bytes[cursor + 1] == b'o') { base = 8; cursor += 2 }
        else if (bytes[cursor + 1] == b'b') { base = 2; cursor += 2 }
    }
    if (cursor >= bytes.size) { throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999") }

    let firstDigit = cursor
    var digits: Int64 = 0
    var previousUnderscore: Bool = false
    var number: Int64 = 0
    var outOfRange: Bool = false
    while (cursor < bytes.size) {
        let byte = bytes[cursor]
        if (byte == b'_') {
            if (digits == 0 || previousUnderscore || cursor + 1 >= bytes.size) {
                throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
            }
            previousUnderscore = true
            cursor++
            continue
        }
        let digit = metadataIntegerDigit(byte)
        if (digit < 0 || digit >= base) {
            throw metadataConfigFailure(line, "metadata 'order' must be an integer in 0..999999")
        }
        if (previousUnderscore) { previousUnderscore = false }
        digits++
        if (number > 999999 || digit > 999999 || number * base + digit > 999999) {
            outOfRange = true
        } else {
            number = number * base + digit
        }
        cursor++
    }
    if (digits == 0 || previousUnderscore) {
        throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
    }
    if (base == 10 && bytes[firstDigit] == b'0' && digits > 1) {
        throw metadataConfigFailure(line, "metadata 'order' is not a valid TOML integer")
    }
    if (outOfRange || (negative && number != 0)) {
        throw metadataConfigFailure(line, "metadata 'order' must be in 0..999999")
    }
    number
}
