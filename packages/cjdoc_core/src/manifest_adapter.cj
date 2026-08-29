package cjdoc_core

import std.collection.*
import std.sort.*

// Minimal, fail-closed cjpm manifest view. The installed SDK has no public
// TOML parser, so TOML handling is isolated here instead of leaking line-based
// assumptions into project discovery. Only the fields consumed by cjdoc are
// exposed: package.name, workspace.members, and dependency inline-table path.
public class CjpmManifestView {
    public let packageName: ?String
    public let workspaceMembers: ArrayList<String>
    public let pathDependencies: ArrayList<String>

    public init(packageName: ?String, workspaceMembers: ArrayList<String>,
        pathDependencies: ArrayList<String>) {
        this.packageName = packageName
        this.workspaceMembers = workspaceMembers
        this.pathDependencies = pathDependencies
    }
}

public class CjpmLockedDependency {
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

private func collectTomlStrings(line: String, values: ArrayList<String>): Bool {
    var delimiterState: ?Rune = None
    var escaped = false
    var value = StringBuilder()
    for (rune in line.runes()) {
        match (delimiterState) {
            case Some(delimiter) =>
                if (escaped) {
                    value.append(rune)
                    escaped = false
                } else if (delimiter == r'"' && rune == r'\\') {
                    escaped = true
                } else if (rune == delimiter) {
                    values.add(value.toString())
                    value = StringBuilder()
                    delimiterState = None
                } else {
                    value.append(rune)
                }
            case None =>
                if (rune == r'#') { return false }
                if (rune == r'"' || rune == r'\'') {
                    delimiterState = rune
                } else if (rune == r']') {
                    return true
                }
        }
    }
    return false
}

private func parseWorkspaceMembers(manifest: String): ArrayList<String> {
    let members = ArrayList<String>()
    var inWorkspace = false
    var inMembers = false
    for (line in manifest.split("\n")) {
        let trimmed = line.trimAscii()
        if (!inMembers && trimmed.startsWith("[")) {
            inWorkspace = trimmed == "[workspace]"
            continue
        }
        if (!inWorkspace) { continue }
        if (!inMembers) {
            let parts = line.split("=")
            if (parts.size < 2 || parts[0].trimAscii() != "members") { continue }
            inMembers = true
        }
        if (collectTomlStrings(line, members)) { inMembers = false }
    }
    return members
}

private func parsePackageName(manifest: String): ?String {
    var inPackage = false
    for (line in manifest.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("[")) {
            inPackage = trimmed == "[package]"
            continue
        }
        if (!inPackage) { continue }
        let parts = line.split("=")
        if (parts.size < 2 || parts[0].trimAscii() != "name") { continue }
        let names = ArrayList<String>()
        let _ = collectTomlStrings(line, names)
        if (!names.isEmpty()) { return names[0] }
    }
    return None
}

private func isTomlNameByte(value: Byte): Bool {
    (value >= b'a' && value <= b'z') || (value >= b'A' && value <= b'Z') ||
        (value >= b'0' && value <= b'9') || value == b'_' || value == b'-'
}

private func tomlInlineStringField(line: String, field: String, initialBraceDepth: Int64): ?String {
    var delimiter: ?Byte = None
    var escaped = false
    var braceDepth = initialBraceDepth
    var index: Int64 = 0
    while (index < line.size) {
        let byte = line[index]
        match (delimiter) {
            case Some(quoteByte) =>
                if (escaped) {
                    escaped = false
                } else if (quoteByte == b'"' && byte == b'\\') {
                    escaped = true
                } else if (byte == quoteByte) {
                    delimiter = None
                }
                index++
            case None =>
                if (byte == b'#') { return None }
                if (byte == b'"' || byte == b'\'') {
                    delimiter = Some(byte)
                    index++
                    continue
                }
                if (byte == b'{') { braceDepth++; index++; continue }
                if (byte == b'}') { braceDepth--; index++; continue }
                let fieldEnd = index + field.size
                if (braceDepth == 1 && fieldEnd <= line.size && line[index..fieldEnd] == field &&
                    (index == 0 || !isTomlNameByte(line[index - 1])) &&
                    (fieldEnd == line.size || !isTomlNameByte(line[fieldEnd]))) {
                    var cursor = fieldEnd
                    while (cursor < line.size && (line[cursor] == b' ' || line[cursor] == b'\t')) { cursor++ }
                    if (cursor >= line.size || line[cursor] != b'=') { index = fieldEnd; continue }
                    cursor++
                    while (cursor < line.size && (line[cursor] == b' ' || line[cursor] == b'\t')) { cursor++ }
                    if (cursor >= line.size || (line[cursor] != b'"' && line[cursor] != b'\'')) { return None }
                    let quoteByte = line[cursor]
                    cursor++
                    let out = StringBuilder()
                    var valueEscaped = false
                    while (cursor < line.size) {
                        let current = line[cursor]
                        if (valueEscaped) {
                            out.append(String.fromUtf8([current]))
                            valueEscaped = false
                        } else if (quoteByte == b'"' && current == b'\\') {
                            valueEscaped = true
                        } else if (current == quoteByte) {
                            return Some(out.toString())
                        } else {
                            out.append(String.fromUtf8([current]))
                        }
                        cursor++
                    }
                    return None
                }
                index++
        }
    }
    None
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

private func parsePathDependencies(manifest: String): ArrayList<String> {
    let paths = ArrayList<String>()
    var inDependencies = false
    var braceDepth: Int64 = 0
    for (line in manifest.split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("[")) {
            inDependencies = trimmed == "[dependencies]"
            braceDepth = 0
            continue
        }
        if (!inDependencies) { continue }
        if (let Some(path) <- tomlInlineStringField(line, "path", braceDepth)) { paths.add(path) }
        braceDepth += tomlBraceDelta(line)
    }
    sort(paths)
    paths
}

public func parseCjpmManifest(manifest: String): CjpmManifestView {
    CjpmManifestView(parsePackageName(manifest), parseWorkspaceMembers(manifest),
        parsePathDependencies(manifest))
}

private func dependencyName(entry: String): ?String {
    let equals = entry.indexOf("=")
    if (equals.isNone()) { return None }
    let raw = entry[..equals.getOrThrow()].trimAscii()
    if (raw.isEmpty()) { return None }
    if ((raw.startsWith("\"") && raw.endsWith("\"")) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
        if (raw.size < 2) { return None }
        return Some(raw[1..raw.size - 1])
    }
    for (byte in raw.toArray()) {
        if (!isTomlNameByte(byte)) { return None }
    }
    Some(raw)
}

private func addLockedDependency(entry: String,
    dependencies: ArrayList<CjpmLockedDependency>): Unit {
    if (let Some(name) <- dependencyName(entry)) {
        let openBrace = entry.indexOf("{")
        if (openBrace.isNone()) { return }
        let braceAt = openBrace.getOrThrow()
        let body = entry[braceAt..]
        let git = tomlInlineStringField(body, "git", 0)
        let commitId = tomlInlineStringField(body, "commitId", 0)
        let version = tomlInlineStringField(body, "version", 0)
        if ((git.isSome() && commitId.isSome()) || version.isSome()) {
            dependencies.add(CjpmLockedDependency(name, git, commitId, version))
        }
    }
}

public func parseCjpmLock(lockText: String): ArrayList<CjpmLockedDependency> {
    let dependencies = ArrayList<CjpmLockedDependency>()
    var inRequires = false
    var entry = StringBuilder()
    var braceDepth: Int64 = 0
    for (line in lockText.split("\n")) {
        let trimmed = line.trimAscii()
        if (braceDepth == 0 && trimmed.startsWith("[")) {
            inRequires = trimmed == "[requires]"
            continue
        }
        if (!inRequires || (braceDepth == 0 && (trimmed.isEmpty() || trimmed.startsWith("#")))) {
            continue
        }
        if (!entry.toString().isEmpty()) { entry.append("\n") }
        entry.append(line)
        braceDepth += tomlBraceDelta(line)
        if (braceDepth < 0) {
            entry = StringBuilder()
            braceDepth = 0
            continue
        }
        if (braceDepth == 0) {
            addLockedDependency(entry.toString(), dependencies)
            entry = StringBuilder()
        }
    }
    sort(dependencies, lessThan: { left, right => left.name < right.name }, stable: true)
    dependencies
}
