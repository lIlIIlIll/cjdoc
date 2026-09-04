package cjdoc

import std.collection.*
import std.fs.*

internal func validateRecoveryCollections(transaction: Path, plan: OutputTransactionPlan): Unit {
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

internal func validateRollbackState(root: Path, transaction: Path,
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

internal func rollbackPendingTransaction(root: Path, transaction: Path,
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

internal func recoverPendingPreparation(root: Path, faults: TransactionFaultController,
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

internal func recoverPendingBootstrap(root: Path, faults: TransactionFaultController,
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

internal func recoverPendingRetirement(root: Path, lock: OutputLockHandle): Unit {
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

internal func recoverPendingTransaction(root: Path, faults: TransactionFaultController,
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

internal func recoverPendingOutputState(root: Path, faults: TransactionFaultController,
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
