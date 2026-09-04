package cjdoc

import std.collection.*

internal func parseCjpmWorkspaceMembersWithBudget(manifest: String, maxEntries: Int64,
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

internal class CjpmPackageFields {
    var name: ?String = None
    var sourceDirectory: ?String = None
    var organization: ?String = None
    var nameSeen = false
    var sourceDirectorySeen = false
    var organizationSeen = false
    var invalid = false
}

internal func tomlAssignmentString(code: String, equals: Int64): TomlDecodedString {
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

internal func compactTomlBareKey(value: String): String {
    value.replace(" ", "").replace("\t", "")
}

internal func parseCjpmPackageMetadataWithBudget(manifest: String,
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
        } else if (inPackage && key == "organization") {
            "organization"
        } else if (inRoot && key == "package.name") {
            "name"
        } else if (inRoot && key == "package.src-dir") {
            "src-dir"
        } else if (inRoot && key == "package.organization") {
            "organization"
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
        } else if (field == "src-dir") {
            if (fields.sourceDirectorySeen) {
                fields.invalid = true
                break
            }
            fields.sourceDirectorySeen = true
            fields.sourceDirectory = Some(value)
        } else {
            if (fields.organizationSeen) {
                fields.invalid = true
                break
            }
            fields.organizationSeen = true
            fields.organization = if (value.isEmpty()) { None<String> } else { Some(value) }
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
        }, organization: if (fields.invalid || budget.limitReached) {
            NO_TOML_STRING
        } else {
            fields.organization
        })
}

internal func isTomlNameByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'_' || value == b'-'
}

internal class TomlInlineStringField {
    let value: ?String
    let invalid: Bool

    init(value: ?String, invalid!: Bool = false) {
        this.value = value
        this.invalid = invalid
    }
}

internal class TomlInlineTableView {
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

internal class TomlInlineTableParser {
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

internal func parseTomlInlineStringTable(entry: String): TomlInlineTableView {
    let equals = tomlAssignmentEquals(entry)
    if (equals.isNone()) {
        return TomlInlineTableView(HashMap<String, String>(), HashSet<String>(), true)
    }
    TomlInlineTableParser(entry[equals.getOrThrow() + 1..]).parse()
}

internal func tomlBraceDelta(line: String): Int64 {
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

internal func dependencyTableMode(table: String, selectedTarget: ?String): (Int64, Bool) {
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

internal func tomlTableName(code: String): ?String {
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

internal func addUniqueDependencyPath(paths: ArrayList<String>, seen: HashSet<String>,
    path: String, maxEntries: Int64): Bool {
    if (seen.contains(path)) { return true }
    if (paths.size >= maxEntries) { return false }
    let _ = seen.add(path)
    paths.add(path)
    true
}

internal func unsupportedDottedDependencyAssignment(key: String,
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
