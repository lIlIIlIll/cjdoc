package cjdoc.model

import std.collection.*

// STS 1.2.0 std.core.cjo declares String/Array; the builtin-name probe
// confirms String/Array/Char lex as IDENTIFIER (highlight-builtin-identifiers.txt).
// This closed presentation list never creates semantic type identity or links.
public func codeBuiltinIdentifierKind(kind: String, spelling: String): String {
    if (kind != "IDENTIFIER") { return "" }
    match (spelling) {
        case "String" | "Array" | "Char" => "type"
        case _ => ""
    }
}

public class CodeSpan {
    public let startByte: Int64
    public let endByte: Int64
    public let kind: String
    public init(startByte: Int64, endByte: Int64, kind: String) {
        if (startByte < 0 || endByte <= startByte || codeKindClass(kind).isEmpty()) {
            throw IllegalArgumentException("invalid code span")
        }
        this.startByte = startByte; this.endByte = endByte; this.kind = kind
    }
}

// Presentation metadata is independent of declaration and source-contract identity.
public class CodeHighlight {
    public let language: String
    public let sourceHash: String
    public let byteLength: Int64
    public let engineId: String
    public let engineRevision: String
    public let state: String
    public let reason: ?String
    private let spansStorage: ArrayList<CodeSpan>
    public init(language: String, sourceHash: String, byteLength: Int64, engineId: String,
        engineRevision: String, state: String, reason: ?String, spans: Array<CodeSpan>) {
        if (byteLength < 0 || sourceHash.isEmpty() || engineId.isEmpty() || engineRevision.isEmpty() ||
            (state != "complete" && state != "partial" && state != "plain") ||
            (state == "plain" && (reason.isNone() || !spans.isEmpty())) || spans.size > 65536) {
            throw IllegalArgumentException("invalid code highlight")
        }
        if (let Some(value) <- reason) {
            let reasons = ["disabled", "no-language", "unsupported", "missing-metadata", "backend-unavailable",
                "invalid-spans", "resource-limit", "lexer-failed", "unterminated-token"]
            if (!reasons.contains(value)) { throw IllegalArgumentException("invalid code highlight reason") }
        }
        var previousEnd: Int64 = 0
        for (span in spans) {
            if (span.startByte < previousEnd || span.endByte > byteLength) {
                throw IllegalArgumentException("invalid code highlight spans")
            }
            previousEnd = span.endByte
        }
        if (sourceHash.size != 64) { throw IllegalArgumentException("invalid highlight source hash") }
        for (byte in sourceHash.toArray()) {
            if (!((byte >= b'0' && byte <= b'9') || (byte >= b'a' && byte <= b'f'))) {
                throw IllegalArgumentException("invalid highlight source hash")
            }
        }
        this.language = language; this.sourceHash = sourceHash; this.byteLength = byteLength
        this.engineId = engineId; this.engineRevision = engineRevision; this.state = state
        this.reason = reason; this.spansStorage = ArrayList<CodeSpan>(spans)
    }
    public prop spans: ReadOnlyList<CodeSpan> { get() { spansStorage } }
    public func matchesSource(raw: String): Bool {
        if (raw.size != byteLength || contractFingerprint(raw) != sourceHash) { return false }
        for (span in spansStorage) {
            if ((raw[span.startByte] & 0xC0) == 0x80 ||
                (span.endByte < raw.size && (raw[span.endByte] & 0xC0) == 0x80)) { return false }
        }
        true
    }
}

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
    public let codeHighlight: ?CodeHighlight
    public let tableHeader: ?Bool
    public let tableAlignment: ?String
    public var semanticTarget: ?String
    public var semanticState: ?String
    public var semanticTargetSymbolId: ?String
    public var semanticExternalUrl: ?String
    public var semanticNavigation: ?TypeNavigation
    private let tableAlignmentsStorage: ArrayList<String>

    private init(kind: String, headingLevel!: ?Int64 = None, listKind!: ?String = None,
        listStart!: ?Int64 = None, listDelimiter!: ?String = None, listTight!: ?Bool = None,
        taskState!: ?String = None, codeKind!: ?String = None,
        fenceCharacter!: ?String = None, fenceLength!: ?Int64 = None,
        infoRaw!: ?String = None, language!: ?String = None, attributesRaw!: ?String = None,
        tableAlignments!: Array<String> = [], tableHeader!: ?Bool = None,
        tableAlignment!: ?String = None, semanticTarget!: ?String = None,
        semanticState!: ?String = None, semanticTargetSymbolId!: ?String = None,
        semanticExternalUrl!: ?String = None, codeHighlight!: ?CodeHighlight = None,
        semanticNavigation!: ?TypeNavigation = None) {
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
        this.codeHighlight = codeHighlight
        this.tableAlignmentsStorage = ArrayList<String>(tableAlignments)
        this.tableHeader = tableHeader
        this.tableAlignment = tableAlignment
        this.semanticTarget = semanticTarget
        this.semanticState = semanticState
        this.semanticTargetSymbolId = semanticTargetSymbolId
        this.semanticExternalUrl = semanticExternalUrl
        this.semanticNavigation = semanticNavigation
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
        attributesRaw: String, codeHighlight!: ?CodeHighlight = None): MarkdownNodeMetadata {
        MarkdownNodeMetadata("code_block", codeKind: Some(codeKind),
            fenceCharacter: fenceCharacter, fenceLength: Some(fenceLength),
            infoRaw: Some(infoRaw), language: Some(language), attributesRaw: Some(attributesRaw),
            codeHighlight: codeHighlight)
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

    public static func forSemanticLink(target: String, state: String,
        targetSymbolId!: ?String = None, externalUrl!: ?String = None,
        semanticNavigation!: ?TypeNavigation = None): MarkdownNodeMetadata {
        if (target.isEmpty()) { throw IllegalArgumentException("semantic link target cannot be empty") }
        if (state != "resolved" && state != "unresolved" && state != "ambiguous" && state != "unavailable") {
            throw IllegalArgumentException("invalid semantic link state")
        }
        MarkdownNodeMetadata("semantic_link", semanticTarget: Some(target), semanticState: Some(state),
            semanticTargetSymbolId: targetSymbolId, semanticExternalUrl: externalUrl,
            semanticNavigation: semanticNavigation)
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
    public let defaultLanguage: ?String
    private let localizedTextsStorage: ArrayList<DocumentationText>

    public init(rawText: String, summary: String, description: String, markdown: MarkdownNode,
        tags!: Array<DocTag> = [], defaultLanguage!: ?String = None,
        localizedTexts!: Array<DocumentationText> = []) {
        this.rawText = rawText
        this.summary = summary
        this.description = description
        this.markdown = markdown
        this.tagsStorage = ArrayList<DocTag>(tags)
        if (let Some(language) <- defaultLanguage) {
            if (documentationLanguage(language) != language) { throw IllegalArgumentException("default documentation language must be normalized") }
        }
        this.defaultLanguage = defaultLanguage
        this.localizedTextsStorage = ArrayList<DocumentationText>(localizedTexts)
    }

    public prop tags: ReadOnlyList<DocTag> { get() { tagsStorage } }
    public prop localizedTexts: ReadOnlyList<DocumentationText> { get() { localizedTextsStorage } }
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
    public let signatureHighlight: ?CodeHighlight
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
        sourceApiSignature!: SourceApiSignature = SourceApiSignature("unavailable"),
        signatureHighlight!: ?CodeHighlight = None) {
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
        this.signatureHighlight = signatureHighlight
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
        sourceApiSignature!: SourceApiSignature = SourceApiSignature("unavailable"),
        signatureHighlight!: ?CodeHighlight = None) {
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
        this.signatureHighlight = signatureHighlight
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
    // Generation-only provenance; not reconstructed from diagnostic codes or JSON.
    private var highlightFailure = false
    protected prop isHighlightFailure: Bool { get() { highlightFailure } }
    protected func markHighlightFailure(): Unit { highlightFailure = true }
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
    /** Completeness of API collection, independent of presentation diagnostics. */
    public let apiCollectionState: String
    /** Documentation publication label; independent of API package and source revisions. */
    public let documentationRevision: String
    public let project: ProjectInfo
    public let configuration: ConfigurationSnapshot
    public let languageOptions: ?DocumentationLanguageOptions
    public let readingLanguage: ?String
    private let dependenciesStorage: ArrayList<DependencyInstance>
    private let documentSetsStorage: ArrayList<DocumentSetIdentity>
    private let pagesStorage: ArrayList<DocumentationPage>
    private let externalDocumentationStorage: ArrayList<ExternalDocumentationReference>
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
        diagnostics!: Array<Diagnostic> = [], languageOptions!: ?DocumentationLanguageOptions = None,
        pages!: Array<DocumentationPage> = [], readingLanguage!: ?String = None,
        externalDocumentation!: Array<ExternalDocumentationReference> = [],
        dependencies!: Array<DependencyInstance> = [], documentSets!: Array<DocumentSetIdentity> = [],
        apiCollectionState!: ?String = None, documentationRevision!: String = "") {
        this.schemaVersion = DOC_IR_SCHEMA_VERSION
        this.generator = generator
        this.documentationRevision = documentationRevision
        this.status = status
        this.apiCollectionState = apiCollectionState.getOrDefault({ =>
            if (status == "complete") { "resolved" }
            else if (status == "partial") { "partial" } else { "unavailable" }
        })
        if (this.apiCollectionState != "resolved" && this.apiCollectionState != "partial" &&
            this.apiCollectionState != "unavailable") {
            throw IllegalArgumentException("API collection state must be resolved, partial, or unavailable")
        }
        this.project = project
        this.configuration = configuration
        this.languageOptions = languageOptions
        if (let Some(language) <- readingLanguage) {
            if (documentationLanguage(language) != language) { throw IllegalArgumentException("reading language must be normalized") }
        }
        this.readingLanguage = readingLanguage
        this.dependenciesStorage = ArrayList<DependencyInstance>(dependencies)
        this.documentSetsStorage = ArrayList<DocumentSetIdentity>(documentSets)
        this.pagesStorage = ArrayList<DocumentationPage>(pages)
        this.externalDocumentationStorage = ArrayList<ExternalDocumentationReference>(externalDocumentation)
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
    public func appendDiagnostic(diagnostic: Diagnostic): Unit {
        diagnosticsStorage.add(diagnostic)
    }

    public prop dependencies: ReadOnlyList<DependencyInstance> { get() { dependenciesStorage } }
    public prop documentSets: ReadOnlyList<DocumentSetIdentity> { get() { documentSetsStorage } }
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
    public prop pages: ReadOnlyList<DocumentationPage> { get() { pagesStorage } }
    public prop externalDocumentation: ReadOnlyList<ExternalDocumentationReference> { get() { externalDocumentationStorage } }
}
