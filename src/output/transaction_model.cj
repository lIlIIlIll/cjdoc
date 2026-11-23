protected package cjdoc.output

import std.fs.*


internal let OUTPUT_MANIFEST_NAME = ".cjdoc-output.json"
internal let OUTPUT_LOCK_NAME = ".cjdoc-output-parent.lock"
internal let OUTPUT_LOCK_OWNER_SCHEMA = "cjdoc.output-lock/2"
internal let OUTPUT_LOCK_BOOTSTRAP_NAME = ".cjdoc-output-parent.bootstrap"
internal let OUTPUT_RETIRED_LOCK_NAME = ".cjdoc-output-parent.retired"
internal let OUTPUT_BOOTSTRAP_NAME = ".cjdoc-output-transaction.bootstrap"
internal let OUTPUT_PREPARING_NAME = ".cjdoc-output-transaction.preparing"
internal let OUTPUT_TRANSACTION_NAME = ".cjdoc-output-transaction.txn"
internal let OUTPUT_RETIRED_NAME = ".cjdoc-output-transaction.retired"
internal let OUTPUT_MANIFEST_SCHEMA = "cjdoc.output/3"
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

    init(files: Array<OwnedOutputFile>, directories!: Array<String> = []) {
        this.files = files
        this.directories = directories
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
    let processDomainSha256: ?String
    let token: String
    let root: String

    init(pid: Int64, startTime: String, processDomainSha256: ?String,
        token: String, root: String) {
        this.pid = pid
        this.startTime = startTime
        this.processDomainSha256 = processDomainSha256
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
    let processDomainSha256: ?String
    let token: String
    let root: String
    let ownerFile: File
    let ownerText: String
    var ownerFileClosed: Bool = false
    var ownerChallengeIsSpace: Bool = false

    init(path: Path, parent: Path, parentCanonical: String, pid: Int64,
        startTime: String, processDomainSha256: ?String, token: String, root: String,
        ownerFile: File, ownerText: String) {
        this.path = path
        this.parent = parent
        this.parentCanonical = parentCanonical
        this.pid = pid
        this.startTime = startTime
        this.processDomainSha256 = processDomainSha256
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
    private var scratch: ?Array<Byte> = None

    // A budget belongs to one validation phase, whose files are read serially.
    func readBuffer(): Array<Byte> {
        match (scratch) {
            case Some(buffer) => buffer
            case None =>
                let buffer = Array<Byte>(OUTPUT_HASH_CHUNK_BYTES, repeat: 0)
                scratch = Some(buffer)
                buffer
        }
    }

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
