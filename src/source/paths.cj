protected package cjdoc.source

import cjdoc.filesystem.{hostPathIsWithin, normalizedHostPath}
import std.fs.*

protected func safeLogicalSourcePath(path: String, allowEmpty!: Bool = false): Bool {
    if (path.isEmpty()) { return allowEmpty }
    if (path.startsWith("/") || path.contains("\\")) { return false }
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

internal func safePackageSourceDirectory(path: String): Bool {
    if (path.isEmpty() || path == ".") { return true }
    safeLogicalSourcePath(path)
}

protected func resolvedPackageSourceRoot(moduleRoot: String,
    configured: ?String): ?String {
    let relative = match (configured) {
        case Some(value) => if (value.isEmpty()) { "src" } else { value }
        case None => "src"
    }
    if (!safePackageSourceDirectory(relative)) { return None }
    let candidate = if (relative == ".") {
        moduleRoot
    } else {
        Path(moduleRoot).join(relative).toString()
    }
    let resolved = try { canonicalize(candidate).toString() } catch (_: Exception) { return None }
    if (!hostPathIsWithin(moduleRoot, resolved)) { return None }
    let directory = try { FileInfo(resolved) } catch (_: Exception) { return None }
    if (!directory.isDirectory() || directory.isSymbolicLink()) { return None }
    Some(resolved)
}

protected func relativePathFromResolved(root: String, path: String): ?String {
    let base = normalizedHostPath(root)
    let full = normalizedHostPath(path)
    if (full == base) { return Some("") }
    let prefix = if (base.endsWith("/")) { base } else { base + "/" }
    if (!full.startsWith(prefix)) { return None }
    let relative = full[prefix.size..]
    if (!safeLogicalSourcePath(relative)) { return None }
    Some(relative)
}

protected func relativePath(root: String, path: String): ?String {
    let base = canonicalize(root).toString()
    let full = canonicalize(path).toString()
    relativePathFromResolved(base, full)
}

protected func normalizeSourceNewlines(source: String): String {
    source.replace("\r\n", "\n").replace("\r", "\n")
}
