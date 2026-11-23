protected package cjdoc.semantic

import cjdoc.documentation.comments.DocComment
import cjdoc.documentation.metadata.DocumentationMetadataInventory
import cjdoc.source.{Diagnostic, moduleId}
import cjdoc.source.cfg.CfgProfile
import cjdoc.source.lexing.sourceApiSignatureTokens
import cjdoc.source.model.{DeclarationOrigin, MacroInvocation, OrphanDocComment, SourceFileOrigin, SourceSnapshot, TypeRef, UnsupportedDeclaration}
import std.collection.*
import cjdoc.model as api_model

protected class SemanticParameter {
    protected let name: String
    protected let typeRef: TypeRef

    protected init(name: String, typeRef: TypeRef) {
        this.name = name
        this.typeRef = typeRef
    }
}

protected class SemanticDeclaration {
    protected let sourceKey: String
    protected let kind: String
    protected let name: String
    protected let packageName: String
    protected let moduleId: String
    protected let ownerSourceKey: ?String
    protected let visibility: String
    protected let genericParameters = ArrayList<String>()
    protected let parameters = ArrayList<SemanticParameter>()
    protected var returnType: ?TypeRef = None
    protected let annotations = ArrayList<String>()
    protected let providerAnnotations = ArrayList<String>()
    protected let relationships = ArrayList<TypeRelationship>()
    protected let symbolRelationships = ArrayList<SymbolRelationship>()
    protected let state: String
    protected let provider: String
    protected let canonicalSignature: ?String
    protected let isContainer: Bool
    protected let enumNonExhaustive: ?Bool

    protected init(sourceKey: String, kind: String, name: String, packageName: String, moduleId: String,
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

protected class ModuleSemanticResult {
    protected let moduleId: String
    protected let provider: String
    protected let providerVersion: String
    protected let capabilities: SemanticCapabilities
    protected let declarations = ArrayList<SemanticDeclaration>()
    protected let diagnostics = ArrayList<Diagnostic>()

    protected init(moduleId: String, provider: String, providerVersion: String,
        capabilities: SemanticCapabilities) {
        this.moduleId = moduleId
        this.provider = provider
        this.providerVersion = providerVersion
        this.capabilities = capabilities
    }
}

protected class SemanticResult {
    protected let modules = ArrayList<ModuleSemanticResult>()
    protected let diagnostics = ArrayList<Diagnostic>()
}

protected class SemanticCapabilities {
    protected let sourceBinding: Bool
    protected let ownership: Bool
    protected let visibility: Bool
    protected let canonicalTypes: Bool
    protected let canonicalSignatures: Bool
    protected let symbolRelationships: Bool
    protected let annotations: Bool

    protected init(sourceBinding: Bool, ownership: Bool, visibility: Bool,
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
protected class SemanticBindingStats {
    protected let moduleId: String
    protected let provider: String
    protected let providerVersion: String
    protected let capabilities: SemanticCapabilities
    protected var matched: Int64 = 0
    protected var missing: Int64 = 0
    protected var ambiguous: Int64 = 0
    protected var extraneous: Int64 = 0
    protected var contractViolations: Int64 = 0

    protected init(moduleId: String, provider: String, providerVersion: String,
        capabilities: SemanticCapabilities) {
        this.moduleId = moduleId
        this.provider = provider
        this.providerVersion = providerVersion
        this.capabilities = capabilities
    }
}


protected class TypeRelationship {
    protected let kind: String
    protected let target: TypeRef

    protected init(kind: String, target: TypeRef) {
        this.kind = kind
        this.target = target
    }
}

protected class SymbolRelationship {
    protected let kind: String
    protected let targetDisplay: String
    protected var state: String
    protected var targetSymbolId: ?String
    protected let targetSourceKey: ?String

    protected init(kind: String, targetDisplay: String, state: String,
        targetSymbolId!: ?String = None, targetSourceKey!: ?String = None) {
        this.kind = kind
        this.targetDisplay = targetDisplay
        this.state = state
        this.targetSymbolId = targetSymbolId
        this.targetSourceKey = targetSourceKey
    }
}

protected interface SemanticProvider {
    func providerName(): String
    func providerVersion(): String
    func analyze(source: SourceSnapshot): SemanticResult
}
