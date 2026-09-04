package cjdoc

import cjdoc.render.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*

internal func prepareOutputTransaction(root: Path, artifacts: Array<RenderArtifact>,
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

internal func commitOutput(root: Path, transaction: Path, plan: OutputTransactionPlan,
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

internal func writeOwnedArtifactsLocked(outputDirectory: String, artifacts: Array<RenderArtifact>,
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
