package cjdoc

import std.collection.*
import std.env.*
import std.fs.*

internal func ensureNoSymbolicLinkAncestorChain(path: Path, description: String): Unit {
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

internal func ensureNoSymbolicLinkAncestors(path: Path, description: String): Unit {
    let raw = if (path.isAbsolute()) { path } else { getWorkingDirectory().join(path) }
    ensureNoSymbolicLinkAncestorChain(raw, description)
    let normalized = raw.normalize()
    if (normalized.toString() != raw.toString()) {
        ensureNoSymbolicLinkAncestorChain(normalized, description)
    }
}

internal func canonicalForWrite(path: Path, description: String): Path {
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

internal func pathContains(ancestor: Path, candidate: Path): Bool {
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

internal func portablePathKey(path: Path): String {
    let normalized = path.normalize().toString().replace("\\", "/")
    let out = StringBuilder()
    let parts = normalized.split("/")
    var index: Int64 = 0
    for (part in parts) {
        if (index > 0) { out.append("/") }
        out.append(portableFileNameKey(part))
        index++
    }
    out.toString()
}

internal func portablePathContains(ancestor: Path, candidate: Path): Bool {
    let ancestorKey = portablePathKey(ancestor)
    let candidateKey = portablePathKey(candidate)
    candidateKey == ancestorKey || candidateKey.startsWith(ancestorKey + "/")
}

internal func pathsOverlapIncludingPortableAliases(first: Path, second: Path): Bool {
    pathContains(first, second) || pathContains(second, first) ||
        portablePathContains(first, second) || portablePathContains(second, first)
}

internal func internalSiblingPaths(output: Path): Array<Path> {
    let parent = output.parent
    [
        parent.join(OUTPUT_LOCK_NAME),
        parent.join(OUTPUT_LOCK_BOOTSTRAP_NAME),
        parent.join(OUTPUT_RETIRED_LOCK_NAME),
        parent.join(OUTPUT_BOOTSTRAP_NAME),
        parent.join(OUTPUT_PREPARING_NAME),
        parent.join(OUTPUT_TRANSACTION_NAME),
        parent.join(OUTPUT_RETIRED_NAME)
    ]
}

internal func prepareOutputAndCacheDirectories(outputDirectory: String,
    cacheDirectory: ?String): (String, ?String) {
    let output = canonicalForWrite(Path(outputDirectory), "output path")
    if (!isSafeRootName(output.fileName) || collidesWithInternalSibling(output.fileName)) {
        throw IllegalArgumentException("output path collides with reserved cjdoc transaction state")
    }
    match (cacheDirectory) {
        case Some(rawCache) =>
            let cache = canonicalForWrite(Path(rawCache), "source cache path")
            if (pathsOverlapIncludingPortableAliases(output, cache)) {
                throw IllegalArgumentException(
                    "output directory '${output}' and source cache directory '${cache}' overlap")
            }
            for (internalPath in internalSiblingPaths(output)) {
                if (pathsOverlapIncludingPortableAliases(internalPath, cache)) {
                    throw IllegalArgumentException(
                        "source cache directory '${cache}' collides with reserved cjdoc transaction state")
                }
            }
            (output.toString(), Some(cache.toString()))
        case None => (output.toString(), None)
    }
}

internal func readCappedRegularText(path: Path, description: String, limit: Int64): String {
    ensureNoSymbolicLinkAncestors(path, description)
    readTextBounded(path, limit)
}

internal func isSafeOutputPath(path: String): Bool {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains(":")) { return false }
    if (path == OUTPUT_MANIFEST_NAME) { return false }
    let parts = path.split("/")
    if (parts.isEmpty()) { return false }
    for (part in parts) {
        if (part.isEmpty() || part == "." || part == "..") { return false }
    }
    Path(path).isRelative()
}

internal func isSha256(value: String): Bool {
    if (value.size != 64) { return false }
    for (rune in value.runes()) {
        match (rune) {
            case '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9' |
                'a' | 'b' | 'c' | 'd' | 'e' | 'f' => ()
            case _ => return false
        }
    }
    true
}

internal func ensureRegularNonSymlink(path: Path, description: String): Unit {
    if (!exists(path)) { throw IllegalArgumentException("missing ${description} '${path}'") }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isRegular()) {
        throw IllegalArgumentException("${description} must be a regular non-symbolic-link file: '${path}'")
    }
}
