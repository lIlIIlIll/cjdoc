package cjdoc

import cjdoc.model as public_model
import cjdoc.provider as public_provider
import cjdoc.render as public_render
import markdown.{CodeBlockKind, ListDelimiter, ListKind, MarkdownEngine, MarkdownProfile, NodeKind, NodeRef, 
    SourceBuffer, TableAlignment, TaskState}
import std.collection.*
import std.sort.*

public class GenerationRequest {
    public let projectRoot: String
    public let includePathDependencies: Bool
    public let includeCachedDependencies: Bool
    public let jobs: Int64
    public let audience: String
    public let lintProfile: String
    public let cacheDirectory: ?String
    public let cacheFingerprint: ?String
    public let astPreflightExecutable: ?String
    public let cjpmCacheRoot: ?String
    private let dependencySourcesStorage: ArrayList<DependencySourceInput>
    private let cfgValuesStorage: ArrayList<CfgValue>
    private let providerFactoriesStorage: ArrayList<public_provider.SemanticProviderFactory>

    public init(projectRoot: String, includePathDependencies!: Bool = false, includeCachedDependencies!: Bool = false,
        jobs!: Int64 = 1, audience!: String = "external", lintProfile!: String = "standard",
        dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
        providerFactories!: Array<public_provider.SemanticProviderFactory> = [], cacheDirectory!: ?String = None,
        cacheFingerprint!: ?String = None, astPreflightExecutable!: ?String = None, cjpmCacheRoot!: ?String = None) {
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
        this.projectRoot = projectRoot
        this.includePathDependencies = includePathDependencies
        this.includeCachedDependencies = includeCachedDependencies
        this.jobs = jobs
        this.audience = audience
        this.lintProfile = lintProfile
        this.cacheDirectory = cacheDirectory
        this.cacheFingerprint = cacheFingerprint
        this.astPreflightExecutable = astPreflightExecutable
        this.cjpmCacheRoot = cjpmCacheRoot
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

private let MAX_PROVIDER_BATCH_DECLARATIONS: Int64 = 100000
private let MAX_PROVIDER_BATCH_DIAGNOSTICS: Int64 = 4096
private let MAX_PROVIDER_BATCH_RELATIONSHIPS_AND_ANNOTATIONS: Int64 = 16384
private let MAX_PROVIDER_BATCH_TYPE_NODES: Int64 = 16384
private let MAX_PROVIDER_BATCH_TYPE_ARGUMENTS: Int64 = 16384
private let MAX_PROVIDER_BATCH_UTF8_BYTES: Int64 = 16 * 1024 * 1024
private let MAX_PROVIDER_IDENTITY_UTF8_BYTES: Int64 = 1024

private class ProviderIdentitySnapshot {
    let name: String
    let version: String
    let failure: ?String

    init(name: String, version: String, failure: ?String) {
        this.name = name
        this.version = version
        this.failure = failure
    }
}

private func captureProviderIdentity(factory: public_provider.SemanticProviderFactory): ProviderIdentitySnapshot {
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

private func providerExceptionSummary(stage: String): String {
    "provider ${stage} raised an exception"
}

private class ProviderBatchBudget {
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

private class PublicSourceMapper {
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

private func providerType(value: public_model.TypeRef): TypeRef {
    let arguments = ArrayList<TypeRef>()
    for (argument in value.arguments) {
        arguments.add(providerType(argument))
    }
    TypeRef(value.spelling, canonical: value.semantic.canonical, state: value.semantic.state, kind: value.kind,
        nullable: value.nullable, arguments: arguments.toArray())
}

private func moduleOwnsDeclaration(module: SourceModule, declaration: SourceDeclaration): Bool {
    module.id == declaration.moduleId
}

private func validProviderDiagnosticCode(code: String): Bool {
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

private func issuedSourceKey(issuer: public_provider.SourceDeclarationIssuer,
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

private func validProviderVisibility(value: String): Bool {
    value == "public" || value == "protected" || value == "internal" || value == "private"
}

private func safeProviderPath(value: String): Bool {
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

private func validateProviderRange(value: public_model.SourceRange, moduleSourceFiles: HashSet<String>,
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

private func validProviderSymbolId(value: String): Bool {
    value.startsWith("cjdoc:v2:") && value.size > "cjdoc:v2:".size
}

private func validateProviderType(value: public_model.TypeRef, capabilities: public_model.SemanticCapabilities,
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

private func validateProviderDiagnostic(value: public_model.Diagnostic, moduleSourceFiles: HashSet<String>,
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

private func fallbackModuleResult(module: SourceModule, identity: ProviderIdentitySnapshot, message: String): ModuleSemanticResult {
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

private class FactorySemanticProviderAdapter <: SemanticProvider {
    private let factory: public_provider.SemanticProviderFactory
    private let identity: ProviderIdentitySnapshot

    init(factory: public_provider.SemanticProviderFactory) {
        this.factory = factory
        this.identity = captureProviderIdentity(factory)
    }

    public func providerName(): String {
        identity.name
    }
    public func providerVersion(): String {
        identity.version
    }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult()
        let sourceMapper = PublicSourceMapper(origins: source.sourceFileOrigins.toArray())
        for (module in source.modules) {
            if (let Some(message) <- identity.failure) {
                result.modules.add(fallbackModuleResult(module, identity, message))
                continue
            }
            try {
                let moduleDeclarations = ArrayList<SourceDeclaration>()
                let declarationsByKey = HashMap<String, SourceDeclaration>()
                let issued = HashMap<String, public_provider.SourceDeclarationId>()
                let issuer = public_provider.SourceDeclarationIssuer()
                for (declaration in source.declarations) {
                    if (!moduleOwnsDeclaration(module, declaration)) {
                        continue
                    }
                    if (issued.contains(declaration.sourceKey)) {
                        throw IllegalArgumentException("duplicate source declaration id in module")
                    }
                    moduleDeclarations.add(declaration)
                    declarationsByKey[declaration.sourceKey] = declaration
                    issued[declaration.sourceKey] = issuer.issue(declaration.sourceKey)
                }
                let moduleSourceFiles = HashSet<String>()
                for (pkg in source.packages) {
                    if (pkg.moduleId != module.id) {
                        continue
                    }
                    for (path in pkg.sourceFiles) {
                        let _ = moduleSourceFiles.add(path)
                    }
                }
                for (declaration in moduleDeclarations) {
                    let _ = moduleSourceFiles.add(declaration.source.path)
                }
                let views = ArrayList<public_provider.SourceDeclarationView>()
                for (declaration in moduleDeclarations) {
                    let parameters = ArrayList<public_provider.SourceParameterView>()
                    for (parameter in declaration.parameters) {
                        parameters.add(
                            public_provider.SourceParameterView(parameter.name, parameter.typeSpelling,
                                defaultExpression: parameter.defaultExpression))
                    }
                    let id = issued[declaration.sourceKey]
                    let owner: ?public_provider.SourceDeclarationId = match (declaration.ownerSourceKey) {
                        case Some(value) => match (issued.get(value)) {
                            case Some(ownerId) => Some(ownerId)
                            case None => throw IllegalArgumentException(
                                "source owner is outside the provider module transaction")
                        }
                        case None => None
                    }
                    views.add(
                        public_provider.SourceDeclarationView(id, declaration.kind, declaration.name,
                            declaration.packageName, declaration.visibility, declaration.genericParameters.size,
                            sourceMapper.range(declaration.source), declaration.sourceSignature,
                            declaration.enumNonExhaustive, ownerId: owner, parameters: parameters.toArray(),
                            returnTypeSpelling: declaration.returnTypeSpelling,
                            annotations: declaration.annotations.toArray()))
                }

                let semanticModule = public_provider.SemanticModule(module.id, module.name, module.role,
                    module.sourcePrefix)
                var openedSession: ?public_provider.SemanticProviderSession = None
                try {
                    openedSession = Some(factory.open(semanticModule))
                } catch (_: Exception) {
                    result.modules.add(fallbackModuleResult(module, identity, providerExceptionSummary("open")))
                }
                if (openedSession.isNone()) {
                    continue
                }
                let session = openedSession.getOrThrow()
                var stagedResult: ?ModuleSemanticResult = None
                var failureMessage: ?String = None
                try {
                    let batch = session.analyze(views)
                    let budget = ProviderBatchBudget(moduleDeclarations.size)
                    budget.consumeText(identity.name)
                    budget.consumeText(identity.version)
                    budget.consumeDeclarations(batch.declarations.size)
                    budget.consumeDiagnostics(batch.diagnostics.size)
                    if (!batch.capabilities.sourceBinding && !batch.declarations.isEmpty()) {
                        throw IllegalArgumentException(
                            "semantic provider returned declarations without sourceBinding capability")
                    }
                    let staged = ModuleSemanticResult(module.id, identity.name, identity.version,
                        SemanticCapabilities(batch.capabilities.sourceBinding, batch.capabilities.ownership,
                            batch.capabilities.visibility, batch.capabilities.canonicalTypes,
                            batch.capabilities.canonicalSignatures,
                            symbolRelationships: batch.capabilities.relationships,
                            annotations: batch.capabilities.annotations))
                    let returned = HashSet<String>()
                    for (item in batch.declarations) {
                        budget.consumeText(item.sourceId.serialize())
                        budget.consumeText(item.state)
                        let sourceKey = match (issuedSourceKey(issuer, issued, item.sourceId)) {
                            case Some(value) => value
                            case None => throw IllegalArgumentException(
                                "semantic provider returned an unknown or cross-session source declaration id")
                        }
                        if (!returned.add(sourceKey)) {
                            throw IllegalArgumentException(
                                "semantic provider returned a duplicate source declaration id")
                        }
                        let original = declarationsByKey[sourceKey]
                        let owner = match (item.ownerId) {
                            case Some(candidate) =>
                                budget.consumeText(candidate.serialize())
                                if (!batch.capabilities.ownership) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned ownership without ownership capability")
                                }
                                let key = match (issuedSourceKey(issuer, issued, candidate)) {
                                    case Some(value) => value
                                    case None => throw IllegalArgumentException(
                                        "semantic provider returned an unknown or cross-session owner id")
                                }
                                if (original.ownerSourceKey != Some(key)) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed source declaration ownership")
                                }
                                Some(key)
                            case None => original.ownerSourceKey
                        }
                        let visibility = match (item.visibility) {
                            case Some(value) =>
                                budget.consumeText(value)
                                if (!batch.capabilities.visibility) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned visibility without visibility capability")
                                }
                                if (!validProviderVisibility(value)) {
                                    throw IllegalArgumentException("semantic provider returned invalid visibility")
                                }
                                value
                            case None => original.visibility
                        }
                        if (item.canonicalSignature.isSome() && !batch.capabilities.canonicalSignatures) {
                            throw IllegalArgumentException(
                                "semantic provider returned canonical signature without capability")
                        }
                        if (let Some(canonicalSignature) <- item.canonicalSignature) {
                            budget.consumeText(canonicalSignature)
                            if (canonicalSignature.trimAscii().isEmpty()) {
                                throw IllegalArgumentException(
                                    "semantic provider returned an empty canonical signature")
                            }
                            if (item.state == "unavailable") {
                                throw IllegalArgumentException(
                                    "semantic provider attached a canonical signature to an unavailable declaration")
                            }
                        }
                        if (item.annotationsProvided && !batch.capabilities.annotations) {
                            throw IllegalArgumentException(
                                "semantic provider returned annotations without annotations capability")
                        }
                        budget.consumeRelationshipsAndAnnotations(item.annotations.size)
                        for (annotation in item.annotations) {
                            budget.consumeText(annotation)
                            if (annotation.isEmpty()) {
                                throw IllegalArgumentException(
                                    "semantic provider returned an empty annotation spelling")
                            }
                        }
                        if ((!item.typeRelationships.isEmpty() || !item.symbolRelationships.isEmpty()) &&
                            !batch.capabilities.relationships) {
                            throw IllegalArgumentException(
                                "semantic provider returned relationships without relationships capability")
                        }
                        budget.consumeRelationshipsAndAnnotations(item.typeRelationships.size)
                        budget.consumeRelationshipsAndAnnotations(item.symbolRelationships.size)
                        let semantic = SemanticDeclaration(sourceKey, original.kind, original.name, original.packageName,
                            original.moduleId, owner, visibility, item.state, identity.name,
                            canonicalSignature: item.canonicalSignature, isContainer: original.isContainer,
                            enumNonExhaustive: original.enumNonExhaustive)
                        semantic.genericParameters.add(all: original.genericParameters)
                        if (item.parameters.isEmpty()) {
                            for (parameter in original.parameters) {
                                semantic
                                    .parameters
                                    .add(
                                        SemanticParameter(parameter.name,
                                            TypeRef(parameter.typeSpelling, state: "partial")))
                            }
                        } else {
                            if (item.parameters.size != original.parameters.size) {
                                throw IllegalArgumentException("semantic provider changed declaration parameter count")
                            }
                            var parameterIndex: Int64 = 0
                            while (parameterIndex < item.parameters.size) {
                                budget.consumeText(item.parameters[parameterIndex].name)
                                if (item.parameters[parameterIndex].name != original.parameters[parameterIndex].name) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed declaration parameter name")
                                }
                                validateProviderType(item.parameters[parameterIndex].typeRef, batch.capabilities,
                                    identity.name, budget)
                                semantic
                                    .parameters
                                    .add(
                                        SemanticParameter(item.parameters[parameterIndex].name,
                                            providerType(item.parameters[parameterIndex].typeRef)))
                                parameterIndex++
                            }
                        }
                        semantic.returnType = match (item.returnType) {
                            case Some(value) =>
                                validateProviderType(value, batch.capabilities, identity.name, budget)
                                Some(providerType(value))
                            case None => match (original.returnTypeSpelling) {
                                case Some(value) => Some(TypeRef(value, state: "partial"))
                                case None => None
                            }
                        }
                        semantic.annotations.add(all: original.annotations)
                        if (item.annotationsProvided) {
                            semantic.providerAnnotations.add(all: item.annotations)
                        }
                        for (relationship in item.typeRelationships) {
                            budget.consumeText(relationship.kind)
                            validateProviderType(relationship.target, batch.capabilities, identity.name, budget)
                            semantic
                                .relationships
                                .add(TypeRelationship(relationship.kind, providerType(relationship.target)))
                        }
                        for (relationship in item.symbolRelationships) {
                            budget.consumeText(relationship.kind)
                            budget.consumeText(relationship.targetDisplay)
                            budget.consumeText(relationship.state)
                            if (let Some(targetId) <- relationship.targetSymbolId) {
                                budget.consumeText(targetId)
                                if (!validProviderSymbolId(targetId)) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned an invalid relationship target SymbolId")
                                }
                            }
                            let targetSourceKey: ?String = match (relationship.targetSourceId) {
                                case Some(target) =>
                                    budget.consumeText(target.serialize())
                                    match (issuedSourceKey(issuer, issued, target)) {
                                        case Some(value) => Some(value)
                                        case None => throw IllegalArgumentException(
                                            "semantic provider returned an unknown or cross-session relationship target id")
                                    }
                                case None => None
                            }
                            semantic
                                .symbolRelationships
                                .add(
                                    SymbolRelationship(relationship.kind, relationship.targetDisplay, relationship.state,
                                        targetSymbolId: relationship.targetSymbolId, targetSourceKey: targetSourceKey))
                        }
                        staged.declarations.add(semantic)
                    }
                    if ((batch.capabilities.canonicalTypes || batch.capabilities.visibility) &&
                        providerIntroducesSymbolIdConflict(moduleDeclarations, staged.declarations, identity.name)) {
                        throw IllegalArgumentException("semantic provider introduced conflicting SymbolIds")
                    }
                    for (diagnostic in batch.diagnostics) {
                        validateProviderDiagnostic(diagnostic, moduleSourceFiles, sourceMapper, budget)
                        staged
                            .diagnostics
                            .add(
                                Diagnostic(diagnostic.severity, diagnostic.code, diagnostic.message,
                                    source: match (diagnostic.source) {
                                        case Some(range) => Some(
                                            SourceLocation(range.path, range.start.line, range.start.column,
                                                range.end.line, range.end.column))
                                        case None => None
                                    }, symbolId: diagnostic.symbolId))
                    }
                    stagedResult = Some(staged)
                } catch (_: Exception) {
                    failureMessage = Some(providerExceptionSummary("analysis or validation"))
                }
                try {
                    session.close()
                } catch (_: Exception) {
                    failureMessage = Some(match (failureMessage) {
                        case Some(previous) => previous + "; " + providerExceptionSummary("close")
                        case None => providerExceptionSummary("close")
                    })
                }
                match (failureMessage) {
                    case Some(message) => result.modules.add(fallbackModuleResult(module, identity, message))
                    case None => result.modules.add(stagedResult.getOrThrow())
                }
            } catch (_: Exception) {
                result
                    .modules
                    .add(fallbackModuleResult(module, identity, providerExceptionSummary("module transaction")))
            }
        }
        return result
    }
}

private func publicType(value: TypeRef, provider: String, providerState: String): public_model.TypeRef {
    // A failed module transaction retains source spellings in the internal
    // fallback TypeRef, but none of those spellings are provider facts. Expose
    // them as unavailable semantics while preserving the source-facing shape.
    let state = if (providerState == "unavailable") { "unavailable" } else { value.state }
    let canonical: ?String = if (providerState == "unavailable") { None } else { value.canonical }
    let semanticProvider: ?String = if (state == "unavailable") {
        None
    } else {
        Some(provider)
    }
    let arguments = ArrayList<public_model.TypeRef>()
    for (argument in value.arguments) {
        arguments.add(publicType(argument, provider, providerState))
    }
    public_model.TypeRef(value.kind, value.display,
        public_model.SemanticType(state, canonical: canonical, provider: semanticProvider),
        nullable: value.nullable, arguments: arguments.toArray())
}

private func publicTag(value: DocTag): public_model.DocTag {
    let state = match (value.referenceState) {
        case "resolved" => "resolved"
        case "ambiguous" => "ambiguous"
        case "unresolved" => "unavailable"
        case "broken" => "unavailable"
        case _ => "unavailable"
    }
    public_model.DocTag(value.name, value.subject, value.description, referenceState: state,
        targetSymbolId: value.targetSymbolId)
}

private let MAX_GENERATED_MARKDOWN_DEPTH: Int64 = 48
private let MAX_GENERATED_MARKDOWN_NODES: Int64 = 100000
private let MAX_GENERATED_MARKDOWN_STRING_BYTES: Int64 = 1024 * 1024
private let MAX_GENERATED_MARKDOWN_TOTAL_BYTES: Int64 = 16 * 1024 * 1024
private let MARKDOWN_FALLBACK_TEXT = "Documentation omitted because Markdown resource limits were exceeded."

private class MarkdownGenerationContext {
    private var nodes: Int64 = 0
    private var textBytes: Int64 = 0
    private let diagnosticsStorage = ArrayList<public_model.Diagnostic>()
    private let failedSymbols = HashSet<String>()
    var incomplete: Bool = false

    func consumeNode(depth: Int64): Unit {
        if (depth < 0 || depth > MAX_GENERATED_MARKDOWN_DEPTH || nodes >= MAX_GENERATED_MARKDOWN_NODES) {
            throw IllegalArgumentException("generated Markdown exceeds node/depth budget")
        }
        nodes++
    }

    func consumeText(value: String): Unit {
        let size = value.size
        if (size > MAX_GENERATED_MARKDOWN_STRING_BYTES || size > MAX_GENERATED_MARKDOWN_TOTAL_BYTES - textBytes) {
            throw IllegalArgumentException("generated Markdown exceeds text budget")
        }
        textBytes += size
    }

    func requireBodySize(summary: String, description: String): Unit {
        let separator: Int64 = if (description.isEmpty()) {
            0
        } else {
            2
        }
        if (summary.size > MAX_GENERATED_MARKDOWN_STRING_BYTES || description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES ||
            description.size > MAX_GENERATED_MARKDOWN_STRING_BYTES - separator || summary.size >
            MAX_GENERATED_MARKDOWN_STRING_BYTES - description.size - separator) {
            throw IllegalArgumentException("generated Markdown input exceeds comment budget")
        }
    }

    func fail(source: public_model.SourceRange, symbolId: String): Unit {
        incomplete = true
        if (!failedSymbols.add(symbolId)) {
            return
        }
        diagnosticsStorage.add(
            public_model.Diagnostic("warning", "CJDOC3026",
                "documentation Markdown was replaced by a bounded fallback after parsing or resource-limit failure",
                source: Some(source), symbolId: Some(symbolId)))
    }

    func diagnostics(): Array<public_model.Diagnostic> {
        diagnosticsStorage.toArray()
    }
}

private func fallbackPublicMarkdown(): public_model.MarkdownNode {
    public_model.MarkdownNode("document",
        children: [public_model.MarkdownNode("paragraph",
            children: [public_model.MarkdownNode("text", literal: MARKDOWN_FALLBACK_TEXT)])])
}

private func publicMarkdownKind(kind: NodeKind): String {
    match (kind) {
        case NodeKind.DocumentNode => "document"
        case NodeKind.BlockQuote => "block_quote"
        case NodeKind.List => "list"
        case NodeKind.ListItem => "list_item"
        case NodeKind.Paragraph => "paragraph"
        case NodeKind.Heading => "heading"
        case NodeKind.ThematicBreak => "thematic_break"
        case NodeKind.CodeBlock => "code_block"
        case NodeKind.HtmlBlock => "html_block"
        case NodeKind.Table => "table"
        case NodeKind.TableRow => "table_row"
        case NodeKind.TableCell => "table_cell"
        case NodeKind.CustomBlock => "custom_block"
        case NodeKind.Text => "text"
        case NodeKind.SoftBreak => "soft_break"
        case NodeKind.HardBreak => "hard_break"
        case NodeKind.CodeSpan => "code_span"
        case NodeKind.Emphasis => "emphasis"
        case NodeKind.Strong => "strong"
        case NodeKind.Strikethrough => "strikethrough"
        case NodeKind.Link => "link"
        case NodeKind.Image => "image"
        case NodeKind.HtmlInline => "html_inline"
        case NodeKind.CustomInline => "custom_inline"
    }
}

private func publicListKind(value: ListKind): String {
    match (value) {
        case ListKind.Bullet => "bullet"
        case ListKind.Ordered => "ordered"
    }
}

private func publicListDelimiter(value: ListDelimiter): String {
    match (value) {
        case ListDelimiter.Period => "period"
        case ListDelimiter.Parenthesis => "parenthesis"
        case ListDelimiter.None => "none"
    }
}

private func publicTaskState(value: TaskState): String {
    match (value) {
        case TaskState.NotTask => "notTask"
        case TaskState.Checked => "checked"
        case TaskState.Unchecked => "unchecked"
    }
}

private func publicCodeBlockKind(value: CodeBlockKind): String {
    match (value) {
        case CodeBlockKind.Indented => "indented"
        case CodeBlockKind.Fenced => "fenced"
    }
}

private func publicTableAlignment(value: TableAlignment): String {
    match (value) {
        case TableAlignment.None => "none"
        case TableAlignment.Left => "left"
        case TableAlignment.Center => "center"
        case TableAlignment.Right => "right"
    }
}

private func publicMarkdownMetadata(node: NodeRef, context: MarkdownGenerationContext): ?public_model.MarkdownNodeMetadata {
    match (node.kind) {
        case NodeKind.Heading => Some(public_model.MarkdownNodeMetadata.forHeading(node.asHeading().getOrThrow().level))
        case NodeKind.List =>
            let value = node.asList().getOrThrow()
            Some(
                public_model
                    .MarkdownNodeMetadata
                    .forList(publicListKind(value.listKind), value.start, publicListDelimiter(value.delimiter),
                        value.tight))
        case NodeKind.ListItem => Some(
            public_model.MarkdownNodeMetadata.forListItem(publicTaskState(node.asListItem().getOrThrow().taskState)))
        case NodeKind.CodeBlock =>
            let value = node.asCodeBlock().getOrThrow()
            context.consumeText(value.infoRaw)
            context.consumeText(value.language)
            context.consumeText(value.attributesRaw)
            let fenceCharacter = match (value.fenceCharacter) {
                case Some(marker) => Some(String.fromUtf8([marker]))
                case None => None<String>
            }
            Some(
                public_model
                    .MarkdownNodeMetadata
                    .forCodeBlock(publicCodeBlockKind(value.codeKind), fenceCharacter, value.fenceLength, value.infoRaw,
                        value.language, value.attributesRaw))
        case NodeKind.Table =>
            let alignments = ArrayList<String>()
            let sourceAlignments = node.asTable().getOrThrow().alignments
            var index: Int64 = 0
            while (index < sourceAlignments.size) {
                alignments.add(publicTableAlignment(sourceAlignments[index]))
                index++
            }
            Some(public_model.MarkdownNodeMetadata.forTable(alignments.toArray()))
        case NodeKind.TableRow => Some(
            public_model.MarkdownNodeMetadata.forTableRow(node.asTableRow().getOrThrow().header))
        case NodeKind.TableCell => Some(
            public_model
                .MarkdownNodeMetadata
                .forTableCell(publicTableAlignment(node.asTableCell().getOrThrow().alignment)))
        case _ => None<public_model.MarkdownNodeMetadata>
    }
}

private func publicMarkdownNode(node: NodeRef, source: SourceBuffer, assetCollector: LocalAssetCollector,
    sourcePath: String, declarationSource: public_model.SourceRange, symbolId: String,
    context: MarkdownGenerationContext, depth: Int64): public_model.MarkdownNode {
    context.consumeNode(depth)
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = node.children()
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(
            publicMarkdownNode(sourceChildren[index], source, assetCollector, sourcePath, declarationSource, symbolId,
                context, depth + 1))
        index++
    }
    let literal = match (node.kind) {
        case NodeKind.Text => node.asText().getOrThrow().value
        case NodeKind.CodeBlock => node.asCodeBlock().getOrThrow().literal
        case NodeKind.CodeSpan => node.asCodeSpan().getOrThrow().literal
        case NodeKind.HtmlBlock => node.asHtmlBlock().getOrThrow().literal
        case NodeKind.HtmlInline => node.asHtmlInline().getOrThrow().literal
        case NodeKind.Link => node.asLink().getOrThrow().destination
        case NodeKind.Image =>
            let destination = node.asImage().getOrThrow().destination
            match (assetCollector.reference(sourcePath, destination, declarationSource, symbolId)) {
                case Some(assetId) => assetId
                case None => destination
            }
        case NodeKind.DocumentNode | NodeKind.BlockQuote | NodeKind.List | NodeKind.ListItem | NodeKind.Paragraph
            | NodeKind.Heading | NodeKind.ThematicBreak | NodeKind.Table | NodeKind.TableRow | NodeKind.TableCell
            | NodeKind.SoftBreak | NodeKind.HardBreak | NodeKind.Emphasis | NodeKind.Strong | NodeKind.Strikethrough => ""
        case _ =>
            if (sourceChildren.isEmpty()) {
                source.text(node)
            } else {
                ""
            }
    }
    context.consumeText(literal)
    match (publicMarkdownMetadata(node, context)) {
        case Some(metadata) => public_model.MarkdownNode(publicMarkdownKind(node.kind), metadata, literal: literal,
            children: children.toArray())
        case None => public_model.MarkdownNode(publicMarkdownKind(node.kind), literal: literal,
            children: children.toArray())
    }
}

private func publicMarkdown(body: String, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext): public_model.MarkdownNode {
    if (body.isEmpty()) {
        return public_model.MarkdownNode("document")
    }
    let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
    publicMarkdownNode(result.document.root(), result.source, assetCollector, sourcePath, declarationSource, symbolId,
        context, 0)
}

private func publicComment(value: DocComment, assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String, context: MarkdownGenerationContext): public_model.DocComment {
    try {
        context.consumeText(value.raw)
        context.consumeText(value.summaryMarkdown)
        context.consumeText(value.descriptionMarkdown)
        context.requireBodySize(value.summaryMarkdown, value.descriptionMarkdown)
        let tags = ArrayList<public_model.DocTag>()
        for (tag in value.params) {
            tags.add(publicTag(tag))
        }
        match (value.returns) {
            case Some(tag) => tags.add(publicTag(tag))
            case None => ()
        }
        for (tag in value.throwsTags) {
            tags.add(publicTag(tag))
        }
        for (tag in value.see) {
            tags.add(publicTag(tag))
        }
        match (value.since) {
            case Some(text) => tags.add(public_model.DocTag("since", "", text))
            case None => ()
        }
        match (value.deprecated) {
            case Some(text) => tags.add(public_model.DocTag("deprecated", "", text))
            case None => ()
        }
        for (text in value.authors) {
            tags.add(public_model.DocTag("author", "", text))
        }
        match (value.version) {
            case Some(text) => tags.add(public_model.DocTag("version", "", text))
            case None => ()
        }
        for (tag in tags) {
            context.consumeText(tag.name);
            context.consumeText(tag.subject)
            context.consumeText(tag.description)
            match (tag.targetSymbolId) {
                case Some(value) => context.consumeText(value)
                case None => ()
            }
        }
        let body = if (value.descriptionMarkdown.isEmpty()) {
            value.summaryMarkdown
        } else {
            "${value.summaryMarkdown}\n\n${value.descriptionMarkdown}"
        }
        return public_model.DocComment(value.raw, value.summaryMarkdown, value.descriptionMarkdown,
            publicMarkdown(body, assetCollector, sourcePath, declarationSource, symbolId, context), tags: tags.toArray())
    } catch (_: Exception) {
        context.fail(declarationSource, symbolId)
        return public_model.DocComment("", MARKDOWN_FALLBACK_TEXT, "", fallbackPublicMarkdown())
    }
}

private func remapDiagnosticCode(code: String): String {
    match (code) {
        case "CJDOC1001" => "CJDOC3001"
        case "CJDOC1002" => "CJDOC3002"
        case "CJDOC1003" => "CJDOC3003"
        case "CJDOC1004" => "CJDOC3004"
        case "CJDOC1005" => "CJDOC3005"
        case "CJDOC1006" => "CJDOC2006"
        case "CJDOC1007" => "CJDOC2007"
        case "CJDOC1008" => "CJDOC3008"
        case "CJDOC1017" => "CJDOC2017"
        case "CJDOC1022" => "CJDOC3022"
        case "CJDOC1023" => "CJDOC3023"
        case "CJDOC1024" => "CJDOC4024"
        case "CJDOC1025" => "CJDOC3025"
        case _ => code
    }
}

private func comparePublicString(left: String, right: String): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

private func comparePublicInt(left: Int64, right: Int64): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

private func comparePublicOptionalString(left: ?String, right: ?String): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    comparePublicString(left.getOrThrow(), right.getOrThrow())
}

private func comparePublicSource(left: ?public_model.SourceRange, right: ?public_model.SourceRange): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    let leftValue = left.getOrThrow()
    let rightValue = right.getOrThrow()
    var compared = comparePublicString(leftValue.path, rightValue.path)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.line, rightValue.start.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.column, rightValue.start.column)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.byteOffset, rightValue.start.byteOffset)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.line, rightValue.end.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.column, rightValue.end.column)
    if (compared != 0) {
        return compared
    }
    comparePublicInt(leftValue.end.byteOffset, rightValue.end.byteOffset)
}

private func comparePublicDiagnostic(left: public_model.Diagnostic, right: public_model.Diagnostic): Int64 {
    var compared = comparePublicSource(left.source, right.source)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.code, right.code)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.severity, right.severity)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.message, right.message)
    if (compared != 0) {
        return compared
    }
    comparePublicOptionalString(left.symbolId, right.symbolId)
}

private class FinalSemanticStateSummary {
    var total: Int64 = 0
    var resolved: Int64 = 0
    var partial: Int64 = 0
    var unavailable: Int64 = 0
    var ambiguous: Int64 = 0

    func add(state: String): Unit {
        total++
        match (state) {
            case "resolved" => resolved++
            case "partial" => partial++
            case "unavailable" => unavailable++
            case "ambiguous" => ambiguous++
            case _ => partial++
        }
    }
}

private func summarizeFinalSemanticStates(documentation: DocumentationSet): HashMap<String, FinalSemanticStateSummary> {
    let summaries = HashMap<String, FinalSemanticStateSummary>()
    for (symbol in documentation.symbols) {
        let summary = match (summaries.get(symbol.moduleId)) {
            case Some(value) => value
            case None =>
                let value = FinalSemanticStateSummary()
                summaries[symbol.moduleId] = value
                value
        }
        summary.add(symbol.semanticState)
    }
    summaries
}

private func aggregateProviderState(binding: SemanticBindingStats, summary: FinalSemanticStateSummary): String {
    if (!binding.capabilities.sourceBinding) {
        return "unavailable"
    }
    if (summary.total > 0 && summary.unavailable == summary.total) {
        return "unavailable"
    }
    if (summary.total > 0 && summary.ambiguous == summary.total) {
        return "ambiguous"
    }
    if (summary.total == 0 || summary.partial > 0 || summary.unavailable > 0 || summary.ambiguous > 0 ||
        binding.missing > 0 || binding.ambiguous > 0 || binding.contractViolations > 0 || binding.extraneous > 0) {
        return "partial"
    }
    "resolved"
}

protected func boundGeneratedDocumentation(candidate: public_model.DocumentationSet,
    request: GenerationRequest, force!: Bool = false): public_model.DocumentationSet {
    if (!force &&
        public_render.docIrFitsEncodedBudget(candidate, public_model.DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES)) {
        return candidate
    }
    // Generation must return a valid, renderable value even when a hostile or
    // unexpectedly large source/provider field would exceed codec or output
    // transaction limits. Fixed strings keep this fallback independent of the
    // oversized input that caused it.
    public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.7.1"), "partial",
        public_model.ProjectInfo("resource-limited"),
        public_model.ConfigurationSnapshot(audience: request.audience, lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) {
                "default"
            } else {
                "custom"
            }),
        diagnostics: [public_model.Diagnostic("warning", "CJDOC3027",
            "generated documentation exceeded codec or output resource limits and was replaced by a bounded fallback")])
}

private func publicDocumentation(documentation: DocumentationSet, request: GenerationRequest): public_model.DocumentationSet {
    let sourceMapper = PublicSourceMapper(origins: documentation.sourceFileOrigins.toArray())
    let modules = ArrayList<public_model.ModuleDoc>()
    for (module in documentation.modules) {
        modules.add(
            public_model.ModuleDoc(module.id, module.name, module.role, module.sourcePrefix,
                packageNames: module.packageNames.toArray(), dependencyIds: module.dependencyIds.toArray(),
                organization: module.organization))
    }
    let packages = ArrayList<public_model.PackageDoc>()
    let files = ArrayList<public_model.FileDoc>()
    for (pkg in documentation.packages) {
        let reExports = ArrayList<public_model.ReExportDoc>()
        for (reExport in pkg.reExports) {
            let bindings = ArrayList<public_model.ReExportBinding>()
            for (binding in reExport.bindings) {
                bindings.add(public_model.ReExportBinding(binding.exposedName,
                    targetSymbolIds: binding.targetSymbolIds.toArray()))
            }
            reExports.add(public_model.ReExportDoc(reExport.id, reExport.kind,
                reExport.targetPackageName, reExport.state, sourceMapper.range(reExport.source),
                organization: reExport.organization, targetModuleId: reExport.targetModuleId,
                alias: reExport.alias, bindings: bindings.toArray()))
        }
        packages.add(
            public_model.PackageDoc(pkg.name, pkg.moduleId, sourceFiles: pkg.sourceFiles.toArray(),
                symbolIds: pkg.symbolIds.toArray(), reExports: reExports.toArray()))
        for (path in pkg.sourceFiles) {
            files.add(public_model.FileDoc(path, pkg.moduleId, pkg.name))
        }
    }
    let semanticSummaries = summarizeFinalSemanticStates(documentation)
    let providerStatesByModule = HashMap<String, String>()
    for (binding in documentation.semanticBindings) {
        let summary = match (semanticSummaries.get(binding.moduleId)) {
            case Some(value) => value
            case None => FinalSemanticStateSummary()
        }
        providerStatesByModule[binding.moduleId] = aggregateProviderState(binding, summary)
    }
    let declarations = ArrayList<public_model.SymbolDoc>()
    let assetCollector = LocalAssetCollector(documentation.sourceFileOrigins)
    let markdownContext = MarkdownGenerationContext()
    for (symbol in documentation.symbols) {
        let providerState = match (providerStatesByModule.get(symbol.moduleId)) {
            case Some(value) => value
            case None => "unavailable"
        }
        let declarationSource = sourceMapper.range(symbol.source)
        let parameters = ArrayList<public_model.ParameterDoc>()
        let annotations = ArrayList<public_model.AnnotationDoc>()
        let typeRelationships = ArrayList<public_model.TypeRelationship>()
        let symbolRelationships = ArrayList<public_model.SymbolRelationship>()
        for (parameter in symbol.parameters) {
            parameters.add(
                public_model.ParameterDoc(parameter.name,
                    publicType(parameter.typeRef, symbol.semanticProvider, providerState),
                    documentation: parameter.documentation, defaultExpression: parameter.defaultExpression))
        }
        for (relationship in symbol.relationships) {
            typeRelationships.add(
                public_model.TypeRelationship(relationship.kind,
                    publicType(relationship.target, symbol.semanticProvider, providerState)))
        }
        for (relationship in symbol.symbolRelationships) {
            symbolRelationships.add(
                public_model.SymbolRelationship(relationship.kind, relationship.targetDisplay, relationship.state,
                    targetSymbolId: relationship.targetSymbolId))
        }
        for (annotation in symbol.annotations) {
            annotations.add(
                public_model.AnnotationDoc(annotation.spelling, provenance: annotation.provenance,
                    provider: annotation.provider))
        }
        declarations.add(
            public_model.SymbolDoc(symbol.id, symbol.kind, symbol.name, symbol.qualifiedName, symbol.packageName,
                symbol.moduleId, symbol.visibility, declarationSource, symbol.sourceSignature,
                public_model.SemanticInfo(symbol.semanticState, symbol.semanticProvider,
                    canonicalSignature: symbol.canonicalSignature), symbol.enumNonExhaustive, ownerId: symbol.ownerId,
                genericParameters: symbol.genericParameters.toArray(), parameters: parameters.toArray(),
                returnType: match (symbol.returnType) {
                    case Some(value) => Some(publicType(value, symbol.semanticProvider, providerState))
                    case None => None
                }, annotations: annotations.toArray(), typeRelationships: typeRelationships.toArray(),
                symbolRelationships: symbolRelationships.toArray(), documentation: match (symbol.documentation) {
                    case Some(value) => Some(
                        publicComment(value, assetCollector, symbol.source.path, declarationSource, symbol.id,
                            markdownContext))
                    case None => None
                },
                origin: public_model.DeclarationOrigin(kind: symbol.origin.kind,
                    macroSymbolId: symbol.origin.macroSymbolId),
                sourceApiSignature: if (symbol.sourceApiSignatureTokens.isEmpty()) {
                    public_model.SourceApiSignature("unavailable")
                } else {
                    public_model.SourceApiSignature("available",
                        tokens: symbol.sourceApiSignatureTokens.toArray())
                }))
    }
    let unsupported = ArrayList<public_model.UnsupportedDeclaration>()
    let orphanDocComments = ArrayList<public_model.OrphanDocComment>()
    for (comment in documentation.orphanDocComments) {
        orphanDocComments.add(public_model.OrphanDocComment(comment.rawText, sourceMapper.range(comment.source)))
    }
    let macroInvocations = ArrayList<public_model.MacroInvocation>()
    for (invocation in documentation.macroInvocations) {
        macroInvocations.add(public_model.MacroInvocation(invocation.name, sourceMapper.range(invocation.source)))
    }
    for (item in documentation.unsupportedDeclarations) {
        unsupported.add(
            public_model.UnsupportedDeclaration(item.kind, item.name, item.reason, sourceMapper.range(item.source)))
    }
    let diagnostics = ArrayList<public_model.Diagnostic>()
    var hasError = false
    var hasIncompleteSource = !documentation.orphanDocComments.isEmpty() || !documentation.macroInvocations.isEmpty() ||
        !documentation.unsupportedDeclarations.isEmpty()
    for (diagnostic in documentation.diagnostics) {
        let publicCode = remapDiagnosticCode(diagnostic.code)
        if (diagnostic.severity == "error") {
            hasError = true
        }
        if (publicCode.startsWith("CJDOC1")) {
            hasIncompleteSource = true
        }
        diagnostics.add(
            public_model.Diagnostic(diagnostic.severity, publicCode, diagnostic.message,
                source: match (diagnostic.source) {
                    case Some(value) => Some(sourceMapper.range(value))
                    case None => None
                }, symbolId: diagnostic.symbolId))
    }
    if (assetCollector.incomplete) {
        hasIncompleteSource = true
    }
    diagnostics.add(all: assetCollector.diagnostics())
    if (markdownContext.incomplete) {
        hasIncompleteSource = true
    }
    diagnostics.add(all: markdownContext.diagnostics())
    sort(diagnostics, lessThan: {
        left, right => comparePublicDiagnostic(left, right) < 0
    }, stable: true)
    let providers = ArrayList<public_model.ProviderInfo>()
    var hasIncompleteSemantic = false
    for (binding in documentation.semanticBindings) {
        let capabilities = binding.capabilities
        let summary = match (semanticSummaries.get(binding.moduleId)) {
            case Some(value) => value
            case None => FinalSemanticStateSummary()
        }
        let providerState = match (providerStatesByModule.get(binding.moduleId)) {
            case Some(value) => value
            case None => "unavailable"
        }
        if (!capabilities.sourceBinding || binding.missing > 0 || binding.ambiguous > 0 || binding.contractViolations > 0 ||
            binding.extraneous > 0 || summary.unavailable > 0 || summary.ambiguous > 0) {
            hasIncompleteSemantic = true
        }
        providers.add(
            public_model.ProviderInfo(binding.provider, binding.providerVersion, binding.moduleId, providerState,
                public_model.SemanticCapabilities(capabilities.sourceBinding, capabilities.ownership,
                    capabilities.visibility, capabilities.canonicalTypes, capabilities.canonicalSignatures,
                    relationships: capabilities.symbolRelationships, annotations: capabilities.annotations)))
    }
    let candidate = public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.7.1"),
        if (hasError || hasIncompleteSource || hasIncompleteSemantic) {
            "partial"
        } else {
            "complete"
        }, public_model.ProjectInfo(documentation.projectName),
        public_model.ConfigurationSnapshot(audience: request.audience, lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) {
                "default"
            } else {
                "custom"
            }), providers: providers.toArray(), modules: modules.toArray(), packages: packages.toArray(),
        files: files.toArray(), declarations: declarations.toArray(), assets: assetCollector.assets(),
        orphanDocComments: orphanDocComments.toArray(), macroInvocations: macroInvocations.toArray(),
        unsupportedDeclarations: unsupported.toArray(), diagnostics: diagnostics.toArray())
    boundGeneratedDocumentation(candidate, request)
}

public class DocumentationEngine {
    public func generate(request: GenerationRequest): public_model.DocumentationSet {
        let semanticProvider: SemanticProvider = if (request.providerFactories.isEmpty()) {
            defaultSemanticProvider()
        } else {
            FactorySemanticProviderAdapter(request.providerFactories[0])
        }
        let documentation = generateDocumentation(request.projectRoot,
            includePathDependencies: request.includePathDependencies,
            dependencySources: request.dependencySources.toArray(), cfgValues: request.cfgValues.toArray(),
            jobs: request.jobs, cacheDirectory: request.cacheDirectory, cacheFingerprint: request.cacheFingerprint,
            astPreflightExecutable: request.astPreflightExecutable,
            includeCachedDependencies: request.includeCachedDependencies, cjpmCacheRoot: request.cjpmCacheRoot,
            semanticProvider: semanticProvider)
        match (request.lintProfile) {
            case "off" => resolveDocumentationReferences(documentation)
            case "standard" => lintDocumentation(documentation, false)
            case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true)
            case _ => ()
        }
        sortDocumentationDeterministically(documentation)
        let result = publicDocumentation(documentation, request)
        validateGeneratedDocIr(result)
        result
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) {
            results.add(generate(request))
        }
        results.toArray()
    }
}
