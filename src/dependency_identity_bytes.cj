package cjdoc

import std.collection.*
import std.fs.*
import std.time.*

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

private func dependencyArtifactDigest(path: Path, budget: SourceAuxiliaryBudget,
    expectedSize!: ?Int64 = None): (String, Int64, DateTime, DateTime) {
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
    (digest.finish(), size, creation, modified)
}

private func dependencySourceDigest(path: Path, budget: SourceAuxiliaryBudget): (String, Int64, DateTime, DateTime) {
    // Keep the byte-bearing snapshot in this frame, not the multi-file loop.
    let snapshot = readAuxiliaryFileBoundedSnapshot(path, DEPENDENCY_IDENTITY_FILE_BYTES, budget)
    (Sha256Digest.digestBytes(snapshot.bytes), snapshot.size, snapshot.creationTime, snapshot.lastModificationTime)
}


internal func dependencyObservedIdentity(path: String, source: Bool,
    byteBudget!: ?SourceAuxiliaryBudget = None, directoryBudget!: ?SourceDirectoryBudget = None,
    manifestDigest!: Option<(String) -> Unit> = None): String {
    let root = canonicalize(path).toString()
    let info = FileInfo(root)
    if (info.isSymbolicLink()) { throw IllegalArgumentException("dependency input is a symbolic link") }
    let budget = byteBudget.getOrDefault({ => SourceAuxiliaryBudget(DEPENDENCY_IDENTITY_BYTES, DEPENDENCY_IDENTITY_BYTES) })
    if (info.isRegular()) {
        if (source) { throw IllegalArgumentException("source dependency must be a directory") }
        let (digest, _, _, _) = dependencyArtifactDigest(Path(root), budget)
        return "sha256:" + digest
    }
    if (!info.isDirectory()) { throw IllegalArgumentException("dependency input is not a file or directory") }
    let entries = directoryBudget.getOrDefault({ => SourceDirectoryBudget(maxEntries: 100000, maxDepth: 128) })
    let files = ArrayList<String>()
    dependencyInventoryFiles(root, source, files, entries)
    sortStrings(files)
    if (files.isEmpty()) { throw IllegalArgumentException("dependency inventory is empty") }
    let inventory = StringBuilder()
    inventory.append("cjdoc.dependency-inventory/1\n")
    let observed = ArrayList<(Int64, DateTime, DateTime)>()
    for (relative in files) {
        let current = Path(root).join(relative)
        let (digest, size, creation, modified) = if (source) {
            dependencySourceDigest(current, budget)
        } else {
            let expectedSize = FileInfo(current).size
            dependencyArtifactDigest(current, budget, expectedSize: Some(expectedSize))
        }
        observed.add((size, creation, modified))
        if (source && relative == "cjpm.toml") {
            if (let Some(capture) <- manifestDigest) { capture(digest) }
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
    // A stable individual read does not prove the earlier files or tree
    // membership survived while later files were hashed. Revisit the same scope
    // without charging its entries or content bytes twice to the shared budgets.
    let finalFiles = ArrayList<String>()
    dependencyInventoryFiles(root, source, finalFiles,
        SourceDirectoryBudget(maxEntries: entries.maxEntries, maxDepth: entries.maxDepth))
    sortStrings(finalFiles)
    if (finalFiles.size != files.size) {
        throw IllegalArgumentException("dependency artifact changed while hashing")
    }
    for (index in 0..files.size) {
        if (finalFiles[index] != files[index]) {
            throw IllegalArgumentException("dependency artifact changed while hashing")
        }
        let metadata = FileInfo(Path(root).join(finalFiles[index]))
        let (size, creation, modified) = observed[index]
        if (!metadata.isRegular() || metadata.isSymbolicLink() || metadata.size != size ||
            metadata.creationTime != creation || metadata.lastModificationTime != modified) {
            throw IllegalArgumentException("dependency artifact changed while hashing")
        }
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
