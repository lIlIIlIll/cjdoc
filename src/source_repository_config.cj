package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.fs.*

internal let SOURCE_REPOSITORY_CONFIG_MAX_BYTES: Int64 = 64 * 1024
internal let MAX_SOURCE_REPOSITORY_REGISTRATIONS: Int64 = 4096
internal let MAX_SOURCE_PROVENANCE_RECEIPT_TOTAL_FILES: Int64 = 100000
internal let MAX_SOURCE_PROVENANCE_WARNINGS: Int64 = 4096

private class SourceRepositoryTableFields {
    let values = HashMap<String, String>()

    func put(key: String, value: String): Unit {
        if (values.contains(key)) { throw IllegalArgumentException("duplicate source repository setting") }
        values[key] = value
    }

    func required(key: String): String {
        match (values.get(key)) {
            case Some(value) => value
            case None => throw IllegalArgumentException("source repository registration is missing '${key}'")
        }
    }

    func optional(key: String): ?String { values.get(key) }
}

private func sourceRepositoryConfigInput(fields: SourceRepositoryTableFields): SourceRepositoryInput {
    let root = fields.required("root")
    let url = fields.required("url")
    let revision = fields.required("revision")
    let repository = try {
        public_model.RepositoryInfo(url, revision)
    } catch (_: Exception) {
        throw IllegalArgumentException("source repository URL or revision is invalid")
    }
    SourceRepositoryInput(root, repository,
        repositoryPath: fields.optional("repository-path").getOrDefault({ => "" }),
        receipt: fields.optional("receipt"),
        receiptSha256: fields.optional("receipt-sha256"))
}

private func sourceRepositoryConfigString(code: String, equals: Int64): String {
    let decoded = tomlAssignmentString(code, equals)
    if (decoded.invalid || decoded.value.isNone()) {
        throw IllegalArgumentException("source repository settings require TOML strings")
    }
    decoded.value.getOrThrow()
}

private func sourceRepositoryArrayTableHeader(line: String): ?String {
    let trimmed = line.trimAscii()
    if (!trimmed.startsWith("[[") || !trimmed.endsWith("]]")) { return None }
    let name = compactTomlBareKey(trimmed[2..trimmed.size - 2].trimAscii())
    if (name.isEmpty() || name.contains("[") || name.contains("]") ||
        name.contains("\"") || name.contains("'")) { return None }
    Some(name)
}

internal func loadSourceRepositoryConfig(projectRoot: String,
    budget: SourceAuxiliaryBudget): ArrayList<SourceRepositoryInput> {
    let path = Path(projectRoot).join("cjdoc.toml")
    let result = ArrayList<SourceRepositoryInput>()
    if (!exists(path)) { return result }
    let text = try {
        readAuxiliaryTextBounded(path, SOURCE_REPOSITORY_CONFIG_MAX_BYTES, budget)
    } catch (_: Exception) {
        throw IllegalArgumentException("source repository configuration is unavailable or exceeds 64 KiB")
    }
    if (!budget.consumeWork(text.size)) {
        throw IllegalArgumentException("source repository configuration exceeded the configured work budget")
    }
    let scanner = TomlLineScanner()
    var section = ""
    var current: ?SourceRepositoryTableFields = None
    for (rawLine in text.split("\n")) {
        let code = match (scanner.code(rawLine)) {
            case Some(value) => value
            case None =>
                if (section == "source.repositories" && !rawLine.trimAscii().isEmpty()) {
                    throw IllegalArgumentException("source repository settings cannot use multiline TOML values")
                }
                continue
        }
        let trimmed = code.trimAscii()
        if (trimmed.isEmpty()) { continue }
        if (trimmed.startsWith("[")) {
            if (let Some(fields) <- current) { result.add(sourceRepositoryConfigInput(fields)) }
            current = None
            let arrayTable = sourceRepositoryArrayTableHeader(trimmed)
            if (let Some(name) <- arrayTable) {
                if (name == "source.repositories") {
                    if (result.size >= MAX_SOURCE_REPOSITORY_REGISTRATIONS) {
                        throw IllegalArgumentException("source repository registration limit exceeded")
                    }
                    current = Some(SourceRepositoryTableFields())
                    section = "source.repositories"
                    continue
                }
                if (name == "source" || name.startsWith("source.")) {
                    throw IllegalArgumentException("unsupported source repository configuration table")
                }
                section = "other"
                continue
            }
            let table = tomlTableName(trimmed)
            if (table.isNone()) {
                if (trimmed.startsWith("[[source") || trimmed.startsWith("[source")) {
                    throw IllegalArgumentException("malformed source repository configuration table")
                }
                section = "other"
                continue
            }
            let name = table.getOrThrow()
            if (name == "source" || name.startsWith("source.")) {
                throw IllegalArgumentException("source.repositories must be an array of tables")
            }
            section = "other"
            continue
        }
        let equals = tomlAssignmentEquals(code)
        if (section == "source.repositories") {
            let split = match (equals) {
                case Some(value) => value
                case None => throw IllegalArgumentException("malformed source repository setting")
            }
            let key = code[..split].trimAscii()
            if (![
                "root", "url", "revision", "repository-path", "receipt", "receipt-sha256"
            ].contains(key)) {
                throw IllegalArgumentException("unknown source repository setting")
            }
            current.getOrThrow().put(key, sourceRepositoryConfigString(code, split))
        } else if (section.isEmpty()) {
            if (let Some(split) <- equals) {
                let key = code[..split].trimAscii()
                if (key == "source" || key.startsWith("source.")) {
                    throw IllegalArgumentException("configure source repositories with [[source.repositories]]")
                }
            }
        }
    }
    if (let Some(fields) <- current) { result.add(sourceRepositoryConfigInput(fields)) }
    result
}

private class SourceRepositoryRegistration {
    let root: String
    let rootIsFile: Bool
    let input: SourceRepositoryInput
    let receipt: SourceProvenanceReceiptLoad

    init(root: String, rootIsFile: Bool, input: SourceRepositoryInput,
        receipt: SourceProvenanceReceiptLoad) {
        this.root = normalizedHostPath(root)
        this.rootIsFile = rootIsFile
        this.input = input
        this.receipt = receipt
    }

    func identity(): String {
        let pin = input.receiptSha256.getOrDefault({ => "" })
        "${input.repository.url}\n${input.repository.revision}\n${input.repositoryPath}\n${pin}"
    }
}

private class SourceRepositoryCandidate {
    let registration: SourceRepositoryRegistration
    let repositoryPath: ?String

    init(registration: SourceRepositoryRegistration, repositoryPath: ?String) {
        this.registration = registration
        this.repositoryPath = repositoryPath
    }

    func identity(): String {
        let path = repositoryPath.getOrDefault({ => "<invalid-path>" })
        let pin = registration.input.receiptSha256.getOrDefault({ => "" })
        "${registration.input.repository.url}\n${registration.input.repository.revision}\n${path}\n${pin}"
    }
}

private func sourceRegistrationRoot(projectRoot: String, value: String): (String, Bool) {
    let absolute = value.startsWith("/") || (value.size >= 3 && value[1] == b':' &&
        (value[2] == b'/' || value[2] == b'\\'))
    let supplied = if (absolute) { Path(value) } else { Path(projectRoot).join(value) }
    let suppliedInfo = try { FileInfo(supplied) } catch (_: Exception) {
        throw IllegalArgumentException("source repository root is unavailable")
    }
    if (suppliedInfo.isSymbolicLink()) {
        throw IllegalArgumentException("source repository root cannot be a symbolic link")
    }
    let resolved = try { canonicalize(supplied).toString() } catch (_: Exception) {
        throw IllegalArgumentException("source repository root is unavailable")
    }
    let info = try { FileInfo(resolved) } catch (_: Exception) {
        throw IllegalArgumentException("source repository root is unavailable")
    }
    if (info.isSymbolicLink()) { throw IllegalArgumentException("source repository root cannot be a symbolic link") }
    if (info.isDirectory()) { return (resolved, false) }
    if (!info.isRegular()) { throw IllegalArgumentException("source repository root must be a file or directory") }
    (resolved, true)
}

private func sourceRepositoryPathFor(registration: SourceRepositoryRegistration,
    actualPath: String): ?String {
    if (registration.rootIsFile) {
        if (normalizedHostPath(actualPath) != registration.root) { return None }
        return Some(registration.input.repositoryPath)
    }
    let relative = match (relativePathFromResolved(registration.root, actualPath)) {
        case Some(value) => value
        case None => return None
    }
    if (relative.isEmpty()) { return None }
    let prefix = registration.input.repositoryPath
    let full = if (prefix.isEmpty()) { relative } else { "${prefix}/${relative}" }
    if (!safeSourceRepositoryPath(full)) { return None }
    Some(full)
}

/** Per-generation immutable source-registration/evidence index. */
internal class SourceRepositoryRegistry {
    let strict: Bool
    private let registrationsByRoot = HashMap<String, ArrayList<SourceRepositoryRegistration>>()
    private let legacyRepository: ?public_model.RepositoryInfo
    private let legacyRoot: ?String
    private let diagnostics: ArrayList<Diagnostic>
    private let warningKeys = HashSet<String>()
    private let cachedReceipts = HashMap<String, SourceProvenanceReceiptLoad>()
    private var receiptFileRecords: Int64 = 0
    private var warningCount: Int64 = 0
    private var warningLimitReported = false
    private var budgetLimitReported = false

    init(projectRoot: String, configured!: Array<SourceRepositoryInput>,
        override!: ?ReadOnlyList<SourceRepositoryInput> = None,
        legacyRepository!: ?public_model.RepositoryInfo = None, legacyRoot!: ?String = None,
        budget!: SourceAuxiliaryBudget, diagnostics!: ArrayList<Diagnostic>) {
        this.legacyRepository = legacyRepository
        this.legacyRoot = match (legacyRoot) {
            case Some(value) => try { Some(canonicalize(value).toString()) } catch (_: Exception) { None }
            case None => if (legacyRepository.isSome()) {
                try { Some(canonicalize(projectRoot).toString()) } catch (_: Exception) { None }
            } else { None }
        }
        this.diagnostics = diagnostics
        strict = override.isSome() || !configured.isEmpty()
        let inputs = ArrayList<SourceRepositoryInput>()
        match (override) {
            case Some(values) => inputs.add(all: values)
            case None => inputs.add(all: configured)
        }
        if (inputs.size > MAX_SOURCE_REPOSITORY_REGISTRATIONS) {
            throw IllegalArgumentException("source repository registration limit exceeded")
        }
        for (input in inputs) {
            let (root, rootIsFile) = sourceRegistrationRoot(projectRoot, input.root)
            if (rootIsFile && input.repositoryPath.isEmpty()) {
                throw IllegalArgumentException("file source roots require a complete repository path")
            }
            let pinKey = sourceProvenanceReceiptCacheKey(projectRoot, input)
            let cachedLoad = match (cachedReceipts.get(pinKey)) {
                case Some(value) => value
                case None =>
                    let remaining = if (receiptFileRecords >= MAX_SOURCE_PROVENANCE_RECEIPT_TOTAL_FILES) {
                        0
                    } else {
                        MAX_SOURCE_PROVENANCE_RECEIPT_TOTAL_FILES - receiptFileRecords
                    }
                    let value = loadSourceProvenanceReceipt(projectRoot, input, budget, remaining)
                    if (let Some(receipt) <- value.receipt) {
                        receiptFileRecords += receipt.files.size
                    }
                    cachedReceipts[pinKey] = value
                    value
            }
            let repositoryMatches = match (cachedLoad.receipt) {
                case Some(receipt) => receipt.repository.url == input.repository.url &&
                    receipt.repository.revision == input.repository.revision
                case None => true
            }
            let load = if (cachedLoad.reason == "receipt_matched" && !repositoryMatches) {
                SourceProvenanceReceiptLoad(None<SourceProvenanceReceipt>,
                    "receipt_repository_mismatch")
            } else {
                cachedLoad
            }
            if (load.reason == "resource_limit") {
                addBudgetDiagnostic("source metadata or provenance evidence exceeded the configured aggregate byte/work safety budget")
            }
            let registration = SourceRepositoryRegistration(root, rootIsFile, input, load)
            let group = registrationsByRoot.get(registration.root).getOrDefault({ => ArrayList<SourceRepositoryRegistration>() })
            group.add(registration)
            registrationsByRoot[registration.root] = group
        }
        let roots = ArrayList<String>()
        for ((root, _) in registrationsByRoot) { roots.add(root) }
        for (root in roots) {
            let group = registrationsByRoot.get(root).getOrDefault({ =>
                ArrayList<SourceRepositoryRegistration>()
            })
            let order = ArrayList<String>()
            let byIdentity = HashMap<String, SourceRepositoryRegistration>()
            for (registration in group) {
                let identity = registration.identity()
                match (byIdentity.get(identity)) {
                    case Some(existing) =>
                        if (existing.receipt.reason != "receipt_matched" &&
                            registration.receipt.reason == "receipt_matched") {
                            byIdentity[identity] = registration
                        }
                    case None =>
                        order.add(identity)
                        byIdentity[identity] = registration
                }
            }
            let unique = ArrayList<SourceRepositoryRegistration>()
            for (identity in order) {
                if (let Some(registration) <- byIdentity.get(identity)) { unique.add(registration) }
            }
            registrationsByRoot[root] = unique
        }
        if (budget.limitReached()) {
            addBudgetDiagnostic("source metadata or provenance evidence exceeded the configured aggregate byte/work safety budget")
        }
    }

    private func candidates(actualPath: String): ArrayList<SourceRepositoryCandidate> {
        let result = ArrayList<SourceRepositoryCandidate>()
        var current = normalizedHostPath(actualPath)
        var steps: Int64 = 0
        while (!current.isEmpty() && steps <= MAX_SOURCE_DIRECTORY_DEPTH) {
            if (let Some(registrations) <- registrationsByRoot.get(current)) {
                for (registration in registrations) {
                    if (registration.rootIsFile && normalizedHostPath(actualPath) != registration.root) { continue }
                    let repositoryPath = if (registration.rootIsFile) {
                        Some(registration.input.repositoryPath)
                    } else {
                        sourceRepositoryPathFor(registration, actualPath)
                    }
                    result.add(SourceRepositoryCandidate(registration, repositoryPath))
                }
            }
            let parent = try { Path(current).parent.toString() } catch (_: Exception) { current }
            let normalizedParent = normalizedHostPath(parent)
            if (normalizedParent == current) { break }
            current = normalizedParent
            steps++
        }
        result
    }

    func needsSourceDigests(actualPath: String): Bool {
        if (!strict) { return false }
        for (candidate in candidates(actualPath)) {
            if (candidate.repositoryPath.isNone()) { continue }
            if (candidate.registration.receipt.reason == "receipt_matched") { return true }
        }
        false
    }

    private func provenanceWarning(reason: String, logicalPath: String,
        registration: ?SourceRepositoryRegistration): Unit {
        let key = match (registration) {
            case Some(value) where reason != "no_registration" && reason != "missing_file_record" &&
                reason != "digest_mismatch" && reason != "path_escape" =>
                "root\n${value.root}\n${reason}"
            case _ => "file\n${logicalPath}\n${reason}"
        }
        if (!warningKeys.add(key)) { return }
        if (warningCount >= MAX_SOURCE_PROVENANCE_WARNINGS) {
            if (!warningLimitReported) {
                warningLimitReported = true
                addBudgetDiagnostic("source provenance warning limit was reached; additional warnings were omitted")
            }
            return
        }
        warningCount++
        diagnostics.add(Diagnostic("warning", "CJDOC1032",
            "source provenance is ${reason}; source API content is retained",
            source: Some(SourceLocation(logicalPath, 1, 1, 1, 1))))
    }

    private func addBudgetDiagnostic(message: String): Unit {
        if (budgetLimitReported) { return }
        budgetLimitReported = true
        addSourceLimitDiagnostic(diagnostics, message)
    }

    private func unavailable(reason: String, logicalPath: String,
        facts: ?CapturedSourceFacts, registration: ?SourceRepositoryRegistration): public_model.SourceProvenance {
        if (reason == "resource_limit") {
            addBudgetDiagnostic("source metadata or provenance evidence exceeded the configured aggregate byte/work safety budget")
        }
        provenanceWarning(reason, logicalPath, registration)
        let sourceDigest = match (facts) {
            case Some(value) => sourceDigestValue(value.rawDigest)
            case None => None<String>
        }
        let normalizedDigest = match (facts) {
            case Some(value) => sourceDigestValue(value.normalizedDigest)
            case None => None<String>
        }
        if (reason == "conflicting_registration") {
            return public_model.SourceProvenance("ambiguous", reason,
                sourceDigest: sourceDigest, normalizedDigest: normalizedDigest)
        }
        public_model.SourceProvenance.unavailable(reason,
            sourceDigest: sourceDigest, normalizedDigest: normalizedDigest)
    }

    private func sourceDigestValue(value: ?String): ?String {
        value.map({ digest => "sha256:${digest}" })
    }

    func provenance(actualPath: String, logicalPath: String,
        facts: ?CapturedSourceFacts): public_model.SourceProvenance {
        if (!strict) {
            let repository = match (legacyRepository) {
                case Some(value) => value
                case None => return public_model.SourceProvenance.unavailable("no_project_repository")
            }
            let root = match (legacyRoot) {
                case Some(value) => value
                case None => return public_model.SourceProvenance.unavailable("no_project_repository")
            }
            if (!hostPathIsWithin(root, actualPath)) {
                return public_model.SourceProvenance.unavailable("path_escape")
            }
            let path = match (relativePathFromResolved(root, actualPath)) {
                case Some(value) => if (value.isEmpty()) { return public_model.SourceProvenance.unavailable("path_escape") } else { value }
                case None => return public_model.SourceProvenance.unavailable("path_escape")
            }
            if (!safeSourceRepositoryPath(path)) {
                return public_model.SourceProvenance.unavailable("path_escape")
            }
            return public_model.SourceProvenance("declared", "legacy_project_repository",
                repository: Some(repository), repositoryPath: Some(path))
        }

        let candidates = this.candidates(actualPath)
        if (candidates.isEmpty()) {
            return unavailable("no_registration", logicalPath, facts, None<SourceRepositoryRegistration>)
        }
        let firstIdentity = candidates[0].identity()
        var selected = candidates[0].registration
        var repositoryPathOption: ?String = candidates[0].repositoryPath
        for (candidate in candidates) {
            if (candidate.identity() != firstIdentity) {
                return unavailable("conflicting_registration", logicalPath, facts, None<SourceRepositoryRegistration>)
            }
            if (selected.receipt.reason != "receipt_matched" &&
                candidate.registration.receipt.reason == "receipt_matched") {
                selected = candidate.registration
                repositoryPathOption = candidate.repositoryPath
            }
        }
        let repositoryPath = match (repositoryPathOption) {
            case Some(value) => value
            case None => return unavailable("path_escape", logicalPath, facts, Some(selected))
        }
        if (selected.receipt.reason != "receipt_matched") {
            return unavailable(selected.receipt.reason, logicalPath, facts, Some(selected))
        }
        let receipt = match (selected.receipt.receipt) {
            case Some(value) => value
            case None => return unavailable("invalid_receipt", logicalPath, facts, Some(selected))
        }
        let observed = match (facts) {
            case Some(value) where value.resourceLimit =>
                return unavailable("resource_limit", logicalPath, facts, Some(selected))
            case Some(value) => value
            case None => return unavailable("capture_unavailable", logicalPath, facts, Some(selected))
        }
        let rawDigest = match (observed.rawDigest) {
            case Some(value) => value
            case None => return unavailable("capture_unavailable", logicalPath, facts, Some(selected))
        }
        let normalizedDigest = match (observed.normalizedDigest) {
            case Some(value) => value
            case None => return unavailable("capture_unavailable", logicalPath, facts, Some(selected))
        }
        let expected = match (receipt.files.get(repositoryPath)) {
            case Some(value) => value
            case None => return unavailable("missing_file_record", logicalPath, facts, Some(selected))
        }
        if (rawDigest != expected) {
            return unavailable("digest_mismatch", logicalPath, facts, Some(selected))
        }
        public_model.SourceProvenance("verified", "receipt_matched",
            repository: Some(selected.input.repository), repositoryPath: Some(repositoryPath),
            sourceDigest: Some("sha256:${rawDigest}"),
            normalizedDigest: Some("sha256:${normalizedDigest}"),
            evidenceIdentity: Some(receipt.evidenceIdentity), evidenceKind: "caller_pinned_receipt")
    }
}
