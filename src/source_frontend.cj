package cjdoc

import std.ast.*
import std.collection.*
import std.fs.*
import std.sync.AtomicInt64

internal let SOURCE_CACHE_FORMAT = "cjdoc-source-cache-v9"
internal let MAX_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
internal let MAX_SOURCE_CACHE_BYTES: Int64 = 64 * 1024 * 1024
internal let MAX_SOURCE_CACHE_ITEMS: Int64 = 100000
internal let MAX_SOURCE_FILES: Int64 = 100000
internal let MAX_SOURCE_DIRECTORY_DEPTH: Int64 = 128
internal let MAX_SOURCE_DIRECTORY_ENTRIES: Int64 = 100000
internal let MAX_TOTAL_SOURCE_BYTES: Int64 = 512 * 1024 * 1024
internal let MAX_SOURCE_MODULES: Int64 = 4096
internal let MAX_SOURCE_DEPENDENCY_EDGES: Int64 = 16384
internal let MAX_SOURCE_OWNER_DEPTH: Int64 = 128
internal let MAX_SOURCE_AUXILIARY_BYTES: Int64 = 512 * 1024 * 1024
internal let MAX_SOURCE_AUXILIARY_WORK: Int64 = 1024 * 1024 * 1024

internal class SourceAuxiliaryBudget {
    private let maxBytes: Int64
    private let maxWork: Int64
    private let bytes = AtomicInt64(0)
    private let work = AtomicInt64(0)
    private let exceeded = AtomicInt64(0)

    init(maxBytes: Int64, maxWork: Int64) {
        if (maxBytes < 0 || maxWork < 0) {
            throw IllegalArgumentException("source auxiliary limits must be non-negative")
        }
        this.maxBytes = maxBytes
        this.maxWork = maxWork
    }

    private func consume(counter: AtomicInt64, maximum: Int64, amount: Int64): Bool {
        if (amount < 0 || amount > maximum) {
            let _ = exceeded.fetchAdd(1)
            return false
        }
        let previous = counter.fetchAdd(amount)
        if (previous > maximum - amount) {
            let _ = exceeded.fetchAdd(1)
            return false
        }
        true
    }

    func consumeBytes(amount: Int64): Bool { consume(bytes, maxBytes, amount) }
    func consumeWork(amount: Int64): Bool { consume(work, maxWork, amount) }
    func limitReached(): Bool { exceeded.fetchAdd(0) > 0 }
}

internal func readAuxiliaryTextBounded(path: Path, perFileLimit: Int64,
    budget: SourceAuxiliaryBudget): String {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink() || info.size < 0 ||
        info.size > perFileLimit) {
        throw IllegalArgumentException("auxiliary input is not a bounded regular file")
    }
    if (!budget.consumeBytes(info.size)) {
        throw IllegalArgumentException("source auxiliary byte budget exceeded")
    }
    readTextBounded(path, perFileLimit)
}

internal func readAuxiliaryFileBounded(path: Path, perFileLimit: Int64,
    budget: SourceAuxiliaryBudget): Array<Byte> {
    let info = FileInfo(path)
    if (!info.isRegular() || info.isSymbolicLink() || info.size < 0 ||
        info.size > perFileLimit) {
        throw IllegalArgumentException("auxiliary input is not a bounded regular file")
    }
    if (!budget.consumeBytes(info.size) || !budget.consumeWork(info.size)) {
        throw IllegalArgumentException("source auxiliary cache budget exceeded")
    }
    readFileBounded(path, perFileLimit)
}

class SourceCacheStats {
    public var hits: Int64 = 0
    public var misses: Int64 = 0
    public var writes: Int64 = 0
    public var corruptEntries: Int64 = 0
    public var writeFailures: Int64 = 0

    func reset(): Unit {
        hits = 0
        misses = 0
        writes = 0
        corruptEntries = 0
        writeFailures = 0
    }
}

internal class RawDocComment {
    let raw: String
    let source: SourceLocation
    var bound = false

    init(raw: String, source: SourceLocation) {
        this.raw = raw
        this.source = source
    }
}

internal func positionLess(lineA: Int64, columnA: Int64, lineB: Int64, columnB: Int64): Bool {
    return lineA < lineB || (lineA == lineB && columnA < columnB)
}

internal func positionLessOrEqual(lineA: Int64, columnA: Int64,
    lineB: Int64, columnB: Int64): Bool {
    !positionLess(lineB, columnB, lineA, columnA)
}

internal func makeSourceDeclarationKey(source: SourceLocation, kind: String, name: String): String {
    "${source.path}:${source.startLine}:${source.startColumn}:${kind}:${name}"
}

internal func rangeContains(outer: SourceLocation, inner: SourceLocation): Bool {
    if (outer.path != inner.path) { return false }
    let startsBefore = !positionLess(inner.startLine, inner.startColumn, outer.startLine, outer.startColumn)
    let endsAfter = !positionLess(outer.endLine, outer.endColumn, inner.endLine, inner.endColumn)
    return startsBefore && endsAfter
}

internal func declarationVisibility(decl: Decl): String {
    for (modifier in decl.modifiers) {
        match (modifier.keyword.value) {
            case "public" => return "public"
            case "protected" => return "protected"
            case "private" => return "private"
            case "internal" => return "internal"
            case _ => ()
        }
    }
    return "internal"
}

internal func normalizedTokens(node: Node): String {
    return node.toTokens().toString().trimAscii()
}

internal func sourceApiSignatureTokens(signature: String): Array<String> {
    let result = ArrayList<String>()
    try {
        for (token in cangjieLex(signature)) {
            if (token.kind == COMMENT || token.kind == NL || token.value.isEmpty()) { continue }
            result.add("${token.kind}:${token.value.size}:${token.value}")
        }
    } catch (_: Exception) {
        return []
    }
    result.toArray()
}

// One immutable source buffer is shared by declaration extraction and comment
// binding. Line starts make source-position conversion logarithmic instead of
// rescanning and reallocating the complete file for every declaration.
internal class IndexedSourceBuffer {
    let source: String
    let bytes: Array<UInt8>
    let lineStarts = ArrayList<Int64>()

    init(source: String) {
        this.source = source
        this.bytes = source.toArray()
        lineStarts.add(0)
        var index: Int64 = 0
        while (index < bytes.size) {
            if (bytes[index] == b'\n') { lineStarts.add(index + 1) }
            index++
        }
    }

    func byteOffset(line: Int64, column: Int64): Int64 {
        if (line < 1 || column < 1 || line > lineStarts.size) { return -1 }
        let lineIndex = line - 1
        let result = lineStarts[lineIndex] + column - 1
        let lineEnd = if (lineIndex + 1 < lineStarts.size) {
            lineStarts[lineIndex + 1]
        } else {
            bytes.size
        }
        if (result < lineStarts[lineIndex] || result > lineEnd || result > bytes.size) { return -1 }
        result
    }

    func position(offset: Int64): (Int64, Int64) {
        if (offset < 0 || offset > bytes.size) { return (1, 1) }
        var low: Int64 = 0
        var high: Int64 = lineStarts.size
        while (low + 1 < high) {
            let middle = low + (high - low) / 2
            if (lineStarts[middle] <= offset) {
                low = middle
            } else {
                high = middle
            }
        }
        (low + 1, offset - lineStarts[low] + 1)
    }

    func slice(location: SourceLocation): String {
        let start = byteOffset(location.startLine, location.startColumn)
        let end = byteOffset(location.endLine, location.endColumn)
        if (start < 0 || end < start || end > bytes.size) { return "" }
        String.fromUtf8(bytes[start..end])
    }
}

internal func enumCaseStart(source: IndexedSourceBuffer, line: Int64, column: Int64): (Int64, Int64) {
    let start = source.byteOffset(line, column)
    if (start <= 0) { return (line, column) }
    var cursor = start - 1
    while (cursor >= 0 && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor-- }
    if (cursor < 0 || source.bytes[cursor] != b'|') { return (line, column) }
    source.position(cursor)
}

internal func headerEndOffset(source: String): Int64 {
    var roundDepth: Int64 = 0
    var squareDepth: Int64 = 0
    for (token in cangjieLex(source)) {
        match (token.kind) {
            case LPAREN => roundDepth++
            case RPAREN => roundDepth--
            case LSQUARE => squareDepth++
            case RSQUARE => squareDepth--
            case LCURL =>
                if (roundDepth == 0 && squareDepth == 0) {
                    return IndexedSourceBuffer(source).byteOffset(Int64(token.pos.line), Int64(token.pos.column))
                }
            case _ => ()
        }
    }
    return source.size
}

internal func declarationSignature(decl: Decl, source: IndexedSourceBuffer, location: SourceLocation,
    hasBody: Bool): String {
    let exact = source.slice(location)
    if (exact.isEmpty()) { return normalizedTokens(decl) }
    if (!hasBody) { return exact.trimAscii() }
    let end = headerEndOffset(exact)
    let bytes = exact.toArray()
    let selected = ArrayList<UInt8>()
    var index: Int64 = 0
    while (index < end && index < bytes.size) {
        selected.add(bytes[index])
        index++
    }
    return String.fromUtf8(selected.toArray()).trimAscii()
}

internal func addCommonAstData(symbol: SourceDeclaration, decl: Decl): Unit {
    for (annotation in decl.annotations) {
        symbol.annotations.add(annotation.toTokens().toString().trimAscii())
    }
    for (modifier in decl.modifiers) {
        symbol.modifiers.add(modifier.keyword.value)
        if (modifier.keyword.value == "override") {
            symbol.symbolRelationships.add(SourceSymbolRelationship("override", symbol.name))
        }
    }
    if (decl.isGenericDecl) {
        for (token in decl.genericParam.parameters) {
            if (token.kind == IDENTIFIER) { symbol.genericParameters.add(token.value) }
        }
    }
}

internal func tokenEndPosition(token: Token): (Int64, Int64) {
    let lines = token.value.split("\n")
    let endLine = Int64(token.pos.line) + lines.size - 1
    let endColumn = if (lines.size == 1) {
        Int64(token.pos.column) + token.value.size
    } else {
        lines[lines.size - 1].size + 1
    }
    (endLine, endColumn)
}

internal func importKindName(kind: ImportKind): String {
    match (kind) {
        case ImportKind.Single => "single"
        case ImportKind.Alias => "alias"
        case ImportKind.All => "all"
        case ImportKind.Multi => "multi"
    }
}

internal func importAliasName(tokens: Tokens): ?String {
    var index = tokens.size
    while (index > 0) {
        index--
        let value = tokens[index].value
        if (!value.isEmpty() && value != "as") { return Some(value) }
    }
    None
}

internal func importPrefixPaths(tokens: Tokens): Array<String> {
    let result = ArrayList<String>()
    for (token in tokens) {
        if (!token.value.isEmpty()) { result.add(token.value) }
    }
    result.toArray()
}

internal func importLocation(path: String, value: ImportList): ?SourceLocation {
    let tokens = value.toTokens()
    if (tokens.size == 0) { return None }
    var first: Int64 = 0
    while (first < tokens.size && (tokens[first].value.isEmpty() || tokens[first].kind == NL)) { first++ }
    if (first >= tokens.size || tokens[first].pos.line <= 0 || tokens[first].pos.column <= 0) { return None }
    var last = tokens.size
    while (last > first && (tokens[last - 1].value.isEmpty() || tokens[last - 1].kind == NL)) { last-- }
    if (last <= first) { return None }
    let endToken = tokens[last - 1]
    if (endToken.pos.line <= 0 || endToken.pos.column <= 0) { return None }
    let (endLine, endColumn) = tokenEndPosition(endToken)
    Some(SourceLocation(path, Int64(tokens[first].pos.line), Int64(tokens[first].pos.column),
        endLine, endColumn))
}

internal func collectPublicReExports(program: Program, path: String, packageName: String,
    moduleId: String): Array<SourceReExport> {
    let result = ArrayList<SourceReExport>()
    for (importList in program.importLists) {
        if (importList.modifier.value != "public") { continue }
        let location = match (importLocation(path, importList)) {
            case Some(value) => value
            case None => continue
        }
        let content = importList.content
        let items = ArrayList<SourceImportItem>()
        for (item in content.items) {
            if (item.identifier.value.isEmpty()) { continue }
            items.add(SourceImportItem(item.identifier.value,
                alias: importAliasName(item.importAlias)))
        }
        result.add(SourceReExport(importKindName(content.importKind),
            if (content.orgName.value.isEmpty()) { None } else { Some(content.orgName.value) },
            content.identifier.value, importAliasName(content.importAlias), location,
            importList.toTokens().toString().trimAscii(), packageName, moduleId,
            prefixPaths: importPrefixPaths(content.prefixPaths), items: items.toArray()))
    }
    result.toArray()
}

internal class PatternBinding {
    let name: String

    init(name: String) { this.name = name }
}

internal class PatternBindingCollector <: Visitor {
    let bindings = ArrayList<PatternBinding>()

    public override func visit(pattern: VarPattern): Unit {
        let name = pattern.identifier.value
        if (!name.isEmpty()) { bindings.add(PatternBinding(name)) }
        breakTraverse()
    }
}
