package cjdoc

import std.collection.*

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
    public let examples = ArrayList<DocTag>()
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

internal func isExternallyVisible(symbol: SymbolDoc): Bool {
    return symbol.visibility == "public" || symbol.visibility == "protected"
}
