package cjdoc.model

import std.collection.*

public class MarkdownNodeMetadata {
    public let kind: String
    public let headingLevel: ?Int64
    public let listKind: ?String
    public let listStart: ?Int64
    public let listDelimiter: ?String
    public let listTight: ?Bool
    public let taskState: ?String
    public let codeKind: ?String
    public let fenceCharacter: ?String
    public let fenceLength: ?Int64
    public let infoRaw: ?String
    public let language: ?String
    public let attributesRaw: ?String
    public let tableHeader: ?Bool
    public let tableAlignment: ?String
    private let tableAlignmentsStorage: ArrayList<String>

    private init(kind: String, headingLevel!: ?Int64 = None, listKind!: ?String = None,
        listStart!: ?Int64 = None, listDelimiter!: ?String = None, listTight!: ?Bool = None,
        taskState!: ?String = None, codeKind!: ?String = None,
        fenceCharacter!: ?String = None, fenceLength!: ?Int64 = None,
        infoRaw!: ?String = None, language!: ?String = None, attributesRaw!: ?String = None,
        tableAlignments!: Array<String> = [], tableHeader!: ?Bool = None,
        tableAlignment!: ?String = None) {
        this.kind = kind
        this.headingLevel = headingLevel
        this.listKind = listKind
        this.listStart = listStart
        this.listDelimiter = listDelimiter
        this.listTight = listTight
        this.taskState = taskState
        this.codeKind = codeKind
        this.fenceCharacter = fenceCharacter
        this.fenceLength = fenceLength
        this.infoRaw = infoRaw
        this.language = language
        this.attributesRaw = attributesRaw
        this.tableAlignmentsStorage = ArrayList<String>(tableAlignments)
        this.tableHeader = tableHeader
        this.tableAlignment = tableAlignment
    }

    public static func forHeading(level: Int64): MarkdownNodeMetadata {
        MarkdownNodeMetadata("heading", headingLevel: Some(level))
    }

    public static func forList(listKind: String, start: Int64, delimiter: String,
        tight: Bool): MarkdownNodeMetadata {
        MarkdownNodeMetadata("list", listKind: Some(listKind), listStart: Some(start),
            listDelimiter: Some(delimiter), listTight: Some(tight))
    }

    public static func forListItem(taskState: String): MarkdownNodeMetadata {
        MarkdownNodeMetadata("list_item", taskState: Some(taskState))
    }

    public static func forCodeBlock(codeKind: String, fenceCharacter: ?String,
        fenceLength: Int64, infoRaw: String, language: String,
        attributesRaw: String): MarkdownNodeMetadata {
        MarkdownNodeMetadata("code_block", codeKind: Some(codeKind),
            fenceCharacter: fenceCharacter, fenceLength: Some(fenceLength),
            infoRaw: Some(infoRaw), language: Some(language), attributesRaw: Some(attributesRaw))
    }

    public static func forTable(alignments: Array<String>): MarkdownNodeMetadata {
        MarkdownNodeMetadata("table", tableAlignments: alignments)
    }

    public static func forTableRow(header: Bool): MarkdownNodeMetadata {
        MarkdownNodeMetadata("table_row", tableHeader: Some(header))
    }

    public static func forTableCell(alignment: String): MarkdownNodeMetadata {
        MarkdownNodeMetadata("table_cell", tableAlignment: Some(alignment))
    }

    public prop tableAlignments: ReadOnlyList<String> { get() { tableAlignmentsStorage } }
}

public class MarkdownNode {
    public let kind: String
    public let literal: String
    public let source: ?SourceRange
    public let metadata: ?MarkdownNodeMetadata
    private let childrenStorage: ArrayList<MarkdownNode>

    public init(kind: String, literal!: String = "", source!: ?SourceRange = None,
        children!: Array<MarkdownNode> = []) {
        this.kind = kind
        this.literal = literal
        this.source = source
        this.metadata = None
        this.childrenStorage = ArrayList<MarkdownNode>(children)
    }

    public init(kind: String, metadata: MarkdownNodeMetadata, literal!: String = "",
        source!: ?SourceRange = None, children!: Array<MarkdownNode> = []) {
        this.kind = kind
        this.literal = literal
        this.source = source
        this.metadata = Some(metadata)
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
    public let sourceApiSignature: SourceApiSignature
    public let semantic: SemanticInfo
    public let origin: DeclarationOrigin
    public let enumNonExhaustive: ?Bool
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
        origin!: DeclarationOrigin = DeclarationOrigin(),
        sourceApiSignature!: SourceApiSignature = SourceApiSignature("unavailable")) {
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
        this.sourceApiSignature = sourceApiSignature
        this.semantic = semantic
        this.returnType = returnType
        this.documentation = documentation
        this.origin = origin
        this.enumNonExhaustive = None
        this.genericParametersStorage = ArrayList<String>(genericParameters)
        this.parametersStorage = ArrayList<ParameterDoc>(parameters)
        this.annotationsStorage = ArrayList<AnnotationDoc>(annotations)
        this.typeRelationshipsStorage = ArrayList<TypeRelationship>(typeRelationships)
        this.symbolRelationshipsStorage = ArrayList<SymbolRelationship>(symbolRelationships)
    }

    public init(id: String, kind: String, name: String, qualifiedName: String, packageName: String,
        moduleId: String, visibility: String, source: SourceRange, headerSpelling: String,
        semantic: SemanticInfo, enumNonExhaustive: ?Bool,
        ownerId!: ?String = None, genericParameters!: Array<String> = [],
        parameters!: Array<ParameterDoc> = [], returnType!: ?TypeRef = None,
        annotations!: Array<AnnotationDoc> = [], typeRelationships!: Array<TypeRelationship> = [],
        symbolRelationships!: Array<SymbolRelationship> = [], documentation!: ?DocComment = None,
        origin!: DeclarationOrigin = DeclarationOrigin(),
        sourceApiSignature!: SourceApiSignature = SourceApiSignature("unavailable")) {
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
        this.sourceApiSignature = sourceApiSignature
        this.semantic = semantic
        this.returnType = returnType
        this.documentation = documentation
        this.origin = origin
        this.enumNonExhaustive = enumNonExhaustive
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
