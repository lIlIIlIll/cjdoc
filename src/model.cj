package cjdoc

import std.collection.*

class SourceLocation {
    public let path: String
    public let startLine: Int64
    public let startColumn: Int64
    public let endLine: Int64
    public let endColumn: Int64

    public init(path: String, startLine: Int64, startColumn: Int64, endLine: Int64, endColumn: Int64) {
        this.path = path
        this.startLine = startLine
        this.startColumn = startColumn
        this.endLine = endLine
        this.endColumn = endColumn
    }
}

class TypeRef {
    public let display: String
    public let canonical: ?String
    public let state: String
    public let kind: String
    public let nullable: Bool
    public let arguments: ArrayList<TypeRef>

    public init(display: String, canonical!: ?String = None, state!: String = "partial",
        kind!: String = "source", nullable!: Bool = false, arguments!: Array<TypeRef> = []) {
        this.display = display
        this.canonical = canonical
        this.state = state
        this.kind = kind
        this.nullable = nullable
        this.arguments = ArrayList<TypeRef>(arguments)
    }
}

// Source models contain only facts recovered from the source lexer/parser.
// sourceKey is an internal binding key; it is never serialized as a SymbolId.
class SourceParameter {
    public let name: String
    public let typeSpelling: String
    public let defaultExpression: ?String

    public init(name: String, typeSpelling: String,
        defaultExpression!: ?String = None) {
        this.name = name
        this.typeSpelling = typeSpelling
        this.defaultExpression = defaultExpression
    }
}

class SourceTypeRelationship {
    public let kind: String
    public let targetSpelling: String

    public init(kind: String, targetSpelling: String) {
        this.kind = kind
        this.targetSpelling = targetSpelling
    }
}

class SourceImportItem {
    public let name: String
    public let alias: ?String

    public init(name: String, alias!: ?String = None) {
        this.name = name
        this.alias = alias
    }
}

class SourceReExport {
    public let kind: String
    public let organization: ?String
    public let prefixPaths = ArrayList<String>()
    public let identifier: String
    public let alias: ?String
    public let items = ArrayList<SourceImportItem>()
    public let source: SourceLocation
    public let normalizedSpec: String
    public let packageName: String
    public let moduleId: String

    public init(kind: String, organization: ?String, identifier: String, alias: ?String,
        source: SourceLocation, normalizedSpec: String, packageName: String, moduleId: String,
        prefixPaths!: Array<String> = [], items!: Array<SourceImportItem> = []) {
        this.kind = kind
        this.organization = organization
        this.identifier = identifier
        this.alias = alias
        this.source = source
        this.normalizedSpec = normalizedSpec
        this.packageName = packageName
        this.moduleId = moduleId
        this.prefixPaths.add(all: prefixPaths)
        this.items.add(all: items)
    }
}

class SourceSymbolRelationship {
    public let kind: String
    public let targetDisplay: String

    public init(kind: String, targetDisplay: String) {
        this.kind = kind
        this.targetDisplay = targetDisplay
    }
}

class SourceDeclaration {
    public let sourceKey: String
    public let kind: String
    public let name: String
    public let packageName: String
    public let moduleId: String
    public var visibility: String
    public let genericParameters = ArrayList<String>()
    public let parameters = ArrayList<SourceParameter>()
    public var returnTypeSpelling: ?String = None
    public let annotations = ArrayList<String>()
    public let modifiers = ArrayList<String>()
    public let relationships = ArrayList<SourceTypeRelationship>()
    public let symbolRelationships = ArrayList<SourceSymbolRelationship>()
    public var documentation: ?DocComment = None
    public let source: SourceLocation
    public let sourceSignature: String
    public let sourceApiSignatureTokens = ArrayList<String>()
    public let isContainer: Bool
    // `Some(true)`/`Some(false)` is source truth for enum declarations.
    // Non-enum declarations use `None` so the fact cannot be mistaken for an
    // exhaustive enum during provider/binder projection.
    public let enumNonExhaustive: ?Bool
    public var ownerSourceKey: ?String = None
    var ownerIndex: Int64 = -1

    public init(sourceKey: String, kind: String, name: String, packageName: String, moduleId: String,
        visibility: String, source: SourceLocation, sourceSignature: String,
        isContainer!: Bool = false, enumNonExhaustive!: ?Bool = None,
        sourceApiSignatureTokens!: Array<String> = []) {
        this.sourceKey = sourceKey
        this.kind = kind
        this.name = name
        this.packageName = packageName
        this.moduleId = moduleId
        this.visibility = visibility
        this.source = source
        this.sourceSignature = sourceSignature
        this.sourceApiSignatureTokens.add(all: sourceApiSignatureTokens)
        this.isContainer = isContainer
        this.enumNonExhaustive = enumNonExhaustive
    }
}

class SourcePackage {
    public let name: String
    public let moduleId: String
    public let sourceFiles = ArrayList<String>()

    public init(name: String, moduleId: String) { this.name = name; this.moduleId = moduleId }
}

class SourceModule {
    public let id: String
    public let name: String
    public let role: String
    public let sourcePrefix: String
    public let organization: ?String
    public let packageNames = ArrayList<String>()
    public let dependencyIds = ArrayList<String>()

    public init(id: String, name: String, role: String, sourcePrefix: String,
        organization!: ?String = None) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.organization = organization
    }
}

// Immutable byte offsets derived from the exact normalized source text captured
// by the bounded frontend read. Retaining only line boundaries keeps later
// public/provider range mapping deterministic without reopening host paths.
let MAX_CAPTURED_SOURCE_LINES: Int64 = 1000000

class CapturedSourceIndex {
    public let byteLength: Int64
    public let available: Bool
    private let lineStarts = ArrayList<Int64>()

    public init(source: String, maxLines!: Int64 = MAX_CAPTURED_SOURCE_LINES) {
        if (maxLines < 1) {
            throw IllegalArgumentException("captured source line limit must be positive")
        }
        let bytes = source.toArray()
        this.byteLength = bytes.size
        lineStarts.add(0)
        var withinLimit = true
        var index: Int64 = 0
        while (index < bytes.size) {
            if (bytes[index] == b'\n') {
                if (lineStarts.size >= maxLines) {
                    withinLimit = false
                    break
                }
                lineStarts.add(index + 1)
            }
            index++
        }
        this.available = withinLimit
    }

    public func byteOffset(line: Int64, column: Int64): ?Int64 {
        if (!available || line < 1 || column < 1) { return None }
        let lineIndex = line - 1
        if (lineIndex >= lineStarts.size) { return None }
        let start = lineStarts[lineIndex]
        let end = if (lineIndex + 1 < lineStarts.size) {
            lineStarts[lineIndex + 1] - 1
        } else {
            byteLength
        }
        let delta = column - 1
        if (delta > end - start) { return None }
        Some(start + delta)
    }

    public func positionMatches(line: Int64, column: Int64, byteOffset: Int64): Bool {
        match (this.byteOffset(line, column)) {
            case Some(expected) => expected == byteOffset
            case None => false
        }
    }
}

// Host paths are retained only while generating one in-memory result. They are
// never exposed through the public model or serialized into Doc IR.
class SourceFileOrigin {
    public let logicalPath: String
    public let actualPath: String
    public let actualRoot: String
    public let logicalPrefix: String
    public let capturedSourceIndex: ?CapturedSourceIndex

    public init(logicalPath: String, actualPath: String, actualRoot: String,
        logicalPrefix: String, capturedSourceIndex!: ?CapturedSourceIndex = None) {
        this.logicalPath = logicalPath
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.logicalPrefix = logicalPrefix
        this.capturedSourceIndex = capturedSourceIndex
    }
}

class DeclarationOrigin {
    public let kind: String
    public let macroSymbolId: ?String

    public init(kind: String, macroSymbolId!: ?String = None) {
        this.kind = kind
        this.macroSymbolId = macroSymbolId
    }
}

class UnsupportedDeclaration {
    public let kind: String
    public let name: String
    public let reason: String
    public let source: SourceLocation
    public let origin: DeclarationOrigin

    public init(kind: String, name: String, reason: String, source: SourceLocation,
        origin!: DeclarationOrigin = DeclarationOrigin("source")) {
        this.kind = kind
        this.name = name
        this.reason = reason
        this.source = source
        this.origin = origin
    }
}

class OrphanDocComment {
    public let rawText: String
    public let source: SourceLocation

    public init(rawText: String, source: SourceLocation) {
        this.rawText = rawText
        this.source = source
    }
}

class MacroInvocation {
    public let name: String
    public let source: SourceLocation

    public init(name: String, source: SourceLocation) {
        this.name = name
        this.source = source
    }
}

class SourceSnapshot {
    public let projectName: String
    public let modules = ArrayList<SourceModule>()
    public let packages = ArrayList<SourcePackage>()
    public let declarations = ArrayList<SourceDeclaration>()
    public let reExports = ArrayList<SourceReExport>()
    public let sourceFileOrigins = ArrayList<SourceFileOrigin>()
    public let orphanDocComments = ArrayList<OrphanDocComment>()
    public let macroInvocations = ArrayList<MacroInvocation>()
    public let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    public let diagnostics = ArrayList<Diagnostic>()

    public init(projectName: String) { this.projectName = projectName }
}

// Explicit offline source supplied for a registry/git dependency. The path is
// an input only and is never serialized into Doc IR.
public class DependencySourceInput {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        if (!safeDependencyLogicalName(name)) {
            throw IllegalArgumentException("dependency name must use non-empty ASCII alphanumeric, '_' or '-' dot-separated segments")
        }
        this.name = name
        this.path = path
    }
}

func safeDependencyLogicalName(name: String): Bool {
    if (name.isEmpty()) { return false }
    var segmentBytes: Int64 = 0
    for (byte in name.toArray()) {
        if (byte == b'.') {
            if (segmentBytes == 0) { return false }
            segmentBytes = 0
            continue
        }
        let allowed = (byte >= b'a' && byte <= b'z') ||
            (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-'
        if (!allowed) { return false }
        segmentBytes++
    }
    segmentBytes > 0
}

class SemanticParameter {
    public let name: String
    public let typeRef: TypeRef

    public init(name: String, typeRef: TypeRef) {
        this.name = name
        this.typeRef = typeRef
    }
}

class SemanticDeclaration {
    public let sourceKey: String
    public let kind: String
    public let name: String
    public let packageName: String
    public let moduleId: String
    public let ownerSourceKey: ?String
    public let visibility: String
    public let genericParameters = ArrayList<String>()
    public let parameters = ArrayList<SemanticParameter>()
    public var returnType: ?TypeRef = None
    public let annotations = ArrayList<String>()
    public let providerAnnotations = ArrayList<String>()
    public let relationships = ArrayList<TypeRelationship>()
    public let symbolRelationships = ArrayList<SymbolRelationship>()
    public let state: String
    public let provider: String
    public let canonicalSignature: ?String
    public let isContainer: Bool
    public let enumNonExhaustive: ?Bool

    public init(sourceKey: String, kind: String, name: String, packageName: String, moduleId: String,
        ownerSourceKey: ?String, visibility: String, state: String, provider: String,
        canonicalSignature!: ?String = None, isContainer!: Bool = false,
        enumNonExhaustive!: ?Bool = None) {
        this.sourceKey = sourceKey
        this.kind = kind
        this.name = name
        this.packageName = packageName
        this.moduleId = moduleId
        this.ownerSourceKey = ownerSourceKey
        this.visibility = visibility
        this.state = state
        this.provider = provider
        this.canonicalSignature = canonicalSignature
        this.isContainer = isContainer
        this.enumNonExhaustive = enumNonExhaustive
    }
}

class ModuleSemanticResult {
    public let moduleId: String
    public let provider: String
    public let providerVersion: String
    public let capabilities: SemanticCapabilities
    public let declarations = ArrayList<SemanticDeclaration>()
    public let diagnostics = ArrayList<Diagnostic>()

    public init(moduleId: String, provider: String, providerVersion: String,
        capabilities: SemanticCapabilities) {
        this.moduleId = moduleId
        this.provider = provider
        this.providerVersion = providerVersion
        this.capabilities = capabilities
    }
}

class SemanticResult {
    public let modules = ArrayList<ModuleSemanticResult>()
    public let diagnostics = ArrayList<Diagnostic>()
}

class SemanticCapabilities {
    public let sourceBinding: Bool
    public let ownership: Bool
    public let visibility: Bool
    public let canonicalTypes: Bool
    public let canonicalSignatures: Bool
    public let symbolRelationships: Bool
    public let annotations: Bool

    public init(sourceBinding: Bool, ownership: Bool, visibility: Bool,
        canonicalTypes: Bool, canonicalSignatures: Bool,
        symbolRelationships!: Bool = false, annotations!: Bool = false) {
        this.sourceBinding = sourceBinding
        this.ownership = ownership
        this.visibility = visibility
        this.canonicalTypes = canonicalTypes
        this.canonicalSignatures = canonicalSignatures
        this.symbolRelationships = symbolRelationships
        this.annotations = annotations
    }
}

// Records the observable result of joining semantic declarations back to the
// source declarations that own comments and source ranges.
class SemanticBindingStats {
    public let moduleId: String
    public let provider: String
    public let providerVersion: String
    public let capabilities: SemanticCapabilities
    public var matched: Int64 = 0
    public var missing: Int64 = 0
    public var ambiguous: Int64 = 0
    public var extraneous: Int64 = 0
    public var contractViolations: Int64 = 0

    public init(moduleId: String, provider: String, providerVersion: String,
        capabilities: SemanticCapabilities) {
        this.moduleId = moduleId
        this.provider = provider
        this.providerVersion = providerVersion
        this.capabilities = capabilities
    }
}

class ParameterDoc {
    public let name: String
    public let typeRef: TypeRef
    public let defaultExpression: ?String
    public var documentation: ?String = None

    public init(name: String, typeRef: TypeRef,
        defaultExpression!: ?String = None) {
        this.name = name
        this.typeRef = typeRef
        this.defaultExpression = defaultExpression
    }
}

class TypeRelationship {
    public let kind: String
    public let target: TypeRef

    public init(kind: String, target: TypeRef) {
        this.kind = kind
        this.target = target
    }
}

class SymbolRelationship {
    public let kind: String
    public let targetDisplay: String
    public var state: String
    public var targetSymbolId: ?String
    public let targetSourceKey: ?String

    public init(kind: String, targetDisplay: String, state: String,
        targetSymbolId!: ?String = None, targetSourceKey!: ?String = None) {
        this.kind = kind
        this.targetDisplay = targetDisplay
        this.state = state
        this.targetSymbolId = targetSymbolId
        this.targetSourceKey = targetSourceKey
    }
}

class DocTag {
    public let name: String
    public let subject: String
    public var description: String
    // Populated for @see tags by the declaration-index resolution pass.
    public var referenceState: String = "unresolved"
    public var targetSymbolId: ?String = None

    public init(name: String, subject: String, description: String) {
        this.name = name
        this.subject = subject
        this.description = description
    }
}

class DocComment {
    public let raw: String
    public let summaryMarkdown: String
    public let descriptionMarkdown: String
    public let params = ArrayList<DocTag>()
    public var returns: ?DocTag = None
    public var returnTagCount: Int64 = 0
    public let throwsTags = ArrayList<DocTag>()
    public let see = ArrayList<DocTag>()
    public var since: ?String = None
    public var deprecated: ?String = None
    public let authors = ArrayList<String>()
    public var version: ?String = None

    public init(raw: String, summaryMarkdown: String, descriptionMarkdown: String) {
        this.raw = raw
        this.summaryMarkdown = summaryMarkdown
        this.descriptionMarkdown = descriptionMarkdown
    }
}

class Diagnostic {
    public let severity: String
    public let code: String
    public let message: String
    public let source: ?SourceLocation
    public let symbolId: ?String

    public init(severity: String, code: String, message: String,
        source!: ?SourceLocation = None, symbolId!: ?String = None) {
        this.severity = severity
        this.code = code
        this.message = message
        this.source = source
        this.symbolId = symbolId
    }
}

class DocAnnotation {
    public let spelling: String
    public let provenance: String
    public let provider: ?String

    public init(spelling: String, provenance!: String = "source", provider!: ?String = None) {
        this.spelling = spelling
        this.provenance = provenance
        this.provider = provider
    }
}

class SymbolDoc {
    public var id: String = ""
    public let kind: String
    public let name: String
    public var qualifiedName: String = ""
    public let packageName: String
    public let moduleId: String
    public var ownerId: ?String = None
    public var visibility: String
    public let genericParameters = ArrayList<String>()
    public let parameters = ArrayList<ParameterDoc>()
    public var returnType: ?TypeRef = None
    public let annotations = ArrayList<DocAnnotation>()
    public let relationships = ArrayList<TypeRelationship>()
    public let symbolRelationships = ArrayList<SymbolRelationship>()
    public var documentation: ?DocComment = None
    public let source: SourceLocation
    public let sourceSignature: String
    public let sourceApiSignatureTokens = ArrayList<String>()
    public let semanticState: String
    public let semanticProvider: String
    public let canonicalSignature: ?String
    public let isContainer: Bool
    public let enumNonExhaustive: ?Bool
    public let origin: DeclarationOrigin
    var ownerIndex: Int64 = -1

    public init(kind: String, name: String, packageName: String, moduleId: String, visibility: String,
        source: SourceLocation, sourceSignature: String, isContainer!: Bool = false,
        semanticState!: String = "partial", semanticProvider!: String = "ast",
        canonicalSignature!: ?String = None, enumNonExhaustive!: ?Bool = None,
        origin!: DeclarationOrigin = DeclarationOrigin("source"),
        sourceApiSignatureTokens!: Array<String> = []) {
        this.kind = kind
        this.name = name
        this.packageName = packageName
        this.moduleId = moduleId
        this.visibility = visibility
        this.source = source
        this.sourceSignature = sourceSignature
        this.sourceApiSignatureTokens.add(all: sourceApiSignatureTokens)
        this.semanticState = semanticState
        this.semanticProvider = semanticProvider
        this.canonicalSignature = canonicalSignature
        this.isContainer = isContainer
        this.enumNonExhaustive = enumNonExhaustive
        this.origin = origin
    }
}

class ReExportBinding {
    public let exposedName: String
    public let targetSymbolIds = ArrayList<String>()

    public init(exposedName: String, targetSymbolIds!: Array<String> = []) {
        this.exposedName = exposedName
        this.targetSymbolIds.add(all: targetSymbolIds)
    }
}

class ReExportDoc {
    public let id: String
    public let kind: String
    public let organization: ?String
    public let targetPackageName: String
    public let targetModuleId: ?String
    public let alias: ?String
    public let state: String
    public let source: SourceLocation
    public let bindings = ArrayList<ReExportBinding>()

    public init(id: String, kind: String, organization: ?String, targetPackageName: String,
        targetModuleId: ?String, alias: ?String, state: String, source: SourceLocation,
        bindings!: Array<ReExportBinding> = []) {
        this.id = id
        this.kind = kind
        this.organization = organization
        this.targetPackageName = targetPackageName
        this.targetModuleId = targetModuleId
        this.alias = alias
        this.state = state
        this.source = source
        this.bindings.add(all: bindings)
    }
}

class PackageDoc {
    public let name: String
    public let moduleId: String
    public let sourceFiles = ArrayList<String>()
    public let symbolIds = ArrayList<String>()
    public let reExports = ArrayList<ReExportDoc>()

    public init(name: String, moduleId: String) { this.name = name; this.moduleId = moduleId }
}

class ModuleDoc {
    public let id: String
    public let name: String
    public let role: String
    public let sourcePrefix: String
    public let organization: ?String
    public let packageNames = ArrayList<String>()
    public let dependencyIds = ArrayList<String>()

    public init(id: String, name: String, role: String, sourcePrefix: String,
        organization!: ?String = None) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.organization = organization
    }
}

class DocumentationSet {
    public let projectName: String
    public let modules = ArrayList<ModuleDoc>()
    public let packages = ArrayList<PackageDoc>()
    public let symbols = ArrayList<SymbolDoc>()
    public let sourceFileOrigins = ArrayList<SourceFileOrigin>()
    public let orphanDocComments = ArrayList<OrphanDocComment>()
    public let macroInvocations = ArrayList<MacroInvocation>()
    public let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    public let diagnostics = ArrayList<Diagnostic>()
    public let semanticBindings = ArrayList<SemanticBindingStats>()
    public var cfgProfile = CfgProfile()

    public init(projectName: String) { this.projectName = projectName }
}

interface SourceProvider {
    func collect(projectRoot: String): SourceSnapshot
}

interface SemanticProvider {
    func providerName(): String
    func providerVersion(): String
    func analyze(source: SourceSnapshot): SemanticResult
}

private func isExternallyVisible(symbol: SymbolDoc): Bool {
    return symbol.visibility == "public" || symbol.visibility == "protected"
}

func retainPublicApi(documentation: DocumentationSet): Unit {
    let kept = HashSet<String>()
    for (symbol in documentation.symbols) {
        if (symbol.ownerId.isNone() && isExternallyVisible(symbol)) { let _ = kept.add(symbol.id) }
    }
    for (symbol in documentation.symbols where symbol.kind == "extend") {
        for (member in documentation.symbols) {
            if (member.ownerId == Some(symbol.id) && isExternallyVisible(member)) {
                let _ = kept.add(symbol.id)
                break
            }
        }
    }
    var changed = true
    while (changed) {
        changed = false
        for (symbol in documentation.symbols) {
            if (!kept.contains(symbol.id) && isExternallyVisible(symbol)) {
                match (symbol.ownerId) {
                    case Some(owner) =>
                        if (kept.contains(owner)) {
                            let _ = kept.add(symbol.id)
                            changed = true
                        }
                    case None => ()
                }
            }
        }
    }
    var index = documentation.symbols.size - 1
    while (index >= 0) {
        if (!kept.contains(documentation.symbols[index].id)) {
            documentation.symbols.remove(at: index)
        }
        index--
    }
    for (pkg in documentation.packages) {
        index = pkg.symbolIds.size - 1
        while (index >= 0) {
            if (!kept.contains(pkg.symbolIds[index])) { pkg.symbolIds.remove(at: index) }
            index--
        }
    }
    index = documentation.diagnostics.size - 1
    while (index >= 0) {
        if (let Some(symbolId) <- documentation.diagnostics[index].symbolId) {
            if (!kept.contains(symbolId)) { documentation.diagnostics.remove(at: index) }
        }
        index--
    }
    resolveDocumentationReferences(documentation)
}
