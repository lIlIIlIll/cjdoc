package cjdoc.render

import cjdoc.model.*
import yjson.*

internal func appendSourceProvenance(out: StringBuilder, value: SourceProvenance): Unit {
    out.append("{\"state\":${escapeJsonString(value.state)},\"reason\":${escapeJsonString(value.reason)},\"repository\":")
    match (value.repository) {
        case Some(repository) => out.append("{\"url\":${escapeJsonString(repository.url)},\"revision\":${escapeJsonString(repository.revision)}}")
        case None => out.append("null")
    }
    out.append(",\"repositoryPath\":${nullableString(value.repositoryPath)},\"sourceDigest\":${nullableString(value.sourceDigest)},")
    out.append("\"normalizedDigest\":${nullableString(value.normalizedDigest)},\"evidenceIdentity\":${nullableString(value.evidenceIdentity)},")
    out.append("\"evidenceKind\":${escapeJsonString(value.evidenceKind)}}")
}

internal func decodeSourceProvenance(node: JsonNode, path: String): SourceProvenance {
    let value = strictObject(node, path, ["state", "reason", "repository", "repositoryPath",
        "sourceDigest", "normalizedDigest", "evidenceIdentity", "evidenceKind"])
    SourceProvenance(stringAt(value, "state", path), stringAt(value, "reason", path),
        repository: nullableRepositoryAt(value, "repository", path),
        repositoryPath: nullableStringAt(value, "repositoryPath", path),
        sourceDigest: nullableStringAt(value, "sourceDigest", path),
        normalizedDigest: nullableStringAt(value, "normalizedDigest", path),
        evidenceIdentity: nullableStringAt(value, "evidenceIdentity", path),
        evidenceKind: stringAt(value, "evidenceKind", path))
}

internal func consumeSourceProvenanceEncoding(value: SourceProvenance, path: String,
    budget: DocIrEncodingBudget): Unit {
    budget.consumeObject(path, depth: 3, fields: 8)
    budget.consumeString(value.state, path + ".state")
    budget.consumeString(value.reason, path + ".reason")
    budget.consumeString(value.evidenceKind, path + ".evidenceKind")
    budget.consumeOptionalString(value.repositoryPath, path + ".repositoryPath")
    budget.consumeOptionalString(value.sourceDigest, path + ".sourceDigest")
    budget.consumeOptionalString(value.normalizedDigest, path + ".normalizedDigest")
    budget.consumeOptionalString(value.evidenceIdentity, path + ".evidenceIdentity")
    match (value.repository) {
        case Some(repository) =>
            budget.consumeObject(path + ".repository", depth: 4, fields: 2)
            budget.consumeString(repository.url, path + ".repository.url")
            budget.consumeString(repository.revision, path + ".repository.revision")
        case None => budget.consumeBytes(4, path + ".repository")
    }
}
