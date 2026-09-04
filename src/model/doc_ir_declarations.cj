package cjdoc.model

import std.collection.*


public class PackageDoc {
    public let name: String
    public let moduleId: String
    private let sourceFilesStorage: ArrayList<String>
    private let symbolIdsStorage: ArrayList<String>
    private let reExportsStorage: ArrayList<ReExportDoc>

    public init(name: String, moduleId: String, sourceFiles!: Array<String> = [],
        symbolIds!: Array<String> = [], reExports!: Array<ReExportDoc> = []) {
        this.name = name
        this.moduleId = moduleId
        this.sourceFilesStorage = ArrayList<String>(sourceFiles)
        this.symbolIdsStorage = ArrayList<String>(symbolIds)
        this.reExportsStorage = ArrayList<ReExportDoc>(reExports)
    }

    public prop sourceFiles: ReadOnlyList<String> { get() { sourceFilesStorage } }
    public prop symbolIds: ReadOnlyList<String> { get() { symbolIdsStorage } }
    public prop reExports: ReadOnlyList<ReExportDoc> { get() { reExportsStorage } }
}

public class ReExportBinding {
    public let exposedName: String
    private let targetSymbolIdsStorage: ArrayList<String>

    public init(exposedName: String, targetSymbolIds!: Array<String> = []) {
        if (exposedName.isEmpty() || targetSymbolIds.isEmpty()) {
            throw IllegalArgumentException("re-export binding requires a name and target symbols")
        }
        this.exposedName = exposedName
        this.targetSymbolIdsStorage = ArrayList<String>(targetSymbolIds)
    }

    public prop targetSymbolIds: ReadOnlyList<String> { get() { targetSymbolIdsStorage } }
}

public class ReExportDoc {
    public let id: String
    public let kind: String
    public let organization: ?String
    public let targetPackageName: String
    public let targetModuleId: ?String
    public let alias: ?String
    public let state: String
    public let source: SourceRange
    private let bindingsStorage: ArrayList<ReExportBinding>

    public init(id: String, kind: String, targetPackageName: String, state: String,
        source: SourceRange, organization!: ?String = None, targetModuleId!: ?String = None,
        alias!: ?String = None, bindings!: Array<ReExportBinding> = []) {
        if (id.isEmpty() || targetPackageName.isEmpty() || !isSemanticState(state)) {
            throw IllegalArgumentException("invalid re-export identity or state")
        }
        match (kind) {
            case "single" | "alias" | "all" | "multi" | "packageAlias" => ()
            case _ => throw IllegalArgumentException("invalid re-export kind")
        }
        if (kind == "packageAlias" && alias.isNone()) {
            throw IllegalArgumentException("package alias re-export requires an alias")
        }
        if (state == "resolved" && targetModuleId.isNone()) {
            throw IllegalArgumentException("resolved re-export requires a target module")
        }
        this.id = id
        this.kind = kind
        this.organization = organization
        this.targetPackageName = targetPackageName
        this.targetModuleId = targetModuleId
        this.alias = alias
        this.state = state
        this.source = source
        this.bindingsStorage = ArrayList<ReExportBinding>(bindings)
    }

    public prop bindings: ReadOnlyList<ReExportBinding> { get() { bindingsStorage } }
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

