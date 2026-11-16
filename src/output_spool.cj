package cjdoc

import cjdoc.render.*
import std.collection.*
import std.fs.*

private class SpoolArtifactEntry {
    let path: String
    let mediaType: String
    let text: Bool
    var storageName: String
    var size: Int64
    var digest: String

    init(path: String, mediaType: String, text: Bool, storageName: String,
        size: Int64, digest: String) {
        this.path = path
        this.mediaType = mediaType
        this.text = text
        this.storageName = storageName
        this.size = size
        this.digest = digest
    }
}

internal class OutputArtifactSpool <: RenderArtifactStore {
    let lock: OutputLockHandle
    let path: Path
    private let artifactLimit: Int64
    private let totalLimit: Int64
    private let entryLimit: Int64
    private var budget: RenderArtifactBudget
    private var paths = OutputArtifactPathBudget()
    private let entries = ArrayList<SpoolArtifactEntry>()
    private let storedNames = HashMap<String, SpoolArtifactEntry>()
    private var serial: Int64 = 0
    private var sealedFiles: ?Array<OwnedOutputFile> = None
    private var disposed: Bool = false

    init(lock: OutputLockHandle, artifactLimit!: Int64 = OUTPUT_ARTIFACT_LIMIT,
        totalLimit!: Int64 = OUTPUT_ARTIFACT_TOTAL_LIMIT,
        entryLimit!: Int64 = OUTPUT_ENTRY_LIMIT) {
        this.lock = lock
        this.path = lock.path.join("spool")
        this.artifactLimit = artifactLimit
        this.totalLimit = totalLimit
        this.entryLimit = entryLimit
        this.budget = RenderArtifactBudget(artifactLimit: artifactLimit,
            totalLimit: totalLimit, entryLimit: entryLimit)
        createSpool()
    }

    private func createSpool(): Unit {
        ensureOutputLockCurrent(lock)
        if (exists(path)) {
            throw IllegalStateException("refusing an existing output spool")
        }
        lockedDirectoryCreate(path, lock)
        ensureCurrent()
    }

    private func ensureCurrent(): Unit {
        ensureOutputLockCurrent(lock)
        ensureNoSymbolicLinkAncestors(path, "output spool")
        ensureTransactionCollectionDirectory(path, "output spool")
    }

    private func ensureWritable(): Unit {
        if (disposed || sealedFiles.isSome()) {
            throw IllegalStateException("output spool is not open for rendering")
        }
        ensureCurrent()
    }

    private func nextStorageName(ordinal: Int64): String {
        let name = "${ordinal}-${serial}.payload"
        serial++
        if (exists(path.join(name))) {
            throw IllegalStateException("output spool payload already exists")
        }
        name
    }

    private func writeTextPayload(name: String, content: String): String {
        ensureCurrent()
        let target = path.join(name)
        if (exists(target)) { throw IllegalStateException("output spool payload already exists") }
        let file = File(target, OpenMode.Write)
        let digest = StreamingOutputSha256()
        try {
            let capacity = if (content.size < OUTPUT_HASH_CHUNK_BYTES) { content.size }
                else { OUTPUT_HASH_CHUNK_BYTES }
            let buffer = Array<Byte>(capacity, repeat: 0)
            var offset: Int64 = 0
            while (offset < content.size) {
                let remaining = content.size - offset
                let count = if (remaining < buffer.size) { remaining } else { buffer.size }
                for (index in 0..count) { buffer[index] = content[offset + index] }
                if (count == buffer.size) { file.write(buffer) }
                else { file.write(buffer[0..count]) }
                digest.update(buffer, count)
                offset += count
            }
        } finally { file.close() }
        ensureCurrent()
        ensureRegularNonSymlink(target, "output spool payload")
        if (FileInfo(target).size != content.size) {
            throw IllegalStateException("output spool payload size changed while writing")
        }
        digest.finish()
    }

    private func writeBytesPayload(name: String, bytes: Array<Byte>): String {
        ensureCurrent()
        let target = path.join(name)
        if (exists(target)) { throw IllegalStateException("output spool payload already exists") }
        let file = File(target, OpenMode.Write)
        let digest = StreamingOutputSha256()
        try {
            file.write(bytes)
            digest.update(bytes, bytes.size)
        } finally { file.close() }
        ensureCurrent()
        ensureRegularNonSymlink(target, "output spool payload")
        if (FileInfo(target).size != bytes.size) {
            throw IllegalStateException("output spool payload size changed while writing")
        }
        digest.finish()
    }

    public func addText(path: String, mediaType: String, content: String): Int64 {
        ensureWritable()
        budget.checkAdd(path, content.size)
        validateRenderArtifactPath(path)
        let allowance = paths.check(path)
        let ordinal = entries.size
        let name = nextStorageName(ordinal)
        let digest = writeTextPayload(name, content)
        let entry = SpoolArtifactEntry(path, mediaType, true, name, content.size, digest)
        entries.add(entry)
        storedNames[name] = entry
        paths.commit(path, allowance)
        budget.commitAdd(content.size)
        ordinal
    }

    public func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64 {
        ensureWritable()
        budget.checkAdd(path, bytes.size)
        validateRenderArtifactPath(path)
        let allowance = paths.check(path)
        let ordinal = entries.size
        let name = nextStorageName(ordinal)
        let digest = writeBytesPayload(name, bytes)
        let entry = SpoolArtifactEntry(path, mediaType, false, name, bytes.size, digest)
        entries.add(entry)
        storedNames[name] = entry
        paths.commit(path, allowance)
        budget.commitAdd(bytes.size)
        ordinal
    }

    private func textEntry(ordinal: Int64): SpoolArtifactEntry {
        if (disposed || ordinal < 0 || ordinal >= entries.size || !entries[ordinal].text) {
            throw IllegalArgumentException("output spool entry ${ordinal} is not text")
        }
        entries[ordinal]
    }

    public func readText(entry: Int64, limit: Int64): String {
        ensureCurrent()
        let value = textEntry(entry)
        if (limit < 0 || value.size > limit) {
            throw RenderResourceLimitException("output spool entry ${entry} exceeds ${limit} UTF-8 bytes")
        }
        // Hash the exact observed bytes that become the returned text, never a
        // separate validation read followed by a second path-based read.
        let observed = readFileBoundedSnapshot(path.join(value.storageName), value.size)
        let digest = StreamingOutputSha256()
        digest.update(observed.bytes, observed.bytes.size)
        if (observed.size != value.size || digest.finish() != value.digest) {
            throw IllegalStateException("output spool payload changed while reading")
        }
        ensureCurrent()
        String.fromUtf8(observed.bytes)
    }

    public func replaceText(entry: Int64, content: String): Unit {
        ensureWritable()
        let previous = textEntry(entry)
        budget.checkReplace(previous.path, previous.size, content.size)
        verifyEntry(previous, OutputHashBudget())
        let name = nextStorageName(entry)
        let digest = writeTextPayload(name, content)
        // The new private file is complete before the registered entry changes.
        // Any failure leaves the generation unpublished and the old entry intact.
        let oldName = previous.storageName
        try {
            if (!lockedRemoveIfExists(path.join(oldName), lock)) {
                throw IllegalStateException("output spool payload disappeared during replacement")
            }
        } catch (error: Exception) {
            if (!lockedRemoveIfExists(path.join(name), lock)) {
                throw IllegalStateException("unable to retire failed output spool replacement")
            }
            throw error
        }
        budget.commitReplace(previous.size, content.size)
        let _ = storedNames.remove(oldName)
        previous.storageName = name
        previous.size = content.size
        previous.digest = digest
        storedNames[name] = previous
    }

    func appendArtifacts(artifacts: Array<RenderArtifact>): Unit {
        if (artifacts.size > OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException("render artifacts exceed ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let outputBudget = OutputHashBudget()
        for (artifact in artifacts) {
            outputBudget.reserve(artifact.byteSize, "render artifact '${artifact.path}'")
            if (artifact.hasBinaryPayload) {
                let _ = addOwnedBytes(artifact.path, artifact.mediaType, artifact.ownedBytes)
            } else {
                let _ = addText(artifact.path, artifact.mediaType, artifact.content)
            }
        }
    }

    private func verifyEntry(entry: SpoolArtifactEntry, hashBudget: OutputHashBudget): Unit {
        let target = path.join(entry.storageName)
        ensureRegularNonSymlink(target, "output spool payload")
        if (FileInfo(target).size != entry.size ||
            digestRegularFile(target, "output spool payload", hashBudget) != entry.digest) {
            throw IllegalStateException("output spool payload does not match its registered bytes")
        }
    }

    private func verifyInventory(): Unit {
        ensureCurrent()
        let observed = HashSet<String>()
        let hashBudget = OutputHashBudget()
        for (file in Directory.readFrom(path)) {
            let entry = storedNames.get(file.name)
            if (entry.isNone() || !observed.add(file.name)) {
                throw IllegalStateException("output spool contains an unregistered entry")
            }
            verifyEntry(entry.getOrThrow(), hashBudget)
            ensureOutputLockCurrent(lock)
        }
        if (observed.size != entries.size) {
            throw IllegalStateException("output spool inventory is incomplete")
        }
        ensureCurrent()
    }

    func seal(): Array<OwnedOutputFile> {
        if (disposed) { throw IllegalStateException("output spool was disposed") }
        verifyInventory()
        if (let Some(files) <- sealedFiles) { return files }
        let ordered = paths.orderedPaths()
        let files = ArrayList<OwnedOutputFile>()
        for (path in ordered) {
            let entry = entries[paths.ordinal(path)]
            files.add(OwnedOutputFile(path, entry.digest))
        }
        let result = files.toArray()
        sealedFiles = Some(result)
        result
    }

    func stageInto(stage: Path): Unit {
        if (disposed || sealedFiles.isNone()) {
            throw IllegalStateException("only a sealed output spool can be staged")
        }
        // Prove the entire inventory before moving even its first payload.
        verifyInventory()
        let stageBudget = OutputHashBudget()
        for (entry in entries) {
            let ignored = ArrayList<Path>()
            ensureParentDirectories(stage, entry.path, ignored, lock)
            let target = stage.join(entry.path)
            lockedRename(path.join(entry.storageName), target, lock)
            if (digestRegularFile(target, "staged output artifact", stageBudget) != entry.digest) {
                throw IllegalStateException("staged output digest mismatch for '${entry.path}'")
            }
        }
        ensureCurrent()
        if (!Directory.isEmpty(path) || !lockedRemoveIfExists(path, lock)) {
            throw IllegalStateException("unable to remove emptied output spool")
        }
        disposed = true
    }

    func discard(): Unit {
        ensureOutputLockCurrent(lock)
        if (disposed) {
            if (exists(path)) { throw IllegalStateException("output spool reappeared after disposal") }
            return
        }
        verifyInventory()
        if (!lockedRemoveIfExists(path, lock, recursive: true) || exists(path)) {
            throw IllegalStateException("unable to discard output spool")
        }
        entries.clear()
        storedNames.clear()
        disposed = true
    }

    func reset(): Unit {
        discard()
        budget = RenderArtifactBudget(artifactLimit: artifactLimit,
            totalLimit: totalLimit, entryLimit: entryLimit)
        paths = OutputArtifactPathBudget()
        sealedFiles = None
        serial = 0
        disposed = false
        createSpool()
    }
}
