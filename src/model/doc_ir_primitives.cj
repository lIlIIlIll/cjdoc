package cjdoc.model

import std.collection.*

public let DOC_IR_SCHEMA_VERSION = "cjdoc.doc-ir/8"
public let DOC_IR_V7_SCHEMA_VERSION = "cjdoc.doc-ir/7"
public let DOC_IR_V6_SCHEMA_VERSION = "cjdoc.doc-ir/6"
public let DOC_IR_MAX_TYPE_DEPTH: Int64 = 64
public let DOC_IR_MAX_MARKDOWN_DEPTH: Int64 = 64
public let DOC_IR_MAX_FENCE_LENGTH: Int64 = 1024
protected let DOC_IR_MAX_JSON_STRING_BYTES: Int64 = 24 * 1024 * 1024
// The release runtime uses a 256 MiB default heap. Keep the complete JSON text,
// parsed tree, schema evaluation graph, and typed Doc IR simultaneously bounded
// by limiting input to one eighth of that heap and independently bounding its
// structured shape below.
protected let DOC_IR_MAX_JSON_DOCUMENT_BYTES: Int64 = 32 * 1024 * 1024
protected let DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES: Int64 = 64 * 1024 * 1024
protected let DOC_IR_MAX_SCHEMA_OBJECTS: Int64 = 65536
protected let DOC_IR_MAX_SCHEMA_ARRAY_ITEMS: Int64 = 100000
protected let DOC_IR_MAX_TYPE_OCCURRENCES: Int64 = 32768
protected let DOC_IR_MAX_TYPE_EDGES: Int64 = 32768
protected let DOC_IR_MAX_MARKDOWN_OCCURRENCES: Int64 = 32768
protected let DOC_IR_MAX_MARKDOWN_EDGES: Int64 = 32768
protected let DOC_IR_MAX_PROVIDER_IDENTITY_BYTES: Int64 = 1024
protected let DOC_IR_MAX_ORDERED_LIST_NUMBER: Int64 = 999999999
protected let DOC_IR_MAX_REEXPORT_EDGES: Int64 = 100000

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

public class SourceApiSignature {
    public let state: String
    private let tokensStorage: ArrayList<String>

    public init(state: String, tokens!: Array<String> = []) {
        if (state != "available" && state != "unavailable") {
            throw IllegalArgumentException("invalid source API signature state")
        }
        if ((state == "available" && tokens.isEmpty()) ||
            (state == "unavailable" && !tokens.isEmpty())) {
            throw IllegalArgumentException("source API signature state/tokens mismatch")
        }
        for (token in tokens) {
            if (token.isEmpty()) { throw IllegalArgumentException("source API signature token cannot be empty") }
        }
        this.state = state
        this.tokensStorage = ArrayList<String>(tokens)
    }

    public prop tokens: ReadOnlyList<String> { get() { tokensStorage } }
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

private func portableModuleSourcePrefix(value: String): Bool {
    if (value.isEmpty()) { return true }
    if (value.startsWith("/") || value.endsWith("/") || value.contains("//") ||
        value.contains("\\")) { return false }
    let segments = value.split("/")
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    let first = segments[0].toArray()
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'A' && first[0] <= b'Z') ||
        (first[0] >= b'a' && first[0] <= b'z'))) {
        return false
    }
    true
}

public class ModuleDoc {
    public let id: String
    public let name: String
    public let role: String
    public let sourcePrefix: String
    public let organization: ?String
    private let packageNamesStorage: ArrayList<String>
    private let dependencyIdsStorage: ArrayList<String>

    public init(id: String, name: String, role: String, sourcePrefix: String,
        packageNames!: Array<String> = [], dependencyIds!: Array<String> = [],
        organization!: ?String = None) {
        if (!portableModuleSourcePrefix(sourcePrefix)) {
            throw IllegalArgumentException(
                "module sourcePrefix must be empty or a portable relative logical path")
        }
        this.id = id
        this.name = name
        this.role = role
        this.sourcePrefix = sourcePrefix
        this.organization = organization
        this.packageNamesStorage = ArrayList<String>(packageNames)
        this.dependencyIdsStorage = ArrayList<String>(dependencyIds)
    }

    public prop packageNames: ReadOnlyList<String> { get() { packageNamesStorage } }
    public prop dependencyIds: ReadOnlyList<String> { get() { dependencyIdsStorage } }
}
