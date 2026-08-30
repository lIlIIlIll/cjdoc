package cjdoc.provider

import cjdoc.model.*
import std.collection.*
import std.sync.AtomicInt64

private let NEXT_SOURCE_DECLARATION_ISSUER_ID = AtomicInt64(1)

public class SourceDeclarationId {
    private let encoded: String
    let issuerId: Int64

    init(encoded: String, issuerId: Int64) {
        if (encoded.isEmpty()) { throw IllegalArgumentException("source declaration id cannot be empty") }
        this.encoded = encoded
        this.issuerId = issuerId
    }

    public func serialize(): String { encoded }

    public operator func ==(other: SourceDeclarationId): Bool {
        encoded == other.encoded && issuerId == other.issuerId
    }
    public operator func !=(other: SourceDeclarationId): Bool { !(this == other) }
}

public class SourceDeclarationIssuer {
    private let id: Int64

    public init() { id = NEXT_SOURCE_DECLARATION_ISSUER_ID.fetchAdd(1) }

    public func issue(encoded: String): SourceDeclarationId {
        SourceDeclarationId(encoded, id)
    }

    public func owns(candidate: SourceDeclarationId): Bool { candidate.issuerId == id }
}

public class SourceParameterView {
    public let name: String
    public let typeSpelling: String
    public let defaultExpression: ?String

    public init(name: String, typeSpelling: String, defaultExpression!: ?String = None) {
        this.name = name
        this.typeSpelling = typeSpelling
        this.defaultExpression = defaultExpression
    }
}

public class SourceDeclarationView {
    public let id: SourceDeclarationId
    public let kind: String
    public let name: String
    public let packageName: String
    public let ownerId: ?SourceDeclarationId
    public let visibility: String
    public let genericArity: Int64
    public let returnTypeSpelling: ?String
    public let source: SourceRange
    public let headerSpelling: String
    private let parametersStorage: ArrayList<SourceParameterView>
    private let annotationsStorage: ArrayList<String>

    public init(id: SourceDeclarationId, kind: String, name: String, packageName: String,
        visibility: String, genericArity: Int64, source: SourceRange, headerSpelling: String,
        ownerId!: ?SourceDeclarationId = None, parameters!: Array<SourceParameterView> = [],
        returnTypeSpelling!: ?String = None, annotations!: Array<String> = []) {
        this.id = id
        this.kind = kind
        this.name = name
        this.packageName = packageName
        this.ownerId = ownerId
        this.visibility = visibility
        this.genericArity = genericArity
        this.returnTypeSpelling = returnTypeSpelling
        this.source = source
        this.headerSpelling = headerSpelling
        this.parametersStorage = ArrayList<SourceParameterView>(parameters)
        this.annotationsStorage = ArrayList<String>(annotations)
    }

    public prop parameters: ReadOnlyList<SourceParameterView> { get() { parametersStorage } }
    public prop annotations: ReadOnlyList<String> { get() { annotationsStorage } }
}

public class SemanticModule {
    public let id: String
    public let name: String
    public let role: String
    public let sourcePrefix: String

    public init(id: String, name: String, role: String, sourcePrefix: String) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
    }
}

public class SemanticParameter {
    public let name: String
    public let typeRef: TypeRef

    public init(name: String, typeRef: TypeRef) {
        this.name = name
        this.typeRef = typeRef
    }
}

public class SemanticTypeRelationship {
    public let kind: String
    public let target: TypeRef

    public init(kind: String, target: TypeRef) {
        if (kind.isEmpty()) { throw IllegalArgumentException("semantic type relationship kind cannot be empty") }
        this.kind = kind
        this.target = target
    }
}

public class SemanticSymbolRelationship {
    public let kind: String
    public let targetDisplay: String
    public let state: String
    public let targetSourceId: ?SourceDeclarationId
    public let targetSymbolId: ?String

    public init(kind: String, targetDisplay: String, state: String,
        targetSourceId!: ?SourceDeclarationId = None, targetSymbolId!: ?String = None) {
        if (kind.isEmpty() || !isSemanticState(state)) {
            throw IllegalArgumentException("invalid semantic symbol relationship")
        }
        if (targetSourceId.isSome() && targetSymbolId.isSome()) {
            throw IllegalArgumentException("symbol relationship accepts one target identity")
        }
        if (state == "resolved" && targetSourceId.isNone() && targetSymbolId.isNone()) {
            throw IllegalArgumentException("resolved symbol relationship requires a target identity")
        }
        this.kind = kind
        this.targetDisplay = targetDisplay
        this.state = state
        this.targetSourceId = targetSourceId
        this.targetSymbolId = targetSymbolId
    }
}

public class SemanticDeclaration {
    public let sourceId: SourceDeclarationId
    public let state: String
    public let visibility: ?String
    public let ownerId: ?SourceDeclarationId
    public let returnType: ?TypeRef
    public let canonicalSignature: ?String
    public let annotationsProvided: Bool
    private let parametersStorage: ArrayList<SemanticParameter>
    private let annotationsStorage: ArrayList<String>
    private let typeRelationshipsStorage: ArrayList<SemanticTypeRelationship>
    private let symbolRelationshipsStorage: ArrayList<SemanticSymbolRelationship>

    public init(sourceId: SourceDeclarationId, state: String, visibility!: ?String = None,
        ownerId!: ?SourceDeclarationId = None, parameters!: Array<SemanticParameter> = [],
        returnType!: ?TypeRef = None, canonicalSignature!: ?String = None,
        annotations!: Array<String> = [], annotationsProvided!: Bool = false,
        typeRelationships!: Array<SemanticTypeRelationship> = [],
        symbolRelationships!: Array<SemanticSymbolRelationship> = []) {
        if (!isSemanticState(state)) { throw IllegalArgumentException("invalid semantic declaration state") }
        this.sourceId = sourceId
        this.state = state
        this.visibility = visibility
        this.ownerId = ownerId
        this.returnType = returnType
        this.canonicalSignature = canonicalSignature
        this.annotationsProvided = annotationsProvided || !annotations.isEmpty()
        this.parametersStorage = ArrayList<SemanticParameter>(parameters)
        this.annotationsStorage = ArrayList<String>(annotations)
        this.typeRelationshipsStorage = ArrayList<SemanticTypeRelationship>(typeRelationships)
        this.symbolRelationshipsStorage = ArrayList<SemanticSymbolRelationship>(symbolRelationships)
    }

    public prop parameters: ReadOnlyList<SemanticParameter> { get() { parametersStorage } }
    public prop annotations: ReadOnlyList<String> { get() { annotationsStorage } }
    public prop typeRelationships: ReadOnlyList<SemanticTypeRelationship> { get() { typeRelationshipsStorage } }
    public prop symbolRelationships: ReadOnlyList<SemanticSymbolRelationship> {
        get() { symbolRelationshipsStorage }
    }
}

public class SemanticBatch {
    public let capabilities: SemanticCapabilities
    private let declarationsStorage: ArrayList<SemanticDeclaration>
    private let diagnosticsStorage: ArrayList<Diagnostic>

    public init(capabilities: SemanticCapabilities, declarations!: Array<SemanticDeclaration> = [],
        diagnostics!: Array<Diagnostic> = []) {
        this.capabilities = capabilities
        this.declarationsStorage = ArrayList<SemanticDeclaration>(declarations)
        this.diagnosticsStorage = ArrayList<Diagnostic>(diagnostics)
    }

    public prop declarations: ReadOnlyList<SemanticDeclaration> { get() { declarationsStorage } }
    public prop diagnostics: ReadOnlyList<Diagnostic> { get() { diagnosticsStorage } }
}

public interface SemanticProviderSession {
    func analyze(declarations: ReadOnlyList<SourceDeclarationView>): SemanticBatch
    func close(): Unit
}

public interface SemanticProviderFactory {
    prop name: String
    prop version: String
    func open(module: SemanticModule): SemanticProviderSession
}

public class UnavailableSemanticProviderSession <: SemanticProviderSession {
    public func analyze(_: ReadOnlyList<SourceDeclarationView>): SemanticBatch {
        SemanticBatch(SemanticCapabilities(false, false, false, false, false))
    }

    public func close(): Unit {}
}

public class UnavailableSemanticProviderFactory <: SemanticProviderFactory {
    public prop name: String { get() { "ast-fallback" } }
    public prop version: String { get() { "1" } }

    public func open(_: SemanticModule): SemanticProviderSession {
        UnavailableSemanticProviderSession()
    }
}
