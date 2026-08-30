package cjdoc.model

import std.collection.*

public let DOC_IR_SCHEMA_VERSION = "cjdoc.doc-ir/7"
public let DOC_IR_V6_SCHEMA_VERSION = "cjdoc.doc-ir/6"

public func isSemanticState(value: String): Bool {
    value == "resolved" || value == "partial" || value == "unavailable" || value == "ambiguous"
}

public class SourcePosition {
    public let line: Int64
    public let column: Int64
    public let byteOffset: Int64

    public init(line: Int64, column: Int64, byteOffset: Int64) {
        if (line < 1 || column < 1 || byteOffset < 0) {
            throw IllegalArgumentException("source positions use 1-based line/UTF-8-byte column and 0-based byte offset")
        }
        this.line = line
        this.column = column
        this.byteOffset = byteOffset
    }
}

public class SourceRange {
    public let path: String
    public let start: SourcePosition
    public let end: SourcePosition

    public init(path: String, start: SourcePosition, end: SourcePosition) {
        if (path.isEmpty() || path.startsWith("/") || path.contains("\\")) {
            throw IllegalArgumentException("source path must be a non-empty portable relative path")
        }
        this.path = path
        this.start = start
        this.end = end
    }
}

public class GeneratorInfo {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        this.name = name
        this.version = version
    }
}

public class ProjectInfo {
    public let name: String
    public let kind: String

    public init(name: String, kind!: String = "package") {
        this.name = name
        this.kind = kind
    }
}

public class ConfigurationSnapshot {
    public let audience: String
    public let lintProfile: String
    public let cfgProfile: String

    public init(audience!: String = "external", lintProfile!: String = "standard",
        cfgProfile!: String = "default") {
        this.audience = audience
        this.lintProfile = lintProfile
        this.cfgProfile = cfgProfile
    }
}

public class SemanticCapabilities {
    public let sourceBinding: Bool
    public let ownership: Bool
    public let visibility: Bool
    public let canonicalTypes: Bool
    public let canonicalSignatures: Bool
    public let relationships: Bool
    public let annotations: Bool

    public init(sourceBinding: Bool, ownership: Bool, visibility: Bool, canonicalTypes: Bool,
        canonicalSignatures: Bool, relationships!: Bool = false,
        annotations!: Bool = false) {
        this.sourceBinding = sourceBinding
        this.ownership = ownership
        this.visibility = visibility
        this.canonicalTypes = canonicalTypes
        this.canonicalSignatures = canonicalSignatures
        this.relationships = relationships
        this.annotations = annotations
    }
}

public class ProviderInfo {
    public let name: String
    public let version: String
    public let moduleId: String
    public let state: String
    public let capabilities: SemanticCapabilities

    public init(name: String, version: String, moduleId: String, state: String,
        capabilities: SemanticCapabilities) {
        if (!isSemanticState(state)) { throw IllegalArgumentException("invalid provider semantic state") }
        if (moduleId.isEmpty()) { throw IllegalArgumentException("provider moduleId cannot be empty") }
        this.name = name
        this.version = version
        this.moduleId = moduleId
        this.state = state
        this.capabilities = capabilities
    }
}

public class ModuleDoc {
    public let id: String
    public let name: String
    public let role: String
    public let sourcePrefix: String
    private let packageNamesStorage: ArrayList<String>
    private let dependencyIdsStorage: ArrayList<String>

    public init(id: String, name: String, role: String, sourcePrefix: String,
        packageNames!: Array<String> = [], dependencyIds!: Array<String> = []) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.packageNamesStorage = ArrayList<String>(packageNames)
        this.dependencyIdsStorage = ArrayList<String>(dependencyIds)
    }

    public prop packageNames: ReadOnlyList<String> { get() { packageNamesStorage } }
    public prop dependencyIds: ReadOnlyList<String> { get() { dependencyIdsStorage } }
}

public class PackageDoc {
    public let name: String
    public let moduleId: String
    private let sourceFilesStorage: ArrayList<String>
    private let symbolIdsStorage: ArrayList<String>

    public init(name: String, moduleId: String, sourceFiles!: Array<String> = [],
        symbolIds!: Array<String> = []) {
        this.name = name
        this.moduleId = moduleId
        this.sourceFilesStorage = ArrayList<String>(sourceFiles)
        this.symbolIdsStorage = ArrayList<String>(symbolIds)
    }

    public prop sourceFiles: ReadOnlyList<String> { get() { sourceFilesStorage } }
    public prop symbolIds: ReadOnlyList<String> { get() { symbolIdsStorage } }
}

public class FileDoc {
    public let path: String
    public let moduleId: String
    public let packageName: String

    public init(path: String, moduleId: String, packageName: String) {
        this.path = path
        this.moduleId = moduleId
        this.packageName = packageName
    }
}

public class SemanticType {
    public let state: String
    public let canonical: ?String
    public let provider: ?String

    public init(state: String, canonical!: ?String = None, provider!: ?String = None) {
        if (!isSemanticState(state)) { throw IllegalArgumentException("invalid type semantic state") }
        if (state == "resolved" && canonical.isNone()) {
            throw IllegalArgumentException("resolved semantic type requires a canonical spelling")
        }
        this.state = state
        this.canonical = canonical
        this.provider = provider
    }
}

public class TypeRef {
    public let kind: String
    public let spelling: String
    public let nullable: Bool
    public let semantic: SemanticType
    private let argumentsStorage: ArrayList<TypeRef>

    public init(kind: String, spelling: String, semantic: SemanticType,
        nullable!: Bool = false, arguments!: Array<TypeRef> = []) {
        this.kind = kind
        this.spelling = spelling
        this.nullable = nullable
        this.semantic = semantic
        this.argumentsStorage = ArrayList<TypeRef>(arguments)
    }

    public prop arguments: ReadOnlyList<TypeRef> { get() { argumentsStorage } }
}

public class TypeRelationship {
    public let kind: String
    public let target: TypeRef

    public init(kind: String, target: TypeRef) {
        if (kind.isEmpty()) { throw IllegalArgumentException("type relationship kind cannot be empty") }
        this.kind = kind
        this.target = target
    }
}

public class SymbolRelationship {
    public let kind: String
    public let targetDisplay: String
    public let state: String
    public let targetSymbolId: ?String

    public init(kind: String, targetDisplay: String, state: String,
        targetSymbolId!: ?String = None) {
        if (kind.isEmpty() || !isSemanticState(state)) {
            throw IllegalArgumentException("invalid symbol relationship")
        }
        if (state == "resolved" && targetSymbolId.isNone()) {
            throw IllegalArgumentException("resolved symbol relationship requires targetSymbolId")
        }
        this.kind = kind
        this.targetDisplay = targetDisplay
        this.state = state
        this.targetSymbolId = targetSymbolId
    }
}

public class ParameterDoc {
    public let name: String
    public let typeRef: TypeRef
    public let documentation: ?String
    public let defaultExpression: ?String

    public init(name: String, typeRef: TypeRef, documentation!: ?String = None,
        defaultExpression!: ?String = None) {
        this.name = name
        this.typeRef = typeRef
        this.documentation = documentation
        this.defaultExpression = defaultExpression
    }
}

public class DocTag {
    public let name: String
    public let subject: String
    public let description: String
    public let referenceState: String
    public let targetSymbolId: ?String

    public init(name: String, subject: String, description: String,
        referenceState!: String = "unavailable", targetSymbolId!: ?String = None) {
        if (!isSemanticState(referenceState)) { throw IllegalArgumentException("invalid reference state") }
        this.name = name
        this.subject = subject
        this.description = description
        this.referenceState = referenceState
        this.targetSymbolId = targetSymbolId
    }
}

public class MarkdownNode {
    public let kind: String
    public let literal: String
    public let source: ?SourceRange
    private let childrenStorage: ArrayList<MarkdownNode>

    public init(kind: String, literal!: String = "", source!: ?SourceRange = None,
        children!: Array<MarkdownNode> = []) {
        this.kind = kind
        this.literal = literal
        this.source = source
        this.childrenStorage = ArrayList<MarkdownNode>(children)
    }

    public prop children: ReadOnlyList<MarkdownNode> { get() { childrenStorage } }
}

public class DocComment {
    public let rawText: String
    public let summary: String
    public let description: String
    public let markdown: MarkdownNode
    private let tagsStorage: ArrayList<DocTag>

    public init(rawText: String, summary: String, description: String, markdown: MarkdownNode,
        tags!: Array<DocTag> = []) {
        this.rawText = rawText
        this.summary = summary
        this.description = description
        this.markdown = markdown
        this.tagsStorage = ArrayList<DocTag>(tags)
    }

    public prop tags: ReadOnlyList<DocTag> { get() { tagsStorage } }
}

public class SemanticInfo {
    public let state: String
    public let provider: String
    public let canonicalSignature: ?String

    public init(state: String, provider: String, canonicalSignature!: ?String = None) {
        if (!isSemanticState(state)) { throw IllegalArgumentException("invalid declaration semantic state") }
        this.state = state
        this.provider = provider
        this.canonicalSignature = canonicalSignature
    }
}

public class DeclarationOrigin {
    public let kind: String
    public let macroSymbolId: ?String

    public init(kind!: String = "source", macroSymbolId!: ?String = None) {
        this.kind = kind
        this.macroSymbolId = macroSymbolId
    }
}

public class AnnotationDoc {
    public let spelling: String
    public let provenance: String
    public let provider: ?String

    public init(spelling: String, provenance!: String = "source", provider!: ?String = None) {
        if (spelling.isEmpty()) { throw IllegalArgumentException("annotation spelling cannot be empty") }
        if (provenance != "source" && provenance != "provider") {
            throw IllegalArgumentException("invalid annotation provenance")
        }
        if ((provenance == "source" && provider.isSome()) ||
            (provenance == "provider" && provider.isNone())) {
            throw IllegalArgumentException("annotation provenance/provider mismatch")
        }
        this.spelling = spelling
        this.provenance = provenance
        this.provider = provider
    }
}

public class SymbolDoc {
    public let id: String
    public let kind: String
    public let name: String
    public let qualifiedName: String
    public let packageName: String
    public let moduleId: String
    public let ownerId: ?String
    public let visibility: String
    public let returnType: ?TypeRef
    public let documentation: ?DocComment
    public let source: SourceRange
    public let headerSpelling: String
    public let semantic: SemanticInfo
    public let origin: DeclarationOrigin
    private let genericParametersStorage: ArrayList<String>
    private let parametersStorage: ArrayList<ParameterDoc>
    private let annotationsStorage: ArrayList<AnnotationDoc>
    private let typeRelationshipsStorage: ArrayList<TypeRelationship>
    private let symbolRelationshipsStorage: ArrayList<SymbolRelationship>

    public init(id: String, kind: String, name: String, qualifiedName: String, packageName: String,
        moduleId: String,
        visibility: String, source: SourceRange, headerSpelling: String, semantic: SemanticInfo,
        ownerId!: ?String = None, genericParameters!: Array<String> = [],
        parameters!: Array<ParameterDoc> = [], returnType!: ?TypeRef = None,
        annotations!: Array<AnnotationDoc> = [], typeRelationships!: Array<TypeRelationship> = [],
        symbolRelationships!: Array<SymbolRelationship> = [], documentation!: ?DocComment = None,
        origin!: DeclarationOrigin = DeclarationOrigin()) {
        this.id = id
        this.kind = kind
        this.name = name
        this.qualifiedName = qualifiedName
        this.packageName = packageName
        this.moduleId = moduleId
        this.ownerId = ownerId
        this.visibility = visibility
        this.source = source
        this.headerSpelling = headerSpelling
        this.semantic = semantic
        this.returnType = returnType
        this.documentation = documentation
        this.origin = origin
        this.genericParametersStorage = ArrayList<String>(genericParameters)
        this.parametersStorage = ArrayList<ParameterDoc>(parameters)
        this.annotationsStorage = ArrayList<AnnotationDoc>(annotations)
        this.typeRelationshipsStorage = ArrayList<TypeRelationship>(typeRelationships)
        this.symbolRelationshipsStorage = ArrayList<SymbolRelationship>(symbolRelationships)
    }

    public prop genericParameters: ReadOnlyList<String> { get() { genericParametersStorage } }
    public prop parameters: ReadOnlyList<ParameterDoc> { get() { parametersStorage } }
    public prop annotations: ReadOnlyList<AnnotationDoc> { get() { annotationsStorage } }
    public prop typeRelationships: ReadOnlyList<TypeRelationship> { get() { typeRelationshipsStorage } }
    public prop symbolRelationships: ReadOnlyList<SymbolRelationship> { get() { symbolRelationshipsStorage } }
}

public class AssetDoc {
    public let id: String
    public let mediaType: String
    public let sourcePath: String
    public let base64: String

    public init(id: String, mediaType: String, sourcePath: String, base64: String) {
        this.id = id
        this.mediaType = mediaType
        this.sourcePath = sourcePath
        this.base64 = base64
    }
}

public class OrphanDocComment {
    public let rawText: String
    public let source: SourceRange

    public init(rawText: String, source: SourceRange) {
        this.rawText = rawText
        this.source = source
    }
}

public class MacroInvocation {
    public let name: String
    public let source: SourceRange

    public init(name: String, source: SourceRange) {
        this.name = name
        this.source = source
    }
}

public class UnsupportedDeclaration {
    public let kind: String
    public let name: String
    public let reason: String
    public let source: SourceRange

    public init(kind: String, name: String, reason: String, source: SourceRange) {
        this.kind = kind
        this.name = name
        this.reason = reason
        this.source = source
    }
}

public class UnboundSemanticDeclaration {
    public let provider: String
    public let display: String
    public let reason: String

    public init(provider: String, display: String, reason: String) {
        this.provider = provider
        this.display = display
        this.reason = reason
    }
}

public class Diagnostic {
    public let severity: String
    public let code: String
    public let message: String
    public let source: ?SourceRange
    public let symbolId: ?String

    public init(severity: String, code: String, message: String,
        source!: ?SourceRange = None, symbolId!: ?String = None) {
        this.severity = severity
        this.code = code
        this.message = message
        this.source = source
        this.symbolId = symbolId
    }
}

public class DocumentationSet {
    public let schemaVersion: String
    public let generator: GeneratorInfo
    public let status: String
    public let project: ProjectInfo
    public let configuration: ConfigurationSnapshot
    private let providersStorage: ArrayList<ProviderInfo>
    private let modulesStorage: ArrayList<ModuleDoc>
    private let packagesStorage: ArrayList<PackageDoc>
    private let filesStorage: ArrayList<FileDoc>
    private let declarationsStorage: ArrayList<SymbolDoc>
    private let assetsStorage: ArrayList<AssetDoc>
    private let orphanDocCommentsStorage: ArrayList<OrphanDocComment>
    private let macroInvocationsStorage: ArrayList<MacroInvocation>
    private let unsupportedDeclarationsStorage: ArrayList<UnsupportedDeclaration>
    private let unboundSemanticDeclarationsStorage: ArrayList<UnboundSemanticDeclaration>
    private let diagnosticsStorage: ArrayList<Diagnostic>

    public init(generator: GeneratorInfo, status: String, project: ProjectInfo,
        configuration: ConfigurationSnapshot, providers!: Array<ProviderInfo> = [],
        modules!: Array<ModuleDoc> = [], packages!: Array<PackageDoc> = [], files!: Array<FileDoc> = [],
        declarations!: Array<SymbolDoc> = [], assets!: Array<AssetDoc> = [],
        orphanDocComments!: Array<OrphanDocComment> = [], macroInvocations!: Array<MacroInvocation> = [],
        unsupportedDeclarations!: Array<UnsupportedDeclaration> = [],
        unboundSemanticDeclarations!: Array<UnboundSemanticDeclaration> = [],
        diagnostics!: Array<Diagnostic> = []) {
        this.schemaVersion = DOC_IR_SCHEMA_VERSION
        this.generator = generator
        this.status = status
        this.project = project
        this.configuration = configuration
        this.providersStorage = ArrayList<ProviderInfo>(providers)
        this.modulesStorage = ArrayList<ModuleDoc>(modules)
        this.packagesStorage = ArrayList<PackageDoc>(packages)
        this.filesStorage = ArrayList<FileDoc>(files)
        this.declarationsStorage = ArrayList<SymbolDoc>(declarations)
        this.assetsStorage = ArrayList<AssetDoc>(assets)
        this.orphanDocCommentsStorage = ArrayList<OrphanDocComment>(orphanDocComments)
        this.macroInvocationsStorage = ArrayList<MacroInvocation>(macroInvocations)
        this.unsupportedDeclarationsStorage = ArrayList<UnsupportedDeclaration>(unsupportedDeclarations)
        this.unboundSemanticDeclarationsStorage = ArrayList<UnboundSemanticDeclaration>(unboundSemanticDeclarations)
        this.diagnosticsStorage = ArrayList<Diagnostic>(diagnostics)
    }

    public prop providers: ReadOnlyList<ProviderInfo> { get() { providersStorage } }
    public prop modules: ReadOnlyList<ModuleDoc> { get() { modulesStorage } }
    public prop packages: ReadOnlyList<PackageDoc> { get() { packagesStorage } }
    public prop files: ReadOnlyList<FileDoc> { get() { filesStorage } }
    public prop declarations: ReadOnlyList<SymbolDoc> { get() { declarationsStorage } }
    public prop assets: ReadOnlyList<AssetDoc> { get() { assetsStorage } }
    public prop orphanDocComments: ReadOnlyList<OrphanDocComment> { get() { orphanDocCommentsStorage } }
    public prop macroInvocations: ReadOnlyList<MacroInvocation> { get() { macroInvocationsStorage } }
    public prop unsupportedDeclarations: ReadOnlyList<UnsupportedDeclaration> { get() { unsupportedDeclarationsStorage } }
    public prop unboundSemanticDeclarations: ReadOnlyList<UnboundSemanticDeclaration> { get() { unboundSemanticDeclarationsStorage } }
    public prop diagnostics: ReadOnlyList<Diagnostic> { get() { diagnosticsStorage } }
}
