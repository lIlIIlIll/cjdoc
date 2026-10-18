package cjdoc

import std.collection.*
import std.fs.*

// These limits apply to observation, not to assertions in a build record.
private let DEPENDENCY_IDENTITY_BYTES: Int64 = 512 * 1024 * 1024
private let DEPENDENCY_IDENTITY_FILE_BYTES: Int64 = 64 * 1024 * 1024

private func dependencyInventoryFiles(root: String, source: Bool,
    files: ArrayList<String>, budget: SourceDirectoryBudget): Unit {
    // Bound depth with the inventory budget instead of the VM call stack.
    let pending = ArrayList<String>()
    pending.add(root)
    while (!pending.isEmpty()) {
        let directory = pending.remove(at: pending.size - 1)
        Directory.walk(Path(directory), { entry =>
            let relative = relativePathFromResolved(root, entry.path.toString()).getOrThrow()
            if (!budget.consume(relative)) { throw IllegalArgumentException("dependency inventory limit exceeded") }
            if (entry.name.startsWith(".") || (source && entry.name == "target")) { return true }
            if (entry.isSymbolicLink()) { throw IllegalArgumentException("dependency inventory contains a symbolic link") }
            if (entry.isDirectory()) {
                pending.add(entry.path.toString())
            } else if (entry.isRegular() && (!source || entry.path.extensionName == "cj" ||
                entry.name == "cjpm.toml" || entry.name == "cjpm.lock")) {
                files.add(relative)
            }
            true
        })
    }
}

private func dependencyArtifactDigest(path: Path, budget: SourceAuxiliaryBudget, expectedSize!: ?Int64 = None): String {
    let before = FileInfo(path)
    let size = before.size
    if (let Some(expected) <- expectedSize) {
        if (size != expected) { throw IllegalArgumentException("dependency artifact changed before hashing") }
    }
    let creation = before.creationTime
    let modified = before.lastModificationTime
    if (!before.isRegular() || before.isSymbolicLink() || size < 0 ||
        !budget.consumeBytes(size) || !budget.consumeWork(size)) {
        throw IllegalArgumentException("dependency artifact observation budget exceeded")
    }
    let file = File(path, OpenMode.Read)
    let digest = StreamingOutputSha256()
    var total: Int64 = 0
    try {
        let opened = file.info
        if (!opened.isRegular() || opened.isSymbolicLink() || opened.size != size ||
            opened.creationTime != creation || opened.lastModificationTime != modified || file.length != size) {
            throw IllegalArgumentException("dependency artifact changed while opening")
        }
        let buffer = Array<Byte>(64 * 1024, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count < 0 || count > buffer.size || count > size - total) {
                throw IllegalArgumentException("dependency artifact changed while reading")
            }
            if (count == 0) { break }
            digest.update(buffer, count); total += count
        }
        if (total != size || file.length != size) { throw IllegalArgumentException("dependency artifact changed while reading") }
    } finally { file.close() }
    let after = FileInfo(path)
    if (!after.isRegular() || after.isSymbolicLink() || after.size != size ||
        after.creationTime != creation || after.lastModificationTime != modified) {
        throw IllegalArgumentException("dependency artifact changed while hashing")
    }
    digest.finish()
}


internal func dependencyObservedIdentity(path: String, source: Bool,
    byteBudget!: ?SourceAuxiliaryBudget = None, directoryBudget!: ?SourceDirectoryBudget = None): String {
    let root = canonicalize(path).toString()
    let info = FileInfo(root)
    if (info.isSymbolicLink()) { throw IllegalArgumentException("dependency input is a symbolic link") }
    let budget = byteBudget.getOrDefault({ => SourceAuxiliaryBudget(DEPENDENCY_IDENTITY_BYTES, DEPENDENCY_IDENTITY_BYTES) })
    if (info.isRegular()) {
        if (source) { throw IllegalArgumentException("source dependency must be a directory") }
        return "sha256:" + dependencyArtifactDigest(Path(root), budget)
    }
    if (!info.isDirectory()) { throw IllegalArgumentException("dependency input is not a file or directory") }
    let files = ArrayList<String>()
    dependencyInventoryFiles(root, source, files,
        directoryBudget.getOrDefault({ => SourceDirectoryBudget(maxEntries: 100000, maxDepth: 128) }))
    sortStrings(files)
    if (files.isEmpty()) { throw IllegalArgumentException("dependency inventory is empty") }
    let inventory = StringBuilder()
    inventory.append("cjdoc.dependency-inventory/1\n")
    for (relative in files) {
        let current = Path(root).join(relative)
        let (size, digest) = if (source) {
            let bytes = readAuxiliaryFileBounded(current, DEPENDENCY_IDENTITY_FILE_BYTES, budget)
            // The length and digest must describe the same stable read.
            (bytes.size, Sha256Digest.digestBytes(bytes))
        } else {
            let size = FileInfo(current).size
            (size, dependencyArtifactDigest(current, budget, expectedSize: Some(size)))
        }
        inventory.append(relative.size.toString())
        inventory.append(":")
        inventory.append(relative)
        inventory.append(":")
        inventory.append(size.toString())
        inventory.append(":")
        inventory.append(digest)
        inventory.append("\n")
    }
    "sha256:" + Sha256Digest.digest(inventory.toString())
}

// Local paths and timestamps never participate in the portable content identity.
internal func dependencySourceIdentity(root: String): String {
    dependencyObservedIdentity(root, true)
}

internal func dependencyCfg(request: GenerationRequest): String {
    let result = StringBuilder()
    var first = true
    for (value in request.cfgValues) {
        if (!first) { result.append("\n") }
        first = false
        result.append(value.name + "=" + value.value)
    }
    result.toString()
}

internal func dependencyTarget(request: GenerationRequest): String {
    for (value in request.cfgValues) { if (value.name == "target") { return value.value } }
    ""
}
