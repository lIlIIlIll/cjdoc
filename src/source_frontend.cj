package cjdoc

import std.ast.*
import std.collection.*
import std.fs.*
import std.sync.AtomicInt64

internal let SOURCE_CACHE_FORMAT = "cjdoc-source-cache-v11"
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
internal func sourceLexerTokens(source: String): Tokens {
    cangjieLex(source)
}
internal let MAX_SOURCE_BINARY_DEPTH: Int64 = 64
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

    func byteOffsetFromLexerPosition(line: Int64, column: Int64): Int64 {
        if (line < 1 || column < 1 || line > lineStarts.size) { return -1 }
        let lineIndex = line - 1
        let start = lineStarts[lineIndex]
        let lineEnd = if (lineIndex + 1 < lineStarts.size) {
            lineStarts[lineIndex + 1] - 1
        } else {
            bytes.size
        }
        let offset = start + column - 1
        if (offset < start || offset > lineEnd) { return -1 }
        offset
    }

    func byteOffset(line: Int64, column: Int64): Int64 {
        byteOffsetFromLexerPosition(line, column)
    }

    // Public SourcePosition columns are 1-based UTF-8 byte columns.
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
                    return IndexedSourceBuffer(source).byteOffsetFromLexerPosition(
                        Int64(token.pos.line), Int64(token.pos.column))
                }
            case _ => ()
        }
    }
    return source.size
}

internal func commentLocation(path: String, token: Token, index: IndexedSourceBuffer): SourceLocation {
    let lines = token.value.split("\n")
    let rawStart = index.byteOffsetFromLexerPosition(Int64(token.pos.line),
        Int64(token.pos.column))
    let (startLine, startColumn) = index.position(rawStart)
    let endLine = startLine + lines.size - 1
    let endColumn = if (lines.size == 1) {
        startColumn + lines[0].toArray().size
    } else {
        lines[lines.size - 1].toArray().size + 1
    }
    SourceLocation(path, startLine, startColumn, endLine, endColumn)
}

internal func collectDocComments(path: String, tokens: Tokens,
    index: IndexedSourceBuffer): ArrayList<RawDocComment> {
    let comments = ArrayList<RawDocComment>()
    for (token in tokens) {
        if (token.kind == COMMENT && token.value.startsWith("/**")) {
            comments.add(RawDocComment(token.value, commentLocation(path, token, index)))
        }
    }
    comments
}


internal func isFunctionLike(symbol: SourceDeclaration): Bool {
    symbol.kind == "function" || symbol.kind == "constructor"
}

internal func sourceOrderLess(left: SourceDeclaration, right: SourceDeclaration): Bool {
    if (left.source.path != right.source.path) { return left.source.path < right.source.path }
    if (left.source.startLine != right.source.startLine) {
        return left.source.startLine < right.source.startLine
    }
    if (left.source.startColumn != right.source.startColumn) {
        return left.source.startColumn < right.source.startColumn
    }
    if (left.source.endLine != right.source.endLine) { return left.source.endLine > right.source.endLine }
    left.source.endColumn > right.source.endColumn
}

internal func removeLocalDeclarations(symbols: ArrayList<SourceDeclaration>,
    extraScopes: ArrayList<SourceLocation>): Unit {
    let activeFunctions = ArrayList<SourceLocation>()
    var index: Int64 = 0
    while (index < symbols.size) {
        var inExtraScope = false
        for (scope in extraScopes) {
            if (rangeContains(scope, symbols[index].source)) {
                inExtraScope = true
                break
            }
        }
        if (inExtraScope) {
            symbols.remove(at: index)
            continue
        }
        while (!activeFunctions.isEmpty() &&
            !rangeContains(activeFunctions[activeFunctions.size - 1], symbols[index].source)) {
            activeFunctions.remove(at: activeFunctions.size - 1)
        }
        if (!activeFunctions.isEmpty() && symbols[index].kind != "variable") {
            symbols.remove(at: index)
        } else {
            if (isFunctionLike(symbols[index])) { activeFunctions.add(symbols[index].source) }
            index++
        }
    }
}

internal func assignOwners(symbols: ArrayList<SourceDeclaration>): Unit {
    let containers = ArrayList<Int64>()
    var index: Int64 = 0
    while (index < symbols.size) {
        while (!containers.isEmpty() &&
            !rangeContains(symbols[containers[containers.size - 1]].source, symbols[index].source)) {
            containers.remove(at: containers.size - 1)
        }
        let best = if (containers.isEmpty()) { -1 } else { containers[containers.size - 1] }
        symbols[index].ownerIndex = best
        if (best >= 0) { symbols[index].ownerSourceKey = Some(symbols[best].sourceKey) }
        if (best >= 0 && symbols[best].kind == "interface" && symbols[index].visibility == "internal") {
            symbols[index].visibility = "public"
        }
        if (symbols[index].isContainer) { containers.add(index) }
        index++
    }
}

internal func onlyWhitespaceBetween(source: IndexedSourceBuffer, left: SourceLocation,
    right: SourceLocation): Bool {
    let start = source.byteOffset(left.endLine, left.endColumn)
    let end = source.byteOffset(right.startLine, right.startColumn)
    if (start < 0 || end < start) { return false }
    var index = start
    while (index < end && index < source.bytes.size) {
        match (source.bytes[index]) {
            case 9u8 | 10u8 | 13u8 | 32u8 => ()
            case _ => return false
        }
        index++
    }
    index == end
}

internal func sameSourceRange(left: SourceLocation, right: SourceLocation): Bool {
    left.path == right.path && left.startLine == right.startLine &&
        left.startColumn == right.startColumn && left.endLine == right.endLine &&
        left.endColumn == right.endColumn
}

internal func bindComments(symbols: ArrayList<SourceDeclaration>,
    comments: ArrayList<RawDocComment>, source: IndexedSourceBuffer): ArrayList<OrphanDocComment> {
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    var symbolIndex: Int64 = 0
    while (symbolIndex < symbols.size) {
        let symbol = symbols[symbolIndex]
        while (commentIndex < comments.size &&
            positionLessOrEqual(comments[commentIndex].source.endLine,
                comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        if (let Some(comment) <- candidate) {
            if (!comment.bound && onlyWhitespaceBetween(source, comment.source, symbol.source)) {
                var groupedIndex = symbolIndex
                while (groupedIndex < symbols.size &&
                    sameSourceRange(symbols[groupedIndex].source, symbol.source)) {
                    symbols[groupedIndex].documentation = parseDocComment(comment.raw)
                    groupedIndex++
                }
                comment.bound = true
            }
            candidate = None
        }
        var nextIndex = symbolIndex + 1
        while (nextIndex < symbols.size && sameSourceRange(symbols[nextIndex].source, symbol.source)) {
            nextIndex++
        }
        symbolIndex = nextIndex
    }
    let orphans = ArrayList<OrphanDocComment>()
    for (comment in comments where !comment.bound) {
        orphans.add(OrphanDocComment(comment.raw, comment.source))
    }
    orphans
}


