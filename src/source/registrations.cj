protected package cjdoc.source

import cjdoc.dependency.validateDependencySourceName
import cjdoc.digest.{isFullGitSha, isSha256}
import cjdoc.filesystem.safeSourceRepositoryPath
import cjdoc.model.RepositoryInfo

protected struct DependencySourceSelection {
    protected let name: String
    protected let path: String

    protected init(name: String, path: String) {
        validateDependencySourceName(name)
        this.name = name
        this.path = path
    }
}

protected func validateSourceRepository(root: String, repository: RepositoryInfo,
    repositoryPath: String, receipt: ?String, receiptSha256: ?String): Unit {
    if (root.trimAscii().isEmpty() || root.contains("\u{0}") ||
        !safeSourceRepositoryPath(repositoryPath, allowEmpty: true)) {
        throw IllegalArgumentException("source repository root or repository path is invalid")
    }
    if (let Some(path) <- receipt) {
        if (path.trimAscii().isEmpty() || path.contains("\u{0}")) {
            throw IllegalArgumentException("source provenance receipt path is invalid")
        }
    }
    if (let Some(pin) <- receiptSha256) {
        if (!isSha256(pin)) {
            throw IllegalArgumentException("source provenance receipt pin must be a lowercase SHA-256")
        }
    }
    if (!isFullGitSha(repository.revision)) {
        throw IllegalArgumentException("source repository registration requires a full lowercase Git SHA")
    }
}

protected struct SourceRepositoryRegistrationInput {
    protected let root: String
    protected let repository: RepositoryInfo
    protected let repositoryPath: String
    protected let receipt: ?String
    protected let receiptSha256: ?String

    protected init(root: String, repository: RepositoryInfo, repositoryPath!: String = "",
        receipt!: ?String = None, receiptSha256!: ?String = None) {
        validateSourceRepository(root, repository, repositoryPath, receipt, receiptSha256)
        this.root = root
        this.repository = repository
        this.repositoryPath = repositoryPath
        this.receipt = receipt
        this.receiptSha256 = receiptSha256
    }
}
