package cjdoc

import std.fs.*
import std.overflow.*


internal let OUTPUT_MANIFEST_NAME = ".cjdoc-output.json"
internal let OUTPUT_LOCK_NAME = ".cjdoc-output-parent.lock"
internal let OUTPUT_LOCK_BOOTSTRAP_NAME = ".cjdoc-output-parent.bootstrap"
internal let OUTPUT_RETIRED_LOCK_NAME = ".cjdoc-output-parent.retired"
internal let OUTPUT_BOOTSTRAP_NAME = ".cjdoc-output-transaction.bootstrap"
internal let OUTPUT_PREPARING_NAME = ".cjdoc-output-transaction.preparing"
internal let OUTPUT_TRANSACTION_NAME = ".cjdoc-output-transaction.txn"
internal let OUTPUT_RETIRED_NAME = ".cjdoc-output-transaction.retired"
internal let OUTPUT_MANIFEST_SCHEMA = "cjdoc.output/3"
internal let OUTPUT_LEGACY_MANIFEST_SCHEMA = "cjdoc.output/2"
internal let OUTPUT_DIGEST_ALGORITHM = "sha256"
internal let OUTPUT_MANIFEST_LIMIT: Int64 = 8 * 1024 * 1024
internal let OUTPUT_ARTIFACT_LIMIT: Int64 = 64 * 1024 * 1024
internal let OUTPUT_ARTIFACT_TOTAL_LIMIT: Int64 = 512 * 1024 * 1024
internal let OUTPUT_ENTRY_LIMIT: Int64 = 65536
internal let OUTPUT_HASH_CHUNK_BYTES: Int64 = 64 * 1024
internal let OUTPUT_LOCK_OWNER_LIMIT: Int64 = 64 * 1024
internal let OUTPUT_PREPARATION_MARKER_NAME = "marker.json"
internal let OUTPUT_PREPARATION_MARKER_SCHEMA = "cjdoc.output-preparing/4"
internal let OUTPUT_PREPARATION_MARKER_LIMIT: Int64 = 64 * 1024
internal let OUTPUT_TRANSACTION_PLAN_NAME = "plan.json"
internal let OUTPUT_TRANSACTION_PLAN_SCHEMA = "cjdoc.output-transaction/4"
// A plan contains the exact previous manifest (escaped once), compact previous/next
// entry arrays, and fixed metadata. Eight manifest limits covers the worst-case
// JSON escaping while leaving deterministic headroom for all fixed fields.
internal let OUTPUT_TRANSACTION_PLAN_LIMIT: Int64 = OUTPUT_MANIFEST_LIMIT * 8

internal class OwnedOutputFile {
    let path: String
    let digest: String

    init(path: String, digest: String) {
        this.path = path
        this.digest = digest
    }
}

internal class OwnedOutputManifest {
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

internal enum OutputProcessState {
    | Alive
    | Dead
    | Unknown
}

internal class OwnedOutputSnapshot {
    let manifest: OwnedOutputManifest
    let exactText: String

    init(manifest: OwnedOutputManifest, exactText: String) {
        this.manifest = manifest
        this.exactText = exactText
    }
}

internal class PreviousOutputFile {
    let path: String
    let ownershipDigest: String
    let rollbackDigest: String

    init(path: String, ownershipDigest: String, rollbackDigest: String) {
        this.path = path
        this.ownershipDigest = ownershipDigest
        this.rollbackDigest = rollbackDigest
    }
}

internal class OutputLockOwner {
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

internal class OutputTransactionPlan {
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

internal class OutputPreparationMarker {
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

internal class OutputHashBudget {
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

internal let OUTPUT_SHA256_CONSTANTS: Array<UInt32> = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
]

internal func outputShaRotateRight(value: UInt32, bits: UInt32): UInt32 {
    (value >> bits) | (value << (32 - bits))
}

internal class StreamingOutputSha256 {
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

internal func outputShaHex(words: Array<UInt32>): String {
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

internal class TransactionFaultController {
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

internal class CommitFaultCounter {
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
