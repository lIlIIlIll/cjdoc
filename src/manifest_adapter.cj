package cjdoc

import std.collection.*
import std.sort.*

private let MAX_MANIFEST_ADAPTER_ENTRIES: Int64 = 100000
private let MAX_MANIFEST_ADAPTER_BYTES: Int64 = 32 * 1024 * 1024
private let MAX_MANIFEST_ADAPTER_WORK: Int64 = 128 * 1024 * 1024
private let NO_TOML_STRING: ?String = None

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
    public let limitReached: Bool
    public let invalid: Bool

    public init(value: ?String, limitReached: Bool, invalid: Bool,
        sourceDirectory!: ?String = None) {
        this.value = value
        this.sourceDirectory = sourceDirectory
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

private class TomlParseBudget {
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

private class TomlLineCursor {
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

private class TomlDecodedString {
    let value: ?String
    let nextOffset: Int64
    let invalid: Bool

    init(value: ?String, nextOffset: Int64, invalid: Bool) {
        this.value = value
        this.nextOffset = nextOffset
        this.invalid = invalid
    }
}

private func tomlHexValue(value: Byte): Int64 {
    if (value >= b'0' && value <= b'9') { return Int64(value) - Int64(b'0') }
    if (value >= b'a' && value <= b'f') { return Int64(value) - Int64(b'a') + 10 }
    if (value >= b'A' && value <= b'F') { return Int64(value) - Int64(b'A') + 10 }
    -1
}

private func appendTomlScalar(bytes: ArrayList<UInt8>, value: Int64): Bool {
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
private func decodeTomlString(line: String, quoteAt: Int64): TomlDecodedString {
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

private class TomlLineScanner {
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

private class TomlStringArrayState {
    var started = false
    var expectValue = true
}

private func collectTomlStrings(line: String, values: ArrayList<String>,
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

private func parseCjpmWorkspaceMembersWithBudget(manifest: String, maxEntries: Int64,
    budget: TomlParseBudget): CjpmStringEntries {
    if (maxEntries < 0) { throw IllegalArgumentException("manifest entry limit must be non-negative") }
    let members = ArrayList<String>()
    let scanner = TomlLineScanner()
    var inWorkspace = false
    var inMembers = false
    var limitReached = false
    var invalid = false
    let arrayState = TomlStringArrayState()
    let lines = TomlLineCursor(manifest, budget)
    while (true) {
        let line = match (lines.next()) {
            case Some(value) => value
            case None => break
        }
        let code = match (scanner.code(line)) {
            case Some(value) => value
            case None => continue
        }
        let trimmed = code.trimAscii()
        if (!inMembers && trimmed.startsWith("[")) {
            inWorkspace = trimmed == "[workspace]"
            continue
        }
        if (!inWorkspace) { continue }
        if (!inMembers) {
            let equals = code.indexOf("=")
            if (equals.isNone() || code[..equals.getOrThrow()].trimAscii() != "members") { continue }
            inMembers = true
            let valueStart = equals.getOrThrow() + 1
            let (complete, exceeded, invalidString) = collectTomlStrings(
                code[valueStart..], members, maxEntries, arrayState)
            if (invalidString) { invalid = true; break }
            if (exceeded) { limitReached = true; break }
            if (complete) { inMembers = false }
            continue
        }
        let (complete, exceeded, invalidString) = collectTomlStrings(
            code, members, maxEntries, arrayState)
        if (invalidString) { invalid = true; break }
        if (exceeded) { limitReached = true; break }
        if (complete) { inMembers = false }
    }
    if (inMembers && !budget.limitReached) { invalid = true }
    CjpmStringEntries(members, members.size, limitReached || budget.limitReached,
        invalid: invalid)
}

func parseCjpmWorkspaceMembers(manifest: String, maxEntries: Int64,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmStringEntries {
    let budget = TomlParseBudget(manifest, maxBytes, maxWork)
    parseCjpmWorkspaceMembersWithBudget(manifest, maxEntries, budget)
}

private class CjpmPackageFields {
    var name: ?String = None
    var sourceDirectory: ?String = None
    var nameSeen = false
    var sourceDirectorySeen = false
    var invalid = false
}

private func tomlAssignmentString(code: String, equals: Int64): TomlDecodedString {
    var cursor = equals + 1
    while (cursor < code.size && (code[cursor] == b' ' || code[cursor] == b'\t')) { cursor++ }
    if (cursor >= code.size || (code[cursor] != b'"' && code[cursor] != b'\'')) {
        return TomlDecodedString(NO_TOML_STRING, cursor, true)
    }
    let decoded = decodeTomlString(code, cursor)
    if (decoded.invalid || decoded.value.isNone() ||
        !code[decoded.nextOffset..].trimAscii().isEmpty()) {
        return TomlDecodedString(NO_TOML_STRING, decoded.nextOffset, true)
    }
    decoded
}

private func compactTomlBareKey(value: String): String {
    value.replace(" ", "").replace("\t", "")
}

private func parseCjpmPackageMetadataWithBudget(manifest: String,
    budget: TomlParseBudget): CjpmPackageFields {
    let fields = CjpmPackageFields()
    let scanner = TomlLineScanner()
    var inPackage = false
    var inRoot = true
    let lines = TomlLineCursor(manifest, budget)
    while (true) {
        let line = match (lines.next()) {
            case Some(value) => value
            case None => break
        }
        let code = match (scanner.code(line)) {
            case Some(value) => value
            case None => continue
        }
        let trimmed = code.trimAscii()
        if (trimmed.startsWith("[")) {
            inPackage = trimmed == "[package]"
            inRoot = false
            continue
        }
        let equals = code.indexOf("=")
        if (equals.isNone()) { continue }
        let key = compactTomlBareKey(code[..equals.getOrThrow()].trimAscii())
        let field = if (inPackage && key == "name") {
            "name"
        } else if (inPackage && key == "src-dir") {
            "src-dir"
        } else if (inRoot && key == "package.name") {
            "name"
        } else if (inRoot && key == "package.src-dir") {
            "src-dir"
        } else {
            continue
        }
        let decoded = tomlAssignmentString(code, equals.getOrThrow())
        if (decoded.invalid || decoded.value.isNone()) {
            fields.invalid = true
            break
        }
        let value = decoded.value.getOrThrow()
        if (field == "name") {
            if (fields.nameSeen || value.isEmpty()) {
                fields.invalid = true
                break
            }
            fields.nameSeen = true
            fields.name = Some(value)
        } else {
            if (fields.sourceDirectorySeen) {
                fields.invalid = true
                break
            }
            fields.sourceDirectorySeen = true
            fields.sourceDirectory = Some(value)
        }
    }
    fields
}

func parseCjpmPackageName(manifest: String): ?String {
    parseCjpmPackageNameChecked(manifest).value
}

func parseCjpmPackageNameChecked(manifest: String,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmPackageNameView {
    let budget = TomlParseBudget(manifest, maxBytes, maxWork)
    let fields = parseCjpmPackageMetadataWithBudget(manifest, budget)
    CjpmPackageNameView(
        if (fields.invalid || budget.limitReached) { NO_TOML_STRING } else { fields.name },
        budget.limitReached, fields.invalid,
        sourceDirectory: if (fields.invalid || budget.limitReached) {
            NO_TOML_STRING
        } else {
            fields.sourceDirectory
        })
}

private func isTomlNameByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'_' || value == b'-'
}

private class TomlInlineStringField {
    let value: ?String
    let invalid: Bool

    init(value: ?String, invalid!: Bool = false) {
        this.value = value
        this.invalid = invalid
    }
}

private class TomlInlineTableView {
    let fields: HashMap<String, String>
    let keys: HashSet<String>
    let invalid: Bool

    init(fields: HashMap<String, String>, keys: HashSet<String>, invalid: Bool) {
        this.fields = fields
        this.keys = keys
        this.invalid = invalid
    }

    func field(name: String): ?String { fields.get(name) }
    func contains(name: String): Bool { keys.contains(name) }
}

private class TomlInlineTableParser {
    private let source: String
    private var offset: Int64 = 0
    private let rootFields = HashMap<String, String>()
    private let rootKeys = HashSet<String>()

    init(source: String) { this.source = source }

    private func skipWhitespace(): Unit {
        while (offset < source.size && (source[offset] == b' ' || source[offset] == b'\t' ||
            source[offset] == b'\r' || source[offset] == b'\n')) { offset++ }
    }

    private func parseKey(): ?String {
        skipWhitespace()
        if (offset >= source.size) { return None }
        if (source[offset] == b'"' || source[offset] == b'\'') {
            let decoded = decodeTomlString(source, offset)
            if (decoded.invalid || decoded.value.isNone()) { return None }
            offset = decoded.nextOffset
            return decoded.value
        }
        let start = offset
        while (offset < source.size && isTomlNameByte(source[offset])) { offset++ }
        if (offset == start) { None } else { Some(source[start..offset]) }
    }

    private func parseBareValue(): Bool {
        let start = offset
        while (offset < source.size) {
            let byte = source[offset]
            if (byte == b',' || byte == b'}' || byte == b']' || byte == b' ' ||
                byte == b'\t' || byte == b'\r' || byte == b'\n') { break }
            offset++
        }
        if (offset == start) { return false }
        let token = source[start..offset]
        if (token == "true" || token == "false" || token == "inf" || token == "+inf" ||
            token == "-inf" || token == "nan" || token == "+nan" || token == "-nan") {
            return true
        }
        var hasDigit = false
        for (byte in token.toArray()) {
            if (byte >= b'0' && byte <= b'9') { hasDigit = true }
            if (!((byte >= b'0' && byte <= b'9') || byte == b'+' || byte == b'-' ||
                byte == b'.' || byte == b'_' || byte == b':' || byte == b'T' ||
                byte == b'Z' || byte == b'e' || byte == b'E' || byte == b'x' ||
                byte == b'o' || byte == b'b')) { return false }
        }
        hasDigit
    }

    private func parseArray(depth: Int64): Bool {
        if (depth > 128 || offset >= source.size || source[offset] != b'[') { return false }
        offset++
        skipWhitespace()
        if (offset < source.size && source[offset] == b']') { offset++; return true }
        while (true) {
            let (validValue, _) = parseValue(depth + 1)
            if (!validValue) { return false }
            skipWhitespace()
            if (offset >= source.size) { return false }
            if (source[offset] == b']') { offset++; return true }
            if (source[offset] != b',') { return false }
            offset++
            skipWhitespace()
            if (offset < source.size && source[offset] == b']') { offset++; return true }
        }
        false
    }

    private func parseValue(depth: Int64): (Bool, ?String) {
        if (depth > 128) { return (false, None) }
        skipWhitespace()
        if (offset >= source.size) { return (false, None) }
        if (source[offset] == b'"' || source[offset] == b'\'') {
            let decoded = decodeTomlString(source, offset)
            if (decoded.invalid || decoded.value.isNone()) { return (false, None) }
            offset = decoded.nextOffset
            return (true, decoded.value)
        }
        if (source[offset] == b'{') {
            return (parseTable(false, depth + 1), None)
        }
        if (source[offset] == b'[') {
            return (parseArray(depth + 1), None)
        }
        (parseBareValue(), None)
    }

    private func parseTable(captureRoot: Bool, depth: Int64): Bool {
        if (depth > 128 || offset >= source.size || source[offset] != b'{') { return false }
        offset++
        let keys = HashSet<String>()
        skipWhitespace()
        if (offset < source.size && source[offset] == b'}') { offset++; return true }
        while (true) {
            let key = match (parseKey()) {
                case Some(value) => value
                case None => return false
            }
            if (!keys.add(key)) { return false }
            if (captureRoot) { let _ = rootKeys.add(key) }
            skipWhitespace()
            if (offset >= source.size || source[offset] != b'=') { return false }
            offset++
            let (validValue, stringValue) = parseValue(depth + 1)
            if (!validValue) { return false }
            if (captureRoot) {
                if (let Some(value) <- stringValue) { rootFields[key] = value }
            }
            skipWhitespace()
            if (offset >= source.size) { return false }
            if (source[offset] == b'}') { offset++; return true }
            if (source[offset] != b',') { return false }
            offset++
            skipWhitespace()
            // TOML inline tables do not admit an array-style trailing comma.
            if (offset >= source.size || source[offset] == b'}') { return false }
        }
        false
    }

    func parse(): TomlInlineTableView {
        skipWhitespace()
        let valid = parseTable(true, 0)
        skipWhitespace()
        TomlInlineTableView(rootFields, rootKeys, !valid || offset != source.size)
    }
}

private func parseTomlInlineStringTable(entry: String): TomlInlineTableView {
    let equals = tomlAssignmentEquals(entry)
    if (equals.isNone()) {
        return TomlInlineTableView(HashMap<String, String>(), HashSet<String>(), true)
    }
    TomlInlineTableParser(entry[equals.getOrThrow() + 1..]).parse()
}

private func tomlBraceDelta(line: String): Int64 {
    var delimiter: ?Byte = None
    var escaped = false
    var delta: Int64 = 0
    for (byte in line.toArray()) {
        match (delimiter) {
            case Some(quoteByte) =>
                if (escaped) {
                    escaped = false
                } else if (quoteByte == b'"' && byte == b'\\') {
                    escaped = true
                } else if (byte == quoteByte) {
                    delimiter = None
                }
            case None =>
                if (byte == b'#') { return delta }
                if (byte == b'"' || byte == b'\'') {
                    delimiter = Some(byte)
                } else if (byte == b'{') {
                    delta++
                } else if (byte == b'}') {
                    delta--
                }
        }
    }
    delta
}

private func dependencyTableMode(table: String, selectedTarget: ?String): (Int64, Bool) {
    if (table == "dependencies") { return (1, false) }
    if (table.startsWith("dependencies.")) {
        let name = table.removePrefix("dependencies.")
        if (!name.isEmpty() && !name.contains(".")) { return (2, false) }
        return (0, true)
    }
    if (!table.startsWith("target.")) { return (0, false) }
    let segments = table.split(".")
    if (segments.size < 3 || segments[0] != "target") { return (0, false) }
    match (selectedTarget) {
        case None =>
            for (segment in segments where segment == "dependencies") {
                return (0, true)
            }
            return (0, false)
        case Some(target) =>
            if (segments[1] != target) { return (0, false) }
    }
    if (segments.size == 3 && segments[2] == "dependencies") { return (1, false) }
    if (segments.size == 4 && segments[2] == "dependencies" &&
        !segments[3].isEmpty()) { return (2, false) }
    for (segment in segments where segment == "dependencies") {
        // Profile-specific and otherwise unfamiliar target dependency tables
        // are legal cjpm shapes, but selecting their effective profile is
        // outside this source-only adapter.
        return (0, true)
    }
    (0, false)
}

private func tomlTableName(code: String): ?String {
    let trimmed = code.trimAscii()
    if (!trimmed.startsWith("[") || trimmed.startsWith("[[") ||
        !trimmed.endsWith("]")) { return NO_TOML_STRING }
    let inner = compactTomlBareKey(trimmed[1..trimmed.size - 1].trimAscii())
    if (inner.isEmpty() || inner.contains("[") || inner.contains("]") ||
        inner.contains("\"") || inner.contains("'")) {
        return NO_TOML_STRING
    }
    Some(inner)
}

private func addUniqueDependencyPath(paths: ArrayList<String>, seen: HashSet<String>,
    path: String, maxEntries: Int64): Bool {
    if (seen.contains(path)) { return true }
    if (paths.size >= maxEntries) { return false }
    let _ = seen.add(path)
    paths.add(path)
    true
}

private func unsupportedDottedDependencyAssignment(key: String,
    selectedTarget: ?String): Bool {
    if (key.startsWith("dependencies.") || key.startsWith("\"dependencies\".") ||
        key.startsWith("'dependencies'.")) { return true }
    if (!key.startsWith("target.")) {
        // Quoted top-level target keys cannot be selected safely without a
        // complete TOML key parser. Mark dependency-shaped keys partial rather
        // than silently claiming a complete graph.
        return (key.startsWith("\"target\".") || key.startsWith("'target'.")) &&
            key.contains("dependencies")
    }
    let segments = key.split(".")
    if (segments.size < 3) { return false }
    var hasDependencies = false
    for (segment in segments where segment == "dependencies") {
        hasDependencies = true
    }
    if (!hasDependencies) { return false }
    match (selectedTarget) {
        case Some(target) => segments[1] == target
        case None => true
    }
}

private func parseCjpmPathDependenciesWithBudget(manifest: String, maxEntries: Int64,
    budget: TomlParseBudget, selectedTarget: ?String): CjpmStringEntries {
    if (maxEntries < 0) { throw IllegalArgumentException("manifest entry limit must be non-negative") }
    let paths = ArrayList<String>()
    let seenPaths = HashSet<String>()
    let scanner = TomlLineScanner()
    var tableMode: Int64 = 0
    var braceDepth: Int64 = 0
    var limitReached = false
    var invalid = false
    var partial = false
    var inlineEntry = StringBuilder()
    var inlineEntryStarted = false
    var inlineEntrySupported = true
    let lines = TomlLineCursor(manifest, budget)
    while (true) {
        let line = match (lines.next()) {
            case Some(value) => value
            case None => break
        }
        let code = match (scanner.code(line)) {
            case Some(value) => value
            case None =>
                if (tableMode != 0) { partial = true }
                continue
        }
        let trimmed = code.trimAscii()
        if (trimmed.startsWith("[")) {
            if (braceDepth != 0) { invalid = true; break }
            let table = tomlTableName(trimmed)
            if (table.isNone()) {
                if (trimmed.contains("dependencies")) { partial = true }
                tableMode = 0
                continue
            }
            let (mode, unsupported) = dependencyTableMode(table.getOrThrow(), selectedTarget)
            tableMode = mode
            if (unsupported) { partial = true }
            braceDepth = 0
            continue
        }
        if (tableMode == 0) {
            if (let Some(equals) <- code.indexOf("=")) {
                let key = compactTomlBareKey(code[..equals].trimAscii())
                if (unsupportedDottedDependencyAssignment(key, selectedTarget)) {
                    partial = true
                }
            }
            continue
        }
        if (tableMode == 2) {
            let equals = code.indexOf("=")
            if (equals.isNone()) { continue }
            let key = compactTomlBareKey(code[..equals.getOrThrow()].trimAscii())
            if (key == "path") {
                let decoded = tomlAssignmentString(code, equals.getOrThrow())
                if (decoded.invalid || decoded.value.isNone()) { invalid = true; break }
                if (!addUniqueDependencyPath(paths, seenPaths,
                    decoded.value.getOrThrow(), maxEntries)) {
                    limitReached = true
                    break
                }
            } else if (key.contains(".")) {
                partial = true
            }
            continue
        }
        if (braceDepth == 0) {
            if (trimmed.isEmpty()) { continue }
            let equals = tomlAssignmentEquals(code)
            if (equals.isNone()) { invalid = true; break }
            inlineEntrySupported = !compactTomlBareKey(
                code[..equals.getOrThrow()].trimAscii()).contains(".")
            if (!inlineEntrySupported) {
                partial = true
            } else if (dependencyName(code).invalid) {
                invalid = true
                break
            }
            inlineEntry = StringBuilder()
            inlineEntryStarted = false
        }
        if (inlineEntryStarted) { inlineEntry.append("\n") }
        inlineEntry.append(code)
        inlineEntryStarted = true
        braceDepth += tomlBraceDelta(code)
        if (braceDepth < 0) { invalid = true; break }
        if (braceDepth == 0) {
            let entry = inlineEntry.toString()
            let equals = tomlAssignmentEquals(entry).getOrThrow()
            let assigned = entry[equals + 1..].trimAscii()
            if (assigned.startsWith("{")) {
                let table = parseTomlInlineStringTable(entry)
                if (table.invalid) { invalid = true; break }
                if (table.contains("path") && table.field("path").isNone()) {
                    invalid = true
                    break
                }
                if (inlineEntrySupported) {
                    if (let Some(path) <- table.field("path")) {
                        if (!addUniqueDependencyPath(paths, seenPaths, path, maxEntries)) {
                            limitReached = true
                            break
                        }
                    }
                }
            } else {
                // cjpm also accepts the compact dependency form
                // `name = "version"`. It carries no path source, but it must
                // remain a valid dependency entry rather than poisoning the
                // complete manifest when inline tables are validated strictly.
                let version = tomlAssignmentString(entry, equals)
                if (version.invalid || version.value.isNone()) { invalid = true; break }
            }
            inlineEntry = StringBuilder()
            inlineEntryStarted = false
            inlineEntrySupported = true
        }
    }
    if ((braceDepth != 0 || inlineEntryStarted) && !budget.limitReached) { invalid = true }
    sort(paths)
    CjpmStringEntries(paths, paths.size, limitReached || budget.limitReached,
        invalid: invalid, partial: partial)
}

func parseCjpmPathDependencies(manifest: String, maxEntries: Int64,
    selectedTarget!: ?String = None,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmStringEntries {
    let budget = TomlParseBudget(manifest, maxBytes, maxWork)
    parseCjpmPathDependenciesWithBudget(manifest, maxEntries, budget, selectedTarget)
}

func parseCjpmManifest(manifest: String,
    maxEntries!: Int64 = MAX_MANIFEST_ADAPTER_ENTRIES,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmManifestView {
    if (maxEntries < 0) { throw IllegalArgumentException("manifest entry limit must be non-negative") }
    let budget = TomlParseBudget(manifest, maxBytes, maxWork)
    let packageFields = parseCjpmPackageMetadataWithBudget(manifest, budget)
    let workspace = if (budget.limitReached) {
        CjpmStringEntries(ArrayList<String>(), 0, true)
    } else {
        parseCjpmWorkspaceMembersWithBudget(manifest, maxEntries, budget)
    }
    let remaining = maxEntries - workspace.entryCount
    let paths = if (workspace.limitReached || workspace.invalid || budget.limitReached) {
        CjpmStringEntries(ArrayList<String>(), 0, budget.limitReached)
    } else {
        parseCjpmPathDependenciesWithBudget(manifest, remaining, budget, None<String>)
    }
    CjpmManifestView(packageFields.name, workspace.values, paths.values,
        limitReached: workspace.limitReached || paths.limitReached || budget.limitReached,
        invalid: packageFields.invalid || workspace.invalid || paths.invalid,
        packageSrcDir: packageFields.sourceDirectory,
        partial: paths.partial)
}

private func tomlAssignmentEquals(entry: String): ?Int64 {
    var delimiter: ?Byte = None
    var escaped = false
    var index: Int64 = 0
    while (index < entry.size) {
        let current = entry[index]
        match (delimiter) {
            case Some(quoteByte) =>
                if (escaped) {
                    escaped = false
                } else if (quoteByte == b'"' && current == b'\\') {
                    escaped = true
                } else if (current == quoteByte) {
                    delimiter = None
                }
            case None =>
                if (current == b'"' || current == b'\'') {
                    delimiter = Some(current)
                } else if (current == b'=') {
                    return Some(index)
                }
        }
        index++
    }
    None
}

private func dependencyName(entry: String): TomlInlineStringField {
    let equals = tomlAssignmentEquals(entry)
    if (equals.isNone()) { return TomlInlineStringField(NO_TOML_STRING, invalid: true) }
    let raw = entry[..equals.getOrThrow()].trimAscii()
    if (raw.isEmpty()) { return TomlInlineStringField(NO_TOML_STRING, invalid: true) }
    if ((raw.startsWith("\"") && raw.endsWith("\"")) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
        let decoded = decodeTomlString(raw, 0)
        if (decoded.invalid || decoded.nextOffset != raw.size) {
            return TomlInlineStringField(NO_TOML_STRING, invalid: true)
        }
        return TomlInlineStringField(decoded.value)
    }
    for (byte in raw.toArray()) {
        if (!isTomlNameByte(byte)) {
            return TomlInlineStringField(NO_TOML_STRING, invalid: true)
        }
    }
    TomlInlineStringField(Some(raw))
}

private func addLockedDependency(entry: String,
    dependencies: ArrayList<CjpmLockedDependency>): Bool {
    let nameField = dependencyName(entry)
    if (nameField.invalid) { return false }
    let name = nameField.value.getOrThrow()
    let equals = tomlAssignmentEquals(entry)
    if (equals.isNone()) { return false }
    let table = parseTomlInlineStringTable(entry)
    if (table.invalid) { return false }
    let git = table.field("git")
    let commitId = table.field("commitId")
    let version = table.field("version")
    if ((table.contains("git") && git.isNone()) ||
        (table.contains("commitId") && commitId.isNone()) ||
        (table.contains("version") && version.isNone())) { return false }
    if ((git.isSome() && commitId.isSome()) || version.isSome()) {
        dependencies.add(CjpmLockedDependency(name, git, commitId, version))
    }
    true
}

func parseCjpmLock(lockText: String,
    maxEntries!: Int64 = MAX_MANIFEST_ADAPTER_ENTRIES,
    maxBytes!: Int64 = MAX_MANIFEST_ADAPTER_BYTES,
    maxWork!: Int64 = MAX_MANIFEST_ADAPTER_WORK): CjpmLockView {
    if (maxEntries < 0) { throw IllegalArgumentException("lock entry limit must be non-negative") }
    let dependencies = ArrayList<CjpmLockedDependency>()
    let scanner = TomlLineScanner()
    var inRequires = false
    var entry = StringBuilder()
    var entryStarted = false
    var braceDepth: Int64 = 0
    var entryCount: Int64 = 0
    var limitReached = false
    var invalid = false
    let budget = TomlParseBudget(lockText, maxBytes, maxWork)
    let lines = TomlLineCursor(lockText, budget)
    while (true) {
        let line = match (lines.next()) {
            case Some(value) => value
            case None => break
        }
        let code = match (scanner.code(line)) {
            case Some(value) => value
            case None => continue
        }
        let trimmed = code.trimAscii()
        if (braceDepth == 0 && trimmed.startsWith("[")) {
            inRequires = trimmed == "[requires]"
            continue
        }
        if (!inRequires || (braceDepth == 0 && trimmed.isEmpty())) {
            continue
        }
        if (braceDepth == 0) {
            if (entryCount >= maxEntries) { limitReached = true; break }
            entryCount++
            entry = StringBuilder()
            entryStarted = false
        }
        if (entryStarted) { entry.append("\n") }
        entry.append(code)
        entryStarted = true
        braceDepth += tomlBraceDelta(code)
        if (braceDepth < 0) {
            invalid = true
            break
        }
        if (braceDepth == 0) {
            if (!addLockedDependency(entry.toString(), dependencies)) {
                invalid = true
                break
            }
            entry = StringBuilder()
            entryStarted = false
        }
    }
    if ((entryStarted || braceDepth != 0) && !budget.limitReached) { invalid = true }
    sort(dependencies, lessThan: { left, right => left.name < right.name }, stable: true)
    CjpmLockView(dependencies, entryCount, limitReached || budget.limitReached,
        invalid: invalid)
}
