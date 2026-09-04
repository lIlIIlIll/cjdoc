package cjdoc

import std.collection.*
import std.fs.*
import std.sort.*

internal func preflightOutput(root: Path, previous: OwnedOutputManifest,
    nextFiles: Array<OwnedOutputFile>, forceOwned: Bool): Array<PreviousOutputFile> {
    let previousPaths = ArrayList<String>()
    let previousDigests = HashMap<String, String>()
    let rollbackFiles = ArrayList<PreviousOutputFile>()
    let budget = OutputHashBudget()
    for (file in previous.files) {
        previousPaths.add(file.path)
        previousDigests.add(file.path, file.digest)
        ensureSafeExistingAncestors(root, file.path)
        let target = root.join(file.path)
        ensureRegularNonSymlink(target, "owned output artifact")
        let actual = digestRegularFile(target, "owned output artifact", budget)
        if (actual != file.digest && !forceOwned) {
            throw IllegalStateException("owned output artifact '${file.path}' was modified; use --force-owned to replace it")
        }
        rollbackFiles.add(PreviousOutputFile(file.path, file.digest, actual))
    }
    if (hasTopologyCollision(previousPaths.toArray())) {
        throw IllegalArgumentException("invalid cjdoc output manifest path topology")
    }

    if (!previous.hasDirectoryProvenance && !previous.directories.isEmpty() && !forceOwned) {
        throw IllegalStateException(
            "legacy cjdoc output manifest lacks directory provenance; use --force-owned to adopt its directories")
    }
    let previouslyOwnedDirectories = HashSet<String>()
    if (previous.hasDirectoryProvenance || forceOwned) {
        for (directory in previous.directories) {
            let _ = previouslyOwnedDirectories.add(directory)
        }
    }
    for (directory in ownedDirectoriesForFiles(nextFiles)) {
        let target = root.join(directory)
        if (!exists(target)) { continue }
        let info = FileInfo(target)
        if (info.isSymbolicLink() || !info.isDirectory()) {
            throw IllegalStateException("unsafe output parent '${target}' during preflight")
        }
        if (!previouslyOwnedDirectories.contains(directory) && !forceOwned) {
            throw IllegalStateException(
                "render artifact directory '${directory}' is unowned; use --force-owned to adopt it")
        }
    }

    let combinedPaths = previousPaths
    for (file in nextFiles) {
        ensureSafeExistingAncestors(root, file.path)
        let target = root.join(file.path)
        if (exists(target) && !previousDigests.contains(file.path)) {
            throw IllegalStateException("render artifact '${file.path}' collides with unowned output content")
        }
        if (!previousDigests.contains(file.path)) { combinedPaths.add(file.path) }
    }
    if (hasTopologyCollision(combinedPaths.toArray())) {
        throw IllegalStateException("output artifact paths have an unsafe file/directory topology change")
    }
    rollbackFiles.toArray()
}

internal func ensureParentDirectories(root: Path, relativePath: String,
    created: ArrayList<Path>, lock: OutputLockHandle): Unit {
    let parts = relativePath.split("/")
    var current = root
    var index: Int64 = 0
    while (index + 1 < parts.size) {
        current = current.join(parts[index])
        if (!exists(current)) {
            lockedDirectoryCreate(current, lock)
            created.add(current)
        } else {
            let info = FileInfo(current)
            if (info.isSymbolicLink() || !info.isDirectory()) {
                throw IllegalStateException("unsafe output parent '${current}' during commit")
            }
        }
        index++
    }
}

internal func pruneOwnedDirectories(root: Path, directories: Array<String>,
    lock: OutputLockHandle): Unit {
    let ordered = directories.clone()
    sort(ordered)
    var index = ordered.size - 1
    while (index >= 0) {
        let directory = root.join(ordered[index])
        if (exists(directory)) {
            let info = FileInfo(directory)
            if (!info.isSymbolicLink() && info.isDirectory() && Directory.isEmpty(directory)) {
                if (!lockedRemoveIfExists(directory, lock) || exists(directory)) {
                    throw IllegalStateException(
                        "unable to prune stale owned output directory '${directory}'")
                }
            }
        }
        index--
    }
}

internal func transactionPath(root: Path): Path {
    root.parent.join(OUTPUT_TRANSACTION_NAME)
}

internal func preparingPath(root: Path): Path {
    root.parent.join(OUTPUT_PREPARING_NAME)
}

internal func bootstrapPath(root: Path): Path {
    root.parent.join(OUTPUT_BOOTSTRAP_NAME)
}

internal func retiredPath(root: Path): Path {
    root.parent.join(OUTPUT_RETIRED_NAME)
}

internal func outputRootName(root: Path): String {
    let rootName = root.fileName
    if (!isSafeRootName(rootName) || collidesWithInternalSibling(rootName) ||
        root.parent.join(rootName).normalize() != root.normalize()) {
        throw IllegalArgumentException("output path must name a child directory of its parent: '${root}'")
    }
    rootName
}

internal func canonicalParentDigest(parent: Path): String {
    Sha256Digest.digest(canonicalize(parent).toString())
}

internal func resolveStateRoot(parent: Path, rootName: String, expectedParentDigest: String,
    description: String): Path {
    if (!isSafeRootName(rootName) || collidesWithInternalSibling(rootName)) {
        throw IllegalStateException("${description} contains an invalid output root name")
    }
    if (canonicalParentDigest(parent) != expectedParentDigest) {
        throw IllegalStateException("${description} does not belong to the locked physical parent")
    }
    let root = canonicalForWrite(parent.join(rootName), description)
    if (root.parent != parent || root.fileName != rootName) {
        throw IllegalStateException("${description} does not belong to locked parent '${parent}'")
    }
    root
}

internal func retireFixedState(path: Path, description: String,
    faults: TransactionFaultController, lock: OutputLockHandle): Unit {
    ensureOutputLockCurrent(lock)
    if (!exists(path)) {
        throw IllegalStateException("${description} disappeared before retirement: '${path}'")
    }
    let retired = path.parent.join(OUTPUT_RETIRED_NAME)
    if (exists(retired)) {
        throw IllegalStateException(
            "pending cjdoc retirement must be recovered before retiring ${description}")
    }
    try { lockedRename(path, retired, lock) } catch (error: Exception) {
        throw IllegalStateException("unable to retire ${description} '${path}': ${error.message}")
    }
    faults.hit("before-retired-delete")
    if (!lockedRemoveIfExists(retired, lock, recursive: true) || exists(retired)) {
        throw IllegalStateException("unable to delete retired ${description} '${retired}'")
    }
}

internal func ownedFileIndex(files: Array<OwnedOutputFile>): HashMap<String, OwnedOutputFile> {
    let index = HashMap<String, OwnedOutputFile>()
    for (file in files) { index.add(file.path, file) }
    index
}

internal func previousFileIndex(files: Array<PreviousOutputFile>): HashMap<String, PreviousOutputFile> {
    let index = HashMap<String, PreviousOutputFile>()
    for (file in files) { index.add(file.path, file) }
    index
}

internal func verifiedDigest(path: Path, expected: String, description: String,
    budget: OutputHashBudget): Unit {
    if (digestRegularFile(path, description, budget) != expected) {
        throw IllegalStateException("${description} digest does not match transaction plan: '${path}'")
    }
}

internal func manifestTextMatches(path: Path, expected: String): Bool {
    if (!exists(path)) { return false }
    let text = readCappedRegularText(path, "cjdoc output manifest", OUTPUT_MANIFEST_LIMIT)
    text == expected
}

internal func completeNextOutputIsPresent(root: Path, plan: OutputTransactionPlan): Bool {
    if (!exists(root) ||
        !manifestTextMatches(root.join(OUTPUT_MANIFEST_NAME), outputManifest(plan.next.files))) {
        return false
    }
    let budget = OutputHashBudget()
    for (file in plan.next.files) {
        let path = root.join(file.path)
        try { verifiedDigest(path, file.digest, "committed output artifact", budget) }
        catch (_: Exception) { return false }
    }
    true
}

internal func previousOutputIsPresent(root: Path, plan: OutputTransactionPlan): Bool {
    if (!plan.rootExisted) { return !exists(root) }
    if (!exists(root) ||
        !manifestTextMatches(root.join(OUTPUT_MANIFEST_NAME), plan.previousManifestText)) {
        return false
    }
    let budget = OutputHashBudget()
    for (file in plan.previous) {
        try { verifiedDigest(root.join(file.path), file.rollbackDigest,
            "rolled-back output artifact", budget) }
        catch (_: Exception) { return false }
    }
    true
}

internal func addExpectedParentDirectories(path: String, directories: HashSet<String>): Unit {
    let parts = path.split("/")
    let prefix = StringBuilder()
    var index: Int64 = 0
    while (index + 1 < parts.size) {
        if (index > 0) { prefix.append("/") }
        prefix.append(parts[index])
        let _ = directories.add(prefix.toString())
        index++
    }
}

internal func scanStagedTree(directory: Path, prefix: String,
    expectedDirectories: HashSet<String>, actualFiles: HashSet<String>, count: Int64): Int64 {
    var observed = count
    for (entry in Directory.readFrom(directory)) {
        observed++
        if (observed > OUTPUT_ENTRY_LIMIT) {
            throw IllegalStateException("staged output tree exceeds entry limit")
        }
        let relative = if (prefix.isEmpty()) { entry.name } else { "${prefix}/${entry.name}" }
        let info = FileInfo(entry.path)
        if (info.isSymbolicLink()) {
            throw IllegalStateException("staged output contains symbolic link '${relative}'")
        }
        if (info.isDirectory()) {
            if (!expectedDirectories.contains(relative)) {
                throw IllegalStateException("staged output contains unexpected directory '${relative}'")
            }
            observed = scanStagedTree(entry.path, relative, expectedDirectories, actualFiles, observed)
        } else if (info.isRegular()) {
            if (!actualFiles.add(relative)) {
                throw IllegalStateException("staged output contains duplicate file '${relative}'")
            }
        } else {
            throw IllegalStateException("staged output contains unsupported entry '${relative}'")
        }
    }
    observed
}

internal func validateStagedOutput(stage: Path, nextFiles: Array<OwnedOutputFile>): Unit {
    let expectedFiles = HashSet<String>()
    let expectedDirectories = HashSet<String>()
    let _ = expectedFiles.add(OUTPUT_MANIFEST_NAME)
    for (file in nextFiles) {
        let _ = expectedFiles.add(file.path)
        addExpectedParentDirectories(file.path, expectedDirectories)
    }
    let actualFiles = HashSet<String>()
    let _ = scanStagedTree(stage, "", expectedDirectories, actualFiles, 0)
    if (actualFiles.size != expectedFiles.size) {
        throw IllegalStateException("staged output file collection does not match transaction plan")
    }
    for (path in expectedFiles) {
        if (!actualFiles.contains(path)) {
            throw IllegalStateException("staged output is missing planned file '${path}'")
        }
    }
    if (!manifestTextMatches(stage.join(OUTPUT_MANIFEST_NAME), outputManifest(nextFiles))) {
        throw IllegalStateException("staged output manifest does not match transaction plan")
    }
    let budget = OutputHashBudget()
    for (file in nextFiles) {
        verifiedDigest(stage.join(file.path), file.digest, "staged output artifact", budget)
    }
}

internal func ensureTransactionCollectionDirectory(path: Path, description: String): Unit {
    if (!exists(path)) {
        throw IllegalStateException("missing ${description} directory '${path}'")
    }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid ${description} directory '${path}'")
    }
}
