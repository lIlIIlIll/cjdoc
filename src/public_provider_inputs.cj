package cjdoc

import cjdoc.semantic.{ModuleSemanticResult, SemanticCapabilities}
import cjdoc.source.model.{TypeRef, SourceDeclaration, SourceModule, CapturedSourceIndex, SourceFileOrigin}
import cjdoc.source.Diagnostic
import cjdoc.source.SourceLocation
import cjdoc.model as public_model
import cjdoc.provider as public_provider
import std.collection.*

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
    private let indexesByModulePath = HashMap<String, CapturedSourceIndex>()
    private let unavailableModulePaths = HashSet<String>()
    private let ambiguousModulePaths = HashSet<String>()
    private let indexesByPath = HashMap<String, CapturedSourceIndex>()
    private let unavailablePaths = HashSet<String>()
    private let ambiguousPaths = HashSet<String>()
    private let seenPaths = HashSet<String>()

    init(origins!: Array<SourceFileOrigin> = []) {
        for (origin in origins) {
            let path = origin.logicalPath
            let key = "${origin.moduleId}\n${path}"
            if (indexesByModulePath.contains(key) || unavailableModulePaths.contains(key) ||
                ambiguousModulePaths.contains(key)) {
                let _ = indexesByModulePath.remove(key)
                let _ = unavailableModulePaths.add(key)
                let _ = ambiguousModulePaths.add(key)
            } else {
                match (origin.capturedFacts) {
                    case Some(facts) =>
                        if (facts.index.available) { indexesByModulePath[key] = facts.index }
                        else { let _ = unavailableModulePaths.add(key) }
                    case None => let _ = unavailableModulePaths.add(key)
                }
            }
            if (!seenPaths.add(path)) {
                let _ = indexesByPath.remove(path)
                let _ = unavailablePaths.add(path)
                let _ = ambiguousPaths.add(path)
            } else {
                match (origin.capturedFacts) {
                    case Some(facts) =>
                        if (facts.index.available) { indexesByPath[path] = facts.index }
                        else { let _ = unavailablePaths.add(path) }
                    case None => let _ = unavailablePaths.add(path)
                }
            }
        }
    }

    private func sourceIndex(path: String): ?CapturedSourceIndex {
        if (unavailablePaths.contains(path) || ambiguousPaths.contains(path)) { return None }
        indexesByPath.get(path)
    }

    private func sourceIndex(moduleId: String, path: String): ?CapturedSourceIndex {
        let key = "${moduleId}\n${path}"
        if (unavailableModulePaths.contains(key) || ambiguousModulePaths.contains(key)) { return None }
        indexesByModulePath.get(key)
    }

    private func capturedRange(index: CapturedSourceIndex, location: SourceLocation):
        ?public_model.SourceRange {
        let start = index.byteOffset(location.startLine, location.startColumn)
        let end = index.byteOffset(location.endLine, location.endColumn)
        match ((start, end)) {
            case (Some(startOffset), Some(endOffset)) =>
                if (endOffset < startOffset) { return None }
                Some(public_model.SourceRange(location.path,
                    public_model.SourcePosition(location.startLine, location.startColumn, startOffset),
                    public_model.SourcePosition(location.endLine, location.endColumn, endOffset)))
            case _ => None
        }
    }

    func capturedRange(location: SourceLocation): ?public_model.SourceRange {
        match (sourceIndex(location.path)) {
            case Some(index) => capturedRange(index, location)
            case None => None
        }
    }

    func capturedRange(moduleId: String, location: SourceLocation): ?public_model.SourceRange {
        match (sourceIndex(moduleId, location.path)) {
            case Some(index) => capturedRange(index, location)
            case None => None
        }
    }

    func range(location: SourceLocation): public_model.SourceRange {
        match (capturedRange(location)) {
            case Some(value) => value
            case None => fallbackRange(location)
        }
    }

    func range(moduleId: String, location: SourceLocation): public_model.SourceRange {
        match (capturedRange(moduleId, location)) {
            case Some(value) => value
            case None => fallbackRange(location)
        }
    }

    private func fallbackRange(location: SourceLocation): public_model.SourceRange {
        public_model.SourceRange(location.path,
            public_model.SourcePosition(location.startLine, location.startColumn, 0),
            public_model.SourcePosition(location.endLine, location.endColumn, 0))
    }

    func contains(range: public_model.SourceRange): Bool {
        match (sourceIndex(range.path)) {
            case Some(index) => contains(index, range)
            case None => false
        }
    }


    private func contains(index: CapturedSourceIndex, range: public_model.SourceRange): Bool {
        index.positionMatches(range.start.line, range.start.column, range.start.byteOffset) &&
            index.positionMatches(range.end.line, range.end.column, range.end.byteOffset) &&
            range.end.byteOffset >= range.start.byteOffset
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
