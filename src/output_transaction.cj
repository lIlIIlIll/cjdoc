package cjdoc

import cjdoc.render.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*
import yjson.*

private let OUTPUT_MANIFEST_NAME = ".cjdoc-output.json"
private let OUTPUT_MANIFEST_SCHEMA = "cjdoc.output/2"
private let OUTPUT_DIGEST_ALGORITHM = "sha256"

private class OwnedOutputFile {
    let path: String
    let digest: String

    init(path: String, digest: String) {
        this.path = path
        this.digest = digest
    }
}

private class OwnedOutputManifest {
    let files: Array<OwnedOutputFile>

    init(files: Array<OwnedOutputFile>) { this.files = files }
}

private class OutputLockOwner {
    let pid: Int64
    let startTime: String
    let token: String
    let root: String

    init(pid: Int64, startTime: String, token: String, root: String) {
        this.pid = pid
        this.startTime = startTime
        this.token = token
        this.root = root
    }
}

private class OutputLockHandle {
    let path: Path
    let token: String

    init(path: Path, token: String) {
        this.path = path
        this.token = token
    }
}

private class CommitFaultCounter {
    private let failAfter: ?Int64
    private var completed: Int64 = 0

    init(failAfter: ?Int64) { this.failAfter = failAfter }

    func operationCompleted(): Unit {
        completed++
        match (failAfter) {
            case Some(limit) =>
                if (completed == limit) {
                    throw IllegalStateException("injected output commit failure after operation ${completed}")
                }
            case None => ()
        }
    }
}

private func absoluteNormalized(path: Path): Path {
    if (path.isAbsolute()) { path.normalize() } else { getWorkingDirectory().join(path).normalize() }
}

private func isSafeOutputPath(path: String): Bool {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains(":")) { return false }
    if (path == OUTPUT_MANIFEST_NAME) { return false }
    let parts = path.split("/")
    if (parts.isEmpty()) { return false }
    for (part in parts) {
        if (part.isEmpty() || part == "." || part == "..") { return false }
    }
    Path(path).isRelative()
}

private func isSha256(value: String): Bool {
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

private func ensureRegularNonSymlink(path: Path, description: String): Unit {
    if (!exists(path)) { throw IllegalArgumentException("missing ${description} '${path}'") }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isRegular()) {
        throw IllegalArgumentException("${description} must be a regular non-symbolic-link file: '${path}'")
    }
}

private func ensureOutputRoot(root: Path): Unit {
    if (!exists(root)) { return }
    let info = FileInfo(root)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalArgumentException("output path must be a non-symbolic-link directory: '${root}'")
    }
}

private func ensureSafeExistingAncestors(root: Path, relativePath: String): Unit {
    ensureOutputRoot(root)
    let parts = relativePath.split("/")
    var current = root
    var index: Int64 = 0
    while (index + 1 < parts.size) {
        current = current.join(parts[index])
        if (exists(current)) {
            let info = FileInfo(current)
            if (info.isSymbolicLink() || !info.isDirectory()) {
                throw IllegalArgumentException("refusing unsafe output path ancestor '${current}'")
            }
        }
        index++
    }
}

private func readOwnedManifest(root: Path): OwnedOutputManifest {
    let manifestPath = root.join(OUTPUT_MANIFEST_NAME)
    ensureRegularNonSymlink(manifestPath, "cjdoc output manifest")
    let bytes = File.readFrom(manifestPath)
    if (bytes.size > 8 * 1024 * 1024) {
        throw IllegalArgumentException("cjdoc output manifest exceeds 8 MiB")
    }
    let parsed = YJson.parse(String.fromUtf8(bytes), config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 8, maxStringBytes: 1024 * 1024,
            maxBytes: 8 * 1024 * 1024)))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest: expected object")
    }
    if (object.size() != 3 || object.get("schemaVersion").isNone() ||
        object.get("digestAlgorithm").isNone() || object.get("files").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output manifest fields")
    }
    let schema = try { object["schemaVersion"].string } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest schemaVersion")
    }
    if (schema != OUTPUT_MANIFEST_SCHEMA) {
        throw IllegalArgumentException("unsupported cjdoc output manifest '${schema}'")
    }
    let algorithm = try { object["digestAlgorithm"].string } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest digestAlgorithm")
    }
    if (algorithm != OUTPUT_DIGEST_ALGORITHM) {
        throw IllegalArgumentException("unsupported cjdoc output digest algorithm '${algorithm}'")
    }
    let entries = try { object["files"].asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest files")
    }
    let files = ArrayList<OwnedOutputFile>()
    let seen = HashSet<String>()
    for (node in entries.values()) {
        let entry = try { node.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("invalid cjdoc output manifest file entry")
        }
        if (entry.size() != 2 || entry.get("path").isNone() || entry.get("sha256").isNone()) {
            throw IllegalArgumentException("invalid cjdoc output manifest file entry fields")
        }
        let path = try { entry["path"].string } catch (_: Exception) {
            throw IllegalArgumentException("invalid cjdoc output manifest file path")
        }
        let digest = try { entry["sha256"].string } catch (_: Exception) {
            throw IllegalArgumentException("invalid cjdoc output manifest file digest")
        }
        if (!isSafeOutputPath(path) || seen.contains(path) || !isSha256(digest)) {
            throw IllegalArgumentException("invalid owned output entry '${path}'")
        }
        let _ = seen.add(path)
        files.add(OwnedOutputFile(path, digest))
    }
    OwnedOutputManifest(files.toArray())
}

private func orderedOwnedFiles(artifacts: Array<RenderArtifact>): Array<OwnedOutputFile> {
    let digests = HashMap<String, String>()
    let paths = ArrayList<String>()
    for (artifact in artifacts) {
        if (!isSafeOutputPath(artifact.path) || digests.contains(artifact.path)) {
            throw IllegalArgumentException("duplicate or unsafe render artifact '${artifact.path}'")
        }
        digests.add(artifact.path, Sha256Digest.digestBytes(artifact.bytes))
        paths.add(artifact.path)
    }
    let ordered = paths.toArray()
    sort(ordered)
    let files = ArrayList<OwnedOutputFile>()
    for (path in ordered) { files.add(OwnedOutputFile(path, digests[path])) }
    files.toArray()
}

private func outputManifest(files: Array<OwnedOutputFile>): String {
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"${OUTPUT_MANIFEST_SCHEMA}\",\n")
    out.append("  \"digestAlgorithm\": \"${OUTPUT_DIGEST_ALGORITHM}\",\n  \"files\": [")
    var index: Int64 = 0
    while (index < files.size) {
        if (index > 0) { out.append(",") }
        out.append("\n    {\"path\": ${escapeJsonString(files[index].path)}, ")
        out.append("\"sha256\": ${escapeJsonString(files[index].digest)}}")
        index++
    }
    if (!files.isEmpty()) { out.append("\n  ") }
    out.append("]\n}\n")
    out.toString()
}

private func hasTopologyCollision(paths: Array<String>): Bool {
    let ordered = paths.clone()
    sort(ordered)
    var index: Int64 = 1
    while (index < ordered.size) {
        if (ordered[index].startsWith(ordered[index - 1] + "/")) { return true }
        index++
    }
    false
}

private func outputLockOwnerContent(owner: OutputLockOwner): String {
    "{\"schemaVersion\":\"cjdoc.output-lock/1\",\"pid\":${escapeJsonString(owner.pid.toString())}," +
        "\"startTime\":${escapeJsonString(owner.startTime)},\"token\":${escapeJsonString(owner.token)}," +
        "\"root\":${escapeJsonString(owner.root)}}\n"
}

private func readOutputLockOwner(lockPath: Path): OutputLockOwner {
    let ownerPath = lockPath.join("owner.json")
    ensureRegularNonSymlink(ownerPath, "cjdoc output lock owner")
    let bytes = File.readFrom(ownerPath)
    if (bytes.size > 64 * 1024) { throw IllegalArgumentException("cjdoc output lock owner exceeds 64 KiB") }
    let parsed = YJson.parse(String.fromUtf8(bytes), config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 4, maxStringBytes: 16 * 1024, maxBytes: 64 * 1024)))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output lock owner")
    }
    if (object.size() != 5 || object.get("schemaVersion").isNone() || object.get("pid").isNone() ||
        object.get("startTime").isNone() || object.get("token").isNone() || object.get("root").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output lock owner fields")
    }
    let schema = try { object["schemaVersion"].string } catch (_: Exception) { "" }
    let pid = try { Int64.parse(object["pid"].string) } catch (_: Exception) { -1 }
    let startTime = try { object["startTime"].string } catch (_: Exception) { "" }
    let token = try { object["token"].string } catch (_: Exception) { "" }
    let root = try { object["root"].string } catch (_: Exception) { "" }
    if (schema != "cjdoc.output-lock/1" || pid <= 0 || startTime.isEmpty() ||
        token.isEmpty() || root.isEmpty()) {
        throw IllegalArgumentException("invalid cjdoc output lock owner values")
    }
    OutputLockOwner(pid, startTime, token, root)
}

private func ownerProcessIsAlive(owner: OutputLockOwner): Bool {
    try {
        let process = findProcess(owner.pid)
        process.isAlive() && process.startTime.toString() == owner.startTime
    } catch (_: Exception) { false }
}

private func removeBestEffort(path: Path, recursive!: Bool = false): Unit {
    try { let _ = removeIfExists(path, recursive: recursive) } catch (_: Exception) {}
}

private func acquireOutputLock(root: Path): OutputLockHandle {
    let absoluteRoot = absoluteNormalized(root)
    let parent = absoluteRoot.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    let lockPath = parent.join(".cjdoc-output-${Sha256Digest.digest(absoluteRoot.toString())[0..20]}.lock")
    let pid = getProcessId()
    let startTime = findProcess(pid).startTime.toString()
    var attempt: Int64 = 0
    while (attempt < 2) {
        let candidate = Directory.createTemp(parent)
        let token = Sha256Digest.digest("${pid}|${startTime}|${candidate}")
        let owner = OutputLockOwner(pid, startTime, token, absoluteRoot.toString())
        try {
            File.writeTo(candidate.join("owner.json"), outputLockOwnerContent(owner).toArray())
            rename(candidate, to: lockPath, overwrite: false)
            return OutputLockHandle(lockPath, token)
        } catch (error: Exception) {
            removeBestEffort(candidate, recursive: true)
            if (!exists(lockPath)) {
                throw IllegalStateException("unable to acquire output lock '${lockPath}': ${error.message}")
            }
            let existing = try { readOutputLockOwner(lockPath) } catch (_: Exception) {
                throw IllegalStateException("output lock '${lockPath}' is invalid; refusing unsafe recovery")
            }
            if (existing.root != absoluteRoot.toString() || ownerProcessIsAlive(existing)) {
                throw IllegalStateException("output directory '${absoluteRoot}' is locked by process ${existing.pid}")
            }
            let quarantine = Directory.createTemp(parent)
            removeBestEffort(quarantine, recursive: true)
            try { rename(lockPath, to: quarantine, overwrite: false) } catch (_: Exception) {
                throw IllegalStateException("output lock '${lockPath}' changed during stale-lock recovery")
            }
            removeBestEffort(quarantine, recursive: true)
        }
        attempt++
    }
    throw IllegalStateException("unable to acquire output lock '${lockPath}'")
}

private func releaseOutputLock(handle: OutputLockHandle): Unit {
    try {
        if (!exists(handle.path)) { return }
        let owner = readOutputLockOwner(handle.path)
        if (owner.token == handle.token) { removeBestEffort(handle.path, recursive: true) }
    } catch (_: Exception) {}
}

internal func withOutputLock(outputDirectory: String, action: () -> Unit): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    try { action() } finally { releaseOutputLock(handle) }
}

internal func withOutputLockResult(outputDirectory: String, action: () -> Int64): Int64 {
    let handle = acquireOutputLock(Path(outputDirectory))
    try { action() } finally { releaseOutputLock(handle) }
}

private func preflightOutput(root: Path, previous: OwnedOutputManifest,
    nextFiles: Array<OwnedOutputFile>, forceOwned: Bool): Unit {
    let previousPaths = ArrayList<String>()
    let previousDigests = HashMap<String, String>()
    for (file in previous.files) {
        previousPaths.add(file.path)
        previousDigests.add(file.path, file.digest)
        ensureSafeExistingAncestors(root, file.path)
        let target = root.join(file.path)
        ensureRegularNonSymlink(target, "owned output artifact")
        let actual = Sha256Digest.digestBytes(File.readFrom(target))
        if (actual != file.digest && !forceOwned) {
            throw IllegalStateException("owned output artifact '${file.path}' was modified; use --force-owned to replace it")
        }
    }
    if (hasTopologyCollision(previousPaths.toArray())) {
        throw IllegalArgumentException("invalid cjdoc output manifest path topology")
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
}

private func ensureParentDirectories(root: Path, relativePath: String,
    created: ArrayList<Path>): Unit {
    let parts = relativePath.split("/")
    var current = root
    var index: Int64 = 0
    while (index + 1 < parts.size) {
        current = current.join(parts[index])
        if (!exists(current)) {
            Directory.create(current)
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

private func pruneOwnedParents(root: Path, paths: Array<String>): Unit {
    for (relativePath in paths) {
        let parts = relativePath.split("/")
        var depth = parts.size - 1
        while (depth > 0) {
            let prefix = StringBuilder()
            var index: Int64 = 0
            while (index < depth) {
                if (index > 0) { prefix.append("/") }
                prefix.append(parts[index])
                index++
            }
            let directory = root.join(prefix.toString())
            if (exists(directory) && FileInfo(directory).isDirectory() && Directory.readFrom(directory).isEmpty()) {
                let _ = removeIfExists(directory)
            } else { break }
            depth--
        }
    }
}

private func stageOutput(parent: Path, artifacts: Array<RenderArtifact>,
    files: Array<OwnedOutputFile>): Path {
    let stage = Directory.createTemp(parent)
    try {
        for (artifact in artifacts) {
            let target = stage.join(artifact.path)
            let ignored = ArrayList<Path>()
            ensureParentDirectories(stage, artifact.path, ignored)
            File.writeTo(target, artifact.bytes)
            if (Sha256Digest.digestBytes(File.readFrom(target)) !=
                Sha256Digest.digestBytes(artifact.bytes)) {
                throw IllegalStateException("staged output digest mismatch for '${artifact.path}'")
            }
        }
        File.writeTo(stage.join(OUTPUT_MANIFEST_NAME), outputManifest(files).toArray())
        stage
    } catch (error: Exception) {
        removeBestEffort(stage, recursive: true)
        throw error
    }
}

private func rollbackOutput(root: Path, backup: Path, rootExisted: Bool,
    installed: ArrayList<String>, moved: ArrayList<String>, created: ArrayList<Path>,
    manifestInstalled: Bool, manifestMoved: Bool): Bool {
    var failed = false
    if (manifestInstalled) {
        try { let _ = removeIfExists(root.join(OUTPUT_MANIFEST_NAME)) } catch (_: Exception) { failed = true }
    }
    var index = installed.size - 1
    while (index >= 0) {
        try { let _ = removeIfExists(root.join(installed[index])) } catch (_: Exception) { failed = true }
        index--
    }
    index = moved.size - 1
    while (index >= 0) {
        try {
            let ignored = ArrayList<Path>()
            ensureParentDirectories(root, moved[index], ignored)
            rename(backup.join(moved[index]), to: root.join(moved[index]), overwrite: false)
        } catch (_: Exception) { failed = true }
        index--
    }
    if (manifestMoved) {
        try { rename(backup.join(OUTPUT_MANIFEST_NAME), to: root.join(OUTPUT_MANIFEST_NAME), overwrite: false) }
        catch (_: Exception) { failed = true }
    }
    index = created.size - 1
    while (index >= 0) {
        try {
            if (exists(created[index]) && Directory.readFrom(created[index]).isEmpty()) {
                let _ = removeIfExists(created[index])
            }
        } catch (_: Exception) { failed = true }
        index--
    }
    if (!rootExisted) {
        try { let _ = removeIfExists(root, recursive: true) } catch (_: Exception) { failed = true }
    }
    !failed
}

private func commitOutput(root: Path, stage: Path, previous: OwnedOutputManifest,
    nextFiles: Array<OwnedOutputFile>, faultAfterOperation: ?Int64): Unit {
    let parent = root.parent
    let backup = Directory.createTemp(parent)
    let installed = ArrayList<String>()
    let moved = ArrayList<String>()
    let created = ArrayList<Path>()
    let fault = CommitFaultCounter(faultAfterOperation)
    let rootExisted = exists(root)
    var manifestMoved = false
    var manifestInstalled = false
    try {
        if (!rootExisted) { Directory.create(root) }
        let previousPaths = ArrayList<String>()
        for (file in previous.files) { previousPaths.add(file.path) }
        let orderedPrevious = previousPaths.toArray()
        sort(orderedPrevious)
        for (path in orderedPrevious) {
            let ignored = ArrayList<Path>()
            ensureParentDirectories(backup, path, ignored)
            rename(root.join(path), to: backup.join(path), overwrite: false)
            moved.add(path)
            fault.operationCompleted()
        }
        if (rootExisted) {
            rename(root.join(OUTPUT_MANIFEST_NAME), to: backup.join(OUTPUT_MANIFEST_NAME), overwrite: false)
            manifestMoved = true
            fault.operationCompleted()
        }
        for (file in nextFiles) {
            ensureParentDirectories(root, file.path, created)
            rename(stage.join(file.path), to: root.join(file.path), overwrite: false)
            installed.add(file.path)
            fault.operationCompleted()
        }
        rename(stage.join(OUTPUT_MANIFEST_NAME), to: root.join(OUTPUT_MANIFEST_NAME), overwrite: false)
        manifestInstalled = true
        fault.operationCompleted()
        pruneOwnedParents(root, orderedPrevious)
    } catch (error: Exception) {
        let restored = rollbackOutput(root, backup, rootExisted, installed, moved, created,
            manifestInstalled, manifestMoved)
        removeBestEffort(stage, recursive: true)
        if (!restored) {
            throw IllegalStateException("output transaction failed and rollback was incomplete: ${error.message}")
        }
        removeBestEffort(backup, recursive: true)
        throw error
    }
    removeBestEffort(stage, recursive: true)
    removeBestEffort(backup, recursive: true)
}

private func writeOwnedArtifactsLocked(outputDirectory: String, artifacts: Array<RenderArtifact>,
    forceOwned: Bool, faultAfterOperation: ?Int64): Unit {
    let root = absoluteNormalized(Path(outputDirectory))
    ensureOutputRoot(root)
    let nextFiles = orderedOwnedFiles(artifacts)
    let nextPaths = ArrayList<String>()
    for (file in nextFiles) { nextPaths.add(file.path) }
    if (hasTopologyCollision(nextPaths.toArray())) {
        throw IllegalArgumentException("render artifacts have conflicting file/directory paths")
    }

    let previous = if (exists(root)) { readOwnedManifest(root) } else { OwnedOutputManifest([]) }
    if (exists(root)) { preflightOutput(root, previous, nextFiles, forceOwned) }
    let parent = root.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    let stage = stageOutput(parent, artifacts, nextFiles)
    commitOutput(root, stage, previous, nextFiles, faultAfterOperation)
}

internal func writeOwnedArtifactsWithLockHeld(outputDirectory: String,
    artifacts: Array<RenderArtifact>, forceOwned!: Bool = false,
    faultAfterOperation!: ?Int64 = None): Unit {
    writeOwnedArtifactsLocked(outputDirectory, artifacts, forceOwned, faultAfterOperation)
}

internal func writeOwnedArtifacts(outputDirectory: String, artifacts: Array<RenderArtifact>,
    forceOwned!: Bool = false, faultAfterOperation!: ?Int64 = None): Unit {
    withOutputLock(outputDirectory, { =>
        writeOwnedArtifactsLocked(outputDirectory, artifacts, forceOwned, faultAfterOperation)
    })
}
