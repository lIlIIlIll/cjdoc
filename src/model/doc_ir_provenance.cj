package cjdoc.model

/**
 * Per-file source evidence captured by cjdoc. `verified` means the caller-pinned
 * receipt matched the bytes observed during this generation; it does not certify
 * a Git object, repository service, build, or clean working tree.
 */
public class SourceProvenance {
    public let state: String
    public let reason: String
    public let repository: ?RepositoryInfo
    /** Complete repository-relative file path, not a host filesystem path. */
    public let repositoryPath: ?String
    /** sha256:<64 lowercase hex> over the raw bytes observed at capture. */
    public let sourceDigest: ?String
    /** sha256:<64 lowercase hex> over captured bytes after CR/CRLF normalization. */
    public let normalizedDigest: ?String
    /** sha256:<64 lowercase hex> over the caller-pinned receipt bytes. */
    public let evidenceIdentity: ?String
    public let evidenceKind: String

    public init(state: String, reason: String, repository!: ?RepositoryInfo = None,
        repositoryPath!: ?String = None, sourceDigest!: ?String = None,
        normalizedDigest!: ?String = None, evidenceIdentity!: ?String = None,
        evidenceKind!: String = "none") {
        if (!isValidSourceProvenanceState(state) || !isValidSourceProvenanceReason(reason)) {
            throw IllegalArgumentException("invalid source provenance state or reason")
        }
        if (!isOptionalSourceDigest(sourceDigest) || !isOptionalSourceDigest(normalizedDigest) ||
            !isOptionalSourceDigest(evidenceIdentity)) {
            throw IllegalArgumentException("source provenance digests must be sha256 values")
        }
        if (let Some(path) <- repositoryPath) {
            if (!validSourceProvenancePath(path, false)) {
                throw IllegalArgumentException("source provenance repository path must be a safe relative path")
            }
        }
        match (state) {
            case "verified" =>
                let repo = match (repository) {
                    case Some(value) => value
                    case None => throw IllegalArgumentException("verified source provenance requires a repository")
                }
                if (reason != "receipt_matched" || repositoryPath.isNone() ||
                    sourceDigest.isNone() || normalizedDigest.isNone() ||
                    evidenceIdentity.isNone() || evidenceKind != "caller_pinned_receipt" ||
                    !isFullSourceRevision(repo.revision)) {
                    throw IllegalArgumentException("verified source provenance requires a matched pinned receipt")
                }
            case "declared" =>
                if (reason != "legacy_project_repository" || repository.isNone() ||
                    repositoryPath.isNone() || evidenceIdentity.isSome() || evidenceKind != "none" ||
                    sourceDigest.isSome() || normalizedDigest.isSome()) {
                    throw IllegalArgumentException("declared source provenance requires legacy repository mapping")
                }
            case "unavailable" | "ambiguous" =>
                if (repository.isSome() || repositoryPath.isSome() || evidenceIdentity.isSome() ||
                    evidenceKind != "none" || reason == "receipt_matched" ||
                    reason == "legacy_project_repository") {
                    throw IllegalArgumentException("unavailable source provenance cannot identify a repository")
                }
                if ((state == "ambiguous") != (reason == "conflicting_registration")) {
                    throw IllegalArgumentException("source provenance conflict state and reason disagree")
                }
            case _ => throw IllegalArgumentException("invalid source provenance state")
        }
        if (evidenceKind != "caller_pinned_receipt" && evidenceKind != "none") {
            throw IllegalArgumentException("invalid source provenance evidence kind")
        }
        this.state = state
        this.reason = reason
        this.repository = repository
        this.repositoryPath = repositoryPath
        this.sourceDigest = sourceDigest
        this.normalizedDigest = normalizedDigest
        this.evidenceIdentity = evidenceIdentity
        this.evidenceKind = evidenceKind
    }

    public static func unavailable(reason: String, sourceDigest!: ?String = None,
        normalizedDigest!: ?String = None): SourceProvenance {
        SourceProvenance("unavailable", reason, sourceDigest: sourceDigest,
            normalizedDigest: normalizedDigest)
    }
}

private func isValidSourceProvenanceState(state: String): Bool {
    state == "verified" || state == "declared" || state == "unavailable" || state == "ambiguous"
}

private func isValidSourceProvenanceReason(reason: String): Bool {
    ["receipt_matched", "legacy_project_repository", "no_registration",
        "no_project_repository", "missing_receipt", "unpinned_receipt",
        "receipt_unavailable", "invalid_receipt", "receipt_pin_mismatch",
        "receipt_repository_mismatch", "missing_file_record", "digest_mismatch",
        "conflicting_registration", "path_escape", "invalid_range",
        "capture_unavailable", "resource_limit"].contains(reason)
}

private func isOptionalSourceDigest(value: ?String): Bool {
    match (value) {
        case None => true
        case Some(text) => isSourceDigest(text)
    }
}

private func isSourceDigest(value: String): Bool {
    if (value.size != 71 || !value.startsWith("sha256:")) { return false }
    for (byte in value[7..].toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

private func isFullSourceRevision(value: String): Bool {
    if (value.size != 40) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) { return false }
    }
    true
}

private func validSourceProvenancePath(value: String, allowEmpty: Bool): Bool {
    if (value.isEmpty()) { return allowEmpty }
    if (value.startsWith("/") || value.contains("\\") || value.contains("\u{0}")) { return false }
    for (byte in value.toArray()) {
        if (byte < 0x20u8 || byte == 0x7Fu8) { return false }
    }
    let first = value.split("/")[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in value.split("/")) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}
