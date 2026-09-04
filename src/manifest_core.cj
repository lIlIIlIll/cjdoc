package cjdoc

import std.collection.*


internal let MAX_MANIFEST_ADAPTER_ENTRIES: Int64 = 100000
internal let MAX_MANIFEST_ADAPTER_BYTES: Int64 = 32 * 1024 * 1024
internal let MAX_MANIFEST_ADAPTER_WORK: Int64 = 128 * 1024 * 1024
internal let NO_TOML_STRING: ?String = None

// Minimal, fail-closed cjpm manifest view. The installed SDK has no public
// TOML parser, so TOML handling is isolated here instead of leaking line-based
// assumptions into project discovery. Only the fields consumed by cjdoc are
// exposed: package metadata, workspace.members, and supported dependency paths.
class CjpmManifestView {
    public let packageName: ?String
    public let packageSrcDir: ?String
    public let workspaceMembers: ArrayList<String>
    public let pathDependencies: ArrayList<String>
    public let limitReached: Bool
    public let invalid: Bool
    public let partial: Bool

    public init(packageName: ?String, workspaceMembers: ArrayList<String>,
        pathDependencies: ArrayList<String>, limitReached!: Bool = false,
        invalid!: Bool = false, packageSrcDir!: ?String = None,
        partial!: Bool = false) {
        this.packageName = packageName
        this.packageSrcDir = packageSrcDir
        this.workspaceMembers = workspaceMembers
        this.pathDependencies = pathDependencies
        this.limitReached = limitReached
        this.invalid = invalid
        this.partial = partial
    }
}

class CjpmStringEntries {
    public let values: ArrayList<String>
    public let entryCount: Int64
    public let limitReached: Bool
    public let invalid: Bool
    public let partial: Bool

    public init(values: ArrayList<String>, entryCount: Int64, limitReached: Bool,
        invalid!: Bool = false, partial!: Bool = false) {
        this.values = values
        this.entryCount = entryCount
        this.limitReached = limitReached
        this.invalid = invalid
        this.partial = partial
    }
}

class CjpmPackageNameView {
    public let value: ?String
    public let sourceDirectory: ?String
    public let organization: ?String
    public let limitReached: Bool
    public let invalid: Bool

    public init(value: ?String, limitReached: Bool, invalid: Bool,
        sourceDirectory!: ?String = None, organization!: ?String = None) {
        this.value = value
        this.sourceDirectory = sourceDirectory
        this.organization = organization
        this.limitReached = limitReached
        this.invalid = invalid
    }
}

class CjpmLockedDependency {
    public let name: String
    public let git: ?String
    public let commitId: ?String
    public let version: ?String

    public init(name: String, git: ?String, commitId: ?String, version: ?String) {
        this.name = name
        this.git = git
        this.commitId = commitId
        this.version = version
    }
}

class CjpmLockView {
    public let dependencies: ArrayList<CjpmLockedDependency>
    public let entryCount: Int64
    public let limitReached: Bool
    public let invalid: Bool

    public init(dependencies: ArrayList<CjpmLockedDependency>, entryCount: Int64,
        limitReached: Bool, invalid!: Bool = false) {
        this.dependencies = dependencies
        this.entryCount = entryCount
        this.limitReached = limitReached
        this.invalid = invalid
    }
}

internal class TomlParseBudget {
    private let maxWork: Int64
    private var work: Int64 = 0
    var limitReached = false

    init(text: String, maxBytes: Int64, maxWork: Int64) {
        if (maxBytes < 0 || maxWork < 0) {
            throw IllegalArgumentException("manifest adapter limits must be non-negative")
        }
        this.maxWork = maxWork
        if (text.size > maxBytes) { limitReached = true }
    }

    func consume(amount: Int64): Bool {
        if (limitReached || amount < 0 || amount > maxWork - work) {
            limitReached = true
            return false
        }
        work += amount
        true
    }
}

internal class TomlLineCursor {
    private let text: String
    private let budget: TomlParseBudget
    private var offset: Int64 = 0
    private var finished = false

    init(text: String, budget: TomlParseBudget) {
        this.text = text
        this.budget = budget
    }

    func next(): ?String {
        if (finished) { return NO_TOML_STRING }
        var end = offset
        while (end < text.size && text[end] != b'\n') { end++ }
        let separatorBytes: Int64 = if (end < text.size) { 1 } else { 0 }
        let consumed = end - offset + separatorBytes
        if (!budget.consume(consumed)) { finished = true; return NO_TOML_STRING }
        let line = text[offset..end]
        if (end == text.size) {
            finished = true
        } else {
            offset = end + 1
        }
        Some(line)
    }
}

internal class TomlDecodedString {
    let value: ?String
    let nextOffset: Int64
    let invalid: Bool

    init(value: ?String, nextOffset: Int64, invalid: Bool) {
        this.value = value
        this.nextOffset = nextOffset
        this.invalid = invalid
    }
}

internal func tomlHexValue(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value) - Int64(b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value) - Int64(b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value) - Int64(b'A') + 10 }
    -1
}

internal func appendTomlScalar(bytes: ArrayList<UInt8>, value: Int64): Bool {
    if (value < 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) { return false }
    if (value <= 0x7f) {
        bytes.add(UInt8(value))
    } else if (value <= 0x7ff) {
        bytes.add(UInt8(0xc0 | (value >> 6)))
        bytes.add(UInt8(0x80 | (value & 0x3f)))
    } else if (value <= 0xffff) {
        bytes.add(UInt8(0xe0 | (value >> 12)))
        bytes.add(UInt8(0x80 | ((value >> 6) & 0x3f)))
        bytes.add(UInt8(0x80 | (value & 0x3f)))
    } else {
        bytes.add(UInt8(0xf0 | (value >> 18)))
        bytes.add(UInt8(0x80 | ((value >> 12) & 0x3f)))
        bytes.add(UInt8(0x80 | ((value >> 6) & 0x3f)))
        bytes.add(UInt8(0x80 | (value & 0x3f)))
    }
    true
}

// TOML strings are decoded from bytes once. Decoding one byte at a time is not
// valid for multibyte UTF-8 and used to turn otherwise valid Unicode metadata
// into an exception in the project-discovery path.
internal func decodeTomlString(line: String, quoteAt: Int64): TomlDecodedString {
    if (quoteAt < 0 || quoteAt >= line.size ||
        (line[quoteAt] != b'"' && line[quoteAt] != b'\'')) {
        return TomlDecodedString(NO_TOML_STRING, quoteAt, true)
    }
    let quoteByte = line[quoteAt]
    let bytes = ArrayList<UInt8>()
    var cursor = quoteAt + 1
    while (cursor < line.size) {
        let current = line[cursor]
        if (current == quoteByte) {
            let value: ?String = try {
                Some(String.fromUtf8(bytes.toArray()))
            } catch (_: Exception) {
                None
            }
            return TomlDecodedString(value, cursor + 1, value.isNone())
        }
        if (quoteByte == b'"' && current == b'\\') {
            cursor++
            if (cursor >= line.size) {
                return TomlDecodedString(NO_TOML_STRING, cursor, true)
            }
            match (line[cursor]) {
                case b'"' => bytes.add(b'"')
                case b'\\' => bytes.add(b'\\')
                case b'b' => bytes.add(8u8)
                case b't' => bytes.add(9u8)
                case b'n' => bytes.add(10u8)
                case b'f' => bytes.add(12u8)
                case b'r' => bytes.add(13u8)
                case b'u' | b'U' =>
                    let digits: Int64 = if (line[cursor] == b'u') { 4 } else { 8 }
                    if (cursor + digits >= line.size) {
                        return TomlDecodedString(NO_TOML_STRING, cursor, true)
                    }
                    var scalar: Int64 = 0
                    var digit: Int64 = 0
                    while (digit < digits) {
                        let value = tomlHexValue(line[cursor + 1 + digit])
                        if (value < 0) {
                            return TomlDecodedString(NO_TOML_STRING, cursor, true)
                        }
                        scalar = scalar * 16 + value
                        digit++
                    }
                    if (!appendTomlScalar(bytes, scalar)) {
                        return TomlDecodedString(NO_TOML_STRING, cursor, true)
                    }
                    cursor += digits
                case _ => return TomlDecodedString(NO_TOML_STRING, cursor, true)
            }
        } else {
            if ((current < 0x20u8 && current != b'\t') || current == 0x7fu8) {
                return TomlDecodedString(NO_TOML_STRING, cursor, true)
            }
            bytes.add(current)
        }
        cursor++
    }
    TomlDecodedString(NO_TOML_STRING, cursor, true)
}

internal class TomlLineScanner {
    private var multilineDelimiter: ?Byte = None

    private func tripleAt(line: String, index: Int64, marker: Byte): Bool {
        index + 2 < line.size && line[index] == marker && line[index + 1] == marker &&
            line[index + 2] == marker
    }

    private func escapedAt(line: String, index: Int64): Bool {
        var cursor = index
        var slashes: Int64 = 0
        while (cursor > 0 && line[cursor - 1] == b'\\') {
            slashes++
            cursor--
        }
        slashes % 2 == 1
    }

    // Multiline string contents are deliberately unavailable to the minimal
    // manifest adapter. Skipping every line that participates in one prevents
    // examples such as "[workspace] # ..." inside documentation strings from
    // becoming project-discovery input.
    func code(line: String): ?String {
        var delimiter: ?Byte = None
        var escaped = false
        var index: Int64 = 0
        var commentAt = line.size
        var encounteredMultiline = multilineDelimiter.isSome()
        while (index < line.size) {
            match (multilineDelimiter) {
                case Some(marker) =>
                    if (tripleAt(line, index, marker) &&
                        (marker == b'\'' || !escapedAt(line, index))) {
                        multilineDelimiter = None
                        index += 3
                    } else {
                        index++
                    }
                case None =>
                    match (delimiter) {
                        case Some(quoteByte) =>
                            if (escaped) {
                                escaped = false
                            } else if (quoteByte == b'"' && line[index] == b'\\') {
                                escaped = true
                            } else if (line[index] == quoteByte) {
                                delimiter = None
                            }
                            index++
                        case None =>
                            let byte = line[index]
                            if (byte == b'#') {
                                commentAt = index
                                index = line.size
                            } else if ((byte == b'"' || byte == b'\'') &&
                                tripleAt(line, index, byte)) {
                                multilineDelimiter = Some(byte)
                                encounteredMultiline = true
                                index += 3
                            } else if (byte == b'"' || byte == b'\'') {
                                delimiter = Some(byte)
                                escaped = false
                                index++
                            } else {
                                index++
                            }
                    }
            }
        }
        if (encounteredMultiline) {
            NO_TOML_STRING
        } else {
            Some(line[..commentAt].trimAscii())
        }
    }
}

internal class TomlStringArrayState {
    var started = false
    var expectValue = true
}

internal func collectTomlStrings(line: String, values: ArrayList<String>,
    maxValues: Int64, state: TomlStringArrayState): (Bool, Bool, Bool) {
    var index: Int64 = 0
    while (index < line.size) {
        let current = line[index]
        if (current == b' ' || current == b'\t' || current == b'\r') {
            index++
            continue
        }
        if (!state.started) {
            if (current != b'[') { return (false, false, true) }
            state.started = true
            index++
            continue
        }
        if (state.expectValue && current == b']') {
            index++
            while (index < line.size &&
                (line[index] == b' ' || line[index] == b'\t' || line[index] == b'\r')) {
                index++
            }
            return (true, false, index != line.size)
        }
        if (!state.expectValue && current == b',') {
            state.expectValue = true
            index++
            continue
        }
        if (!state.expectValue && current == b']') {
            index++
            while (index < line.size &&
                (line[index] == b' ' || line[index] == b'\t' || line[index] == b'\r')) {
                index++
            }
            return (true, false, index != line.size)
        }
        if (state.expectValue && (current == b'"' || current == b'\'')) {
            let decoded = decodeTomlString(line, index)
            if (decoded.invalid) { return (false, false, true) }
            if (values.size >= maxValues) { return (false, true, false) }
            values.add(decoded.value.getOrThrow())
            state.expectValue = false
            index = decoded.nextOffset
            continue
        }
        return (false, false, true)
    }
    return (false, false, false)
}
