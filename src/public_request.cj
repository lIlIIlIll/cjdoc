package cjdoc

import cjdoc.highlight.highlightExternalOptions
import cjdoc.dependency.{validateDependencySourceName, validateInventoryPin}
import cjdoc.manifest.loadDocIrLimit
import cjdoc.model as public_model
import cjdoc.provider as public_provider
import cjdoc.source.validateSourceRepository
import cjdoc.source.cfg.canonicalCfgValues
import cjdoc.stdlib_docs.{hasBuiltInStandardLibraryDocsBase,
    isValidStandardLibraryDocsBaseUrl, isValidStandardLibraryDocsVersion}
import std.collection.*
import std.fs.*

private func normalizeRepositoryRoot(repositoryRoot: ?String): ?String {
    match (repositoryRoot) {
        case None => None
        case Some(path) =>
            if (path.trimAscii().isEmpty()) {
                throw IllegalArgumentException("repository root cannot be empty")
            }
            let resolved = try { canonicalize(path).toString() } catch (_: Exception) {
                throw IllegalArgumentException("repository root must be an accessible directory")
            }
            let info = try { FileInfo(resolved) } catch (_: Exception) {
                throw IllegalArgumentException("repository root must be an accessible directory")
            }
            if (!info.isDirectory()) {
                throw IllegalArgumentException("repository root must be an accessible directory")
            }
            Some(resolved)
    }
}
public class ChirOptions {
    public let compilerExecutable: String
    public let workerExecutable: ?String
    private let importPathsStorage: ArrayList<String>

    public init(compilerExecutable!: String = "cjc", importPaths!: Array<String> = [],
        workerExecutable!: ?String = None) {
        if (compilerExecutable.trimAscii().isEmpty()) {
            throw IllegalArgumentException("CHIR compiler executable cannot be empty")
        }
        match (workerExecutable) {
            case Some(path) =>
                if (path.trimAscii().isEmpty()) {
                    throw IllegalArgumentException("CHIR worker executable cannot be empty")
                }
            case None => ()
        }
        for (path in importPaths) {
            if (path.trimAscii().isEmpty()) {
                throw IllegalArgumentException("CHIR import paths cannot be empty")
            }
        }
        this.compilerExecutable = compilerExecutable
        this.workerExecutable = workerExecutable
        this.importPathsStorage = ArrayList<String>(importPaths)
    }

    public prop importPaths: ReadOnlyList<String> {
        get() { importPathsStorage }
    }
}

/** A caller-trusted pin for the complete bytes of one local symbol inventory. */
public class DocumentInventoryPin {
    public let path: String
    public let sha256: String
    public init(path: String, sha256: String) {
        validateInventoryPin(path, sha256)
        this.path = path; this.sha256 = sha256
    }
}

/** One explicitly registered local source root and its caller-pinned evidence. */
public class SourceRepositoryInput {
    public let root: String
    public let repository: public_model.RepositoryInfo
    public let repositoryPath: String
    public let receipt: ?String
    public let receiptSha256: ?String

    public init(root: String, repository: public_model.RepositoryInfo,
        repositoryPath!: String = "", receipt!: ?String = None,
        receiptSha256!: ?String = None) {
        validateSourceRepository(root, repository, repositoryPath, receipt, receiptSha256)
        this.root = root
        this.repository = repository
        this.repositoryPath = repositoryPath
        this.receipt = receipt
        this.receiptSha256 = receiptSha256
    }
}

// Explicit offline source supplied for a registry/git dependency. The path is
// an input only and is never serialized into Doc IR.
public class DependencySourceInput {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        validateDependencySourceName(name)
        this.name = name
        this.path = path
    }
}

public class GenerationRequest {
    /** Effective Doc IR budget in UTF-8 bytes; CLI/request overrides [limits]. */
    public let maxDocIrBytes: Int64
    public let projectRoot: String
    public let repository: ?public_model.RepositoryInfo
    public let repositoryRoot: ?String
    public let includePathDependencies: Bool
    public let includeCachedDependencies: Bool
    public let jobs: Int64
    public let audience: String
    public let lintProfile: String
    public let checkExamples: Bool
    public let cacheDirectory: ?String
    public let cacheFingerprint: ?String
    public let astPreflightExecutable: ?String
    public let chir: ?ChirOptions
    public let cjpmCacheRoot: ?String
    public let highlightAdapter: ?String
    public let highlightNode: ?String
    /** Optional host policy override; absent uses the project [highlight] configuration. */
    public let highlight: ?HighlightConfig
    public let i18n: ?public_model.DocumentationLanguageOptions
    public let buildContext: ?String
    public let linkLanguage: String
    public let linkLanguageFallback: Bool
    public let linkCompatible: Bool
    /** Publication revision only; never participates in dependency selection. */
    public let documentationRevision: String
    /** Optional release selector for standard-library documentation links. */
    public let standardLibraryDocsVersion: ?String
    /** Optional HTTPS std-library docs root, used when the release has a different host or route prefix. */
    public let standardLibraryDocsBaseUrl: ?String
    /** `Some`, including an empty array, selects strict source-registration mode. */
    private let sourceRepositoriesStorage: ?ArrayList<SourceRepositoryInput>
    private let documentSourcesStorage: ArrayList<String>
    private let documentInventoryPinsStorage: ArrayList<DocumentInventoryPin>
    private let requiredLanguagesStorage: ArrayList<String>
    private let dependencySourcesStorage: ArrayList<DependencySourceInput>
    private let cfgValuesStorage: ArrayList<CfgValue>
    private let providerFactoriesStorage: ArrayList<public_provider.SemanticProviderFactory>

    public init(projectRoot: String, repository!: ?public_model.RepositoryInfo = None,
        repositoryRoot!: ?String = None, includePathDependencies!: Bool = false, includeCachedDependencies!: Bool = false,
        jobs!: Int64 = 1, audience!: String = "external", lintProfile!: String = "standard",
        checkExamples!: Bool = false,
        dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
        providerFactories!: Array<public_provider.SemanticProviderFactory> = [], cacheDirectory!: ?String = None,
        cacheFingerprint!: ?String = None, astPreflightExecutable!: ?String = None,
        chir!: ?ChirOptions = None, cjpmCacheRoot!: ?String = None,
        highlightAdapter!: ?String = None, highlightNode!: ?String = None, highlight!: ?HighlightConfig = None,
        i18n!: ?public_model.DocumentationLanguageOptions = None, requiredLanguages!: Array<String> = [],
        buildContext!: ?String = None, documentSources!: Array<String> = [], linkLanguage!: String = "",
        linkLanguageFallback!: Bool = false, linkCompatible!: Bool = false,
        documentInventoryPins!: Array<DocumentInventoryPin> = [], documentationRevision!: String = "",
        standardLibraryDocsVersion!: ?String = None,
        standardLibraryDocsBaseUrl!: ?String = None, sourceRepositories!: ?Array<SourceRepositoryInput> = None,
        maxDocIrMiB!: ?Int64 = None) {
        if (projectRoot.isEmpty()) {
            throw IllegalArgumentException("project root cannot be empty")
        }
        if (jobs < 1 || jobs > 64) {
            throw IllegalArgumentException("jobs must be in 1..64")
        }
        if (audience != "external" && audience != "package" && audience != "all") {
            throw IllegalArgumentException("audience must be external, package, or all")
        }
        if (lintProfile != "off" && lintProfile != "standard" && lintProfile != "strict") {
            throw IllegalArgumentException("lint profile must be off, standard, or strict")
        }
        if (providerFactories.size > 1) {
            throw IllegalArgumentException("cjdoc accepts at most one semantic provider factory")
        }
        if (chir.isSome() && !providerFactories.isEmpty()) {
            throw IllegalArgumentException("CHIR cannot be combined with an external semantic provider factory")
        }
        if (repositoryRoot.isSome() && repository.isNone()) {
            throw IllegalArgumentException("repository root requires repository metadata")
        }
        if (let Some(baseUrl) <- standardLibraryDocsBaseUrl) {
            if (!isValidStandardLibraryDocsBaseUrl(baseUrl)) {
                throw IllegalArgumentException("standard-library documentation base URL must be HTTPS and end in /libs/std")
            }
        }
        if (let Some(version) <- standardLibraryDocsVersion) {
            if (!isValidStandardLibraryDocsVersion(version)) {
                throw IllegalArgumentException("standard-library documentation version must be a safe URL path segment")
            }
            if (standardLibraryDocsBaseUrl.isNone() && !hasBuiltInStandardLibraryDocsBase(version)) {
                throw IllegalArgumentException("standard-library documentation base URL is required for this version")
            }
        }
        let _ = highlightExternalOptions(highlightAdapter, highlightNode)
        this.maxDocIrBytes = loadDocIrLimit(projectRoot, maxDocIrMiB)
        this.projectRoot = projectRoot
        this.repository = repository
        this.repositoryRoot = normalizeRepositoryRoot(repositoryRoot)
        this.includePathDependencies = includePathDependencies
        this.includeCachedDependencies = includeCachedDependencies
        this.jobs = jobs
        this.audience = audience
        this.lintProfile = lintProfile
        this.checkExamples = checkExamples
        this.cacheDirectory = cacheDirectory
        this.cacheFingerprint = cacheFingerprint
        this.astPreflightExecutable = astPreflightExecutable
        this.chir = chir
        this.cjpmCacheRoot = cjpmCacheRoot
        this.highlightAdapter = highlightAdapter
        this.highlightNode = highlightNode
        this.highlight = highlight
        this.i18n = i18n
        if (let Some(path) <- buildContext) {
            if (path.trimAscii().isEmpty()) { throw IllegalArgumentException("build context cannot be empty") }
        }
        for (path in documentSources) {
            if (path.trimAscii().isEmpty()) { throw IllegalArgumentException("document source cannot be empty") }
        }
        this.buildContext = buildContext
        if (let Some(inputs) <- sourceRepositories) {
            if (inputs.size > 4096) {
                throw IllegalArgumentException("source repository registration limit exceeded")
            }
            this.sourceRepositoriesStorage = Some(ArrayList<SourceRepositoryInput>(inputs))
        } else {
            this.sourceRepositoriesStorage = None
        }
        this.documentSourcesStorage = ArrayList<String>(documentSources)
        if (documentInventoryPins.size > 256) { throw IllegalArgumentException("inventory pin budget exceeded") }
        this.documentInventoryPinsStorage = ArrayList<DocumentInventoryPin>(documentInventoryPins)
        this.linkLanguage = if (linkLanguage.isEmpty()) { "" } else { public_model.documentationLanguage(linkLanguage) }
        this.linkLanguageFallback = linkLanguageFallback
        this.linkCompatible = linkCompatible
        this.documentationRevision = documentationRevision
        this.standardLibraryDocsVersion = standardLibraryDocsVersion
        this.standardLibraryDocsBaseUrl = standardLibraryDocsBaseUrl
        this.requiredLanguagesStorage = ArrayList<String>()
        for (language in requiredLanguages) {
            let normalized = public_model.documentationLanguage(language)
            if (!requiredLanguagesStorage.contains(normalized)) { requiredLanguagesStorage.add(normalized) }
        }
        this.dependencySourcesStorage = ArrayList<DependencySourceInput>(dependencySources)
        this.cfgValuesStorage = canonicalCfgValues(cfgValues, { entry: CfgValue => (entry.name, entry.value) })
        this.providerFactoriesStorage = ArrayList<public_provider.SemanticProviderFactory>(providerFactories)
    }

    public prop dependencySources: ReadOnlyList<DependencySourceInput> {
        get() {
            dependencySourcesStorage
        }
    }
    public prop requiredLanguages: ReadOnlyList<String> { get() { requiredLanguagesStorage } }
    public prop documentSources: ReadOnlyList<String> { get() { documentSourcesStorage } }
    public prop documentInventoryPins: ReadOnlyList<DocumentInventoryPin> { get() { documentInventoryPinsStorage } }
    public prop cfgValues: ReadOnlyList<CfgValue> {
        get() {
            cfgValuesStorage
        }
    }
    public prop providerFactories: ReadOnlyList<public_provider.SemanticProviderFactory> {
        get() {
            providerFactoriesStorage
        }
    }
    public prop sourceRepositories: ?ReadOnlyList<SourceRepositoryInput> {
        get() {
            match (sourceRepositoriesStorage) {
                case Some(values) => Some(values)
                case None => None
            }
        }
    }
}
