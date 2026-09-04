package cjdoc

import cjdoc.render.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.io.*
import std.process.*
import std.sort.*
import std.unicode.*
import yjson.*

internal func isSafeRootName(rootName: String): Bool {
    !rootName.isEmpty() && rootName != "." && rootName != ".." &&
        !rootName.contains("/") && !rootName.contains("\\") && !rootName.contains(":")
}

internal func portableFileNameKey(name: String): String {
    var trimmed = name
    while (trimmed.endsWith(".") || trimmed.endsWith(" ")) {
        trimmed = trimmed[..trimmed.size - 1]
    }
    trimmed.toLower()
}

internal func collidesWithInternalSibling(rootName: String): Bool {
    let key = portableFileNameKey(rootName)
    key == portableFileNameKey(OUTPUT_LOCK_NAME) ||
        key == portableFileNameKey(OUTPUT_LOCK_BOOTSTRAP_NAME) ||
        key == portableFileNameKey(OUTPUT_RETIRED_LOCK_NAME) ||
        key == portableFileNameKey(OUTPUT_BOOTSTRAP_NAME) ||
        key == portableFileNameKey(OUTPUT_PREPARING_NAME) ||
        key == portableFileNameKey(OUTPUT_TRANSACTION_NAME) ||
        key == portableFileNameKey(OUTPUT_RETIRED_NAME)
}

internal func preparationMarkerContent(marker: OutputPreparationMarker): String {
    "{\"schemaVersion\":${escapeJsonString(OUTPUT_PREPARATION_MARKER_SCHEMA)}," +
        "\"pid\":${escapeJsonString(marker.pid.toString())}," +
        "\"startTime\":${escapeJsonString(marker.startTime)}," +
        "\"rootName\":${escapeJsonString(marker.rootName)}," +
        "\"parentSha256\":${escapeJsonString(marker.parentDigest)}," +
        "\"planSha256\":${escapeJsonString(marker.planDigest)}," +
        "\"transactionId\":${escapeJsonString(marker.transactionId)}}\n"
}

internal func readPreparationMarker(preparing: Path): OutputPreparationMarker {
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

internal func validateTransactionIdentity(transaction: Path,
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

internal func hasTopologyCollision(paths: Array<String>): Bool {
    let ordered = paths.clone()
    sort(ordered)
    var index: Int64 = 1
    while (index < ordered.size) {
        if (ordered[index].startsWith(ordered[index - 1] + "/")) { return true }
        index++
    }
    false
}

internal func outputLockOwnerContent(owner: OutputLockOwner): String {
    "{\"schemaVersion\":\"cjdoc.output-lock/1\",\"pid\":${escapeJsonString(owner.pid.toString())}," +
        "\"startTime\":${escapeJsonString(owner.startTime)},\"token\":${escapeJsonString(owner.token)}," +
        "\"root\":${escapeJsonString(owner.root)}}\n"
}

internal func readOutputLockOwner(lockPath: Path): OutputLockOwner {
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

internal func ownerProcessState(owner: OutputLockOwner): OutputProcessState {
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

internal func ensureLockedParentPathCurrent(path: Path, canonical: String,
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

internal func ensureOutputLockPhysicalIdentity(handle: OutputLockHandle): Unit {
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

internal func ensureOutputLockCurrent(handle: OutputLockHandle): Unit {
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

internal func lockedRename(from: Path, to: Path, handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    rename(from, to: to, overwrite: false)
    ensureOutputLockCurrent(handle)
}

internal func lockedDirectoryCreate(path: Path, handle: OutputLockHandle,
    recursive!: Bool = false): Unit {
    ensureOutputLockCurrent(handle)
    Directory.create(path, recursive: recursive)
    ensureOutputLockCurrent(handle)
}

internal func lockedFileWrite(path: Path, bytes: Array<Byte>, handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    File.writeTo(path, bytes)
    ensureOutputLockCurrent(handle)
}

internal func lockedRemoveIfExists(path: Path, handle: OutputLockHandle,
    recursive!: Bool = false): Bool {
    ensureOutputLockCurrent(handle)
    let removed = removeIfExists(path, recursive: recursive)
    ensureOutputLockCurrent(handle)
    removed
}

internal func removeLockStateStrict(path: Path, parent: Path, parentCanonical: String,
    description: String): Unit {
    ensureLockedParentPathCurrent(parent, parentCanonical, description)
    if (!removeIfExists(path, recursive: true) || exists(path)) {
        throw IllegalStateException("unable to remove ${description} '${path}'")
    }
    ensureLockedParentPathCurrent(parent, parentCanonical, description)
}

internal func acquireOutputLock(root: Path): OutputLockHandle {
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

internal func releaseOutputLock(handle: OutputLockHandle): Unit {
    ensureOutputLockCurrent(handle)
    handle.ownerFile.close()
    handle.ownerFileClosed = true
    if (!removeIfExists(handle.path, recursive: true) || exists(handle.path)) {
        throw IllegalStateException("unable to release output parent lock '${handle.path}'")
    }
}

internal func closeOutputLockOwnerBestEffort(handle: OutputLockHandle): Unit {
    if (!handle.ownerFileClosed) {
        try { handle.ownerFile.close() } catch (_: Exception) {}
        handle.ownerFileClosed = true
    }
}

internal func finishOutputLock(handle: OutputLockHandle, actionError: ?Exception): Unit {
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
