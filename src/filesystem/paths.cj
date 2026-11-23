protected package cjdoc.filesystem

import std.collection.ArrayList
import std.env.getWorkingDirectory
import std.fs.*

private func ensureNoSymbolicLinkAncestorChain(path: Path, description: String): Unit {
    var current = path
    while (true) {
        if (exists(current) && FileInfo(current).isSymbolicLink()) {
            throw IllegalArgumentException(
                "${description} must not contain symbolic-link ancestor '${current}'")
        }
        let parent = current.parent
        if (parent.toString() == current.toString()) { break }
        current = parent
    }
}

protected func ensureNoSymbolicLinkAncestors(path: Path, description: String): Unit {
    let raw = if (path.isAbsolute()) { path } else { getWorkingDirectory().join(path) }
    ensureNoSymbolicLinkAncestorChain(raw, description)
    let normalized = raw.normalize()
    if (normalized.toString() != raw.toString()) {
        ensureNoSymbolicLinkAncestorChain(normalized, description)
    }
}

protected func canonicalForWrite(path: Path, description: String): Path {
    let unresolved = if (path.isAbsolute()) { path } else { getWorkingDirectory().join(path) }
    ensureNoSymbolicLinkAncestors(unresolved, description)
    let absolute = unresolved.normalize()
    let missing = ArrayList<String>()
    var existing = absolute
    while (!exists(existing)) {
        let parent = existing.parent
        if (parent.toString() == existing.toString()) {
            throw IllegalArgumentException("${description} has no existing filesystem ancestor: '${absolute}'")
        }
        missing.add(existing.fileName)
        existing = parent
    }
    var resolved = canonicalize(existing)
    var index = missing.size - 1
    while (index >= 0) {
        resolved = resolved.join(missing[index])
        index--
    }
    resolved.normalize()
}

protected func pathContains(ancestor: Path, candidate: Path): Bool {
    var current = candidate
    while (true) {
        if (current == ancestor ||
            (exists(current) && exists(ancestor) && FileInfo(current) == FileInfo(ancestor))) {
            return true
        }
        let parent = current.parent
        if (parent == current) { return false }
        current = parent
    }
    false
}

protected func ensureRegularNonSymlink(path: Path, description: String): Unit {
    if (!exists(path)) { throw IllegalArgumentException("missing ${description} '${path}'") }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isRegular()) {
        throw IllegalArgumentException("${description} must be a regular non-symbolic-link file: '${path}'")
    }
}

@When[os != "Windows"]
protected func hostPathIsAbsolute(value: String): Bool { value.startsWith("/") }

@When[os == "Windows"]
protected func hostPathIsAbsolute(value: String): Bool {
    if (value.startsWith("\\\\")) { return true }
    value.size >= 3 && ((value[0] >= b'A' && value[0] <= b'Z') ||
        (value[0] >= b'a' && value[0] <= b'z')) && value[1] == b':' &&
        (value[2] == b'\\' || value[2] == b'/')
}

protected func safeSourceRepositoryPath(path: String, allowEmpty!: Bool = false): Bool {
    if (path.isEmpty()) { return allowEmpty }
    if (path.startsWith("/") || path.contains("\\") || path.contains("\u{0}")) { return false }
    for (index in 0..path.size) {
        let byte = path[index]
        if (byte < 0x20u8 || byte == 0x7Fu8) { return false }
    }
    let segments = path.split("/")
    let first = segments[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}

protected func normalizedHostPath(path: String): String {
    // A backslash is a separator on Windows but ordinary filename data on
    // POSIX. Preserve it in absolute POSIX paths so host containment never
    // aliases `a\\b` with `a/b`; logical relative paths reject it.
    let normalized = if (path.startsWith("/")) { path } else { path.replace("\\", "/") }
    if (normalized.endsWith("/") && normalized != "/" && !normalized.endsWith(":/")) {
        normalized.trimEnd("/")
    } else {
        normalized
    }
}

protected func hostPathIsWithin(root: String, candidate: String): Bool {
    let normalizedRoot = normalizedHostPath(root)
    let normalizedCandidate = normalizedHostPath(candidate)
    let prefix = if (normalizedRoot.endsWith("/")) { normalizedRoot } else { normalizedRoot + "/" }
    normalizedCandidate == normalizedRoot || normalizedCandidate.startsWith(prefix)
}
