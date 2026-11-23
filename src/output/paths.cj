protected package cjdoc.output

import cjdoc.filesystem.{
    canonicalForWrite, ensureNoSymbolicLinkAncestors, pathContains, readTextBounded}
import cjdoc.render.routes.portableFileNameKey
import std.fs.*

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

protected func prepareOutputAndCacheDirectories(outputDirectory: String,
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

protected func isSafeOutputPath(path: String): Bool {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains(":")) { return false }
    if (path == OUTPUT_MANIFEST_NAME) { return false }
    let parts = path.split("/")
    if (parts.isEmpty()) { return false }
    for (part in parts) {
        if (part.isEmpty() || part == "." || part == "..") { return false }
    }
    Path(path).isRelative()
}

