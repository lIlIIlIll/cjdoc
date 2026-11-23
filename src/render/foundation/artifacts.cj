protected package cjdoc.render.foundation

import cjdoc.model.*
import std.collection.*

public class RenderResourceLimitException <: Exception {
    public init(message: String) { super(message) }

    protected override func getClassName(): String { "RenderResourceLimitException" }
}

protected let RENDER_ARTIFACT_LIMIT: Int64 = DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES
protected let RENDER_ARTIFACT_TOTAL_LIMIT: Int64 = 512 * 1024 * 1024
protected let RENDER_ARTIFACT_ENTRY_LIMIT: Int64 = 65536

protected func validateRenderArtifactPath(path: String): Unit {
    if (path.isEmpty() || path.startsWith("/") || path.contains("\\") || path.contains("..")) {
        throw IllegalArgumentException("render artifact path must stay within the output directory")
    }
}

internal func reserveRenderBytes(current: Int64, incoming: Int64, limit: Int64,
    description: String): Int64 {
    if (incoming < 0 || incoming > limit || current > limit - incoming) {
        throw RenderResourceLimitException("${description} exceeds ${limit} UTF-8 bytes")
    }
    current + incoming
}

internal let RENDER_TEXT_CHUNK_BYTES: Int64 = 1024 * 1024

protected class RenderTextBuffer {
    private var storage = StringBuilder()
    private var fragments: ?ArrayList<String> = None
    private let limit: Int64
    private var bytesWritten: Int64 = 0
    private var storageBytes: Int64 = 0

    protected init(limit!: Int64 = RENDER_ARTIFACT_LIMIT) {
        if (limit < 0 || limit > RENDER_ARTIFACT_LIMIT) {
            throw IllegalArgumentException("invalid renderer text limit")
        }
        this.limit = limit
    }

    private func appendFragment(value: String): Unit {
        match (fragments) {
            case Some(values) => values.add(value)
            case None => fragments = Some(ArrayList<String>([value]))
        }
    }

    private func flushStorage(): Unit {
        if (storageBytes == 0) { return }
        appendFragment(storage.toString())
        storage = StringBuilder()
        storageBytes = 0
    }

    protected func append(value: String): Unit {
        bytesWritten = reserveRenderBytes(bytesWritten, value.size, limit,
            "renderer text buffer")
        if (value.isEmpty()) { return }
        if (value.size >= RENDER_TEXT_CHUNK_BYTES) {
            flushStorage()
            appendFragment(value)
            return
        }
        if (storageBytes > RENDER_TEXT_CHUNK_BYTES - value.size) { flushStorage() }
        storage.append(value)
        storageBytes += value.size
    }

    protected func append(value: Rune): Unit {
        let code = UInt32(value)
        let width: Int64 = if (code <= 0x7Fu32) { 1 } else if (code <= 0x7FFu32) { 2 }
            else if (code <= 0xFFFFu32) { 3 } else { 4 }
        bytesWritten = reserveRenderBytes(bytesWritten, width, limit,
            "renderer text buffer")
        if (storageBytes > RENDER_TEXT_CHUNK_BYTES - width) { flushStorage() }
        storage.append(value)
        storageBytes += width
    }

    protected prop size: Int64 { get() { bytesWritten } }

    protected func toString(): String {
        match (fragments) {
            case None => storage.toString()
            case Some(values) =>
                // Large pages must not geometrically grow a second contiguous
                // payload while immutable machine artifacts remain live.
                let joined = StringBuilder(bytesWritten)
                for (value in values) { joined.append(value) }
                if (storageBytes > 0) { joined.append(storage.toString()) }
                joined.toString()
        }
    }
}

/**
 * The single append surface for every render product.
 *
 * The in-memory collector keeps payloads; the output package's spool keeps only
 * metadata and writes payloads to disk. Both obey the same entry ordinals:
 * entries are addressed by their stable zero-based append ordinal, so duplicate
 * logical paths stay distinct and keep their published order.
 */
protected interface RenderArtifactStore {
    func addText(path: String, mediaType: String, content: String): Int64

    func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64

    /** Stored text of one text entry, bounded by `limit` bytes. */
    func readText(entry: Int64, limit: Int64): String

    /** Replace the payload of one text entry, keeping its path, media type and ordinal. */
    func replaceText(entry: Int64, content: String): Unit
}

public class RenderArtifact {
    public let path: String
    public let mediaType: String
    public let content: String
    private let bytesStorage: Array<Byte>
    private let binaryPayload: Bool

    public init(path: String, mediaType: String, content: String) {
        validateRenderArtifactPath(path)
        if (content.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = content
        this.bytesStorage = Array<Byte>()
        this.binaryPayload = false
    }

    public init(path: String, mediaType: String, bytes: Array<Byte>) {
        validateRenderArtifactPath(path)
        if (bytes.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = ""
        this.bytesStorage = bytes.clone()
        this.binaryPayload = true
    }

    protected init(path: String, mediaType: String, ownedBytes: Array<Byte>, takeOwnership: Bool) {
        validateRenderArtifactPath(path)
        if (!takeOwnership || ownedBytes.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
        }
        this.path = path
        this.mediaType = mediaType
        this.content = ""
        this.bytesStorage = ownedBytes
        this.binaryPayload = true
    }

    /** True whenever the artifact was built from a byte payload, even an empty one. */
    protected prop hasBinaryPayload: Bool { get() { binaryPayload } }

    public prop bytes: Array<Byte> { get() {
        if (!content.isEmpty()) { return content.toArray() }
        bytesStorage.clone()
    } }
    /** Output spool hook: the stored binary payload without a defensive copy. */
    protected prop ownedBytes: Array<Byte> { get() { bytesStorage } }
    public prop byteSize: Int64 { get() {
        if (!content.isEmpty()) { return content.size }
        bytesStorage.size
    } }
    public prop isBinary: Bool { get() { content.isEmpty() && !bytesStorage.isEmpty() } }
}

/**
 * One artifact budget shared by the in-memory collector and the output spool.
 *
 * Checks never mutate: they prove that the proposed state fits. Commit is a
 * separate call that only the storing implementation makes after the payload is
 * accepted, so a failed append or replacement leaves the previous accounting
 * and payload intact. Replacement charges `total - oldSize + newSize` and never
 * charges another entry.
 */
protected class RenderArtifactBudget {
    private let artifactLimit: Int64
    private let totalLimit: Int64
    private let entryLimit: Int64
    private var entries: Int64 = 0
    private var totalBytes: Int64 = 0

    protected init(artifactLimit!: Int64 = RENDER_ARTIFACT_LIMIT,
        totalLimit!: Int64 = RENDER_ARTIFACT_TOTAL_LIMIT,
        entryLimit!: Int64 = RENDER_ARTIFACT_ENTRY_LIMIT) {
        if (artifactLimit < 0 || artifactLimit > RENDER_ARTIFACT_LIMIT ||
            totalLimit < 0 || totalLimit > RENDER_ARTIFACT_TOTAL_LIMIT ||
            entryLimit < 0 || entryLimit > RENDER_ARTIFACT_ENTRY_LIMIT) {
            throw IllegalArgumentException("invalid render artifact collector limits")
        }
        this.artifactLimit = artifactLimit
        this.totalLimit = totalLimit
        this.entryLimit = entryLimit
    }

    /** Prove one more entry of `size` bytes fits, without changing any accounting. */
    protected func checkAdd(path: String, size: Int64): Unit {
        if (entries >= entryLimit) {
            throw RenderResourceLimitException(
                "render artifacts exceed ${entryLimit} entries")
        }
        checkPayload(path, size)
        checkTotal(size, 0)
    }

    /** Record one accepted entry after its payload is stored. */
    protected func commitAdd(size: Int64): Unit {
        totalBytes = reserveRenderBytes(totalBytes, size, totalLimit,
            "render artifact set")
        entries++
    }

    /** Prove replacing `oldSize` bytes with `newSize` bytes fits. */
    protected func checkReplace(path: String, oldSize: Int64, newSize: Int64): Unit {
        checkPayload(path, newSize)
        checkTotal(newSize, oldSize)
    }

    /** Record an accepted replacement once the new payload is stored. */
    protected func commitReplace(oldSize: Int64, newSize: Int64): Unit {
        if (oldSize > totalBytes) {
            throw IllegalArgumentException("render artifact replacement exceeds the stored payload")
        }
        totalBytes = reserveRenderBytes(totalBytes - oldSize, newSize, totalLimit,
            "render artifact set")
    }

    private func checkPayload(path: String, size: Int64): Unit {
        if (size < 0 || size > artifactLimit) {
            throw RenderResourceLimitException(
                "render artifact '${path}' exceeds ${artifactLimit} bytes")
        }
    }

    private func checkTotal(incoming: Int64, outgoing: Int64): Unit {
        let base = totalBytes - outgoing
        if (base < 0) {
            throw IllegalArgumentException("render artifact replacement exceeds the stored payload")
        }
        let _ = reserveRenderBytes(base, incoming, totalLimit, "render artifact set")
    }
}

/**
 * In-memory `RenderArtifactStore`: the array mode every public renderer entry
 * point still promises. It keeps payloads and metadata per entry, including
 * whether the payload is owned binary bytes, which the public artifact cannot
 * report for an empty owned buffer.
 */
protected class RenderArtifactCollector <: RenderArtifactStore {
    private let artifacts = ArrayList<RenderArtifact>()
    private let budget: RenderArtifactBudget

    protected init(artifactLimit!: Int64 = RENDER_ARTIFACT_LIMIT,
        totalLimit!: Int64 = RENDER_ARTIFACT_TOTAL_LIMIT,
        entryLimit!: Int64 = RENDER_ARTIFACT_ENTRY_LIMIT) {
        this.budget = RenderArtifactBudget(artifactLimit: artifactLimit,
            totalLimit: totalLimit, entryLimit: entryLimit)
    }

    public func addText(path: String, mediaType: String, content: String): Int64 {
        budget.checkAdd(path, content.size)
        artifacts.add(RenderArtifact(path, mediaType, content))
        budget.commitAdd(content.size)
        artifacts.size - 1
    }

    public func addOwnedBytes(path: String, mediaType: String, bytes: Array<Byte>): Int64 {
        budget.checkAdd(path, bytes.size)
        artifacts.add(RenderArtifact(path, mediaType, bytes, true))
        budget.commitAdd(bytes.size)
        artifacts.size - 1
    }

    public func readText(entry: Int64, limit: Int64): String {
        let index = entryIndex(entry, "read")
        let artifact = artifacts[index]
        if (artifact.hasBinaryPayload) {
            throw IllegalArgumentException("render artifact entry ${entry} is not text")
        }
        if (limit < 0 || artifact.content.size > limit) {
            throw RenderResourceLimitException(
                "render artifact entry ${entry} exceeds ${limit} UTF-8 bytes")
        }
        artifact.content
    }

    public func replaceText(entry: Int64, content: String): Unit {
        let index = entryIndex(entry, "replace")
        let previous = artifacts[index]
        if (previous.hasBinaryPayload) {
            throw IllegalArgumentException("render artifact entry ${entry} is not text")
        }
        budget.checkReplace(previous.path, previous.byteSize, content.size)
        artifacts[index] = RenderArtifact(previous.path, previous.mediaType, content)
        budget.commitReplace(previous.byteSize, content.size)
    }

    protected func toArray(): Array<RenderArtifact> { artifacts.toArray() }

    private func entryIndex(entry: Int64, action: String): Int64 {
        if (entry < 0 || entry >= artifacts.size) {
            throw IllegalArgumentException(
                "cannot ${action} render artifact entry ${entry}")
        }
        entry
    }
}

protected func validateRenderArtifactBudgetForTest(sizes: Array<Int64>,
    artifactLimit: Int64, totalLimit: Int64, entryLimit: Int64): Unit {
    let artifacts = RenderArtifactCollector(artifactLimit: artifactLimit,
        totalLimit: totalLimit, entryLimit: entryLimit)
    var index: Int64 = 0
    for (size in sizes) {
        if (size < 0 || size > RENDER_ARTIFACT_LIMIT) {
            throw IllegalArgumentException("invalid test artifact size")
        }
        let _ = artifacts.addText("test-${index}.txt", "text/plain",
            String.fromUtf8(Array<Byte>(size, repeat: b'x')))
        index++
    }
}

protected func escapeHtmlWithRenderLimitForTest(value: String, limit: Int64): String {
    let out = RenderTextBuffer(limit: limit)
    appendHtmlEscapedValue(out, value)
    out.toString()
}
