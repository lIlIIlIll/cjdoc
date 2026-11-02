package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*
import yjson.*

internal let SOURCE_PROVENANCE_RECEIPT_SCHEMA = "cjdoc.source-provenance/1"
internal let MAX_SOURCE_PROVENANCE_RECEIPT_BYTES: Int64 = 16 * 1024 * 1024
internal let MAX_SOURCE_PROVENANCE_RECEIPT_FILES: Int64 = 100000

internal class SourceProvenanceReceipt {
    let repository: public_model.RepositoryInfo
    let files = HashMap<String, String>()
    let evidenceIdentity: String

    init(repository: public_model.RepositoryInfo, evidenceIdentity: String) {
        this.repository = repository
        this.evidenceIdentity = evidenceIdentity
    }
}

internal class SourceProvenanceReceiptLoad {
    let receipt: ?SourceProvenanceReceipt
    let reason: String

    init(receipt: ?SourceProvenanceReceipt, reason: String) {
        this.receipt = receipt
        this.reason = reason
    }
}

private func sourceProvenanceJsonObject(node: JsonNode, allowed: Array<String>): JsonObject {
    let object = try { node.asObject() } catch (_: Exception) {
        throw IllegalArgumentException("source provenance receipt object expected")
    }
    for (index in 0..object.size()) {
        if (!allowed.contains(object.nameAt(index))) {
            throw IllegalArgumentException("source provenance receipt has an unknown field")
        }
    }
    for (key in allowed) {
        if (object.get(key).isNone()) {
            throw IllegalArgumentException("source provenance receipt is missing a required field")
        }
    }
    object
}

private func sourceProvenanceJsonString(object: JsonObject, key: String): String {
    try { object[key].asString() } catch (_: Exception) {
        throw IllegalArgumentException("source provenance receipt string expected")
    }
}

private func sourceProvenanceFullSha(value: String): Bool {
    if (value.size != 40) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

private func sourceProvenanceHexSha(value: String): Bool {
    if (value.size != 64) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

internal func safeSourceRepositoryPath(path: String, allowEmpty!: Bool = false): Bool {
    if (path.isEmpty()) { return allowEmpty }
    if (path.startsWith("/") || path.contains("\\") || path.contains("\u{0}")) { return false }
    for (byte in path.toArray()) {
        if (byte < 0x20u8 || byte == 0x7Fu8) { return false }
    }
    let first = path.split("/")[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in path.split("/")) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}

private func parseSourceProvenanceReceipt(text: String,
    evidenceIdentity: String, maxFiles: Int64): SourceProvenanceReceipt {
    let rootNode = JsonNode.parse(text, config: JsonReadOptions(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        maxDepth: 8, maxStringBytes: MAX_SOURCE_PROVENANCE_RECEIPT_BYTES,
        maxBufferedValueBytes: MAX_SOURCE_PROVENANCE_RECEIPT_BYTES,
        maxInputBytes: MAX_SOURCE_PROVENANCE_RECEIPT_BYTES))
    let root = sourceProvenanceJsonObject(rootNode,
        ["schemaVersion", "repository", "files"])
    if (sourceProvenanceJsonString(root, "schemaVersion") != SOURCE_PROVENANCE_RECEIPT_SCHEMA) {
        throw IllegalArgumentException("unsupported source provenance receipt schema")
    }
    let repositoryObject = sourceProvenanceJsonObject(root["repository"], ["url", "revision"])
    let url = sourceProvenanceJsonString(repositoryObject, "url")
    let revision = sourceProvenanceJsonString(repositoryObject, "revision")
    if (!sourceProvenanceFullSha(revision)) {
        throw IllegalArgumentException("source provenance receipt revision must be a full lowercase Git SHA")
    }
    let repository = public_model.RepositoryInfo(url, revision)
    let files = try { root["files"].asArray() } catch (_: Exception) {
        throw IllegalArgumentException("source provenance receipt files array expected")
    }
    if (files.size() > maxFiles) {
        throw IllegalArgumentException("source provenance receipt file-record budget exceeded")
    }
    let result = SourceProvenanceReceipt(repository, evidenceIdentity)
    for (index in 0..files.size()) {
        let item = sourceProvenanceJsonObject(files[index], ["path", "sha256"])
        let path = sourceProvenanceJsonString(item, "path")
        let digest = sourceProvenanceJsonString(item, "sha256")
        if (!safeSourceRepositoryPath(path) || !sourceProvenanceHexSha(digest) ||
            result.files.contains(path)) {
            throw IllegalArgumentException("source provenance receipt has an invalid or duplicate file record")
        }
        result.files[path] = digest
    }
    result
}

private func sourceProvenanceReceiptPath(projectRoot: String, receipt: String): String {
    let absolute = receipt.startsWith("/") || (receipt.size >= 3 && receipt[1] == b':' &&
        (receipt[2] == b'/' || receipt[2] == b'\\'))
    let path = if (absolute) { Path(receipt) } else { Path(projectRoot).join(receipt) }
    canonicalize(path).toString()
}

internal func sourceProvenanceReceiptCacheKey(projectRoot: String,
    input: SourceRepositoryInput): String {
    let receiptPath = match (input.receipt) {
        case Some(value) => try { sourceProvenanceReceiptPath(projectRoot, value) }
            catch (_: Exception) { value }
        case None => "<missing-receipt>"
    }
    let pin = input.receiptSha256.getOrDefault({ => "<missing-pin>" })
    "${receiptPath}\n${pin}"
}

internal func loadSourceProvenanceReceipt(projectRoot: String,
    input: SourceRepositoryInput, budget: SourceAuxiliaryBudget,
    remainingFiles: Int64): SourceProvenanceReceiptLoad {
    if (input.receipt.isNone()) { return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "missing_receipt") }
    if (input.receiptSha256.isNone()) { return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "unpinned_receipt") }
    let path = try {
        sourceProvenanceReceiptPath(projectRoot, input.receipt.getOrThrow())
    } catch (_: Exception) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "receipt_unavailable")
    }
    let snapshot = try {
        readAuxiliaryFileBoundedSnapshot(Path(path), MAX_SOURCE_PROVENANCE_RECEIPT_BYTES, budget)
    } catch (error: Exception) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>,
            if (budget.limitReached() || error.message.contains("bounded read exceeds")) {
                "resource_limit"
            } else {
                "receipt_unavailable"
            })
    }
    if (!budget.consumeWork(snapshot.bytes.size)) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "resource_limit")
    }
    let actualPin = Sha256Digest.digestBytes(snapshot.bytes)
    if (actualPin != input.receiptSha256.getOrThrow()) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "receipt_pin_mismatch")
    }
    let evidenceIdentity = "sha256:${actualPin}"
    let text = try { String.fromUtf8(snapshot.bytes) } catch (_: Exception) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "invalid_receipt")
    }
    if (!budget.consumeWork(text.size)) {
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>, "resource_limit")
    }
    let receipt = try {
        parseSourceProvenanceReceipt(text, evidenceIdentity,
            if (remainingFiles < MAX_SOURCE_PROVENANCE_RECEIPT_FILES) { remainingFiles }
            else { MAX_SOURCE_PROVENANCE_RECEIPT_FILES })
    } catch (error: Exception) {
        let recordLimit = error.message.contains("file-record budget")
        return SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>,
            if (budget.limitReached() || recordLimit) { "resource_limit" } else { "invalid_receipt" })
    }
    SourceProvenanceReceiptLoad(Some(receipt), "receipt_matched")
}
