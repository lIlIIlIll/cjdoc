package cjdoc

import std.collection.*
import std.sort.*

internal func parseCjpmPathDependenciesWithBudget(manifest: String, maxEntries: Int64,
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

internal func tomlAssignmentEquals(entry: String): ?Int64 {
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

internal func dependencyName(entry: String): TomlInlineStringField {
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

internal func addLockedDependency(entry: String,
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

