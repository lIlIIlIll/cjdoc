protected package cjdoc.output

import cjdoc.filesystem.{ensureNoSymbolicLinkAncestors, ensureRegularNonSymlink}
import cjdoc.digest.{Sha256Digest, StreamingSha256, isSha256}
import cjdoc.render.*
import cjdoc.render.foundation.RenderTextBuffer
import std.collection.*
import std.fs.*
import std.sort.*
import yjson.*

private func jsonArrayValues(value: JsonArray): Array<JsonNode> {
    let result = ArrayList<JsonNode>()
    for (index in 0..value.size()) {
        result.add(value.get(index).getOrThrow())
    }
    result.toArray()
}

internal func digestRegularFile(path: Path, description: String,
    budget: OutputHashBudget): String {
    ensureNoSymbolicLinkAncestors(path, description)
    ensureRegularNonSymlink(path, description)
    let before = FileInfo(path)
    let beforeSize = before.size
    let beforeCreation = before.creationTime
    let beforeModification = before.lastModificationTime
    budget.reserve(beforeSize, description)

    let file = File(path, OpenMode.Read)
    let digest = StreamingSha256()
    var total: Int64 = 0
    try {
        let opened = file.info
        if (opened.isSymbolicLink() || !opened.isRegular() || opened.size != beforeSize ||
            opened.creationTime != beforeCreation || opened.lastModificationTime != beforeModification ||
            file.length != beforeSize) {
            throw IllegalArgumentException("${description} changed while opening: '${path}'")
        }
        let buffer = budget.readBuffer()
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

internal func ensureOutputRoot(root: Path): Unit {
    if (!exists(root)) { return }
    let info = FileInfo(root)
    if (info.isSymbolicLink() || !info.isDirectory()) {
        throw IllegalArgumentException("output path must be a non-symbolic-link directory: '${root}'")
    }
}

internal func ensureSafeExistingAncestors(root: Path, relativePath: String): Unit {
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

// JSON leaves UTF-8 unchanged except for ASCII controls, quote and backslash.
private func manifestPathBytes(path: String): Int64 {
    var size = path.size + 2
    for (index in 0..path.size) {
        let byte = path[index]
        if (byte == b'"' || byte == b'\\' || byte == 0x08 || byte == 0x0C ||
            byte == 0x0A || byte == 0x0D || byte == 0x09) {
            size++
        } else if (byte < 0x20) {
            size += 5
        }
    }
    size
}

internal func ownedDirectoriesForFiles(files: Array<OwnedOutputFile>): Array<String> {
    let directories = ArrayList<String>()
    let seen = HashSet<String>()
    var directoryBytes: Int64 = 0
    for (file in files) {
        let parts = file.path.split("/")
        let prefix = StringBuilder()
        var index: Int64 = 0
        while (index + 1 < parts.size) {
            if (index > 0) { prefix.append("/") }
            prefix.append(parts[index])
            let directory = prefix.toString()
            if (seen.add(directory)) {
                let entryBytes = manifestPathBytes(directory) + "\n    ".size +
                    (if (directories.isEmpty()) { 0 } else { 1 })
                if (entryBytes > OUTPUT_MANIFEST_LIMIT - directoryBytes) {
                    throw IllegalArgumentException(
                        "owned output directories cannot fit the output manifest limit")
                }
                directoryBytes += entryBytes
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

internal func ownedManifest(files: Array<OwnedOutputFile>): OwnedOutputManifest {
    OwnedOutputManifest(files, directories: ownedDirectoriesForFiles(files))
}

internal func parseOwnedDirectoryEntries(entries: JsonArray): Array<String> {
    let directories = ArrayList<String>()
    let seen = HashSet<String>()
    for (node in jsonArrayValues(entries)) {
        if (directories.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException(
                "output manifest directories exceed ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let path = try { node.asString() } catch (_: Exception) {
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

internal func sameStringArray(first: Array<String>, second: Array<String>): Bool {
    if (first.size != second.size) { return false }
    for (index in 0..first.size) {
        if (first[index] != second[index]) { return false }
    }
    true
}

internal func parseOwnedManifest(text: String): OwnedOutputManifest {
    let parsed = JsonNode.parse(text, config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 8, maxStringBytes: OUTPUT_MANIFEST_LIMIT, maxBufferedValueBytes: OUTPUT_MANIFEST_LIMIT, maxInputBytes: OUTPUT_MANIFEST_LIMIT))
    let object = try { parsed.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest: expected object")
    }
    if (object.get("schemaVersion").isNone() ||
        object.get("digestAlgorithm").isNone() || object.get("files").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output manifest fields")
    }
    let schema = try { object["schemaVersion"].asString() } catch (_: Exception) {
        throw IllegalArgumentException("invalid cjdoc output manifest schemaVersion")
    }
    if (schema != OUTPUT_MANIFEST_SCHEMA) {
        throw IllegalArgumentException("unsupported cjdoc output manifest '${schema}'")
    }
    if (object.size() != 4 || object.get("directories").isNone()) {
        throw IllegalArgumentException("invalid cjdoc output manifest fields")
    }
    let algorithm = try { object["digestAlgorithm"].asString() } catch (_: Exception) {
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

internal func readOwnedManifest(root: Path): OwnedOutputSnapshot {
    let manifestPath = root.join(OUTPUT_MANIFEST_NAME)
    let text = readCappedRegularText(manifestPath, "cjdoc output manifest", OUTPUT_MANIFEST_LIMIT)
    OwnedOutputSnapshot(parseOwnedManifest(text), text)
}

internal func parseOwnedFileEntries(entries: JsonArray, description: String): Array<OwnedOutputFile> {
    let files = ArrayList<OwnedOutputFile>()
    let seen = HashSet<String>()
    for (node in jsonArrayValues(entries)) {
        if (files.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException("${description} exceeds ${OUTPUT_ENTRY_LIMIT} entries")
        }
        let entry = try { node.asObject() } catch (_: Exception) {
            throw IllegalArgumentException("invalid ${description} file entry")
        }
        if (entry.size() != 2 || entry.get("path").isNone() || entry.get("sha256").isNone()) {
            throw IllegalArgumentException("invalid ${description} file entry fields")
        }
        let path = try { entry["path"].asString() } catch (_: Exception) {
            throw IllegalArgumentException("invalid ${description} file path")
        }
        let digest = try { entry["sha256"].asString() } catch (_: Exception) {
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

// Shared admission rules for both renderer spools and array output adapters.
// Checking is side-effect free; a failed disk write must not reserve a path.
internal class OutputArtifactPathBudget {
    private let ordinals = HashMap<String, Int64>()
    private let paths = ArrayList<String>()
    private var manifestFileBytes: Int64 = 0
    private var treeWorstCaseEntries: Int64 = 1

    func check(path: String): (Int64, Int64) {
        if (paths.size >= OUTPUT_ENTRY_LIMIT) {
            throw IllegalArgumentException("render artifacts exceed ${OUTPUT_ENTRY_LIMIT} entries")
        }
        if (!isSafeOutputPath(path) || ordinals.contains(path)) {
            throw IllegalArgumentException("duplicate or unsafe render artifact '${path}'")
        }
        // Charge the actual UTF-8/JSON file row, including its fixed SHA-256.
        // The writer separately bounds the complete manifest with its directories.
        let entryBytes = manifestPathBytes(path) + "\n    {\"path\": ".size +
            ", \"sha256\": \"".size + 64 + "\"}".size + (if (paths.isEmpty()) { 0 } else { 1 })
        if (entryBytes > OUTPUT_MANIFEST_LIMIT - manifestFileBytes) {
            throw IllegalArgumentException("render artifacts cannot fit the output manifest limit")
        }
        let pathEntries = path.split("/").size
        if (pathEntries > OUTPUT_ENTRY_LIMIT - treeWorstCaseEntries) {
            throw IllegalArgumentException("render artifacts exceed staged tree entry limit")
        }
        (entryBytes, pathEntries)
    }

    func commit(path: String, allowance: (Int64, Int64)): Unit {
        ordinals[path] = paths.size
        paths.add(path)
        manifestFileBytes += allowance[0]
        treeWorstCaseEntries += allowance[1]
    }

    func ordinal(path: String): Int64 { ordinals[path] }

    func orderedPaths(): Array<String> {
        let ordered = paths.toArray()
        sort(ordered)
        if (hasTopologyCollision(ordered)) {
            throw IllegalArgumentException("render artifacts have conflicting file/directory paths")
        }
        ordered
    }
}

internal func ensurePlannedTreeEntryBudget(paths: Array<String>, description: String): Unit {
    var worstCase: Int64 = 1
    for (path in paths) {
        let pathEntries = path.split("/").size
        if (pathEntries > OUTPUT_ENTRY_LIMIT - worstCase) {
            throw IllegalArgumentException("${description} exceeds transaction tree entry limit")
        }
        worstCase += pathEntries
    }
}

internal func outputManifest(files: Array<OwnedOutputFile>): String {
    let directories = ownedDirectoriesForFiles(files)
    let out = RenderTextBuffer(limit: OUTPUT_MANIFEST_LIMIT)
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

internal func appendOwnedFileArray(out: StringBuilder, files: Array<OwnedOutputFile>): Unit {
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

internal func appendPreviousFileArray(out: StringBuilder, files: Array<PreviousOutputFile>): Unit {
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

internal func outputTransactionPlanContent(plan: OutputTransactionPlan): String {
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

internal func parsePreviousFileEntries(entries: JsonArray): Array<PreviousOutputFile> {
    let files = ArrayList<PreviousOutputFile>()
    let seen = HashSet<String>()
    for (node in jsonArrayValues(entries)) {
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
        let path = try { entry["path"].asString() } catch (_: Exception) { "" }
        let ownership = try { entry["ownershipSha256"].asString() } catch (_: Exception) { "" }
        let rollback = try { entry["rollbackSha256"].asString() } catch (_: Exception) { "" }
        if (!isSafeOutputPath(path) || !seen.add(path) ||
            !isSha256(ownership) || !isSha256(rollback)) {
            throw IllegalArgumentException("invalid output transaction previous entry '${path}'")
        }
        files.add(PreviousOutputFile(path, ownership, rollback))
    }
    files.toArray()
}

internal func validatePreviousManifest(planFiles: Array<PreviousOutputFile>,
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

internal func readOutputTransactionPlan(transaction: Path): OutputTransactionPlan {
    let text = readCappedRegularText(transaction.join(OUTPUT_TRANSACTION_PLAN_NAME),
        "cjdoc output transaction plan", OUTPUT_TRANSACTION_PLAN_LIMIT)
    let parsed = JsonNode.parse(text, config: JsonReadOptions(duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject, maxDepth: 8, maxStringBytes: OUTPUT_TRANSACTION_PLAN_LIMIT, maxBufferedValueBytes: OUTPUT_TRANSACTION_PLAN_LIMIT, maxInputBytes: OUTPUT_TRANSACTION_PLAN_LIMIT))
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
    let schema = try { object["schemaVersion"].asString() } catch (_: Exception) { "" }
    let rootName = try { object["rootName"].asString() } catch (_: Exception) { "" }
    let parentDigest = try { object["parentSha256"].asString() } catch (_: Exception) { "" }
    let transactionId = try { object["transactionId"].asString() } catch (_: Exception) { "" }
    let rootState = try { object["rootState"].asString() } catch (_: Exception) { "" }
    let manifestDigest = try { object["previousManifestSha256"].asString() } catch (_: Exception) { "" }
    let previousManifestText = try { object["previousManifest"].asString() } catch (_: Exception) { "" }
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

protected func validateOwnedManifest(root: Path): Unit {
    let _ = readOwnedManifest(root)
}
