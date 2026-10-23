package cjdoc

import cjdoc.model as public_model
import cjdoc.provider as public_provider
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
        if (path.trimAscii().isEmpty() || path.contains("\u{0}") || sha256.size != 64) {
            throw IllegalArgumentException("inventory pin requires a path and lowercase SHA-256")
        }
        var index: Int64 = 0
        while (index < sha256.size) {
            let byte = sha256[index]
            if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
                throw IllegalArgumentException("inventory pin requires a lowercase SHA-256")
            }
            index++
        }
        this.path = path; this.sha256 = sha256
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
        standardLibraryDocsBaseUrl!: ?String = None, maxDocIrMiB!: ?Int64 = None) {
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
        let normalizedCfg = CfgProfile(values: cfgValues)
        this.cfgValuesStorage = ArrayList<CfgValue>(normalizedCfg.values.toArray())
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
}

internal let MAX_PROVIDER_BATCH_DECLARATIONS: Int64 = 100000
internal let MAX_PROVIDER_BATCH_DIAGNOSTICS: Int64 = 4096
internal let MAX_PROVIDER_BATCH_RELATIONSHIPS_AND_ANNOTATIONS: Int64 = 16384
internal let MAX_PROVIDER_BATCH_TYPE_NODES: Int64 = 16384
internal let MAX_PROVIDER_BATCH_TYPE_ARGUMENTS: Int64 = 16384
internal let MAX_PROVIDER_BATCH_UTF8_BYTES: Int64 = 16 * 1024 * 1024
internal let MAX_PROVIDER_IDENTITY_UTF8_BYTES: Int64 = 1024

internal class ProviderIdentitySnapshot {
    let name: String
    let version: String
    let failure: ?String

    init(name: String, version: String, failure: ?String) {
        this.name = name
        this.version = version
        this.failure = failure
    }
}

internal func captureProviderIdentity(factory: public_provider.SemanticProviderFactory): ProviderIdentitySnapshot {
    var name = "provider-unavailable"
    var version = "unknown"
    let failures = ArrayList<String>()
    try {
        let candidate = factory.name
        if (candidate.toArray().size > MAX_PROVIDER_IDENTITY_UTF8_BYTES) {
            failures.add("provider name exceeds the identity budget")
        } else if (candidate.trimAscii().isEmpty()) {
            failures.add("provider name is empty or whitespace")
        } else {
            name = candidate
        }
    } catch (_: Exception) {
        failures.add("provider name access raised an exception")
    }
    try {
        let candidate = factory.version
        if (candidate.toArray().size > MAX_PROVIDER_IDENTITY_UTF8_BYTES) {
            failures.add("provider version exceeds the identity budget")
        } else if (candidate.trimAscii().isEmpty()) {
            failures.add("provider version is empty or whitespace")
        } else {
            version = candidate
        }
    } catch (_: Exception) {
        failures.add("provider version access raised an exception")
    }
    if (failures.isEmpty()) {
        return ProviderIdentitySnapshot(name, version, None<String>)
    }
    let summary = StringBuilder()
    var index: Int64 = 0
    while (index < failures.size) {
        if (index > 0) {
            summary.append("; ")
        }
        summary.append(failures[index])
        index++
    }
    ProviderIdentitySnapshot(name, version, Some(summary.toString()))
}

internal func providerExceptionSummary(stage: String): String {
    "provider ${stage} raised an exception"
}

internal class ProviderBatchBudget {
    private let declarationLimit: Int64
    private var declarations: Int64 = 0
    private var diagnostics: Int64 = 0
    private var relationshipsAndAnnotations: Int64 = 0
    private var typeNodes: Int64 = 0
    private var typeArguments: Int64 = 0
    private var utf8Bytes: Int64 = 0

    init(sourceDeclarationCount: Int64) {
        declarationLimit = if (sourceDeclarationCount < MAX_PROVIDER_BATCH_DECLARATIONS) {
            sourceDeclarationCount
        } else {
            MAX_PROVIDER_BATCH_DECLARATIONS
        }
    }

    private func checkedAdd(current: Int64, amount: Int64, limit: Int64, label: String): Int64 {
        if (amount < 0 || amount > limit - current) {
            throw IllegalArgumentException("semantic provider module batch exceeds ${label} budget")
        }
        current + amount
    }

    func consumeDeclarations(count: Int64): Unit {
        declarations = checkedAdd(declarations, count, declarationLimit, "declaration")
    }

    func consumeDiagnostics(count: Int64): Unit {
        diagnostics = checkedAdd(diagnostics, count, MAX_PROVIDER_BATCH_DIAGNOSTICS, "diagnostic")
    }

    func consumeRelationshipsAndAnnotations(count: Int64): Unit {
        relationshipsAndAnnotations = checkedAdd(relationshipsAndAnnotations, count,
            MAX_PROVIDER_BATCH_RELATIONSHIPS_AND_ANNOTATIONS, "relationship/annotation")
    }

    func consumeTypeNode(argumentCount: Int64): Unit {
        typeNodes = checkedAdd(typeNodes, 1, MAX_PROVIDER_BATCH_TYPE_NODES, "type-node")
        typeArguments = checkedAdd(typeArguments, argumentCount, MAX_PROVIDER_BATCH_TYPE_ARGUMENTS, "type-argument")
    }

    func consumeText(value: String): Unit {
        utf8Bytes = checkedAdd(utf8Bytes, value.toArray().size, MAX_PROVIDER_BATCH_UTF8_BYTES, "UTF-8 byte")
    }
}

internal class PublicSourceMapper {
    private let indexes = HashMap<String, CapturedSourceIndex>()
    private let unavailable = HashSet<String>()

    init(origins!: Array<SourceFileOrigin> = []) {
        for (origin in origins) {
            if (let Some(index) <- origin.capturedSourceIndex) {
                indexes[origin.logicalPath] = index
            } else {
                let _ = unavailable.add(origin.logicalPath)
            }
        }
    }

    private func sourceIndex(path: String): ?CapturedSourceIndex {
        if (unavailable.contains(path)) {
            return None
        }
        indexes.get(path)
    }

    func range(location: SourceLocation): public_model.SourceRange {
        var startOffset: Int64 = 0
        var endOffset: Int64 = 0
        if (let Some(index) <- sourceIndex(location.path)) {
            if (let Some(start) <- index.byteOffset(location.startLine, location.startColumn)) {
                if (let Some(end) <- index.byteOffset(location.endLine, location.endColumn)) {
                    if (end >= start) {
                        startOffset = start
                        endOffset = end
                    }
                }
            }
        }
        public_model.SourceRange(location.path,
            public_model.SourcePosition(location.startLine, location.startColumn, startOffset),
            public_model.SourcePosition(location.endLine, location.endColumn, endOffset))
    }

    func contains(range: public_model.SourceRange): Bool {
        match (sourceIndex(range.path)) {
            case Some(index) => index.positionMatches(range.start.line, range.start.column, range.start.byteOffset) &&
                index.positionMatches(range.end.line, range.end.column, range.end.byteOffset)
            case None => false
        }
    }
}

internal func providerType(value: public_model.TypeRef): TypeRef {
    let arguments = ArrayList<TypeRef>()
    for (argument in value.arguments) {
        arguments.add(providerType(argument))
    }
    TypeRef(value.spelling, canonical: value.semantic.canonical, state: value.semantic.state, kind: value.kind,
        nullable: value.nullable, arguments: arguments.toArray())
}

internal func moduleOwnsDeclaration(module: SourceModule, declaration: SourceDeclaration): Bool {
    module.id == declaration.moduleId
}

internal func validProviderDiagnosticCode(code: String): Bool {
    if (code.size != 9 || !code.startsWith("CJDOC2")) {
        return false
    }
    let bytes = code.toArray()
    var index: Int64 = 6
    while (index < bytes.size) {
        if (bytes[index] < b'0' || bytes[index] > b'9') {
            return false
        }
        index++
    }
    true
}

internal func issuedSourceKey(issuer: public_provider.SourceDeclarationIssuer,
    issued: HashMap<String, public_provider.SourceDeclarationId>, candidate: public_provider.SourceDeclarationId): ?String {
    if (!issuer.owns(candidate)) {
        return None
    }
    let key = candidate.serialize()
    match (issued.get(key)) {
        case Some(_) => Some(key)
        case None => None
    }
}

internal func validProviderVisibility(value: String): Bool {
    value == "public" || value == "protected" || value == "internal" || value == "private"
}

internal func safeProviderPath(value: String): Bool {
    if (value.isEmpty() || value.startsWith("/") || value.contains("\\")) {
        return false
    }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") {
            return false
        }
    }
    if (segments[0].size == 2 && segments[0].toArray()[1] == b':') {
        return false
    }
    true
}

internal func validateProviderRange(value: public_model.SourceRange, moduleSourceFiles: HashSet<String>,
    sourceMapper: PublicSourceMapper): Unit {
    if (!safeProviderPath(value.path) || !moduleSourceFiles.contains(value.path)) {
        throw IllegalArgumentException("semantic provider diagnostic source is outside its module transaction")
    }
    if (value.end.byteOffset < value.start.byteOffset || value.end.line < value.start.line || (value.end.line == value
        .start
        .line && value.end.column < value.start.column)) {
        throw IllegalArgumentException("semantic provider diagnostic source range is reversed")
    }
    if (!sourceMapper.contains(value)) {
        throw IllegalArgumentException("semantic provider diagnostic source range is out of bounds")
    }
}

internal func validProviderSymbolId(value: String): Bool {
    value.startsWith("cjdoc:v2:") && value.size > "cjdoc:v2:".size
}

internal func validateProviderType(value: public_model.TypeRef, capabilities: public_model.SemanticCapabilities,
    providerName: String, budget: ProviderBatchBudget, depth!: Int64 = 0): Unit {
    if (depth > public_model.DOC_IR_MAX_TYPE_DEPTH) {
        throw IllegalArgumentException("semantic provider type nesting exceeds ${public_model.DOC_IR_MAX_TYPE_DEPTH}")
    }
    budget.consumeTypeNode(value.arguments.size)
    budget.consumeText(value.kind)
    budget.consumeText(value.spelling)
    budget.consumeText(value.semantic.state)
    if (let Some(canonical) <- value.semantic.canonical) {
        budget.consumeText(canonical)
        if (canonical.trimAscii().isEmpty()) {
            throw IllegalArgumentException("semantic provider returned an empty canonical type spelling")
        }
    }
    if (let Some(provider) <- value.semantic.provider) {
        budget.consumeText(provider)
        if (provider != providerName) {
            throw IllegalArgumentException(
                "semantic provider type provenance '${provider}' does not match provider '${providerName}'")
        }
    }
    if (value.kind.isEmpty()) {
        throw IllegalArgumentException("semantic provider returned an empty type kind")
    }
    if (value.semantic.state == "resolved" && value.semantic.canonical.isNone()) {
        throw IllegalArgumentException("semantic provider marked a type resolved without a canonical spelling")
    }
    if (value.semantic.state == "unavailable" && value.semantic.canonical.isSome()) {
        throw IllegalArgumentException("semantic provider attached a canonical spelling to an unavailable type")
    }
    if (!capabilities.canonicalTypes && (value.semantic.canonical.isSome() || value.semantic.state == "resolved")) {
        throw IllegalArgumentException(
            "semantic provider returned canonical type data without canonicalTypes capability")
    }
    for (argument in value.arguments) {
        validateProviderType(argument, capabilities, providerName, budget, depth: depth + 1)
    }
}

internal func validateProviderDiagnostic(value: public_model.Diagnostic, moduleSourceFiles: HashSet<String>,
    sourceMapper: PublicSourceMapper, budget: ProviderBatchBudget): Unit {
    budget.consumeText(value.severity)
    budget.consumeText(value.code)
    budget.consumeText(value.message)
    if ((value.severity != "warning" && value.severity != "error") || !validProviderDiagnosticCode(value.code) ||
        value.message.isEmpty()) {
        throw IllegalArgumentException("semantic provider emitted an invalid diagnostic contract")
    }
    if (let Some(source) <- value.source) {
        budget.consumeText(source.path)
        validateProviderRange(source, moduleSourceFiles, sourceMapper)
    }
    if (let Some(symbolId) <- value.symbolId) {
        budget.consumeText(symbolId)
        if (!validProviderSymbolId(symbolId)) {
            throw IllegalArgumentException("semantic provider diagnostic has an invalid SymbolId")
        }
    }
}

internal func fallbackModuleResult(module: SourceModule, identity: ProviderIdentitySnapshot, message: String): ModuleSemanticResult {
    let result = ModuleSemanticResult(module.id, identity.name, identity.version,
        SemanticCapabilities(false, false, false, false, false))
    result
        .diagnostics
        .add(
            Diagnostic("warning", "CJDOC2001",
                "semantic provider '${identity.name}' failed for module '${module.name}': " +
                    "${message}; AST fallback retained"))
    return result
}
