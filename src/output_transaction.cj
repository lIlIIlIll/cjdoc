package cjdoc

import cjdoc.render.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.io.*
import std.overflow.*
import std.process.*
import std.sort.*
import std.unicode.*
import yjson.*

private let OUTPUT_MANIFEST_NAME = ".cjdoc-output.json"
private let OUTPUT_LOCK_NAME = ".cjdoc-output-parent.lock"
private let OUTPUT_LOCK_BOOTSTRAP_NAME = ".cjdoc-output-parent.bootstrap"
private let OUTPUT_RETIRED_LOCK_NAME = ".cjdoc-output-parent.retired"
private let OUTPUT_BOOTSTRAP_NAME = ".cjdoc-output-transaction.bootstrap"
private let OUTPUT_PREPARING_NAME = ".cjdoc-output-transaction.preparing"
private let OUTPUT_TRANSACTION_NAME = ".cjdoc-output-transaction.txn"
private let OUTPUT_RETIRED_NAME = ".cjdoc-output-transaction.retired"
private let OUTPUT_MANIFEST_SCHEMA = "cjdoc.output/3"
private let OUTPUT_LEGACY_MANIFEST_SCHEMA = "cjdoc.output/2"
private let OUTPUT_DIGEST_ALGORITHM = "sha256"
private let OUTPUT_MANIFEST_LIMIT: Int64 = 8 * 1024 * 1024
private let OUTPUT_ARTIFACT_LIMIT: Int64 = 64 * 1024 * 1024
private let OUTPUT_ARTIFACT_TOTAL_LIMIT: Int64 = 512 * 1024 * 1024
private let OUTPUT_ENTRY_LIMIT: Int64 = 65536
private let OUTPUT_HASH_CHUNK_BYTES: Int64 = 64 * 1024
private let OUTPUT_LOCK_OWNER_LIMIT: Int64 = 64 * 1024
private let OUTPUT_PREPARATION_MARKER_NAME = "marker.json"
private let OUTPUT_PREPARATION_MARKER_SCHEMA = "cjdoc.output-preparing/4"
private let OUTPUT_PREPARATION_MARKER_LIMIT: Int64 = 64 * 1024
private let OUTPUT_TRANSACTION_PLAN_NAME = "plan.json"
private let OUTPUT_TRANSACTION_PLAN_SCHEMA = "cjdoc.output-transaction/4"
// A plan contains the exact previous manifest (escaped once), compact previous/next
// entry arrays, and fixed metadata. Eight manifest limits covers the worst-case
// JSON escaping while leaving deterministic headroom for all fixed fields.
private let OUTPUT_TRANSACTION_PLAN_LIMIT: Int64 = OUTPUT_MANIFEST_LIMIT * 8

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
    let directories: Array<String>
    let hasDirectoryProvenance: Bool

    init(files: Array<OwnedOutputFile>, directories!: Array<String> = [],
        hasDirectoryProvenance!: Bool = true) {
        this.files = files
        this.directories = directories
        this.hasDirectoryProvenance = hasDirectoryProvenance
    }
}

private enum OutputProcessState {
    | Alive
    | Dead
    | Unknown
}

private class OwnedOutputSnapshot {
    let manifest: OwnedOutputManifest
    let exactText: String

    init(manifest: OwnedOutputManifest, exactText: String) {
        this.manifest = manifest
        this.exactText = exactText
    }
}

private class PreviousOutputFile {
    let path: String
    let ownershipDigest: String
    let rollbackDigest: String

    init(path: String, ownershipDigest: String, rollbackDigest: String) {
        this.path = path
        this.ownershipDigest = ownershipDigest
        this.rollbackDigest = rollbackDigest
    }
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

internal class OutputLockHandle {
    let path: Path
    let parent: Path
    let parentCanonical: String
    let pid: Int64
    let startTime: String
    let token: String
    let root: String
    let ownerFile: File
    let ownerText: String
    var ownerFileClosed: Bool = false
    var ownerChallengeIsSpace: Bool = false

    init(path: Path, parent: Path, parentCanonical: String, pid: Int64,
        startTime: String, token: String, root: String, ownerFile: File, ownerText: String) {
        this.path = path
        this.parent = parent
        this.parentCanonical = parentCanonical
        this.pid = pid
        this.startTime = startTime
        this.token = token
        this.root = root
        this.ownerFile = ownerFile
        this.ownerText = ownerText
    }
}

private class OutputTransactionPlan {
    let rootName: String
    let parentDigest: String
    let transactionId: String
    let rootExisted: Bool
    let previousManifestText: String
    let previous: Array<PreviousOutputFile>
    let next: OwnedOutputManifest
    let sourceDigest: String

    init(rootName: String, parentDigest: String, transactionId: String, rootExisted: Bool,
        previousManifestText: String, previous: Array<PreviousOutputFile>, next: OwnedOutputManifest,
        sourceDigest: String) {
        this.rootName = rootName
        this.parentDigest = parentDigest
        this.transactionId = transactionId
        this.rootExisted = rootExisted
        this.previousManifestText = previousManifestText
        this.previous = previous
        this.next = next
        this.sourceDigest = sourceDigest
    }
}

private class OutputPreparationMarker {
    let pid: Int64
    let startTime: String
    let rootName: String
    let parentDigest: String
    let planDigest: String
    let transactionId: String

    init(pid: Int64, startTime: String, rootName: String, parentDigest: String,
        planDigest: String, transactionId: String) {
        this.pid = pid
        this.startTime = startTime
        this.rootName = rootName
        this.parentDigest = parentDigest
        this.planDigest = planDigest
        this.transactionId = transactionId
    }
}

private class OutputHashBudget {
    private var total: Int64 = 0

    func reserve(size: Int64, description: String): Unit {
        if (size < 0 || size > OUTPUT_ARTIFACT_LIMIT) {
            throw IllegalArgumentException(
                "${description} exceeds per-artifact limit ${OUTPUT_ARTIFACT_LIMIT} bytes")
        }
        if (total > OUTPUT_ARTIFACT_TOTAL_LIMIT - size) {
            throw IllegalArgumentException(
                "output artifacts exceed total limit ${OUTPUT_ARTIFACT_TOTAL_LIMIT} bytes")
        }
        total += size
    }
}

private let OUTPUT_SHA256_CONSTANTS: Array<UInt32> = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

private func outputShaRotateRight(value: UInt32, bits: UInt32): UInt32 {
    (value >> bits) | (value << (32 - bits))
}

private class StreamingOutputSha256 {
    private var h0: UInt32 = 0x6a09e667
    private var h1: UInt32 = 0xbb67ae85
    private var h2: UInt32 = 0x3c6ef372
    private var h3: UInt32 = 0xa54ff53a
    private var h4: UInt32 = 0x510e527f
    private var h5: UInt32 = 0x9b05688c
    private var h6: UInt32 = 0x1f83d9ab
    private var h7: UInt32 = 0x5be0cd19
    private let pending = Array<Byte>(64, repeat: 0)
    private var pendingSize: Int64 = 0
    private var inputSize: Int64 = 0

    func update(buffer: Array<Byte>, count: Int64): Unit {
        if (count < 0 || count > buffer.size) {
            throw IllegalArgumentException("invalid streaming digest input length")
        }
        inputSize += count
        for (index in 0..count) {
            pending[pendingSize] = buffer[index]
            pendingSize++
            if (pendingSize == 64) {
                processBlock()
                pendingSize = 0
            }
        }
    }

    func finish(): String {
        let bitLength = UInt64(inputSize).wrappingMul(8)
        pending[pendingSize] = 0x80
        pendingSize++
        if (pendingSize > 56) {
            while (pendingSize < 64) { pending[pendingSize] = 0; pendingSize++ }
            processBlock()
            pendingSize = 0
        }
        while (pendingSize < 56) { pending[pendingSize] = 0; pendingSize++ }
        var shift: Int64 = 56
        while (shift >= 0) {
            pending[pendingSize] = UInt8((bitLength >> UInt64(shift)) & 0xFF)
            pendingSize++
            shift -= 8
        }
        processBlock()
        pendingSize = 0
        outputShaHex([h0, h1, h2, h3, h4, h5, h6, h7])
    }

    private func processBlock(): Unit {
        let words = Array<UInt32>(64, repeat: 0)
        for (index in 0..16) {
            let offset = index * 4
            words[index] = (UInt32(pending[offset]) << 24) |
                (UInt32(pending[offset + 1]) << 16) |
                (UInt32(pending[offset + 2]) << 8) | UInt32(pending[offset + 3])
        }
        for (index in 16..64) {
            let s0 = outputShaRotateRight(words[index - 15], 7) ^
                outputShaRotateRight(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let s1 = outputShaRotateRight(words[index - 2], 17) ^
                outputShaRotateRight(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16].wrappingAdd(s0)
                .wrappingAdd(words[index - 7]).wrappingAdd(s1)
        }
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var h = h7
        for (index in 0..64) {
            let sum1 = outputShaRotateRight(e, 6) ^ outputShaRotateRight(e, 11) ^
                outputShaRotateRight(e, 25)
            let choice = (e & f) ^ ((e ^ 0xFFFFFFFF) & g)
            let temp1 = h.wrappingAdd(sum1).wrappingAdd(choice)
                .wrappingAdd(OUTPUT_SHA256_CONSTANTS[index]).wrappingAdd(words[index])
            let sum0 = outputShaRotateRight(a, 2) ^ outputShaRotateRight(a, 13) ^
                outputShaRotateRight(a, 22)
            let temp2 = sum0.wrappingAdd((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d.wrappingAdd(temp1)
            d = c; c = b; b = a; a = temp1.wrappingAdd(temp2)
        }
        h0 = h0.wrappingAdd(a); h1 = h1.wrappingAdd(b)
        h2 = h2.wrappingAdd(c); h3 = h3.wrappingAdd(d)
        h4 = h4.wrappingAdd(e); h5 = h5.wrappingAdd(f)
        h6 = h6.wrappingAdd(g); h7 = h7.wrappingAdd(h)
    }
}

private func outputShaHex(words: Array<UInt32>): String {
    let digits = "0123456789abcdef"
    let out = StringBuilder()
    for (word in words) {
        var shift: Int64 = 28
        while (shift >= 0) {
            let nibble = Int64((word >> UInt32(shift)) & 0xF)
            out.append(digits[nibble..nibble + 1])
            shift -= 4
        }
    }
    out.toString()
}

private class TransactionFaultController {
    private let point: ?String
    private var interrupted = false

    init(point: ?String) { this.point = point }

    func hit(name: String): Unit {
        match (point) {
            case Some(selected) =>
                if (selected == name) {
                    interrupted = true
                    throw IllegalStateException("injected output transaction interruption at '${name}'")
                }
            case None => ()
        }
    }

    func wasInterrupted(): Bool { interrupted }
}

private class CommitFaultCounter {
    private let failAfter: ?Int64
    private let interruptAfter: ?Int64
    private var completed: Int64 = 0
    private var interrupted = false

    init(failAfter: ?Int64, interruptAfter: ?Int64) {
        this.failAfter = failAfter
        this.interruptAfter = interruptAfter
    }

    func operationCompleted(): Unit {
        completed++
        match (interruptAfter) {
            case Some(limit) =>
                if (completed == limit) {
                    interrupted = true
                    throw IllegalStateException(
                        "injected output commit interruption after operation ${completed}")
                }
            case None => ()
        }
        match (failAfter) {
            case Some(limit) =>
                if (completed == limit) {
                    throw IllegalStateException("injected output commit failure after operation ${completed}")
                }
            case None => ()
        }
    }

    func wasInterrupted(): Bool { interrupted }
}

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

private func ensureNoSymbolicLinkAncestors(path: Path, description: String): Unit {
    let raw = if (path.isAbsolute()) { path } else { getWorkingDirectory().join(path) }
    ensureNoSymbolicLinkAncestorChain(raw, description)
    let normalized = raw.normalize()
    if (normalized.toString() != raw.toString()) {
        ensureNoSymbolicLinkAncestorChain(normalized, description)
    }
}

private func canonicalForWrite(path: Path, description: String): Path {
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

private func pathContains(ancestor: Path, candidate: Path): Bool {
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

private func portablePathKey(path: Path): String {
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

private func portablePathContains(ancestor: Path, candidate: Path): Bool {
    let ancestorKey = portablePathKey(ancestor)
    let candidateKey = portablePathKey(candidate)
    candidateKey == ancestorKey || candidateKey.startsWith(ancestorKey + "/")
}

private func pathsOverlapIncludingPortableAliases(first: Path, second: Path): Bool {
    pathContains(first, second) || pathContains(second, first) ||
        portablePathContains(first, second) || portablePathContains(second, first)
}

private func internalSiblingPaths(output: Path): Array<Path> {
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

private func readCappedRegularText(path: Path, description: String, limit: Int64): String {
    ensureNoSymbolicLinkAncestors(path, description)
    readTextBounded(path, limit)
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

private func digestRegularFile(path: Path, description: String,
    budget: OutputHashBudget): String {
    ensureNoSymbolicLinkAncestors(path, description)
    ensureRegularNonSymlink(path, description)
    let before = FileInfo(path)
    let beforeSize = before.size
    let beforeCreation = before.creationTime
    let beforeModification = before.lastModificationTime
    budget.reserve(beforeSize, description)

    let file = File(path, OpenMode.Read)
    let digest = StreamingOutputSha256()
    var total: Int64 = 0
    try {
        let opened = file.info
        if (opened.isSymbolicLink() || !opened.isRegular() || opened.size != beforeSize ||
            opened.creationTime != beforeCreation || opened.lastModificationTime != beforeModification ||
            file.length != beforeSize) {
            throw IllegalArgumentException("${description} changed while opening: '${path}'")
        }
        let buffer = Array<Byte>(OUTPUT_HASH_CHUNK_BYTES, repeat: 0)
        while (true) {
            let count = file.read(buffer)
            if (count < 0 || count > buffer.size) {
                throw IllegalArgumentException("${description} returned an invalid read length: '${path}'")
            }
            if (count == 0) { break }
            if (total > beforeSize - count) {
                throw IllegalArgumentException("${description} grew while hashing: '${path}'")
            }
            digest.update(buffer, count)
            total += count
        }
        if (total != beforeSize || file.length != beforeSize) {
            throw IllegalArgumentException("${description} changed while hashing: '${path}'")
        }
    } finally { file.close() }

    let after = FileInfo(path)
    if (after.isSymbolicLink() || !after.isRegular() || after.size != beforeSize ||
        after.creationTime != beforeCreation || after.lastModificationTime != beforeModification) {
        throw IllegalArgumentException("${description} changed while hashing: '${path}'")
    }
    digest.finish()
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

private func ownedDirectoriesForFiles(files: Array<OwnedOutputFile>): Array<String> {
    let directories = ArrayList<String>()
    let seen = HashSet<String>()
    var manifestWorstCase: Int64 = 0
    for (file in files) {
        let parts = file.path.split("/")
        let prefix = StringBuilder()
        var index: Int64 = 0
        while (index + 1 < parts.size) {
            if (index > 0) { prefix.append("/") }
            prefix.append(parts[index])
            let directory = prefix.toString()
            if (seen.add(directory)) {
                let pathBytes = directory.toArray().size
                if (pathBytes > (OUTPUT_MANIFEST_LIMIT - manifestWorstCase - 32) / 6) {
                    throw IllegalArgumentException(
                        "owned output directories cannot fit the output manifest limit")
                }
                manifestWorstCase += pathBytes * 6 + 32
                if (directories.size >= OUTPUT_ENTRY_LIMIT) {
                    throw IllegalArgumentException(
                        "owned output directories exceed ${OUTPUT_ENTRY_LIMIT} entries")
                }
                directories.add(directory)
            }
            index++
        }
    }
    let ordered = directories.toArray()
    sort(ordered)
    ordered
}

private func ownedManifest(files: Array<OwnedOutputFile>): OwnedOutputManifest {
    OwnedOutputManifest(files, directories: ownedDirectoriesForFiles(files))
}

private func parseOwnedDirectoryEntries(entries: JsonArrayValue): Array<String> {
    let directories = ArrayList<String>()
    let seen = HashSet<String>()
    for (node in entries.values()) {
        if (directories.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException(
                "output manifest directories exceed ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let path = try { node.string } catch (_: Exception) {
            throw IllegalArgumentException("invalid output manifest directory entry")
        }
        if (!isSafeOutputPath(path) || !seen.add(path)) {
            throw IllegalArgumentException("invalid owned output directory '${path}'")
        }
        directories.add(path)
    }
    let ordered = directories.toArray()
    sort(ordered)
    ordered
}

private func sameStringArray(first: Array<String>, second: Array<String>): Bool {
    if (first.size != second.size) { return false }
    for (index in 0..first.size) {
        if (first[index] != second[index]) { return false }
    }
    true
}

private func parseOwnedManifest(text: String): OwnedOutputManifest {
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 8, maxStringBytes: OUTPUT_MANIFEST_LIMIT,
            maxBytes: OUTPUT_MANIFEST_LIMIT)))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest: expected object")
    }
    if (object.get("schemaVersion").isNone() ||
        object.get("digestAlgorithm").isNone() || object.get("files").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output manifest fields")
    }
    let schema = try { object["schemaVersion"].string } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest schemaVersion")
    }
    if (schema != OUTPUT_MANIFEST_SCHEMA && schema != OUTPUT_LEGACY_MANIFEST_SCHEMA) {
        throw IllegalArgumentException("unsupported cjdoc output manifest '${schema}'")
    }
    if ((schema == OUTPUT_MANIFEST_SCHEMA &&
            (object.size() != 4 || object.get("directories").isNone())) ||
        (schema == OUTPUT_LEGACY_MANIFEST_SCHEMA && object.size() != 3)) {
        throw IllegalArgumentException("invalid cjdoc output manifest fields")
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
    let files = parseOwnedFileEntries(entries, "output manifest")
    let expectedDirectories = ownedDirectoriesForFiles(files)
    if (schema == OUTPUT_LEGACY_MANIFEST_SCHEMA) {
        return OwnedOutputManifest(files, directories: expectedDirectories,
            hasDirectoryProvenance: false)
    }
    let directoryEntries = try { object["directories"].asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest directories")
    }
    let directories = parseOwnedDirectoryEntries(directoryEntries)
    if (!sameStringArray(directories, expectedDirectories)) {
        throw IllegalArgumentException(
            "cjdoc output manifest directory provenance does not match its files")
    }
    OwnedOutputManifest(files, directories: directories)
}

private func readOwnedManifest(root: Path): OwnedOutputSnapshot {
    let manifestPath = root.join(OUTPUT_MANIFEST_NAME)
    let text = readCappedRegularText(manifestPath, "cjdoc output manifest", OUTPUT_MANIFEST_LIMIT)
    OwnedOutputSnapshot(parseOwnedManifest(text), text)
}

private func parseOwnedFileEntries(entries: JsonArrayValue, description: String): Array<OwnedOutputFile> {
    let files = ArrayList<OwnedOutputFile>()
    let seen = HashSet<String>()
    for (node in entries.values()) {
        if (files.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException("${description} exceeds ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let entry = try { node.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("invalid ${description} file entry")
        }
        if (entry.size() != 2 || entry.get("path").isNone() || entry.get("sha256").isNone()) {
            throw IllegalArgumentException("invalid ${description} file entry fields")
        }
        let path = try { entry["path"].string } catch (_: Exception) {
            throw IllegalArgumentException("invalid ${description} file path")
        }
        let digest = try { entry["sha256"].string } catch (_: Exception) {
            throw IllegalArgumentException("invalid ${description} file digest")
        }
        if (!isSafeOutputPath(path) || seen.contains(path) || !isSha256(digest)) {
            throw IllegalArgumentException("invalid owned output entry '${path}'")
        }
        let _ = seen.add(path)
        files.add(OwnedOutputFile(path, digest))
    }
    files.toArray()
}

private func orderedOwnedFiles(artifacts: Array<RenderArtifact>): Array<OwnedOutputFile> {
    if (artifacts.size > OUTPUT_ENTRY_LIMIT) {
        throw IllegalArgumentException("render artifacts exceed ${OUTPUT_ENTRY_LIMIT} entries")
    }
    let digests = HashMap<String, String>()
    let paths = ArrayList<String>()
    let budget = OutputHashBudget()
    var manifestWorstCase: Int64 = 256
    var treeWorstCaseEntries: Int64 = 1
    for (artifact in artifacts) {
        if (!isSafeOutputPath(artifact.path) || digests.contains(artifact.path)) {
            throw IllegalArgumentException("duplicate or unsafe render artifact '${artifact.path}'")
        }
        let pathBytes = artifact.path.toArray().size
        // JSON escaping uses at most six ASCII bytes per input byte. The fixed
        // allowance covers punctuation, the digest, indentation, and separators.
        if (pathBytes > (OUTPUT_MANIFEST_LIMIT - manifestWorstCase - 128) / 6) {
            throw IllegalArgumentException("render artifacts cannot fit the output manifest limit")
        }
        manifestWorstCase += pathBytes * 6 + 128
        let pathEntries = artifact.path.split("/").size
        if (pathEntries > OUTPUT_ENTRY_LIMIT - treeWorstCaseEntries) {
            throw IllegalArgumentException("render artifacts exceed staged tree entry limit")
        }
        treeWorstCaseEntries += pathEntries
        let bytes = artifact.bytes
        budget.reserve(bytes.size, "render artifact '${artifact.path}'")
        digests.add(artifact.path, Sha256Digest.digestBytes(bytes))
        paths.add(artifact.path)
    }
    let ordered = paths.toArray()
    sort(ordered)
    let files = ArrayList<OwnedOutputFile>()
    for (path in ordered) { files.add(OwnedOutputFile(path, digests[path])) }
    files.toArray()
}

private func ensurePlannedTreeEntryBudget(paths: Array<String>, description: String): Unit {
    var worstCase: Int64 = 1
    for (path in paths) {
        let pathEntries = path.split("/").size
        if (pathEntries > OUTPUT_ENTRY_LIMIT - worstCase) {
            throw IllegalArgumentException("${description} exceeds transaction tree entry limit")
        }
        worstCase += pathEntries
    }
}

private func outputManifest(files: Array<OwnedOutputFile>): String {
    let directories = ownedDirectoriesForFiles(files)
    let out = StringBuilder()
    out.append("{\n  \"schemaVersion\": \"${OUTPUT_MANIFEST_SCHEMA}\",\n")
    out.append("  \"digestAlgorithm\": \"${OUTPUT_DIGEST_ALGORITHM}\",\n")
    out.append("  \"directories\": [")
    var directoryIndex: Int64 = 0
    while (directoryIndex < directories.size) {
        if (directoryIndex > 0) { out.append(",") }
        out.append("\n    ${escapeJsonString(directories[directoryIndex])}")
        directoryIndex++
    }
    if (!directories.isEmpty()) { out.append("\n  ") }
    out.append("],\n  \"files\": [")
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

private func appendOwnedFileArray(out: StringBuilder, files: Array<OwnedOutputFile>): Unit {
    out.append("[")
    var index: Int64 = 0
    while (index < files.size) {
        if (index > 0) { out.append(",") }
        out.append("{\"path\":${escapeJsonString(files[index].path)},")
        out.append("\"sha256\":${escapeJsonString(files[index].digest)}}")
        index++
    }
    out.append("]")
}

private func appendPreviousFileArray(out: StringBuilder, files: Array<PreviousOutputFile>): Unit {
    out.append("[")
    var index: Int64 = 0
    while (index < files.size) {
        if (index > 0) { out.append(",") }
        out.append("{\"path\":${escapeJsonString(files[index].path)},")
        out.append("\"ownershipSha256\":${escapeJsonString(files[index].ownershipDigest)},")
        out.append("\"rollbackSha256\":${escapeJsonString(files[index].rollbackDigest)}}")
        index++
    }
    out.append("]")
}

private func outputTransactionPlanContent(plan: OutputTransactionPlan): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":${escapeJsonString(OUTPUT_TRANSACTION_PLAN_SCHEMA)},")
    out.append("\"rootName\":${escapeJsonString(plan.rootName)},")
    out.append("\"parentSha256\":${escapeJsonString(plan.parentDigest)},")
    out.append("\"transactionId\":${escapeJsonString(plan.transactionId)},")
    out.append("\"rootState\":${escapeJsonString(if (plan.rootExisted) { "present" } else { "absent" })},")
    out.append("\"previousManifestSha256\":${escapeJsonString(Sha256Digest.digest(plan.previousManifestText))},")
    out.append("\"previousManifest\":${escapeJsonString(plan.previousManifestText)},")
    out.append("\"previous\":")
    appendPreviousFileArray(out, plan.previous)
    out.append(",\"next\":")
    appendOwnedFileArray(out, plan.next.files)
    out.append("}\n")
    out.toString()
}

private func parsePreviousFileEntries(entries: JsonArrayValue): Array<PreviousOutputFile> {
    let files = ArrayList<PreviousOutputFile>()
    let seen = HashSet<String>()
    for (node in entries.values()) {
        if (files.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException(
                "output transaction previous files exceed ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let entry = try { node.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("invalid output transaction previous file entry")
        }
        if (entry.size() != 3 || entry.get("path").isNone() ||
            entry.get("ownershipSha256").isNone() || entry.get("rollbackSha256").isNone()) {
            throw IllegalArgumentException("invalid output transaction previous file entry fields")
        }
        let path = try { entry["path"].string } catch (_: Exception) { "" }
        let ownership = try { entry["ownershipSha256"].string } catch (_: Exception) { "" }
        let rollback = try { entry["rollbackSha256"].string } catch (_: Exception) { "" }
        if (!isSafeOutputPath(path) || !seen.add(path) ||
            !isSha256(ownership) || !isSha256(rollback)) {
            throw IllegalArgumentException("invalid output transaction previous entry '${path}'")
        }
        files.add(PreviousOutputFile(path, ownership, rollback))
    }
    files.toArray()
}

private func validatePreviousManifest(planFiles: Array<PreviousOutputFile>,
    manifestText: String, rootExisted: Bool): Unit {
    if (manifestText.toArray().size > OUTPUT_MANIFEST_LIMIT) {
        throw IllegalArgumentException("previous output manifest exceeds limit")
    }
    if (!rootExisted) {
        if (!planFiles.isEmpty() || !manifestText.isEmpty()) {
            throw IllegalArgumentException("absent output root has previous ownership state")
        }
        return
    }
    let manifest = parseOwnedManifest(manifestText)
    if (manifest.files.size != planFiles.size) {
        throw IllegalArgumentException("previous output manifest does not match transaction plan")
    }
    let ownershipByPath = HashMap<String, String>()
    for (file in planFiles) { ownershipByPath.add(file.path, file.ownershipDigest) }
    for (file in manifest.files) {
        if (!ownershipByPath.contains(file.path) || ownershipByPath[file.path] != file.digest) {
            throw IllegalArgumentException("previous output manifest does not match transaction plan")
        }
    }
}

private func readOutputTransactionPlan(transaction: Path): OutputTransactionPlan {
    let text = readCappedRegularText(transaction.join(OUTPUT_TRANSACTION_PLAN_NAME),
        "cjdoc output transaction plan", OUTPUT_TRANSACTION_PLAN_LIMIT)
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 8, maxStringBytes: OUTPUT_TRANSACTION_PLAN_LIMIT,
            maxBytes: OUTPUT_TRANSACTION_PLAN_LIMIT)))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output transaction plan: expected object")
    }
    if (object.size() != 9 || object.get("schemaVersion").isNone() ||
        object.get("rootName").isNone() || object.get("parentSha256").isNone() ||
        object.get("transactionId").isNone() || object.get("rootState").isNone() ||
        object.get("previousManifestSha256").isNone() || object.get("previousManifest").isNone() ||
        object.get("previous").isNone() || object.get("next").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output transaction plan fields")
    }
    let schema = try { object["schemaVersion"].string } catch (_: Exception) { "" }
    let rootName = try { object["rootName"].string } catch (_: Exception) { "" }
    let parentDigest = try { object["parentSha256"].string } catch (_: Exception) { "" }
    let transactionId = try { object["transactionId"].string } catch (_: Exception) { "" }
    let rootState = try { object["rootState"].string } catch (_: Exception) { "" }
    let manifestDigest = try { object["previousManifestSha256"].string } catch (_: Exception) { "" }
    let previousManifestText = try { object["previousManifest"].string } catch (_: Exception) { "" }
    if (schema != OUTPUT_TRANSACTION_PLAN_SCHEMA || !isSafeRootName(rootName) ||
        collidesWithInternalSibling(rootName) ||
        !isSha256(parentDigest) || !isSha256(transactionId) || !isSha256(manifestDigest) ||
        Sha256Digest.digest(previousManifestText) != manifestDigest ||
        (rootState != "present" && rootState != "absent")) {
        throw IllegalArgumentException("invalid cjdoc output transaction plan values")
    }
    let previous = try { object["previous"].asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output transaction previous files")
    }
    let next = try { object["next"].asArray() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output transaction next files")
    }
    let previousFiles = parsePreviousFileEntries(previous)
    let nextFiles = parseOwnedFileEntries(next, "output transaction next")
    let previousPaths = ArrayList<String>()
    for (file in previousFiles) { previousPaths.add(file.path) }
    let nextPaths = ArrayList<String>()
    for (file in nextFiles) { nextPaths.add(file.path) }
    ensurePlannedTreeEntryBudget(previousPaths.toArray(), "output transaction previous files")
    ensurePlannedTreeEntryBudget(nextPaths.toArray(), "output transaction next files")
    if (hasTopologyCollision(previousPaths.toArray()) || hasTopologyCollision(nextPaths.toArray())) {
        throw IllegalArgumentException("invalid cjdoc output transaction path topology")
    }
    validatePreviousManifest(previousFiles, previousManifestText, rootState == "present")
    OutputTransactionPlan(rootName, parentDigest, transactionId, rootState == "present",
        previousManifestText, previousFiles, ownedManifest(nextFiles),
        Sha256Digest.digestBytes(text.toArray()))
}

private func isSafeRootName(rootName: String): Bool {
    !rootName.isEmpty() && rootName != "." && rootName != ".." &&
        !rootName.contains("/") && !rootName.contains("\\") && !rootName.contains(":")
}

private func portableFileNameKey(name: String): String {
    var trimmed = name
    while (trimmed.endsWith(".") || trimmed.endsWith(" ")) {
        trimmed = trimmed[..trimmed.size - 1]
    }
    trimmed.toLower()
}

private func collidesWithInternalSibling(rootName: String): Bool {
    let key = portableFileNameKey(rootName)
    key == portableFileNameKey(OUTPUT_LOCK_NAME) ||
        key == portableFileNameKey(OUTPUT_LOCK_BOOTSTRAP_NAME) ||
        key == portableFileNameKey(OUTPUT_RETIRED_LOCK_NAME) ||
        key == portableFileNameKey(OUTPUT_BOOTSTRAP_NAME) ||
        key == portableFileNameKey(OUTPUT_PREPARING_NAME) ||
        key == portableFileNameKey(OUTPUT_TRANSACTION_NAME) ||
        key == portableFileNameKey(OUTPUT_RETIRED_NAME)
}

private func preparationMarkerContent(marker: OutputPreparationMarker): String {
    "{\"schemaVersion\":${escapeJsonString(OUTPUT_PREPARATION_MARKER_SCHEMA)}," +
        "\"pid\":${escapeJsonString(marker.pid.toString())}," +
        "\"startTime\":${escapeJsonString(marker.startTime)}," +
        "\"rootName\":${escapeJsonString(marker.rootName)}," +
        "\"parentSha256\":${escapeJsonString(marker.parentDigest)}," +
        "\"planSha256\":${escapeJsonString(marker.planDigest)}," +
        "\"transactionId\":${escapeJsonString(marker.transactionId)}}\n"
}

private func readPreparationMarker(preparing: Path): OutputPreparationMarker {
    let text = readCappedRegularText(preparing.join(OUTPUT_PREPARATION_MARKER_NAME),
        "cjdoc output preparation marker", OUTPUT_PREPARATION_MARKER_LIMIT)
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: 4, maxStringBytes: 16 * 1024,
            maxBytes: OUTPUT_PREPARATION_MARKER_LIMIT)))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output preparation marker")
    }
    if (object.size() != 7 || object.get("schemaVersion").isNone() ||
        object.get("pid").isNone() || object.get("startTime").isNone() ||
        object.get("rootName").isNone() || object.get("parentSha256").isNone() ||
        object.get("planSha256").isNone() ||
        object.get("transactionId").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output preparation marker fields")
    }
    let schema = try { object["schemaVersion"].string } catch (_: Exception) { "" }
    let pid = try { Int64.parse(object["pid"].string) } catch (_: Exception) { -1 }
    let startTime = try { object["startTime"].string } catch (_: Exception) { "" }
    let rootName = try { object["rootName"].string } catch (_: Exception) { "" }
    let parentDigest = try { object["parentSha256"].string } catch (_: Exception) { "" }
    let planDigest = try { object["planSha256"].string } catch (_: Exception) { "" }
    let transactionId = try { object["transactionId"].string } catch (_: Exception) { "" }
    if (schema != OUTPUT_PREPARATION_MARKER_SCHEMA || pid <= 0 || startTime.isEmpty() ||
        !isSafeRootName(rootName) || collidesWithInternalSibling(rootName) ||
        !isSha256(parentDigest) || !isSha256(planDigest) ||
        !isSha256(transactionId)) {
        throw IllegalArgumentException("invalid cjdoc output preparation marker values")
    }
    OutputPreparationMarker(pid, startTime, rootName, parentDigest, planDigest, transactionId)
}

private func validateTransactionIdentity(transaction: Path,
    plan: OutputTransactionPlan): Unit {
    let marker = readPreparationMarker(transaction)
    if (marker.rootName != plan.rootName || marker.parentDigest != plan.parentDigest ||
        marker.transactionId != plan.transactionId) {
        throw IllegalStateException("output transaction marker does not match its plan")
    }
    if (plan.sourceDigest != marker.planDigest) {
        throw IllegalStateException("output transaction marker plan digest does not match plan bytes")
    }
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
    let text = readCappedRegularText(ownerPath, "cjdoc output lock owner", OUTPUT_LOCK_OWNER_LIMIT)
    let parsed = YJson.parse(text, config: JsonReadConfig(
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

private func ownerProcessState(owner: OutputLockOwner): OutputProcessState {
    try {
        let process = findProcess(owner.pid)
        if (process.isAlive() && process.startTime.toString() == owner.startTime) {
            OutputProcessState.Alive
        } else {
            OutputProcessState.Dead
        }
    } catch (_: Exception) {
        // ProcessException covers both a missing process and failures such as
        // allocation/query errors. Those cases cannot be distinguished by the
        // public API, so lock recovery must fail closed rather than assume dead.
        OutputProcessState.Unknown
    }
}

private func ensureLockedParentPathCurrent(path: Path, canonical: String,
    description: String): Unit {
    ensureNoSymbolicLinkAncestors(path, description)
    if (!exists(path)) {
        throw IllegalStateException("${description} disappeared")
    }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isDirectory() || canonicalize(path).toString() != canonical) {
        throw IllegalStateException("${description} changed while locked")
    }
}

private func ensureOutputLockPhysicalIdentity(handle: OutputLockHandle): Unit {
    if (handle.ownerFileClosed) {
        throw IllegalStateException("output parent lock owner descriptor was closed while in use")
    }
    handle.ownerChallengeIsSpace = !handle.ownerChallengeIsSpace
    let challenge: Byte = if (handle.ownerChallengeIsSpace) { UInt8(0x20) } else { UInt8(0x0a) }
    let offset = handle.ownerText.toArray().size
    if (handle.ownerFile.seek(SeekPosition.Begin(offset)) != offset) {
        throw IllegalStateException("output parent lock owner descriptor cannot be challenged")
    }
    handle.ownerFile.write([challenge])
    handle.ownerFile.setLength(offset + 1)
    let expected = handle.ownerText + String.fromUtf8([challenge])
    if (readCappedRegularText(handle.path.join("owner.json"),
        "cjdoc output lock owner", OUTPUT_LOCK_OWNER_LIMIT) != expected) {
        throw IllegalStateException("output parent lock physical identity changed while in use")
    }
}

private func ensureOutputLockCurrent(handle: OutputLockHandle): Unit {
    ensureLockedParentPathCurrent(handle.parent, handle.parentCanonical, "output parent while locked")
    if (!exists(handle.path)) {
        throw IllegalStateException("output parent lock disappeared while in use")
    }
    let info = FileInfo(handle.path)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("output parent lock changed type while in use")
    }
    ensureOutputLockPhysicalIdentity(handle)
    let owner = readOutputLockOwner(handle.path)
    if (owner.pid != handle.pid || owner.startTime != handle.startTime ||
        owner.token != handle.token || owner.root != handle.root) {
        throw IllegalStateException("output parent lock ownership changed while in use")
    }
}

private func lockedRename(from: Path, to: Path, handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    rename(from, to: to, overwrite: false)
    ensureOutputLockCurrent(handle)
}

private func lockedDirectoryCreate(path: Path, handle: OutputLockHandle,
    recursive!: Bool = false): Unit {
    ensureOutputLockCurrent(handle)
    Directory.create(path, recursive: recursive)
    ensureOutputLockCurrent(handle)
}

private func lockedFileWrite(path: Path, bytes: Array<Byte>, handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    File.writeTo(path, bytes)
    ensureOutputLockCurrent(handle)
}

private func lockedRemoveIfExists(path: Path, handle: OutputLockHandle,
    recursive!: Bool = false): Bool {
    ensureOutputLockCurrent(handle)
    let removed = removeIfExists(path, recursive: recursive)
    ensureOutputLockCurrent(handle)
    removed
}

private func removeLockStateStrict(path: Path, parent: Path, parentCanonical: String,
    description: String): Unit {
    ensureLockedParentPathCurrent(parent, parentCanonical, description)
    if (!removeIfExists(path, recursive: true) || exists(path)) {
        throw IllegalStateException("unable to remove ${description} '${path}'")
    }
    ensureLockedParentPathCurrent(parent, parentCanonical, description)
}

private func acquireOutputLock(root: Path): OutputLockHandle {
    let absoluteRoot = canonicalForWrite(root, "output path")
    let parent = absoluteRoot.parent
    if (!exists(parent)) { Directory.create(parent, recursive: true) }
    let _ = outputRootName(absoluteRoot)
    let parentCanonical = canonicalize(parent).toString()
    let lockPath = parent.join(OUTPUT_LOCK_NAME)
    let bootstrap = parent.join(OUTPUT_LOCK_BOOTSTRAP_NAME)
    let retired = parent.join(OUTPUT_RETIRED_LOCK_NAME)
    let pid = getProcessId()
    let startTime = findProcess(pid).startTime.toString()
    if (exists(retired)) {
        let info = FileInfo(retired)
        if (info.isSymbolicLink() || !info.isDirectory()) {
            throw IllegalStateException("invalid retired output lock state '${retired}'")
        }
        let _ = try { readOutputLockOwner(retired) } catch (_: Exception) {
            throw IllegalStateException("retired output lock state '${retired}' is invalid")
        }
        removeLockStateStrict(retired, parent, parentCanonical, "retired output lock state")
    }
    if (exists(bootstrap)) {
        let owner = try { readOutputLockOwner(bootstrap) } catch (_: Exception) {
            throw IllegalStateException("output lock bootstrap '${bootstrap}' is invalid")
        }
        match (ownerProcessState(owner)) {
            case OutputProcessState.Alive => throw IllegalStateException(
                "output lock acquisition is already in progress for process ${owner.pid}")
            case OutputProcessState.Unknown => throw IllegalStateException(
                "unable to verify output lock bootstrap process ${owner.pid}; refusing unsafe recovery")
            case OutputProcessState.Dead => removeLockStateStrict(bootstrap, parent,
                parentCanonical, "stale output lock bootstrap")
        }
    }
    if (exists(lockPath)) {
        let existing = try { readOutputLockOwner(lockPath) } catch (_: Exception) {
            throw IllegalStateException("output lock '${lockPath}' is invalid; refusing unsafe recovery")
        }
        match (ownerProcessState(existing)) {
            case OutputProcessState.Alive => throw IllegalStateException(
                "output directory '${absoluteRoot}' is locked by process ${existing.pid}")
            case OutputProcessState.Unknown => throw IllegalStateException(
                "unable to verify output lock owner process ${existing.pid}; refusing unsafe recovery")
            case OutputProcessState.Dead => ()
        }
        ensureLockedParentPathCurrent(parent, parentCanonical,
            "output parent during stale-lock recovery")
        try { rename(lockPath, to: retired, overwrite: false) } catch (_: Exception) {
            throw IllegalStateException("output lock '${lockPath}' changed during stale-lock recovery")
        }
        ensureLockedParentPathCurrent(parent, parentCanonical,
            "output parent during stale-lock recovery")
        removeLockStateStrict(retired, parent, parentCanonical, "retired output lock state")
    }

    let token = Sha256Digest.digest("${pid}|${startTime}|${absoluteRoot}|${parentCanonical}")
    let owner = OutputLockOwner(pid, startTime, token, absoluteRoot.toString())
    var created = false
    var published = false
    try {
        ensureLockedParentPathCurrent(parent, parentCanonical,
            "output parent during lock acquisition")
        Directory.create(bootstrap)
        created = true
        let ownerText = outputLockOwnerContent(owner)
        File.writeTo(bootstrap.join("owner.json"), ownerText.toArray())
        rename(bootstrap, to: lockPath, overwrite: false)
        published = true
        let ownerFile = File(lockPath.join("owner.json"), OpenMode.ReadWrite)
        try {
            let handle = OutputLockHandle(lockPath, parent, parentCanonical, pid, startTime, token,
                absoluteRoot.toString(), ownerFile, ownerText)
            ensureOutputLockCurrent(handle)
            return handle
        } catch (error: Exception) {
            try { ownerFile.close() } catch (_: Exception) {}
            throw error
        }
    } catch (error: Exception) {
        if (published) {
            throw IllegalStateException(
                "output parent changed while publishing its lock: ${error.message}")
        }
        if (created && exists(bootstrap)) {
            try { removeLockStateStrict(bootstrap, parent, parentCanonical,
                "failed output lock bootstrap") }
            catch (cleanupError: Exception) {
                throw IllegalStateException(
                    "unable to acquire output lock '${lockPath}': ${error.message}; ${cleanupError.message}")
            }
        }
        throw IllegalStateException("unable to acquire output lock '${lockPath}': ${error.message}")
    }
}

private func releaseOutputLock(handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    handle.ownerFile.close()
    handle.ownerFileClosed = true
    if (!removeIfExists(handle.path, recursive: true) || exists(handle.path)) {
        throw IllegalStateException("unable to release output parent lock '${handle.path}'")
    }
}

private func closeOutputLockOwnerBestEffort(handle: OutputLockHandle): Unit {
    if (!handle.ownerFileClosed) {
        try { handle.ownerFile.close() } catch (_: Exception) {}
        handle.ownerFileClosed = true
    }
}

private func finishOutputLock(handle: OutputLockHandle, actionError: ?Exception): Unit {
    try {
        releaseOutputLock(handle)
    } catch (releaseError: Exception) {
        closeOutputLockOwnerBestEffort(handle)
        match (actionError) {
            case Some(error) => throw IllegalStateException(
                "output action failed and lock release was incomplete: ${error.message}; ${releaseError.message}")
            case None => throw releaseError
        }
    }
    match (actionError) {
        case Some(error) => throw error
        case None => ()
    }
}

internal func withOutputLock(outputDirectory: String, action: () -> Unit): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    var actionError: ?Exception = None
    try {
        ensureOutputLockCurrent(handle)
        action()
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

internal func withOutputLockResult(outputDirectory: String, action: () -> Int64): Int64 {
    let handle = acquireOutputLock(Path(outputDirectory))
    var result: Int64 = 2
    var actionError: ?Exception = None
    try {
        ensureOutputLockCurrent(handle)
        result = action()
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
    result
}

internal func withOutputLockResultGuard(outputDirectory: String,
    action: (OutputLockHandle) -> Int64): Int64 {
    let handle = acquireOutputLock(Path(outputDirectory))
    var result: Int64 = 2
    var actionError: ?Exception = None
    try {
        ensureOutputLockCurrent(handle)
        result = action(handle)
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
    result
}

internal func withOutputLockRaceForTest(outputDirectory: String,
    afterAcquire: () -> Unit, action: () -> Unit): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    var actionError: ?Exception = None
    try {
        afterAcquire()
        ensureOutputLockCurrent(handle)
        action()
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

private func preflightOutput(root: Path, previous: OwnedOutputManifest,
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

private func ensureParentDirectories(root: Path, relativePath: String,
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

private func pruneOwnedDirectories(root: Path, directories: Array<String>,
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

private func transactionPath(root: Path): Path {
    root.parent.join(OUTPUT_TRANSACTION_NAME)
}

private func preparingPath(root: Path): Path {
    root.parent.join(OUTPUT_PREPARING_NAME)
}

private func bootstrapPath(root: Path): Path {
    root.parent.join(OUTPUT_BOOTSTRAP_NAME)
}

private func retiredPath(root: Path): Path {
    root.parent.join(OUTPUT_RETIRED_NAME)
}

private func outputRootName(root: Path): String {
    let rootName = root.fileName
    if (!isSafeRootName(rootName) || collidesWithInternalSibling(rootName) ||
        root.parent.join(rootName).normalize() != root.normalize()) {
        throw IllegalArgumentException("output path must name a child directory of its parent: '${root}'")
    }
    rootName
}

private func canonicalParentDigest(parent: Path): String {
    Sha256Digest.digest(canonicalize(parent).toString())
}

private func resolveStateRoot(parent: Path, rootName: String, expectedParentDigest: String,
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

private func retireFixedState(path: Path, description: String,
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

private func ownedFileIndex(files: Array<OwnedOutputFile>): HashMap<String, OwnedOutputFile> {
    let index = HashMap<String, OwnedOutputFile>()
    for (file in files) { index.add(file.path, file) }
    index
}

private func previousFileIndex(files: Array<PreviousOutputFile>): HashMap<String, PreviousOutputFile> {
    let index = HashMap<String, PreviousOutputFile>()
    for (file in files) { index.add(file.path, file) }
    index
}

private func verifiedDigest(path: Path, expected: String, description: String,
    budget: OutputHashBudget): Unit {
    if (digestRegularFile(path, description, budget) != expected) {
        throw IllegalStateException("${description} digest does not match transaction plan: '${path}'")
    }
}

private func manifestTextMatches(path: Path, expected: String): Bool {
    if (!exists(path)) { return false }
    let text = readCappedRegularText(path, "cjdoc output manifest", OUTPUT_MANIFEST_LIMIT)
    text == expected
}

private func completeNextOutputIsPresent(root: Path, plan: OutputTransactionPlan): Bool {
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

private func previousOutputIsPresent(root: Path, plan: OutputTransactionPlan): Bool {
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

private func addExpectedParentDirectories(path: String, directories: HashSet<String>): Unit {
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

private func scanStagedTree(directory: Path, prefix: String,
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

private func validateStagedOutput(stage: Path, nextFiles: Array<OwnedOutputFile>): Unit {
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

private func ensureTransactionCollectionDirectory(path: Path, description: String): Unit {
    if (!exists(path)) {
        throw IllegalStateException("missing ${description} directory '${path}'")
    }
    let info = FileInfo(path)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid ${description} directory '${path}'")
    }
}

private func validateRecoveryCollections(transaction: Path, plan: OutputTransactionPlan): Unit {
    let stage = transaction.join("stage")
    let backup = transaction.join("backup")
    ensureTransactionCollectionDirectory(stage, "transaction stage")
    ensureTransactionCollectionDirectory(backup, "transaction backup")

    let stageFiles = HashSet<String>()
    let stageDirectories = HashSet<String>()
    addExpectedParentDirectories(OUTPUT_MANIFEST_NAME, stageDirectories)
    let nextByPath = ownedFileIndex(plan.next.files)
    for (file in plan.next.files) { addExpectedParentDirectories(file.path, stageDirectories) }
    let _ = scanStagedTree(stage, "", stageDirectories, stageFiles, 0)
    let stageBudget = OutputHashBudget()
    for (path in stageFiles) {
        if (path == OUTPUT_MANIFEST_NAME) {
            if (!manifestTextMatches(stage.join(path), outputManifest(plan.next.files))) {
                throw IllegalStateException("transaction stage manifest does not match plan")
            }
        } else {
            match (nextByPath.get(path)) {
                case Some(file) => verifiedDigest(stage.join(path), file.digest,
                    "transaction staged artifact", stageBudget)
                case None => throw IllegalStateException(
                    "transaction stage contains unexpected file '${path}'")
            }
        }
    }

    let backupFiles = HashSet<String>()
    let backupDirectories = HashSet<String>()
    addExpectedParentDirectories(OUTPUT_MANIFEST_NAME, backupDirectories)
    let previousByPath = previousFileIndex(plan.previous)
    for (file in plan.previous) { addExpectedParentDirectories(file.path, backupDirectories) }
    let _ = scanStagedTree(backup, "", backupDirectories, backupFiles, 0)
    let backupBudget = OutputHashBudget()
    for (path in backupFiles) {
        if (path == OUTPUT_MANIFEST_NAME) {
            if (!plan.rootExisted ||
                !manifestTextMatches(backup.join(path), plan.previousManifestText)) {
                throw IllegalStateException("transaction backup manifest does not match plan")
            }
        } else {
            match (previousByPath.get(path)) {
                case Some(file) => verifiedDigest(backup.join(path), file.rollbackDigest,
                    "transaction backed-up artifact", backupBudget)
                case None => throw IllegalStateException(
                    "transaction backup contains unexpected file '${path}'")
            }
        }
    }
}

private func validateRollbackState(root: Path, transaction: Path,
    plan: OutputTransactionPlan): Unit {
    let backup = transaction.join("backup")
    let previousByPath = previousFileIndex(plan.previous)
    let nextByPath = ownedFileIndex(plan.next.files)
    let rootBudget = OutputHashBudget()
    let backupBudget = OutputHashBudget()
    let rootDigests = HashMap<String, String>()
    if (exists(root)) { ensureOutputRoot(root) }
    for (next in plan.next.files) {
        let target = root.join(next.path)
        if (!exists(target)) { continue }
        let actual = digestRegularFile(target, "output artifact", rootBudget)
        rootDigests.add(next.path, actual)
        match (previousByPath.get(next.path)) {
            case Some(previous) =>
                if (actual != previous.rollbackDigest && actual != next.digest) {
                    throw IllegalStateException(
                        "output artifact '${next.path}' has an ambiguous recovery state")
                }
            case None =>
                if (actual != next.digest) {
                    throw IllegalStateException(
                        "output artifact '${next.path}' has an ambiguous recovery state")
                }
        }
    }
    for (previous in plan.previous) {
        let target = root.join(previous.path)
        if (exists(target)) {
            let actual = match (rootDigests.get(previous.path)) {
                case Some(value) => value
                case None => digestRegularFile(target, "output artifact", rootBudget)
            }
            if (actual != previous.rollbackDigest) {
                match (nextByPath.get(previous.path)) {
                    case Some(next) =>
                        if (actual != next.digest) {
                            throw IllegalStateException(
                                "output artifact '${previous.path}' has an ambiguous recovery state")
                        }
                        verifiedDigest(backup.join(previous.path), previous.rollbackDigest,
                            "backed-up output artifact", backupBudget)
                    case None => throw IllegalStateException(
                        "output artifact '${previous.path}' has an ambiguous recovery state")
                }
            }
        } else {
            verifiedDigest(backup.join(previous.path), previous.rollbackDigest,
                "backed-up output artifact", backupBudget)
        }
    }
    let rootManifest = root.join(OUTPUT_MANIFEST_NAME)
    let nextManifestText = outputManifest(plan.next.files)
    if (exists(rootManifest) &&
        !manifestTextMatches(rootManifest, plan.previousManifestText) &&
        !manifestTextMatches(rootManifest, nextManifestText)) {
        throw IllegalStateException("output manifest has an ambiguous recovery state")
    }
    if (plan.rootExisted && !manifestTextMatches(rootManifest, plan.previousManifestText)) {
        let backupManifest = backup.join(OUTPUT_MANIFEST_NAME)
        if (!manifestTextMatches(backupManifest, plan.previousManifestText)) {
            throw IllegalStateException("previous output manifest is unavailable for recovery")
        }
    }
}

private func rollbackPendingTransaction(root: Path, transaction: Path,
    plan: OutputTransactionPlan, lock: OutputLockHandle): Unit {
    ensureOutputLockCurrent(lock)
    validateRecoveryCollections(transaction, plan)
    validateRollbackState(root, transaction, plan)
    let backup = transaction.join("backup")
    let stage = transaction.join("stage")
    let rootManifest = root.join(OUTPUT_MANIFEST_NAME)
    if (exists(rootManifest) && !manifestTextMatches(rootManifest, plan.previousManifestText)) {
        let stagedManifest = stage.join(OUTPUT_MANIFEST_NAME)
        if (exists(stagedManifest)) {
            throw IllegalStateException(
                "output manifest lacks transaction installation provenance; refusing deletion")
        }
        lockedRename(rootManifest, stagedManifest, lock)
        if (!manifestTextMatches(stagedManifest, outputManifest(plan.next.files))) {
            try { lockedRename(stagedManifest, rootManifest, lock) } catch (_: Exception) {}
            throw IllegalStateException("installed output manifest changed during rollback move")
        }
    }
    let previousByPath = previousFileIndex(plan.previous)
    let budget = OutputHashBudget()
    for (next in plan.next.files) {
        let target = root.join(next.path)
        if (!exists(target)) { continue }
        let actual = digestRegularFile(target, "output artifact", budget)
        match (previousByPath.get(next.path)) {
            case Some(previous) =>
                if (actual == next.digest && actual != previous.rollbackDigest) {
                    let staged = stage.join(next.path)
                    if (exists(staged)) {
                        throw IllegalStateException(
                            "output artifact '${next.path}' lacks transaction installation provenance")
                    }
                    let ignored = ArrayList<Path>()
                    ensureParentDirectories(stage, next.path, ignored, lock)
                    lockedRename(target, staged, lock)
                    try { verifiedDigest(staged, next.digest,
                        "rolled-back staged output artifact", OutputHashBudget()) }
                    catch (error: Exception) {
                        try { lockedRename(staged, target, lock) } catch (_: Exception) {}
                        throw error
                    }
                }
            case None =>
                let staged = stage.join(next.path)
                if (exists(staged)) {
                    throw IllegalStateException(
                        "unowned output artifact '${next.path}' was not installed by this transaction")
                }
                let ignored = ArrayList<Path>()
                ensureParentDirectories(stage, next.path, ignored, lock)
                lockedRename(target, staged, lock)
                try { verifiedDigest(staged, next.digest,
                    "rolled-back staged output artifact", OutputHashBudget()) }
                catch (error: Exception) {
                    try { lockedRename(staged, target, lock) } catch (_: Exception) {}
                    throw error
                }
        }
    }
    for (previous in plan.previous) {
        let target = root.join(previous.path)
        if (!exists(target)) {
            let ignored = ArrayList<Path>()
            ensureParentDirectories(root, previous.path, ignored, lock)
            lockedRename(backup.join(previous.path), target, lock)
        }
    }
    if (plan.rootExisted && !exists(rootManifest)) {
        lockedRename(backup.join(OUTPUT_MANIFEST_NAME), rootManifest, lock)
    }
    pruneOwnedDirectories(root, plan.next.directories, lock)
    if (!plan.rootExisted && exists(root) && Directory.isEmpty(root)) {
        if (!lockedRemoveIfExists(root, lock) || exists(root)) {
            throw IllegalStateException("unable to remove rolled-back output root '${root}'")
        }
    }
    if (!previousOutputIsPresent(root, plan)) {
        throw IllegalStateException("rolled-back output tree does not match transaction plan")
    }
}

private func recoverPendingPreparation(root: Path, faults: TransactionFaultController,
    lock: OutputLockHandle): Unit {
    let preparing = preparingPath(root)
    if (!exists(preparing)) { return }
    let info = FileInfo(preparing)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid cjdoc output preparation directory '${preparing}'")
    }
    let marker = readPreparationMarker(preparing)
    let _ = resolveStateRoot(preparing.parent, marker.rootName, marker.parentDigest,
        "preparing output path")
    faults.hit("before-recovery-retire")
    retireFixedState(preparing, "output preparation", faults, lock)
}

private func recoverPendingBootstrap(root: Path, faults: TransactionFaultController,
    lock: OutputLockHandle): Unit {
    let bootstrap = bootstrapPath(root)
    if (!exists(bootstrap)) { return }
    let info = FileInfo(bootstrap)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid cjdoc output bootstrap directory '${bootstrap}'")
    }
    let marker = readPreparationMarker(bootstrap)
    let _ = resolveStateRoot(bootstrap.parent, marker.rootName, marker.parentDigest,
        "bootstrap output path")
    faults.hit("before-recovery-retire")
    retireFixedState(bootstrap, "output bootstrap", faults, lock)
}

private func recoverPendingRetirement(root: Path, lock: OutputLockHandle): Unit {
    let retired = retiredPath(root)
    if (!exists(retired)) { return }
    let info = FileInfo(retired)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid retired cjdoc output state '${retired}'")
    }
    let marker = readPreparationMarker(retired)
    let _ = resolveStateRoot(retired.parent, marker.rootName, marker.parentDigest,
        "retired output path")
    if (!lockedRemoveIfExists(retired, lock, recursive: true) || exists(retired)) {
        throw IllegalStateException("unable to delete retired cjdoc output state '${retired}'")
    }
}

private func recoverPendingTransaction(root: Path, faults: TransactionFaultController,
    lock: OutputLockHandle): Unit {
    let transaction = transactionPath(root)
    if (!exists(transaction)) { return }
    let info = FileInfo(transaction)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalStateException("invalid cjdoc output transaction directory '${transaction}'")
    }
    let plan = readOutputTransactionPlan(transaction)
    validateTransactionIdentity(transaction, plan)
    let plannedRoot = resolveStateRoot(transaction.parent, plan.rootName, plan.parentDigest,
        "transaction output path")
    validateRecoveryCollections(transaction, plan)
    if (completeNextOutputIsPresent(plannedRoot, plan)) {
        let previousDirectories = if (plan.rootExisted) {
            parseOwnedManifest(plan.previousManifestText).directories
        } else { Array<String>() }
        pruneOwnedDirectories(plannedRoot, previousDirectories, lock)
        faults.hit("before-recovery-retire")
        retireFixedState(transaction, "output transaction", faults, lock)
        return
    }
    rollbackPendingTransaction(plannedRoot, transaction, plan, lock)
    faults.hit("before-recovery-retire")
    retireFixedState(transaction, "output transaction", faults, lock)
}

private func recoverPendingOutputState(root: Path, faults: TransactionFaultController,
    lock: OutputLockHandle): Unit {
    ensureOutputLockCurrent(lock)
    recoverPendingRetirement(root, lock)
    let bootstrap = bootstrapPath(root)
    let preparing = preparingPath(root)
    let transaction = transactionPath(root)
    var stateCount: Int64 = 0
    if (exists(bootstrap)) { stateCount++ }
    if (exists(preparing)) { stateCount++ }
    if (exists(transaction)) { stateCount++ }
    if (stateCount > 1) {
        throw IllegalStateException(
            "output parent contains multiple active cjdoc transaction states")
    }
    recoverPendingBootstrap(root, faults, lock)
    recoverPendingPreparation(root, faults, lock)
    recoverPendingTransaction(root, faults, lock)
}

private func prepareOutputTransaction(root: Path, artifacts: Array<RenderArtifact>,
    previous: OwnedOutputSnapshot, previousFiles: Array<PreviousOutputFile>,
    nextFiles: Array<OwnedOutputFile>, initialRootExisted: Bool,
    faults: TransactionFaultController, lock: OutputLockHandle): Path {
    let parent = root.parent
    let manifestBytes = outputManifest(nextFiles).toArray()
    if (manifestBytes.size > OUTPUT_MANIFEST_LIMIT) {
        throw IllegalArgumentException("cjdoc output manifest exceeds limit")
    }
    ensureOutputLockCurrent(lock)
    let bootstrap = bootstrapPath(root)
    let preparing = preparingPath(root)
    let transaction = transactionPath(root)
    if (exists(bootstrap) || exists(preparing) || exists(transaction) || exists(retiredPath(root))) {
        throw IllegalStateException("pending cjdoc output state was not recovered before preparation")
    }
    lockedDirectoryCreate(bootstrap, lock)
    let rootName = outputRootName(root)
    let parentDigest = canonicalParentDigest(parent)
    let pid = getProcessId()
    let startTime = findProcess(pid).startTime.toString()
    let transactionId = Sha256Digest.digest(
        "${pid}|${startTime}|${bootstrap}|${rootName}|${parentDigest}")
    let plan = OutputTransactionPlan(rootName, parentDigest, transactionId, initialRootExisted,
        previous.exactText, previousFiles, ownedManifest(nextFiles), "")
    let planBytes = outputTransactionPlanContent(plan).toArray()
    if (planBytes.size > OUTPUT_TRANSACTION_PLAN_LIMIT) {
        if (!lockedRemoveIfExists(bootstrap, lock, recursive: true) || exists(bootstrap)) {
            throw IllegalStateException("unable to remove oversized output bootstrap")
        }
        throw IllegalArgumentException("cjdoc output transaction plan exceeds limit")
    }
    let planDigest = Sha256Digest.digestBytes(planBytes)
    let marker = OutputPreparationMarker(pid, startTime, rootName, parentDigest,
        planDigest, transactionId)
    let markerContent = preparationMarkerContent(marker)
    if (markerContent.toArray().size > OUTPUT_PREPARATION_MARKER_LIMIT) {
        // No marker has been published, so this fixed empty bootstrap is safe
        // to remove strictly while the parent lock is current.
        if (!lockedRemoveIfExists(bootstrap, lock, recursive: true) || exists(bootstrap)) {
            throw IllegalStateException("unable to remove oversized output bootstrap")
        }
        throw IllegalArgumentException("cjdoc output preparation marker exceeds limit")
    }
    try {
        lockedFileWrite(bootstrap.join(OUTPUT_PREPARATION_MARKER_NAME), markerContent.toArray(), lock)
        faults.hit("before-preparing-publish")
        lockedRename(bootstrap, preparing, lock)
        faults.hit("after-preparing-publish")
        let stage = preparing.join("stage")
        let backup = preparing.join("backup")
        lockedDirectoryCreate(stage, lock)
        lockedDirectoryCreate(backup, lock)
        let stageBudget = OutputHashBudget()
        let nextByPath = ownedFileIndex(nextFiles)
        for (artifact in artifacts) {
            let target = stage.join(artifact.path)
            let ignored = ArrayList<Path>()
            ensureParentDirectories(stage, artifact.path, ignored, lock)
            lockedFileWrite(target, artifact.bytes, lock)
            let expected = nextByPath[artifact.path].digest
            if (digestRegularFile(target, "staged output artifact", stageBudget) != expected) {
                throw IllegalStateException("staged output digest mismatch for '${artifact.path}'")
            }
        }
        let stagedManifest = stage.join(OUTPUT_MANIFEST_NAME)
        lockedFileWrite(stagedManifest, manifestBytes, lock)
        if (readFileBounded(stagedManifest, OUTPUT_MANIFEST_LIMIT) != manifestBytes) {
            throw IllegalStateException("staged output manifest does not match planned bytes")
        }
        validateStagedOutput(stage, nextFiles)
        let planPath = preparing.join(OUTPUT_TRANSACTION_PLAN_NAME)
        lockedFileWrite(planPath, planBytes, lock)
        if (Sha256Digest.digestBytes(readFileBounded(planPath, OUTPUT_TRANSACTION_PLAN_LIMIT)) != planDigest) {
            throw IllegalStateException("written output transaction plan digest mismatch")
        }
        lockedRename(preparing, transaction, lock)
        faults.hit("after-transaction-publish")
        transaction
    } catch (error: Exception) {
        if (!faults.wasInterrupted()) {
            let pending = if (exists(preparing)) { Some(preparing) }
                else if (exists(bootstrap)) { Some(bootstrap) }
                else { None<Path> }
            match (pending) {
                case Some(path) => try { retireFixedState(path, "output preparation", faults, lock) }
                    catch (retireError: Exception) {
                        throw IllegalStateException(
                            "output preparation failed and retirement was incomplete: ${error.message}; ${retireError.message}")
                    }
                case None => ()
            }
        }
        throw error
    }
}

private func commitOutput(root: Path, transaction: Path, plan: OutputTransactionPlan,
    faultAfterOperation: ?Int64, interruptAfterOperation: ?Int64,
    faults: TransactionFaultController, lock: OutputLockHandle): Unit {
    let stage = transaction.join("stage")
    let backup = transaction.join("backup")
    let fault = CommitFaultCounter(faultAfterOperation, interruptAfterOperation)
    var committed = false
    try {
        ensureOutputLockCurrent(lock)
        validateStagedOutput(stage, plan.next.files)
        if (!plan.rootExisted) {
            if (exists(root)) {
                throw IllegalStateException("output root appeared after transaction preflight")
            }
            lockedDirectoryCreate(root, lock)
        } else {
            ensureOutputRoot(root)
        }
        if (plan.rootExisted &&
            !manifestTextMatches(root.join(OUTPUT_MANIFEST_NAME), plan.previousManifestText)) {
            throw IllegalStateException("output manifest changed after transaction preflight")
        }
        let previousPaths = ArrayList<String>()
        for (file in plan.previous) { previousPaths.add(file.path) }
        let orderedPrevious = previousPaths.toArray()
        sort(orderedPrevious)
        let previousByPath = previousFileIndex(plan.previous)
        let backupBudget = OutputHashBudget()
        let movedBackupBudget = OutputHashBudget()
        for (path in orderedPrevious) {
            let previous = previousByPath[path]
            verifiedDigest(root.join(path), previous.rollbackDigest,
                "owned output artifact before backup", backupBudget)
            let ignored = ArrayList<Path>()
            ensureParentDirectories(backup, path, ignored, lock)
            if (exists(backup.join(path))) {
                throw IllegalStateException("output backup target already exists for '${path}'")
            }
            lockedRename(root.join(path), backup.join(path), lock)
            verifiedDigest(backup.join(path), previous.rollbackDigest,
                "owned output artifact after backup move", movedBackupBudget)
            fault.operationCompleted()
        }
        if (plan.rootExisted) {
            // Recheck immediately before the manifest move as well as before any
            // artifact move, so a concurrent replacement always fails closed.
            if (!manifestTextMatches(root.join(OUTPUT_MANIFEST_NAME), plan.previousManifestText)) {
                throw IllegalStateException("output manifest changed during transaction commit")
            }
            lockedRename(root.join(OUTPUT_MANIFEST_NAME), backup.join(OUTPUT_MANIFEST_NAME), lock)
            if (!manifestTextMatches(backup.join(OUTPUT_MANIFEST_NAME), plan.previousManifestText)) {
                throw IllegalStateException("output manifest changed during backup move")
            }
            fault.operationCompleted()
        }
        let stageBudget = OutputHashBudget()
        let installedBudget = OutputHashBudget()
        for (file in plan.next.files) {
            verifiedDigest(stage.join(file.path), file.digest,
                "staged output artifact before install", stageBudget)
            if (exists(root.join(file.path))) {
                throw IllegalStateException(
                    "output target '${file.path}' appeared after transaction preflight")
            }
            let ignored = ArrayList<Path>()
            ensureParentDirectories(root, file.path, ignored, lock)
            lockedRename(stage.join(file.path), root.join(file.path), lock)
            verifiedDigest(root.join(file.path), file.digest,
                "output artifact after install move", installedBudget)
            fault.operationCompleted()
        }
        if (!manifestTextMatches(stage.join(OUTPUT_MANIFEST_NAME), outputManifest(plan.next.files)) ||
            exists(root.join(OUTPUT_MANIFEST_NAME))) {
            throw IllegalStateException("staged output manifest changed before install")
        }
        lockedRename(stage.join(OUTPUT_MANIFEST_NAME), root.join(OUTPUT_MANIFEST_NAME), lock)
        if (!manifestTextMatches(root.join(OUTPUT_MANIFEST_NAME), outputManifest(plan.next.files))) {
            throw IllegalStateException("output manifest changed during install move")
        }
        // The manifest is the authoritative ownership record. Once it is
        // installed and verified, recovery must finish this transaction as a
        // committed output rather than restore the previous generation.
        committed = true
        fault.operationCompleted()
        if (!completeNextOutputIsPresent(root, plan)) {
            throw IllegalStateException("committed output tree does not match transaction plan")
        }
        let previousDirectories = if (plan.rootExisted) {
            parseOwnedManifest(plan.previousManifestText).directories
        } else { Array<String>() }
        pruneOwnedDirectories(root, previousDirectories, lock)
    } catch (error: Exception) {
        if (fault.wasInterrupted() || committed) { throw error }
        try {
            rollbackPendingTransaction(root, transaction, plan, lock)
            faults.hit("before-recovery-retire")
            retireFixedState(transaction, "output transaction", faults, lock)
        } catch (recoveryError: Exception) {
            throw IllegalStateException(
                "output transaction failed and recovery was incomplete: ${error.message}; ${recoveryError.message}")
        }
        throw error
    }
    faults.hit("before-commit-retire")
    if (!completeNextOutputIsPresent(root, plan)) {
        throw IllegalStateException("output tree changed before transaction retirement")
    }
    retireFixedState(transaction, "output transaction", faults, lock)
}

private func writeOwnedArtifactsLocked(outputDirectory: String, artifacts: Array<RenderArtifact>,
    forceOwned: Bool, faultAfterOperation: ?Int64, interruptAfterOperation: ?Int64,
    transactionFaultPoint: ?String, lock: OutputLockHandle,
    beforeCommit: () -> Unit): Unit {
    let root = canonicalForWrite(Path(outputDirectory), "output path")
    let faults = TransactionFaultController(transactionFaultPoint)
    ensureOutputLockCurrent(lock)
    if (root.toString() != lock.root) {
        throw IllegalStateException("output path does not match the held output lock")
    }
    recoverPendingOutputState(root, faults, lock)
    ensureOutputRoot(root)
    let nextFiles = orderedOwnedFiles(artifacts)
    let nextPaths = ArrayList<String>()
    for (file in nextFiles) { nextPaths.add(file.path) }
    if (hasTopologyCollision(nextPaths.toArray())) {
        throw IllegalArgumentException("render artifacts have conflicting file/directory paths")
    }

    let rootExisted = exists(root)
    let previous = if (rootExisted) {
        readOwnedManifest(root)
    } else {
        OwnedOutputSnapshot(ownedManifest([]), "")
    }
    let previousFiles = if (rootExisted) {
        preflightOutput(root, previous.manifest, nextFiles, forceOwned)
    } else { Array<PreviousOutputFile>() }
    let transaction = prepareOutputTransaction(root, artifacts, previous, previousFiles, nextFiles,
        rootExisted, faults, lock)
    let plan = readOutputTransactionPlan(transaction)
    validateTransactionIdentity(transaction, plan)
    if (plan.rootName != outputRootName(root) || plan.parentDigest != canonicalParentDigest(root.parent)) {
        throw IllegalStateException("prepared output transaction root does not match '${root}'")
    }
    beforeCommit()
    ensureOutputLockCurrent(lock)
    commitOutput(root, transaction, plan, faultAfterOperation, interruptAfterOperation, faults, lock)
}

internal func writeOwnedArtifactsWithLockHeld(outputDirectory: String,
    artifacts: Array<RenderArtifact>, lock: OutputLockHandle, forceOwned!: Bool = false,
    faultAfterOperation!: ?Int64 = None, interruptAfterOperation!: ?Int64 = None,
    transactionFaultPoint!: ?String = None): Unit {
    writeOwnedArtifactsLocked(outputDirectory, artifacts, forceOwned, faultAfterOperation,
        interruptAfterOperation, transactionFaultPoint, lock, { => })
}

internal func writeOwnedArtifacts(outputDirectory: String, artifacts: Array<RenderArtifact>,
    forceOwned!: Bool = false, faultAfterOperation!: ?Int64 = None,
    interruptAfterOperation!: ?Int64 = None, transactionFaultPoint!: ?String = None): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    var actionError: ?Exception = None
    try {
        writeOwnedArtifactsLocked(outputDirectory, artifacts, forceOwned, faultAfterOperation,
            interruptAfterOperation, transactionFaultPoint, handle, { => })
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

internal func writeOwnedArtifactsWithBeforeCommitForTest(outputDirectory: String,
    artifacts: Array<RenderArtifact>, beforeCommit: () -> Unit): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    var actionError: ?Exception = None
    try {
        writeOwnedArtifactsLocked(outputDirectory, artifacts, false, None<Int64>, None<Int64>,
            None<String>, handle, beforeCommit)
        ensureOutputLockCurrent(handle)
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

internal func withOutputLockReleaseFailureForTest(outputDirectory: String,
    action: () -> Unit): Unit {
    let handle = acquireOutputLock(Path(outputDirectory))
    var actionError: ?Exception = None
    try {
        action()
        // Simulate an ownership change at the release boundary. The strict
        // release must report failure and preserve the fixed lock for diagnosis.
        File.writeTo(handle.path.join("owner.json"), "{}".toArray())
    } catch (error: Exception) { actionError = Some(error) }
    finishOutputLock(handle, actionError)
}

internal func staleLockQueryFailureAllowsRecoveryForTest(queryFailed: Bool): Bool {
    let state = if (queryFailed) { OutputProcessState.Unknown } else { OutputProcessState.Dead }
    match (state) {
        case OutputProcessState.Dead => true
        case OutputProcessState.Alive | OutputProcessState.Unknown => false
    }
}

internal func validateOutputArtifactBudgetForTest(sizes: Array<Int64>): Unit {
    let budget = OutputHashBudget()
    for (size in sizes) { budget.reserve(size, "test output artifact") }
}
