protected package cjdoc.binding

import cjdoc.documentation.comments.DocComment
import cjdoc.documentation.metadata.DocumentationMetadataInventory
import cjdoc.documentation.comments.CommentSpec
import cjdoc.model.DocumentationMetadata
import cjdoc.semantic.{SemanticBindingStats, SymbolRelationship, TypeRelationship}
import cjdoc.source.{Diagnostic, moduleId, SourceLocation}
import cjdoc.source.cfg.CfgProfile
import cjdoc.source.lexing.sourceApiSignatureTokens
import cjdoc.source.model.{DeclarationOrigin, MacroInvocation, OrphanDocComment, SourceFileOrigin, SourceSnapshot, TypeRef, UnsupportedDeclaration}
import std.collection.*

protected class ParameterDoc {
    protected let name: String
    protected let typeRef: TypeRef
    protected let defaultExpression: ?String
    protected var documentation: ?String = None

    protected init(name: String, typeRef: TypeRef,
        defaultExpression!: ?String = None) {
        this.name = name
        this.typeRef = typeRef
        this.defaultExpression = defaultExpression
    }
}



protected class DocAnnotation {
    protected let spelling: String
    protected let provenance: String
    protected let provider: ?String

    protected init(spelling: String, provenance!: String = "source", provider!: ?String = None) {
        this.spelling = spelling
        this.provenance = provenance
        this.provider = provider
    }
}

protected class SymbolDoc {
    protected var id: String = ""
    protected let kind: String
    protected let name: String
    protected var qualifiedName: String = ""
    protected let packageName: String
    protected let moduleId: String
    protected var ownerId: ?String = None
    protected var visibility: String
    protected let genericParameters = ArrayList<String>()
    protected let parameters = ArrayList<ParameterDoc>()
    protected var returnType: ?TypeRef = None
    protected let annotations = ArrayList<DocAnnotation>()
    protected let relationships = ArrayList<TypeRelationship>()
    protected let symbolRelationships = ArrayList<SymbolRelationship>()
    protected var documentation: ?DocComment = None
    protected let source: SourceLocation
    protected let sourceSignature: String
    protected let sourceApiSignatureTokens = ArrayList<String>()
    protected let semanticState: String
    protected let semanticProvider: String
    protected let canonicalSignature: ?String
    protected let isContainer: Bool
    protected let enumNonExhaustive: ?Bool
    protected let origin: DeclarationOrigin
    var ownerIndex: Int64 = -1

    protected init(kind: String, name: String, packageName: String, moduleId: String, visibility: String,
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

protected class ReExportBinding {
    protected let exposedName: String
    protected let importedName: String
    protected let targetSymbolIds = ArrayList<String>()

    protected init(exposedName: String, importedName: String, targetSymbolIds!: Array<String> = []) {
        this.exposedName = exposedName
        this.importedName = importedName
        this.targetSymbolIds.add(all: targetSymbolIds)
    }
}

protected class ReExportDoc {
    protected let id: String
    protected let kind: String
    protected let organization: ?String
    protected let targetPackageName: String
    protected let targetModuleId: ?String
    protected let alias: ?String
    protected let state: String
    protected let source: SourceLocation
    protected let bindings = ArrayList<ReExportBinding>()

    protected init(id: String, kind: String, organization: ?String, targetPackageName: String,
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

protected class PackageDoc {
    protected let name: String
    protected let moduleId: String
    protected let sourceFiles = ArrayList<String>()
    protected let symbolIds = ArrayList<String>()
    protected let reExports = ArrayList<ReExportDoc>()

    protected init(name: String, moduleId: String) { this.name = name; this.moduleId = moduleId }
}

protected class ModuleDoc {
    protected let id: String
    protected let name: String
    protected let role: String
    protected let sourcePrefix: String
    protected let organization: ?String
    protected let packageNames = ArrayList<String>()
    protected let dependencyIds = ArrayList<String>()

    protected init(id: String, name: String, role: String, sourcePrefix: String,
        organization!: ?String = None) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.organization = organization
    }
}

protected class DocumentationSet {
    protected let projectName: String
    // Captured at the source/provider boundary, before documentation preparation.
    protected var apiCollectionState: String = "unavailable"
    protected let modules = ArrayList<ModuleDoc>()
    protected let packages = ArrayList<PackageDoc>()
    protected let symbols = ArrayList<SymbolDoc>()
    protected let sourceFileOrigins = ArrayList<SourceFileOrigin>()
    protected let orphanDocComments = ArrayList<OrphanDocComment>()
    protected let macroInvocations = ArrayList<MacroInvocation>()
    protected let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    protected let diagnostics = ArrayList<Diagnostic>()
    protected let semanticBindings = ArrayList<SemanticBindingStats>()
    protected var cfgProfile = CfgProfile()
    protected var metadata: DocumentationMetadata = DocumentationMetadata()
    protected var metadataInventory = DocumentationMetadataInventory()
    // Captured module comment policies; generation-only, never serialized.
    protected let commentSpecs = HashMap<String, CommentSpec>()

    protected init(projectName: String) { this.projectName = projectName }
}

protected func isExternallyVisible(symbol: SymbolDoc): Bool {
    return symbol.visibility == "public" || symbol.visibility == "protected"
}
