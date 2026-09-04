package cjdoc

import std.ast.*
import std.collection.*
import std.convert.Parsable

class SourceCacheWriter {
    private let bytes = ArrayList<UInt8>()
    private let maxBytes: Int64
    private var remainingItems: Int64
    private var exceeded = false

    init(maxBytes!: Int64 = MAX_SOURCE_CACHE_BYTES,
        maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS) {
        if (maxBytes < 0 || maxItems < 0) {
            throw IllegalArgumentException("source cache limits must be non-negative")
        }
        this.maxBytes = maxBytes
        this.remainingItems = maxItems
    }

    func add(value: String): Unit {
        if (exceeded) { return }
        let lengthBytes = value.size.toString().toArray()
        var remaining = maxBytes - bytes.size
        if (lengthBytes.size > remaining) { exceeded = true; return }
        remaining -= lengthBytes.size
        if (remaining < 1) { exceeded = true; return }
        remaining--
        if (value.size > remaining) { exceeded = true; return }
        bytes.add(all: lengthBytes)
        bytes.add(58u8)
        bytes.add(all: value.toArray())
    }

    func add(value: Int64): Unit { add(value.toString()) }
    func add(value: Bool): Unit { add(if (value) { "1" } else { "0" }) }
    func addCount(count: Int64): Bool {
        if (exceeded || count < 0 || count > remainingItems) {
            exceeded = true
            return false
        }
        remainingItems -= count
        add(count)
        !exceeded
    }
    func canContinue(): Bool { !exceeded }
    func result(): ?Array<UInt8> { if (exceeded) { None } else { Some(bytes.toArray()) } }
}

class SourceCacheReader {
    let bytes: Array<UInt8>
    var offset: Int64 = 0
    private var remainingItems: Int64

    init(bytes: Array<UInt8>, maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS) {
        if (maxItems < 0) { throw IllegalArgumentException("source cache item limit must be non-negative") }
        this.bytes = bytes
        this.remainingItems = maxItems
    }

    func next(): String {
        if (offset >= bytes.size) { throw IllegalArgumentException("truncated cache entry") }
        let lengthBytes = ArrayList<UInt8>()
        while (offset < bytes.size && bytes[offset] != 58u8) {
            let value = bytes[offset]
            if (value < 48u8 || value > 57u8) {
                throw IllegalArgumentException("invalid cache field length")
            }
            lengthBytes.add(value)
            offset++
        }
        if (offset >= bytes.size || lengthBytes.isEmpty()) {
            throw IllegalArgumentException("invalid cache field")
        }
        offset++
        let length = Int64.parse(String.fromUtf8(lengthBytes.toArray()))
        if (length < 0 || length > bytes.size - offset) {
            throw IllegalArgumentException("truncated cache field")
        }
        let value = ArrayList<UInt8>()
        var index: Int64 = 0
        while (index < length) {
            value.add(bytes[offset + index])
            index++
        }
        offset += length
        return String.fromUtf8(value.toArray())
    }

    func nextInt(): Int64 { Int64.parse(next()) }
    func nextCount(): Int64 {
        let count = nextInt()
        if (count < 0 || count > remainingItems) {
            throw IllegalArgumentException("source cache aggregate item limit exceeded")
        }
        remainingItems -= count
        count
    }
    func nextBool(): Bool {
        match (next()) {
            case "1" => true
            case "0" => false
            case _ => throw IllegalArgumentException("invalid cache boolean")
        }
    }
    func finished(): Bool { offset == bytes.size }
}

internal func cacheAddLocation(writer: SourceCacheWriter, value: SourceLocation): Unit {
    writer.add(value.path)
    writer.add(value.startLine)
    writer.add(value.startColumn)
    writer.add(value.endLine)
    writer.add(value.endColumn)
}

internal func cacheReadLocation(reader: SourceCacheReader): SourceLocation {
    SourceLocation(reader.next(), reader.nextInt(), reader.nextInt(), reader.nextInt(), reader.nextInt())
}

internal func cacheAddOptionalString(writer: SourceCacheWriter, value: ?String): Unit {
    match (value) {
        case Some(actual) =>
            writer.add(true)
            writer.add(actual)
        case None => writer.add(false)
    }
}

internal func cacheReadOptionalString(reader: SourceCacheReader): ?String {
    if (reader.nextBool()) { Some(reader.next()) } else { None }
}

internal func cacheAddOptionalBool(writer: SourceCacheWriter, value: ?Bool): Unit {
    match (value) {
        case Some(actual) =>
            writer.add(true)
            writer.add(actual)
        case None => writer.add(false)
    }
}

internal func cacheReadOptionalBool(reader: SourceCacheReader): ?Bool {
    if (reader.nextBool()) { Some(reader.nextBool()) } else { None }
}

internal func cacheAddTag(writer: SourceCacheWriter, tag: DocTag): Unit {
    writer.add(tag.name)
    writer.add(tag.subject)
    writer.add(tag.description)
}

internal func cacheReadTag(reader: SourceCacheReader): DocTag {
    DocTag(reader.next(), reader.next(), reader.next())
}

internal func cacheAddTags(writer: SourceCacheWriter, tags: ArrayList<DocTag>): Unit {
    if (!writer.addCount(tags.size)) { return }
    for (tag in tags) {
        cacheAddTag(writer, tag)
        if (!writer.canContinue()) { return }
    }
}

internal func cacheReadTags(reader: SourceCacheReader, tags: ArrayList<DocTag>): Unit {
    let count = reader.nextCount()
    var index: Int64 = 0
    while (index < count) {
        tags.add(cacheReadTag(reader))
        index++
    }
}

internal func cacheAddStrings(writer: SourceCacheWriter, values: ArrayList<String>): Unit {
    if (!writer.addCount(values.size)) { return }
    for (value in values) {
        writer.add(value)
        if (!writer.canContinue()) { return }
    }
}

internal func cacheReadStrings(reader: SourceCacheReader, values: ArrayList<String>): Unit {
    let count = reader.nextCount()
    var index: Int64 = 0
    while (index < count) {
        values.add(reader.next())
        index++
    }
}

internal func cacheAddDocComment(writer: SourceCacheWriter, value: ?DocComment): Unit {
    match (value) {
        case None => writer.add(false)
        case Some(doc) =>
            writer.add(true)
            writer.add(doc.raw)
            writer.add(doc.summaryMarkdown)
            writer.add(doc.descriptionMarkdown)
            cacheAddTags(writer, doc.params)
            cacheAddTags(writer, doc.examples)
            match (doc.returns) {
                case Some(tag) =>
                    writer.add(true)
                    cacheAddTag(writer, tag)
                case None => writer.add(false)
            }
            writer.add(doc.returnTagCount)
            cacheAddTags(writer, doc.throwsTags)
            cacheAddTags(writer, doc.see)
            cacheAddOptionalString(writer, doc.since)
            cacheAddOptionalString(writer, doc.deprecated)
            cacheAddStrings(writer, doc.authors)
            cacheAddOptionalString(writer, doc.version)
    }
}

internal func cacheReadDocComment(reader: SourceCacheReader): ?DocComment {
    if (!reader.nextBool()) { return None }
    let doc = DocComment(reader.next(), reader.next(), reader.next())
    cacheReadTags(reader, doc.params)
    cacheReadTags(reader, doc.examples)
    if (reader.nextBool()) { doc.returns = Some(cacheReadTag(reader)) }
    doc.returnTagCount = reader.nextInt()
    cacheReadTags(reader, doc.throwsTags)
    cacheReadTags(reader, doc.see)
    doc.since = cacheReadOptionalString(reader)
    doc.deprecated = cacheReadOptionalString(reader)
    cacheReadStrings(reader, doc.authors)
    doc.version = cacheReadOptionalString(reader)
    return Some(doc)
}

internal func cacheAddDeclaration(writer: SourceCacheWriter, value: SourceDeclaration): Unit {
    writer.add(value.sourceKey)
    writer.add(value.kind)
    writer.add(value.name)
    writer.add(value.packageName)
    writer.add(value.moduleId)
    writer.add(value.visibility)
    cacheAddLocation(writer, value.source)
    writer.add(value.sourceSignature)
    cacheAddStrings(writer, value.sourceApiSignatureTokens)
    writer.add(value.isContainer)
    cacheAddOptionalBool(writer, value.enumNonExhaustive)
    cacheAddOptionalString(writer, value.ownerSourceKey)
    cacheAddStrings(writer, value.genericParameters)
    if (!writer.addCount(value.parameters.size)) { return }
    for (parameter in value.parameters) {
        writer.add(parameter.name)
        writer.add(parameter.typeSpelling)
        cacheAddOptionalString(writer, parameter.defaultExpression)
        if (!writer.canContinue()) { return }
    }
    cacheAddOptionalString(writer, value.returnTypeSpelling)
    cacheAddStrings(writer, value.annotations)
    cacheAddStrings(writer, value.modifiers)
    if (!writer.addCount(value.relationships.size)) { return }
    for (relationship in value.relationships) {
        writer.add(relationship.kind)
        writer.add(relationship.targetSpelling)
        if (!writer.canContinue()) { return }
    }
    if (!writer.addCount(value.symbolRelationships.size)) { return }
    for (relationship in value.symbolRelationships) {
        writer.add(relationship.kind)
        writer.add(relationship.targetDisplay)
        if (!writer.canContinue()) { return }
    }
    cacheAddDocComment(writer, value.documentation)
}

internal func cacheReadDeclaration(reader: SourceCacheReader, expectedModuleId: String): SourceDeclaration {
    let sourceKey = reader.next()
    let kind = reader.next()
    let name = reader.next()
    let packageName = reader.next()
    let moduleId = reader.next()
    if (moduleId != expectedModuleId) { throw IllegalArgumentException("cache module mismatch") }
    let visibility = reader.next()
    let source = cacheReadLocation(reader)
    let signature = reader.next()
    let signatureTokens = ArrayList<String>()
    cacheReadStrings(reader, signatureTokens)
    let isContainer = reader.nextBool()
    let enumNonExhaustive = cacheReadOptionalBool(reader)
    let owner = cacheReadOptionalString(reader)
    let value = SourceDeclaration(sourceKey, kind, name, packageName, moduleId, visibility,
        source, signature, isContainer: isContainer, enumNonExhaustive: enumNonExhaustive,
        sourceApiSignatureTokens: signatureTokens.toArray())
    value.ownerSourceKey = owner
    cacheReadStrings(reader, value.genericParameters)
    let parameterCount = reader.nextCount()
    var index: Int64 = 0
    while (index < parameterCount) {
        value.parameters.add(SourceParameter(reader.next(), reader.next(),
            defaultExpression: cacheReadOptionalString(reader)))
        index++
    }
    value.returnTypeSpelling = cacheReadOptionalString(reader)
    cacheReadStrings(reader, value.annotations)
    cacheReadStrings(reader, value.modifiers)
    let relationshipCount = reader.nextCount()
    index = 0
    while (index < relationshipCount) {
        value.relationships.add(SourceTypeRelationship(reader.next(), reader.next()))
        index++
    }
    let symbolRelationshipCount = reader.nextCount()
    index = 0
    while (index < symbolRelationshipCount) {
        value.symbolRelationships.add(SourceSymbolRelationship(reader.next(), reader.next()))
        index++
    }
    value.documentation = cacheReadDocComment(reader)
    return value
}

internal func cacheAddReExport(writer: SourceCacheWriter, value: SourceReExport): Unit {
    writer.add(value.kind)
    cacheAddOptionalString(writer, value.organization)
    cacheAddStrings(writer, value.prefixPaths)
    writer.add(value.identifier)
    cacheAddOptionalString(writer, value.alias)
    cacheAddLocation(writer, value.source)
    writer.add(value.normalizedSpec)
    writer.add(value.packageName)
    writer.add(value.moduleId)
    if (!writer.addCount(value.items.size)) { return }
    for (item in value.items) {
        writer.add(item.name)
        cacheAddOptionalString(writer, item.alias)
    }
}

internal func cacheReadReExport(reader: SourceCacheReader, expectedModuleId: String): SourceReExport {
    let kind = reader.next()
    let organization = cacheReadOptionalString(reader)
    let prefixPaths = ArrayList<String>()
    cacheReadStrings(reader, prefixPaths)
    let identifier = reader.next()
    let alias = cacheReadOptionalString(reader)
    let source = cacheReadLocation(reader)
    let normalizedSpec = reader.next()
    let packageName = reader.next()
    let moduleId = reader.next()
    if (moduleId != expectedModuleId) { throw IllegalArgumentException("cache module mismatch") }
    let items = ArrayList<SourceImportItem>()
    var count = reader.nextCount()
    while (count > 0) {
        items.add(SourceImportItem(reader.next(), alias: cacheReadOptionalString(reader)))
        count--
    }
    SourceReExport(kind, organization, identifier, alias, source, normalizedSpec,
        packageName, moduleId, prefixPaths: prefixPaths.toArray(), items: items.toArray())
}

internal class ParsedSourceFile {
    let input: SourceInputFile
    var packageName: ?String = None
    var capturedSourceIndex: ?CapturedSourceIndex = None
    let declarations = ArrayList<SourceDeclaration>()
    let reExports = ArrayList<SourceReExport>()
    let orphanDocComments = ArrayList<OrphanDocComment>()
    let macroInvocations = ArrayList<MacroInvocation>()
    let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    let diagnostics = ArrayList<Diagnostic>()
    var cacheStatus = "disabled"

    init(input: SourceInputFile) { this.input = input }
}

internal func withCapturedSourceIndex(parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex): ParsedSourceFile {
    if (capturedSourceIndex.available) {
        parsed.capturedSourceIndex = Some(capturedSourceIndex)
    }
    parsed
}

internal func cacheAddUnsupported(writer: SourceCacheWriter, value: UnsupportedDeclaration): Unit {
    writer.add(value.kind)
    writer.add(value.name)
    writer.add(value.reason)
    cacheAddLocation(writer, value.source)
    writer.add(value.origin.kind)
    cacheAddOptionalString(writer, value.origin.macroSymbolId)
}

internal func cacheReadUnsupported(reader: SourceCacheReader): UnsupportedDeclaration {
    UnsupportedDeclaration(reader.next(), reader.next(), reader.next(), cacheReadLocation(reader),
        origin: DeclarationOrigin(reader.next(), macroSymbolId: cacheReadOptionalString(reader)))
}

internal func cacheAddOrphanDocComment(writer: SourceCacheWriter, value: OrphanDocComment): Unit {
    writer.add(value.rawText)
    cacheAddLocation(writer, value.source)
}

internal func cacheReadOrphanDocComment(reader: SourceCacheReader): OrphanDocComment {
    OrphanDocComment(reader.next(), cacheReadLocation(reader))
}

internal func cacheAddMacroInvocation(writer: SourceCacheWriter, value: MacroInvocation): Unit {
    writer.add(value.name)
    cacheAddLocation(writer, value.source)
}

internal func cacheReadMacroInvocation(reader: SourceCacheReader): MacroInvocation {
    MacroInvocation(reader.next(), cacheReadLocation(reader))
}

internal func cacheAddDiagnostic(writer: SourceCacheWriter, value: Diagnostic): Unit {
    writer.add(value.severity)
    writer.add(value.code)
    writer.add(value.message)
    match (value.source) {
        case Some(location) =>
            writer.add(true)
            cacheAddLocation(writer, location)
        case None => writer.add(false)
    }
    cacheAddOptionalString(writer, value.symbolId)
}

internal func cacheReadDiagnostic(reader: SourceCacheReader): Diagnostic {
    let severity = reader.next()
    let code = reader.next()
    let message = reader.next()
    let source: ?SourceLocation = if (reader.nextBool()) {
        Some(cacheReadLocation(reader))
    } else {
        None
    }
    let symbolId = cacheReadOptionalString(reader)
    Diagnostic(severity, code, message, source: source, symbolId: symbolId)
}
