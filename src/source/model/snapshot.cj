protected package cjdoc.source.model

import cjdoc.documentation.comments.{CommentSpec, DocComment}
import cjdoc.documentation.metadata.DocumentationMetadataInventory
import cjdoc.model as public_model
import cjdoc.source.{Diagnostic, SourceLocation}
import cjdoc.source.cfg.CfgProfile
import std.collection.*

protected class TypeRef {
    protected let display: String
    protected let canonical: ?String
    protected let state: String
    protected let kind: String
    protected let nullable: Bool
    protected let arguments: ArrayList<TypeRef>

    protected init(display: String, canonical!: ?String = None, state!: String = "partial",
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
protected class SourceParameter {
    protected let name: String
    protected let typeSpelling: String
    protected let defaultExpression: ?String

    protected init(name: String, typeSpelling: String,
        defaultExpression!: ?String = None) {
        this.name = name
        this.typeSpelling = typeSpelling
        this.defaultExpression = defaultExpression
    }
}

protected class SourceTypeRelationship {
    protected let kind: String
    protected let targetSpelling: String

    protected init(kind: String, targetSpelling: String) {
        this.kind = kind
        this.targetSpelling = targetSpelling
    }
}

protected class SourceImportItem {
    protected let name: String
    protected let alias: ?String

    protected init(name: String, alias!: ?String = None) {
        this.name = name
        this.alias = alias
    }
}

protected class SourceReExport {
    protected let kind: String
    protected let organization: ?String
    protected let prefixPaths = ArrayList<String>()
    protected let identifier: String
    protected let alias: ?String
    protected let items = ArrayList<SourceImportItem>()
    protected let source: SourceLocation
    protected let normalizedSpec: String
    protected let packageName: String
    protected let moduleId: String

    protected init(kind: String, organization: ?String, identifier: String, alias: ?String,
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

protected class SourceSymbolRelationship {
    protected let kind: String
    protected let targetDisplay: String

    protected init(kind: String, targetDisplay: String) {
        this.kind = kind
        this.targetDisplay = targetDisplay
    }
}

protected class SourceDeclaration {
    protected let sourceKey: String
    protected let kind: String
    protected let name: String
    protected let packageName: String
    protected let moduleId: String
    protected var visibility: String
    protected let genericParameters = ArrayList<String>()
    protected let parameters = ArrayList<SourceParameter>()
    protected var returnTypeSpelling: ?String = None
    protected let annotations = ArrayList<String>()
    protected let modifiers = ArrayList<String>()
    protected let relationships = ArrayList<SourceTypeRelationship>()
    protected let symbolRelationships = ArrayList<SourceSymbolRelationship>()
    protected var documentation: ?DocComment = None
    protected let source: SourceLocation
    protected let sourceSignature: String
    protected let sourceApiSignatureTokens = ArrayList<String>()
    protected let isContainer: Bool
    // `Some(true)`/`Some(false)` is source truth for enum declarations.
    // Non-enum declarations use `None` so the fact cannot be mistaken for an
    // exhaustive enum during provider/binder projection.
    protected let enumNonExhaustive: ?Bool
    protected var ownerSourceKey: ?String = None
    protected var ownerIndex: Int64 = -1

    protected init(sourceKey: String, kind: String, name: String, packageName: String, moduleId: String,
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

protected class SourcePackage {
    protected let name: String
    protected let moduleId: String
    protected let sourceFiles = ArrayList<String>()

    protected init(name: String, moduleId: String) { this.name = name; this.moduleId = moduleId }
}

protected class SourceModule {
    protected let id: String
    protected let name: String
    protected let role: String
    protected let sourcePrefix: String
    protected let organization: ?String
    protected let manifestText: ?String
    protected let packageNames = ArrayList<String>()
    protected let dependencyIds = ArrayList<String>()

    protected init(id: String, name: String, role: String, sourcePrefix: String,
        organization!: ?String = None, manifestText!: ?String = None) {
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.organization = organization
        this.manifestText = manifestText
    }
}

// Immutable byte offsets derived from the exact normalized source text captured
// by the bounded frontend read. Retaining only line boundaries keeps later
// public/provider range mapping deterministic without reopening host paths.
protected let MAX_CAPTURED_SOURCE_LINES: Int64 = 1000000

protected class CapturedSourceIndex {
    protected let byteLength: Int64
    protected let available: Bool
    private let lineStarts = ArrayList<Int64>()

    protected init(source: String, maxLines!: Int64 = MAX_CAPTURED_SOURCE_LINES) {
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

    protected func byteOffset(line: Int64, column: Int64): ?Int64 {
        if (!available || line < 1 || column < 1) { return None }
        let lineIndex = line - 1
        if (lineIndex >= lineStarts.size) { return None }
        let start = lineStarts[lineIndex]
        let lineEnd = if (lineIndex + 1 < lineStarts.size) {
            lineStarts[lineIndex + 1] - 1
        } else {
            byteLength
        }
        let offset = start + column - 1
        if (offset > lineEnd) { return None }
        Some(offset)
    }

    protected func positionMatches(line: Int64, column: Int64, byteOffset: Int64): Bool {
        match (this.byteOffset(line, column)) {
            case Some(expected) => expected == byteOffset
            case None => false
        }
    }
}
protected class CapturedSourceFacts {
    protected let index: CapturedSourceIndex
    protected let rawDigest: ?String
    protected let normalizedDigest: ?String
    protected let resourceLimit: Bool

    protected init(index: CapturedSourceIndex, rawDigest!: ?String = None,
        normalizedDigest!: ?String = None, resourceLimit!: Bool = false) {
        this.index = index
        this.rawDigest = rawDigest
        this.normalizedDigest = normalizedDigest
        this.resourceLimit = resourceLimit
    }
}

// Host paths are retained only while generating one in-memory result. They are
// never exposed through the public model or serialized into Doc IR.
protected class SourceFileOrigin {
    protected let logicalPath: String
    protected let actualPath: String
    protected let actualRoot: String
    protected let logicalPrefix: String
    protected let capturedFacts: ?CapturedSourceFacts
    protected let provenance: ?public_model.SourceProvenance
    protected let packageName: String
    protected let moduleId: String
    protected let imports: Array<String>
    protected let packageImports: Array<String>
    protected let capturedSource: String

    protected init(logicalPath: String, actualPath: String, actualRoot: String,
        logicalPrefix: String, moduleId: String, capturedFacts!: ?CapturedSourceFacts = None,
        provenance!: ?public_model.SourceProvenance = None, packageName!: String = "",
        imports!: Array<String> = [], packageImports!: Array<String> = [],
        capturedSource!: String = "") {
        this.logicalPath = logicalPath
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.logicalPrefix = logicalPrefix
        this.capturedFacts = capturedFacts
        this.provenance = provenance
        this.packageName = packageName
        this.moduleId = moduleId
        this.imports = imports
        this.packageImports = packageImports
        this.capturedSource = capturedSource
    }
}

protected class DeclarationOrigin {
    protected let kind: String
    protected let macroSymbolId: ?String

    protected init(kind: String, macroSymbolId!: ?String = None) {
        this.kind = kind
        this.macroSymbolId = macroSymbolId
    }
}

protected class UnsupportedDeclaration {
    protected let kind: String
    protected let name: String
    protected let reason: String
    protected let source: SourceLocation
    protected let origin: DeclarationOrigin

    protected init(kind: String, name: String, reason: String, source: SourceLocation,
        origin!: DeclarationOrigin = DeclarationOrigin("source")) {
        this.kind = kind
        this.name = name
        this.reason = reason
        this.source = source
        this.origin = origin
    }
}

protected class OrphanDocComment {
    protected let rawText: String
    protected let source: SourceLocation

    protected init(rawText: String, source: SourceLocation) {
        this.rawText = rawText
        this.source = source
    }
}

protected class MacroInvocation {
    protected let name: String
    protected let source: SourceLocation

    protected init(name: String, source: SourceLocation) {
        this.name = name
        this.source = source
    }
}

protected class SourceMetadataModuleRoot {
    protected let moduleId: String
    protected let actualRoot: String
    protected let configPath: String

    protected init(moduleId: String, actualRoot: String, configPath: String) {
        this.moduleId = moduleId
        this.actualRoot = actualRoot
        this.configPath = configPath
    }
}

protected class SourceSnapshot {
    protected let projectName: String
    protected let modules = ArrayList<SourceModule>()
    protected let metadataModuleRoots = ArrayList<SourceMetadataModuleRoot>()
    protected var metadataInventory = DocumentationMetadataInventory()
    // Module-scoped author comment policies, captured after source collection
    // and before semantics and binding. Never serialized into Doc IR.
    protected let commentSpecs = HashMap<String, CommentSpec>()
    protected var cfgProfile = CfgProfile()
    protected var manifestText: ?String = None
    protected let packages = ArrayList<SourcePackage>()
    protected let declarations = ArrayList<SourceDeclaration>()
    protected let reExports = ArrayList<SourceReExport>()
    protected let sourceFileOrigins = ArrayList<SourceFileOrigin>()
    protected let orphanDocComments = ArrayList<OrphanDocComment>()
    protected let macroInvocations = ArrayList<MacroInvocation>()
    protected let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    protected let diagnostics = ArrayList<Diagnostic>()

    protected init(projectName: String) { this.projectName = projectName }
}
