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

