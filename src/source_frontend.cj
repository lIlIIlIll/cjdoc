package cjdoc

import std.ast.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*
import std.sync.AtomicInt64

private let SOURCE_CACHE_FORMAT = "cjdoc-source-cache-v8"
private let MAX_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
private let MAX_SOURCE_CACHE_BYTES: Int64 = 64 * 1024 * 1024
private let MAX_SOURCE_CACHE_ITEMS: Int64 = 100000
private let MAX_SOURCE_FILES: Int64 = 100000
private let MAX_SOURCE_DIRECTORY_DEPTH: Int64 = 128
private let MAX_SOURCE_DIRECTORY_ENTRIES: Int64 = 100000
private let MAX_TOTAL_SOURCE_BYTES: Int64 = 512 * 1024 * 1024
private let MAX_SOURCE_MODULES: Int64 = 4096
private let MAX_SOURCE_DEPENDENCY_EDGES: Int64 = 16384
private let MAX_SOURCE_OWNER_DEPTH: Int64 = 128
private let MAX_SOURCE_AUXILIARY_BYTES: Int64 = 512 * 1024 * 1024
private let MAX_SOURCE_AUXILIARY_WORK: Int64 = 1024 * 1024 * 1024

private class SourceAuxiliaryBudget {
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

private func readAuxiliaryTextBounded(path: Path, perFileLimit: Int64,
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

private func readAuxiliaryFileBounded(path: Path, perFileLimit: Int64,
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

private class RawDocComment {
    let raw: String
    let source: SourceLocation
    var bound = false

    init(raw: String, source: SourceLocation) {
        this.raw = raw
        this.source = source
    }
}

private func positionLess(lineA: Int64, columnA: Int64, lineB: Int64, columnB: Int64): Bool {
    return lineA < lineB || (lineA == lineB && columnA < columnB)
}

private func positionLessOrEqual(lineA: Int64, columnA: Int64,
    lineB: Int64, columnB: Int64): Bool {
    !positionLess(lineB, columnB, lineA, columnA)
}

private func makeSourceDeclarationKey(source: SourceLocation, kind: String, name: String): String {
    "${source.path}:${source.startLine}:${source.startColumn}:${kind}:${name}"
}

private func rangeContains(outer: SourceLocation, inner: SourceLocation): Bool {
    if (outer.path != inner.path) { return false }
    let startsBefore = !positionLess(inner.startLine, inner.startColumn, outer.startLine, outer.startColumn)
    let endsAfter = !positionLess(outer.endLine, outer.endColumn, inner.endLine, inner.endColumn)
    return startsBefore && endsAfter
}

private func declarationVisibility(decl: Decl): String {
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

private func normalizedTokens(node: Node): String {
    return node.toTokens().toString().trimAscii()
}

private func sourceApiSignatureTokens(signature: String): Array<String> {
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
private class IndexedSourceBuffer {
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

private func enumCaseStart(source: IndexedSourceBuffer, line: Int64, column: Int64): (Int64, Int64) {
    let start = source.byteOffset(line, column)
    if (start <= 0) { return (line, column) }
    var cursor = start - 1
    while (cursor >= 0 && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor-- }
    if (cursor < 0 || source.bytes[cursor] != b'|') { return (line, column) }
    source.position(cursor)
}

private func headerEndOffset(source: String): Int64 {
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

private func declarationSignature(decl: Decl, source: IndexedSourceBuffer, location: SourceLocation,
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

private func addCommonAstData(symbol: SourceDeclaration, decl: Decl): Unit {
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

private func tokenEndPosition(token: Token): (Int64, Int64) {
    let lines = token.value.split("\n")
    let endLine = Int64(token.pos.line) + lines.size - 1
    let endColumn = if (lines.size == 1) {
        Int64(token.pos.column) + token.value.size
    } else {
        lines[lines.size - 1].size + 1
    }
    (endLine, endColumn)
}

private func importKindName(kind: ImportKind): String {
    match (kind) {
        case ImportKind.Single => "single"
        case ImportKind.Alias => "alias"
        case ImportKind.All => "all"
        case ImportKind.Multi => "multi"
    }
}

private func importAliasName(tokens: Tokens): ?String {
    var index = tokens.size
    while (index > 0) {
        index--
        let value = tokens[index].value
        if (!value.isEmpty() && value != "as") { return Some(value) }
    }
    None
}

private func importPrefixPaths(tokens: Tokens): Array<String> {
    let result = ArrayList<String>()
    for (token in tokens) {
        if (!token.value.isEmpty()) { result.add(token.value) }
    }
    result.toArray()
}

private func importLocation(path: String, value: ImportList): ?SourceLocation {
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

private func collectPublicReExports(program: Program, path: String, packageName: String,
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

private class PatternBinding {
    let name: String

    init(name: String) { this.name = name }
}

private class PatternBindingCollector <: Visitor {
    let bindings = ArrayList<PatternBinding>()

    public override func visit(pattern: VarPattern): Unit {
        let name = pattern.identifier.value
        if (!name.isEmpty()) { bindings.add(PatternBinding(name)) }
        breakTraverse()
    }
}

private class AstDeclarationCollector <: Visitor {
    let path: String
    let packageName: String
    let moduleId: String
    let source: IndexedSourceBuffer
    let declarations = ArrayList<SourceDeclaration>()
    let macroInvocations = ArrayList<MacroInvocation>()
    let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    let diagnostics = ArrayList<Diagnostic>()
    let localScopes = ArrayList<SourceLocation>()
    // Primary-constructor member parameters are lexically inside a constructor
    // but semantically also declare members of the surrounding type. Keep them
    // separate until local declarations have been filtered.
    let primaryConstructorMembers = ArrayList<SourceDeclaration>()

    init(path: String, packageName: String, moduleId: String, source: IndexedSourceBuffer) {
        this.path = path
        this.packageName = packageName
        this.moduleId = moduleId
        this.source = source
    }

    func add(decl: Decl, kind: String, name: String, isContainer!: Bool = false,
        hasBody!: Bool = false, enumNonExhaustive!: ?Bool = None): ?SourceDeclaration {
        if (name.isEmpty()) { return None }
        var startLine = Int64(decl.beginPos.line)
        var startColumn = Int64(decl.beginPos.column)
        let tokens = decl.toTokens()
        if (tokens.size > 0 && tokens[0].pos.line > 0 && tokens[0].pos.column > 0 &&
            positionLess(Int64(tokens[0].pos.line), Int64(tokens[0].pos.column), startLine, startColumn)) {
            startLine = Int64(tokens[0].pos.line)
            startColumn = Int64(tokens[0].pos.column)
        }
        if (startLine <= 0 || startColumn <= 0) { return None }
        let endLine = if (decl.endPos.line > 0) { Int64(decl.endPos.line) } else { startLine }
        let endColumn = if (decl.endPos.column > 0) { Int64(decl.endPos.column) } else { startColumn }
        let location = SourceLocation(path, startLine, startColumn, endLine, endColumn)
        let signature = declarationSignature(decl, source, location, hasBody)
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, kind, name), kind, name,
            packageName, moduleId, declarationVisibility(decl), location,
            signature, isContainer: isContainer,
            enumNonExhaustive: enumNonExhaustive,
            sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
        addCommonAstData(symbol, decl)
        declarations.add(symbol)
        return symbol
    }

    func addParameters(symbol: SourceDeclaration, parameters: ArrayList<FuncParam>): Unit {
        for (parameter in parameters) {
            let parameterName = try { parameter.identifier.value } catch (_: Exception) { "_" }
            let display = try { normalizedTokens(parameter.paramType) } catch (_: Exception) { "" }
            // std.ast throws when expr is accessed for a parameter without an
            // assignment, so the assign token is the required presence guard.
            let defaultExpression: ?String = if (parameter.assign.kind == TokenKind.ILLEGAL) {
                None
            } else {
                let expression = normalizedTokens(parameter.expr)
                if (expression.isEmpty()) { None } else { Some(expression) }
            }
            symbol.parameters.add(SourceParameter(parameterName, display,
                defaultExpression: defaultExpression))
        }
    }

    func addPrimaryConstructorMember(parameter: FuncParam): Unit {
        if (!parameter.isMemberParam()) { return }
        let name = try { parameter.identifier.value } catch (_: Exception) { "" }
        if (name.isEmpty()) { return }
        let tokens = parameter.toTokens()
        if (tokens.size == 0) { return }
        var lastIndex = tokens.size - 1
        while (lastIndex > 0 && tokens[lastIndex].value == ",") { lastIndex-- }
        let first = tokens[0]
        let last = tokens[lastIndex]
        if (first.pos.line <= 0 || first.pos.column <= 0 ||
            last.pos.line <= 0 || last.pos.column <= 0) { return }
        let (endLine, endColumn) = tokenEndPosition(last)
        let location = SourceLocation(path, Int64(first.pos.line), Int64(first.pos.column),
            endLine, endColumn)
        let exact = source.slice(location)
        let signature = if (exact.isEmpty()) {
            normalizedTokens(parameter).trimAscii().trimEnd(",").trimAscii()
        } else {
            exact.trimAscii()
        }
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, "variable", name),
            "variable", name, packageName, moduleId, declarationVisibility(parameter), location,
            signature, sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
        addCommonAstData(symbol, parameter)
        let display = try { normalizedTokens(parameter.paramType) } catch (_: Exception) { "" }
        if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        primaryConstructorMembers.add(symbol)
    }

    func addSuperTypes(symbol: SourceDeclaration, superTypes: ArrayList<TypeNode>): Unit {
        for (superType in superTypes) {
            let display = normalizedTokens(superType)
            symbol.relationships.add(SourceTypeRelationship("superType", display))
        }
    }

    public override func visit(decl: ClassDecl): Unit {
        if (let Some(symbol) <- add(decl, "class", decl.identifier.value,
            isContainer: true, hasBody: true)) {
            addSuperTypes(symbol, decl.superTypes)
        }
    }

    public override func visit(decl: StructDecl): Unit {
        if (let Some(symbol) <- add(decl, "struct", decl.identifier.value,
            isContainer: true, hasBody: true)) {
            addSuperTypes(symbol, decl.superTypes)
        }
    }

    public override func visit(decl: InterfaceDecl): Unit {
        if (let Some(symbol) <- add(decl, "interface", decl.identifier.value,
            isContainer: true, hasBody: true)) {
            addSuperTypes(symbol, decl.superTypes)
        }
    }

    public override func visit(decl: EnumDecl): Unit {
        if (let Some(owner) <- add(decl, "enum", decl.identifier.value, isContainer: true,
            hasBody: true, enumNonExhaustive: Some(decl.ellipsis.kind != TokenKind.ILLEGAL))) {
            addSuperTypes(owner, decl.superTypes)
            for (constructor in decl.constructors) {
                let tokens = constructor.toTokens()
                if (tokens.size == 0) { continue }
                let first = tokens[0]
                let last = tokens[tokens.size - 1]
                let lastLines = last.value.split("\n")
                let endLine = Int64(last.pos.line) + lastLines.size - 1
                let endColumn = if (lastLines.size == 1) {
                    Int64(last.pos.column) + last.value.size
                } else {
                    lastLines[lastLines.size - 1].size + 1
                }
                let (startLine, startColumn) = enumCaseStart(source,
                    Int64(first.pos.line), Int64(first.pos.column))
                let location = SourceLocation(path, startLine, startColumn,
                    endLine, endColumn)
                let exact = source.slice(location)
                let name = constructor.identifier.value
                let signature = if (exact.isEmpty()) {
                    constructor.toTokens().toString().trimAscii()
                } else {
                    exact.trimAscii()
                }
                let symbol = SourceDeclaration(makeSourceDeclarationKey(location, "enumCase", name),
                    "enumCase", name, packageName, moduleId, owner.visibility, location,
                    signature, sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
                var parameterIndex: Int64 = 0
                for (argument in constructor.typeArguments) {
                    symbol.parameters.add(SourceParameter("_${parameterIndex}", normalizedTokens(argument)))
                    parameterIndex++
                }
                for (annotation in constructor.annotations) {
                    symbol.annotations.add(annotation.toTokens().toString().trimAscii())
                }
                declarations.add(symbol)
            }
        }
    }

    public override func visit(decl: ExtendDecl): Unit {
        let target = normalizedTokens(decl.extendType)
        if (let Some(symbol) <- add(decl, "extend", target, isContainer: true, hasBody: true)) {
            symbol.relationships.add(SourceTypeRelationship("extensionTarget", target))
            addSuperTypes(symbol, decl.superTypes)
        }
    }

    public override func visit(decl: TypeAliasDecl): Unit {
        let _ = add(decl, "typeAlias", decl.identifier.value)
        breakTraverse()
    }

    public override func visit(decl: PropDecl): Unit {
        if (let Some(symbol) <- add(decl, "property", decl.identifier.value, hasBody: true)) {
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
        breakTraverse()
    }

    public override func visit(decl: VarDecl): Unit {
        let collector = PatternBindingCollector()
        try { decl.pattern.traverse(collector) } catch (_: Exception) {}
        if (collector.bindings.isEmpty()) {
            let fallback = try { decl.identifier.value } catch (_: Exception) { "" }
            if (!fallback.isEmpty()) { collector.bindings.add(PatternBinding(fallback)) }
        }
        let display = if (collector.bindings.size == 1) {
            try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
        } else {
            ""
        }
        for (binding in collector.bindings) {
            if (let Some(symbol) <- add(decl, "variable", binding.name)) {
                if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
            }
        }
        breakTraverse()
    }

    public override func visit(decl: FuncDecl): Unit {
        let name = decl.identifier.value
        let kind = if (name == "init") { "constructor" } else { "function" }
        if (let Some(symbol) <- add(decl, kind, name, hasBody: true)) {
            addParameters(symbol, decl.funcParams)
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
        breakTraverse()
    }

    public override func visit(decl: PrimaryCtorDecl): Unit {
        if (let Some(symbol) <- add(decl, "constructor", decl.identifier.value, hasBody: true)) {
            addParameters(symbol, decl.funcParams)
        }
        for (parameter in decl.funcParams) { addPrimaryConstructorMember(parameter) }
        breakTraverse()
    }

    public override func visit(decl: MainDecl): Unit {
        if (decl.beginPos.line > 0 && decl.beginPos.column > 0 && decl.endPos.line > 0 && decl.endPos.column > 0) {
            localScopes.add(SourceLocation(path, Int64(decl.beginPos.line), Int64(decl.beginPos.column),
                Int64(decl.endPos.line), Int64(decl.endPos.column)))
        }
        breakTraverse()
    }

    public override func visit(decl: MacroDecl): Unit {
        let location = SourceLocation(path, Int64(decl.beginPos.line), Int64(decl.beginPos.column),
            Int64(decl.endPos.line), Int64(decl.endPos.column))
        diagnostics.add(Diagnostic("warning", "CJDOC1009",
            "unsupported declaration 'macro ${decl.identifier.value}'", source: location))
        unsupportedDeclarations.add(UnsupportedDeclaration("macro", decl.identifier.value,
            "macro expansion is not executed", location))
        breakTraverse()
    }

    public override func visit(decl: MacroExpandDecl): Unit {
        let name = try { decl.fullIdentifier.value } catch (_: Exception) {
            try { decl.identifier.value } catch (_: Exception) { "<macro>" }
        }
        let location = SourceLocation(path, Int64(decl.beginPos.line), Int64(decl.beginPos.column),
            Int64(decl.endPos.line), Int64(decl.endPos.column))
        diagnostics.add(Diagnostic("warning", "CJDOC1009",
            "macro invocation '${name}' is not expanded", source: location))
        macroInvocations.add(MacroInvocation(name, location))
        unsupportedDeclarations.add(UnsupportedDeclaration("macroInvocation", name,
            "macro expansion is not executed", location))
        breakTraverse()
    }
}

private func commentLocation(path: String, token: Token): SourceLocation {
    let lines = token.value.split("\n")
    let startLine = Int64(token.pos.line)
    let startColumn = Int64(token.pos.column)
    let endLine = startLine + lines.size - 1
    let endColumn = if (lines.size == 1) {
        startColumn + lines[0].size
    } else {
        lines[lines.size - 1].size + 1
    }
    return SourceLocation(path, startLine, startColumn, endLine, endColumn)
}

private func collectDocComments(path: String, tokens: Tokens): ArrayList<RawDocComment> {
    let comments = ArrayList<RawDocComment>()
    for (token in tokens) {
        if (token.kind == COMMENT && token.value.startsWith("/**")) {
            comments.add(RawDocComment(token.value, commentLocation(path, token)))
        }
    }
    return comments
}

private func isBinaryOperator(value: String): Bool {
    match (value) {
        case "+" | "-" | "*" | "/" | "%" | "&&" | "||" | "==" | "!=" |
            "<" | ">" | "<=" | ">=" | "&" | "|" | "^" | "<<" | ">>" | "??" => true
        case _ => false
    }
}

// The preflight path excludes punctuation that is ambiguous with enum/generic
// syntax. After a worker SIGSEGV, the broader form classifies the known deep
// BinaryExpr failure while the failed parser supplies the additional signal.
private func looksLikeUnsafeBinaryExpressionDepth(tokens: Tokens,
    includeAmbiguousPunctuation: Bool): Bool {
    let safeOperatorLimit: Int64 = 64
    let outerOperators = ArrayList<Int64>()
    var operators: Int64 = 0
    for (token in tokens) {
        let unambiguous = token.value != "|" && token.value != "<" &&
            token.value != ">" && token.value != ">>" && token.value != "&"
        if (isBinaryOperator(token.value) && (includeAmbiguousPunctuation || unambiguous)) {
            operators++
            if (operators >= safeOperatorLimit) { return true }
        } else {
            match (token.value) {
                case "(" =>
                    outerOperators.add(operators)
                    operators = 0
                case ")" =>
                    if (outerOperators.isEmpty()) {
                        operators = 0
                    } else {
                        operators = outerOperators[outerOperators.size - 1]
                        outerOperators.remove(at: outerOperators.size - 1)
                    }
                case "," => operators = 0
                case ";" | "{" | "}" | "=" | "let" | "var" | "return" =>
                    operators = 0
                    while (!outerOperators.isEmpty()) {
                        outerOperators.remove(at: outerOperators.size - 1)
                    }
                case _ => ()
            }
        }
    }
    false
}

// std.ast in the 2026-08-29 daily reproducibly crashes while serializing a
// BinaryExpr chain at 67 operators. Keep a small safety margin and fail this
// file explicitly instead of allowing a native SIGSEGV to terminate cjdoc.
private func binaryExpressionDepthAtLeast(expression: Expr, depth: Int64): Bool {
    let safeOperatorLimit: Int64 = 64
    match (expression) {
        case binary: BinaryExpr =>
            let nextDepth = depth + 1
            if (nextDepth >= safeOperatorLimit) { return true }
            binaryExpressionDepthAtLeast(binary.leftExpr, nextDepth) ||
                binaryExpressionDepthAtLeast(binary.rightExpr, nextDepth)
        case _ => false
    }
}

private class BinaryExpressionDepthVisitor <: Visitor {
    var exceeded = false

    public override func visit(expression: BinaryExpr): Unit {
        if (!exceeded && binaryExpressionDepthAtLeast(expression, 0)) {
            exceeded = true
        }
        if (exceeded) {
            breakTraverse()
        }
    }
}

private func exceedsSafeBinaryExpressionDepth(program: Program): Bool {
    let visitor = BinaryExpressionDepthVisitor()
    program.traverse(visitor)
    visitor.exceeded
}

private func isFunctionLike(symbol: SourceDeclaration): Bool {
    return symbol.kind == "function" || symbol.kind == "constructor"
}

private func sourceOrderLess(left: SourceDeclaration, right: SourceDeclaration): Bool {
    if (left.source.path != right.source.path) { return left.source.path < right.source.path }
    if (left.source.startLine != right.source.startLine) {
        return left.source.startLine < right.source.startLine
    }
    if (left.source.startColumn != right.source.startColumn) {
        return left.source.startColumn < right.source.startColumn
    }
    if (left.source.endLine != right.source.endLine) { return left.source.endLine > right.source.endLine }
    return left.source.endColumn > right.source.endColumn
}

private func removeLocalDeclarations(symbols: ArrayList<SourceDeclaration>,
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
        if (!activeFunctions.isEmpty()) {
            symbols.remove(at: index)
        } else {
            if (isFunctionLike(symbols[index])) { activeFunctions.add(symbols[index].source) }
            index++
        }
    }
}

private func assignOwners(symbols: ArrayList<SourceDeclaration>): Unit {
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

private func onlyWhitespaceBetween(source: IndexedSourceBuffer, left: SourceLocation,
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
    return index == end
}

private func sameSourceRange(left: SourceLocation, right: SourceLocation): Bool {
    left.path == right.path && left.startLine == right.startLine &&
        left.startColumn == right.startColumn && left.endLine == right.endLine &&
        left.endColumn == right.endColumn
}

private func bindComments(symbols: ArrayList<SourceDeclaration>,
    comments: ArrayList<RawDocComment>, source: IndexedSourceBuffer): ArrayList<OrphanDocComment> {
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    var symbolIndex: Int64 = 0
    while (symbolIndex < symbols.size) {
        let symbol = symbols[symbolIndex]
        while (commentIndex < comments.size &&
            positionLessOrEqual(comments[commentIndex].source.endLine, comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        if (let Some(comment) <- candidate) {
            if (!comment.bound && onlyWhitespaceBetween(source, comment.source, symbol.source)) {
                var groupedIndex = symbolIndex
                while (groupedIndex < symbols.size &&
                    sameSourceRange(symbols[groupedIndex].source, symbol.source)) {
                    // DocComment is mutable while tags are resolved, so every
                    // destructured binding receives an independent instance.
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
    return orphans
}

func percentEscapeSymbolPart(value: String): String {
    let builder = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case ':' => builder.append("%3A")
            case '#' => builder.append("%23")
            case '(' => builder.append("%28")
            case ')' => builder.append("%29")
            case ',' => builder.append("%2C")
            case '%' => builder.append("%25")
            case _ => builder.append(rune)
        }
    }
    return builder.toString()
}

func normalizedHostPath(path: String): String {
    // A backslash is a separator on Windows but ordinary filename data on
    // POSIX. Preserve it in absolute POSIX paths so host containment never
    // aliases `a\\b` with `a/b`; logical relative paths reject it below.
    let normalized = if (path.startsWith("/")) { path } else { path.replace("\\", "/") }
    if (normalized.endsWith("/") && normalized != "/" && !normalized.endsWith(":/")) {
        normalized.trimEnd("/")
    } else {
        normalized
    }
}

func hostPathIsWithin(root: String, candidate: String): Bool {
    let normalizedRoot = normalizedHostPath(root)
    let normalizedCandidate = normalizedHostPath(candidate)
    let prefix = if (normalizedRoot.endsWith("/")) { normalizedRoot } else { normalizedRoot + "/" }
    normalizedCandidate == normalizedRoot || normalizedCandidate.startsWith(prefix)
}

private func safeLogicalSourcePath(path: String, allowEmpty!: Bool = false): Bool {
    if (path.isEmpty()) { return allowEmpty }
    if (path.startsWith("/") || path.contains("\\")) { return false }
    let segments = path.split("/")
    let first = segments[0]
    if (first.size >= 2 && first[1] == b':' &&
        ((first[0] >= b'a' && first[0] <= b'z') ||
        (first[0] >= b'A' && first[0] <= b'Z'))) { return false }
    for (segment in segments) {
        if (segment.isEmpty() || segment == "." || segment == "..") { return false }
    }
    true
}

private func safePackageSourceDirectory(path: String): Bool {
    if (path.isEmpty() || path == ".") { return true }
    safeLogicalSourcePath(path)
}

private func resolvedPackageSourceRoot(moduleRoot: String,
    configured: ?String): ?String {
    let relative = match (configured) {
        case Some(value) => if (value.isEmpty()) { "src" } else { value }
        case None => "src"
    }
    if (!safePackageSourceDirectory(relative)) { return None }
    let candidate = if (relative == ".") {
        moduleRoot
    } else {
        Path(moduleRoot).join(relative).toString()
    }
    let resolved = try { canonicalize(candidate).toString() } catch (_: Exception) { return None }
    if (!hostPathIsWithin(moduleRoot, resolved)) { return None }
    let directory = try { FileInfo(resolved) } catch (_: Exception) { return None }
    if (!directory.isDirectory() || directory.isSymbolicLink()) { return None }
    Some(resolved)
}

func relativePathFromResolved(root: String, path: String): ?String {
    let base = normalizedHostPath(root)
    let full = normalizedHostPath(path)
    if (full == base) { return Some("") }
    let prefix = if (base.endsWith("/")) { base } else { base + "/" }
    if (!full.startsWith(prefix)) { return None }
    let relative = full[prefix.size..]
    if (!safeLogicalSourcePath(relative)) { return None }
    Some(relative)
}

private func relativePath(root: String, path: String): ?String {
    let base = canonicalize(root).toString()
    let full = canonicalize(path).toString()
    relativePathFromResolved(base, full)
}

class SourceDirectoryBudget {
    let maxEntries: Int64
    let maxDepth: Int64
    var entries: Int64 = 0
    var limitReached = false
    var unsafeLogicalPath = false

    init(maxEntries!: Int64 = MAX_SOURCE_DIRECTORY_ENTRIES,
        maxDepth!: Int64 = MAX_SOURCE_DIRECTORY_DEPTH) {
        if (maxEntries < 1 || maxDepth < 0) {
            throw IllegalArgumentException("source directory limits are invalid")
        }
        this.maxEntries = maxEntries
        this.maxDepth = maxDepth
    }

    func consume(relative: String): Bool {
        if (entries >= maxEntries) {
            limitReached = true
            return false
        }
        entries++
        let depth = if (relative.isEmpty()) { 0 } else { relative.split("/").size }
        if (depth > maxDepth) {
            limitReached = true
            return false
        }
        true
    }
}

private func collectSourceFilesInDirectory(rootDirectory: String, directory: String,
    result: ArrayList<String>, limit: Int64, budget: SourceDirectoryBudget): Bool {
    let complete = Array<Bool>(1, repeat: true)
    Directory.walk(Path(directory), { entry =>
        match (relativePathFromResolved(rootDirectory, entry.path.toString())) {
            case None =>
                budget.unsafeLogicalPath = true
                complete[0] = false
                false
            case Some(relative) =>
                if (!budget.consume(relative)) {
                    complete[0] = false
                    false
                } else if (entry.isSymbolicLink() || entry.isHidden()) {
                    true
                } else if (entry.isDirectory()) {
                    if (!collectSourceFilesInDirectory(rootDirectory, entry.path.toString(),
                        result, limit, budget)) {
                        complete[0] = false
                        false
                    } else {
                        true
                    }
                } else if (entry.isRegular() && entry.path.extensionName == "cj" &&
                    !entry.name.endsWith("_test.cj")) {
                    if (result.size >= limit) {
                        budget.limitReached = true
                        complete[0] = false
                        false
                    } else {
                        result.add(entry.path.toString())
                        true
                    }
                } else {
                    true
                }
        }
    })
    complete[0]
}

private func collectSourceFiles(directory: String, result: ArrayList<String>,
    limit: Int64, budget: SourceDirectoryBudget): Bool {
    let complete = collectSourceFilesInDirectory(directory, directory, result, limit, budget)
    sortStrings(result)
    complete
}

private func logicalSourcePath(projectRoot: String, module: SourceModuleRoot,
    file: String): ?String {
    let moduleRelative = match (relativePath(module.actualRoot, file)) {
        case Some(value) => value
        case None => return None
    }
    if (module.logicalPrefix.isEmpty()) { return relativePath(projectRoot, file) }
    let logical = module.logicalPrefix + "/" + moduleRelative
    if (safeLogicalSourcePath(logical)) { Some(logical) } else { None }
}

private class SourceModuleRoot {
    let actualRoot: String
    let actualSourceRoot: String
    let logicalPrefix: String
    let documentation: SourceModule

    init(actualRoot: String, actualSourceRoot: String, logicalPrefix: String,
        documentation: SourceModule) {
        this.actualRoot = actualRoot
        this.actualSourceRoot = actualSourceRoot
        this.logicalPrefix = logicalPrefix
        this.documentation = documentation
    }
}

private class SourceDiscoveryBudget {
    var dependencyEdges: Int64 = 0
    var limitReached = false
    private var moduleCandidates: Int64 = 0
    private var dependencyCandidates: Int64 = 0
    private var invalidDependencyEdgeReported = false

    func remainingModuleCandidates(): Int64 {
        MAX_SOURCE_MODULES - moduleCandidates
    }

    func remainingDependencyCandidates(): Int64 {
        MAX_SOURCE_DEPENDENCY_EDGES - dependencyCandidates
    }

    func remainingDependencyDiscoveries(): Int64 {
        let modules = remainingModuleCandidates()
        let dependencies = remainingDependencyCandidates()
        if (modules < dependencies) { modules } else { dependencies }
    }

    func consumeModuleCandidates(count: Int64): Unit {
        moduleCandidates += count
    }

    func consumeDependencyCandidates(count: Int64): Unit {
        moduleCandidates += count
        dependencyCandidates += count
    }

    // GenerationRequest already bounds explicit dependencySources. Counting
    // those entries as both module candidates and dependency candidates here
    // charged them twice before any module was actually accepted.
    func consumeExplicitDependencyCandidates(count: Int64): Unit {
        dependencyCandidates += count
    }

    func markLimitReached(): Unit { limitReached = true }

    func canAddModule(currentCount: Int64): Bool {
        if (currentCount >= MAX_SOURCE_MODULES) {
            limitReached = true
            return false
        }
        true
    }

    func addDependency(modules: ArrayList<SourceModuleRoot>, owner: SourceModule,
        dependencyId: String, diagnostics: ArrayList<Diagnostic>): Bool {
        for (existing in owner.dependencyIds) {
            if (existing == dependencyId) { return true }
        }
        if (dependencyWouldCreateCycle(modules, owner.id, dependencyId)) {
            if (!invalidDependencyEdgeReported) {
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "dependency edge would create a self-reference or cycle; skipped"))
                invalidDependencyEdgeReported = true
            }
            return true
        }
        if (dependencyEdges >= MAX_SOURCE_DEPENDENCY_EDGES) {
            limitReached = true
            return false
        }
        owner.dependencyIds.add(dependencyId)
        dependencyEdges++
        true
    }
}

private class SourceInputFile {
    let actualPath: String
    let actualRoot: String
    let logicalPath: String
    let module: SourceModule
    let discoveredSize: Int64

    init(actualPath: String, actualRoot: String, logicalPath: String, module: SourceModule,
        discoveredSize: Int64) {
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.logicalPath = logicalPath
        this.module = module
        this.discoveredSize = discoveredSize
    }
}

private func sortStrings(values: ArrayList<String>): Unit {
    sort(values)
}

func dependencyPrefix(name: String): String {
    if (!safeDependencyLogicalName(name)) {
        throw IllegalArgumentException("dependency name cannot form a logical source prefix")
    }
    "dependencies/" + name
}

private func moduleId(role: String, name: String, logicalPrefix: String): String {
    if (role == "root") { return "cjdoc:module:v1:root" }
    if (role == "workspace") { return "cjdoc:module:v1:workspace:${logicalPrefix}" }
    if (role == "externalDependency") { return "cjdoc:module:v1:external:${percentEscapeSymbolPart(name)}" }
    "cjdoc:module:v1:path:${percentEscapeSymbolPart(name)}"
}

private func findSourceModule(modules: ArrayList<SourceModuleRoot>, actualRoot: String): ?SourceModuleRoot {
    for (module in modules) {
        if (module.actualRoot == actualRoot) { return Some(module) }
    }
    None
}

private func findSourceModuleById(modules: ArrayList<SourceModuleRoot>, id: String): ?SourceModuleRoot {
    for (module in modules) {
        if (module.documentation.id == id) { return Some(module) }
    }
    None
}

private func dependencyWouldCreateCycle(modules: ArrayList<SourceModuleRoot>,
    ownerId: String, dependencyId: String): Bool {
    if (ownerId == dependencyId) { return true }
    let pending = ArrayList<String>()
    let visited = HashSet<String>()
    pending.add(dependencyId)
    var cursor: Int64 = 0
    var checkedEdges: Int64 = 0
    while (cursor < pending.size) {
        let currentId = pending[cursor]
        cursor++
        if (currentId == ownerId) { return true }
        if (!visited.add(currentId)) { continue }
        let current = match (findSourceModuleById(modules, currentId)) {
            case Some(value) => value
            case None => return true
        }
        for (next in current.documentation.dependencyIds) {
            checkedEdges++
            if (checkedEdges > MAX_SOURCE_DEPENDENCY_EDGES) { return true }
            if (!visited.contains(next)) { pending.add(next) }
        }
    }
    false
}

private func sourceModuleCollision(modules: ArrayList<SourceModuleRoot>,
    candidate: SourceModuleRoot): Bool {
    for (existing in modules) {
        if (existing.actualRoot == candidate.actualRoot ||
            existing.logicalPrefix == candidate.logicalPrefix ||
            existing.documentation.id == candidate.documentation.id ||
            hostPathIsWithin(existing.actualSourceRoot, candidate.actualSourceRoot) ||
            hostPathIsWithin(candidate.actualSourceRoot, existing.actualSourceRoot)) {
            return true
        }
    }
    false
}

private func addModuleRoot(workspaceRoot: String, candidate: String, roots: ArrayList<String>,
    seen: HashSet<String>, diagnostics: ArrayList<Diagnostic>, required!: Bool = false): Bool {
    let severity = if (required) { "error" } else { "warning" }
    let resolved = try {
        canonicalize(candidate).toString()
    } catch (_: Exception) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member is not accessible"))
        return false
    }
    if (!hostPathIsWithin(workspaceRoot, resolved)) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member escapes project root; skipped"))
        return false
    }
    if (relativePathFromResolved(workspaceRoot, resolved).isNone()) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member cannot be represented by a portable logical path; skipped"))
        return false
    }
    if (!exists(Path(resolved).join("cjpm.toml"))) {
        diagnostics.add(Diagnostic(severity, "CJDOC1010",
            "workspace member must contain cjpm.toml; skipped"))
        return false
    }
    if (!seen.add(resolved)) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace members resolve to a duplicate module root; skipped"))
        return false
    }
    roots.add(resolved)
    return true
}

private func discoverModuleRoots(root: String, manifest: String,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): ArrayList<String> {
    let roots = ArrayList<String>()
    let seen = HashSet<String>()
    let rootPackage = parseCjpmPackageNameChecked(manifest)
    if (rootPackage.value.isSome()) {
        let _ = addModuleRoot(root, root, roots, seen, diagnostics, required: true)
    }
    if (!auxiliaryBudget.consumeWork(manifest.size)) {
        budget.markLimitReached()
        return roots
    }
    let workspace = parseCjpmWorkspaceMembers(manifest, budget.remainingModuleCandidates())
    budget.consumeModuleCandidates(workspace.entryCount)
    if (workspace.invalid) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace metadata contains an invalid TOML string; source discovery stopped"))
        return roots
    }
    for (member in workspace.values) {
        if (!safeLogicalSourcePath(member)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1010",
                "workspace member cannot be represented by a portable logical path; skipped"))
            continue
        }
        let _ = addModuleRoot(root, Path(root).join(member).toString(), roots, seen, diagnostics)
    }
    if (workspace.limitReached) { budget.markLimitReached() }
    if (roots.isEmpty()) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "project must declare a source package or workspace members"))
    }
    sortStrings(roots)
    return roots
}

private func addExternalSourceModule(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, input: DependencySourceInput,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): ?SourceModuleRoot {
    if (!safeDependencyLogicalName(input.name)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source has an unsafe logical name; skipped"))
        return None
    }
    let resolved = try {
        canonicalize(input.path).toString()
    } catch (_: Exception) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' is not accessible; skipped"))
        return None
    }
    if (seen.contains(resolved)) {
        let existing = findSourceModule(modules, resolved)
        if (let Some(module) <- existing) {
            let expectedPrefix = dependencyPrefix(input.name)
            let expectedId = moduleId("externalDependency", input.name, expectedPrefix)
            if (module.logicalPrefix != expectedPrefix || module.documentation.id != expectedId) {
                diagnostics.add(Diagnostic("warning", "CJDOC1018",
                    "configured dependency source collides with an existing module identity; skipped"))
                return None
            }
        }
        return existing
    }
    let manifestPath = Path(resolved).join("cjpm.toml")
    if (!exists(manifestPath)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' must contain cjpm.toml; skipped"))
        return None
    }
    let dependencyManifest = try {
        readAuxiliaryTextBounded(manifestPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
    } catch (_: Exception) {
        if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); return None }
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' manifest is not readable; skipped"))
        return None
    }
    if (!auxiliaryBudget.consumeWork(dependencyManifest.size)) {
        budget.markLimitReached()
        return None
    }
    let packageView = parseCjpmPackageNameChecked(dependencyManifest)
    if (packageView.limitReached) {
        budget.markLimitReached()
        return None
    }
    if (packageView.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source manifest contains invalid metadata; skipped"))
        return None
    }
    let packageName = match (packageView.value) {
        case Some(value) => value
        case None => input.name
    }
    let sourceRoot = match (resolvedPackageSourceRoot(resolved,
        packageView.sourceDirectory)) {
        case Some(value) => value
        case None =>
            diagnostics.add(Diagnostic("warning", "CJDOC1018",
                "configured dependency source has an invalid or unavailable package.src-dir; skipped"))
            return None
    }
    let prefix = dependencyPrefix(input.name)
    for (module in modules) {
        if (module.logicalPrefix == prefix && module.actualRoot != resolved) {
            diagnostics.add(Diagnostic("warning", "CJDOC1018",
                "configured dependency source '${input.name}' has a duplicate logical name; skipped"))
            return None
        }
    }
    let moduleDoc = SourceModule(moduleId("externalDependency", input.name, prefix),
        packageName, "externalDependency", prefix, organization: packageView.organization)
    let module = SourceModuleRoot(resolved, sourceRoot, prefix, moduleDoc)
    if (sourceModuleCollision(modules, module)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source collides with an existing module identity or source root; skipped"))
        return None
    }
    if (!budget.canAddModule(modules.size)) { return None }
    let _ = seen.add(resolved)
    modules.add(module)
    Some(module)
}

private func addExternalSourceModules(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, inputs: Array<DependencySourceInput>, ownerCount: Int64,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    if (inputs.isEmpty() || ownerCount == 0 || budget.limitReached) { return }
    let sortedInputs = ArrayList<DependencySourceInput>()
    let remaining = budget.remainingDependencyDiscoveries()
    var inputIndex: Int64 = 0
    while (inputIndex < inputs.size && sortedInputs.size < remaining) {
        sortedInputs.add(inputs[inputIndex])
        inputIndex++
    }
    let truncated = inputIndex < inputs.size
    budget.consumeExplicitDependencyCandidates(sortedInputs.size)
    sort(sortedInputs, lessThan: { left, right =>
        if (left.name == right.name) { left.path < right.path } else { left.name < right.name }
    }, stable: true)
    for (input in sortedInputs) {
        if (budget.limitReached) { break }
        if (let Some(dependency) <- addExternalSourceModule(modules, seen, input, diagnostics,
            budget, auxiliaryBudget)) {
            var ownerIndex: Int64 = 0
            while (ownerIndex < ownerCount) {
                if (!budget.addDependency(modules, modules[ownerIndex].documentation,
                    dependency.documentation.id, diagnostics)) { break }
                ownerIndex++
            }
        }
    }
    if (truncated) { budget.markLimitReached() }
}

private func safeDependencyCacheName(name: String): Bool {
    if (name.isEmpty() || name == "." || name == "..") { return false }
    for (byte in name.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

private func dependencyInputNamed(inputs: Array<DependencySourceInput>, name: String): ?DependencySourceInput {
    for (input in inputs) {
        if (input.name == name) { return Some(input) }
    }
    None
}

private func selectedCjpmCacheRoot(cacheRoot: ?String,
    diagnostics: ArrayList<Diagnostic>): ?String {
    let selected: ?String = match (cacheRoot) {
        case Some(value) => Some(value)
        case None => match (getVariable("HOME")) {
            case Some(home) => Some(Path(home).join(".cjpm").toString())
            case None => None
        }
    }
    if (selected.isNone()) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery requires --cjpm-cache or HOME"))
        return None
    }
    selected
}

private func cachedDependencySource(dependency: CjpmLockedDependency, cacheRoot: String,
    diagnostics: ArrayList<Diagnostic>): ?DependencySourceInput {
    if (!safeDependencyLogicalName(dependency.name)) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "locked dependency name is unsafe for cache lookup; skipped"))
        return None
    }
    let candidate: ?String = match ((dependency.commitId, dependency.version)) {
        case (Some(commitId), _) =>
            if (!safeDependencyCacheName(commitId)) { None } else {
                Some(Path(cacheRoot).join("git").join(dependency.name)
                    .join(commitId).toString())
            }
        case (_, Some(version)) =>
            if (version.contains("/") || version.contains("\\") || version.contains("..")) { None } else {
                Some(Path(cacheRoot).join("repository").join("source").join("default")
                    .join("${dependency.name}-${version}").toString())
            }
        case _ => None
    }
    match (candidate) {
        case Some(path) =>
            let resolvedRoot = try {
                canonicalize(cacheRoot).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "selected cjpm cache root is not accessible; cached dependency skipped"))
                return None
            }
            let resolved = try {
                canonicalize(path).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            let manifestPath = Path(resolved).join("cjpm.toml")
            let resolvedManifest = try {
                canonicalize(manifestPath).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            let manifestInfo = try { FileInfo(manifestPath) } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                return None
            }
            if (!hostPathIsWithin(resolvedRoot, resolved) ||
                !hostPathIsWithin(resolvedRoot, resolvedManifest) ||
                !manifestInfo.isRegular() || manifestInfo.isSymbolicLink()) {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' escapes the selected cjpm cache; skipped"))
                return None
            }
            Some(DependencySourceInput(dependency.name, resolved))
        case None =>
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "locked dependency '${dependency.name}' cannot be mapped to a safe cjpm cache path; skipped"))
            None
    }
}

private func readLockedDependencies(directory: String, required: Bool,
    diagnostics: ArrayList<Diagnostic>, maxEntries: Int64,
    auxiliaryBudget: SourceAuxiliaryBudget): CjpmLockView {
    let lockPath = Path(directory).join("cjpm.lock")
    if (!exists(lockPath)) {
        if (required) {
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "cached dependency discovery requested but cjpm.lock is missing"))
        }
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, false)
    }
    let lockText = try {
        readAuxiliaryTextBounded(lockPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
    } catch (_: Exception) {
        if (auxiliaryBudget.limitReached()) {
            return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, true)
        }
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery skipped an unreadable cjpm.lock"))
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, false)
    }
    if (!auxiliaryBudget.consumeWork(lockText.size)) {
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), 0, true)
    }
    let parsed = parseCjpmLock(lockText, maxEntries: maxEntries)
    if (parsed.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery skipped invalid lock metadata"))
        return CjpmLockView(ArrayList<CjpmLockedDependency>(), parsed.entryCount,
            parsed.limitReached, invalid: true)
    }
    parsed
}

private func addLockedDependency(modules: ArrayList<SourceModuleRoot>, seen: HashSet<String>,
    owners: Array<SourceModuleRoot>, dependency: CjpmLockedDependency,
    cacheRoot: String, explicitInputs: Array<DependencySourceInput>,
    diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    let input = match (dependencyInputNamed(explicitInputs, dependency.name)) {
        case Some(explicit) => Some(explicit)
        case None => cachedDependencySource(dependency, cacheRoot, diagnostics)
    }
    if (let Some(sourceInput) <- input) {
        if (let Some(dependencyModule) <- addExternalSourceModule(modules, seen,
            sourceInput, diagnostics, budget, auxiliaryBudget)) {
            for (owner in owners) {
                if (!budget.addDependency(modules, owner.documentation,
                    dependencyModule.documentation.id, diagnostics)) { break }
            }
        }
    }
}

private func safeCjpmTargetName(value: String): Bool {
    if (value.isEmpty()) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'_' || byte == b'-')) { return false }
    }
    true
}

private func currentCjpmTarget(): ?String {
    try {
        let (exitCode, output, _) = executeWithOutput("cjc", ["--version"])
        if (exitCode != 0 || output.size > 64 * 1024) { return None }
        let text = String.fromUtf8(output)
        for (line in text.split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.startsWith("Target:")) {
                let value = trimmed.removePrefix("Target:").trimAscii()
                if (safeCjpmTargetName(value)) { return Some(value) }
                return None
            }
        }
    } catch (_: Exception) {}
    None
}

private func addPathDependencies(modules: ArrayList<SourceModuleRoot>, seen: HashSet<String>,
    owners: Array<SourceModuleRoot>, baseRoot: String, manifest: String,
    selectedTarget: ?String, diagnostics: ArrayList<Diagnostic>, budget: SourceDiscoveryBudget,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    if (owners.isEmpty() || budget.limitReached) { return }
    if (!auxiliaryBudget.consumeWork(manifest.size)) {
        budget.markLimitReached()
        return
    }
    let pathDependencies = parseCjpmPathDependencies(manifest,
        budget.remainingDependencyDiscoveries(), selectedTarget: selectedTarget)
    budget.consumeDependencyCandidates(pathDependencies.entryCount)
    if (pathDependencies.partial) {
        diagnostics.add(Diagnostic("warning", "CJDOC1016",
            "path dependency metadata contains a legal form that is not fully supported; dependency graph is partial"))
    }
    if (pathDependencies.invalid) {
        diagnostics.add(Diagnostic("warning", "CJDOC1016",
            "path dependency metadata contains invalid TOML; skipped"))
        return
    }
    for (dependencyPath in pathDependencies.values) {
        let candidatePath = Path(baseRoot).join(dependencyPath).toString()
        let resolved = try {
            canonicalize(candidatePath).toString()
        } catch (_: Exception) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency is not accessible; skipped"))
            continue
        }
        if (seen.contains(resolved)) {
            if (let Some(existing) <- findSourceModule(modules, resolved)) {
                for (owner in owners) {
                    let _ = budget.addDependency(modules, owner.documentation,
                        existing.documentation.id, diagnostics)
                    if (budget.limitReached) { break }
                }
            }
            if (budget.limitReached) { break }
            continue
        }
        let dependencyManifestPath = Path(resolved).join("cjpm.toml")
        if (!exists(dependencyManifestPath)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1015",
                "path dependency is not a Cangjie source package; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencyManifest = try {
            readAuxiliaryTextBounded(dependencyManifestPath, MAX_SOURCE_FILE_BYTES,
                auxiliaryBudget)
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest is not readable; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        if (!auxiliaryBudget.consumeWork(dependencyManifest.size)) {
            budget.markLimitReached()
            break
        }
        let dependencyPackage = parseCjpmPackageNameChecked(dependencyManifest)
        if (dependencyPackage.limitReached) {
            budget.markLimitReached()
            break
        }
        if (dependencyPackage.invalid) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest contains invalid metadata; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencyName = match (dependencyPackage.value) {
            case Some(name) => name
            case None => Path(resolved).fileName
        }
        if (!safeDependencyLogicalName(dependencyName)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency has an unsafe logical name; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let dependencySourceRoot = match (resolvedPackageSourceRoot(resolved,
            dependencyPackage.sourceDirectory)) {
            case Some(value) => value
            case None =>
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "path dependency has an invalid or unavailable package.src-dir; skipped"))
                let _ = seen.add(resolved)
                continue
        }
        let prefix = dependencyPrefix(dependencyName)
        let dependencyDoc = SourceModule(moduleId("pathDependency", dependencyName, prefix),
            dependencyName, "pathDependency", prefix,
            organization: dependencyPackage.organization)
        if (!budget.canAddModule(modules.size)) { break }
        let dependencyModule = SourceModuleRoot(resolved, dependencySourceRoot,
            prefix, dependencyDoc)
        if (sourceModuleCollision(modules, dependencyModule)) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency module identity, source root, or logical prefix collides; skipped"))
            let _ = seen.add(resolved)
            continue
        }
        let _ = seen.add(resolved)
        modules.add(dependencyModule)
        for (owner in owners) {
            let _ = budget.addDependency(modules, owner.documentation,
                dependencyDoc.id, diagnostics)
            if (budget.limitReached) { break }
        }
        if (budget.limitReached) { break }
    }
    if (pathDependencies.limitReached) { budget.markLimitReached() }
}

private func discoverSourceModules(root: String, manifest: String, includePathDependencies: Bool,
    dependencySources: Array<DependencySourceInput>,
    includeCachedDependencies: Bool, cjpmCacheRoot: ?String,
    diagnostics: ArrayList<Diagnostic>, auxiliaryBudget: SourceAuxiliaryBudget): ArrayList<SourceModuleRoot> {
    let modules = ArrayList<SourceModuleRoot>()
    let seen = HashSet<String>()
    let budget = SourceDiscoveryBudget()
    for (moduleRoot in discoverModuleRoots(root, manifest, diagnostics, budget, auxiliaryBudget)) {
        if (budget.limitReached) { break }
        if (!budget.canAddModule(modules.size)) { break }
        let _ = seen.add(moduleRoot)
        let moduleManifest = try {
            if (moduleRoot == root) { manifest } else {
                readAuxiliaryTextBounded(Path(moduleRoot).join("cjpm.toml"),
                    MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
            }
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                "CJDOC1010", "workspace member manifest is not readable; skipped"))
            continue
        }
        if (!auxiliaryBudget.consumeWork(moduleManifest.size)) {
            budget.markLimitReached()
            break
        }
        let packageView = parseCjpmPackageNameChecked(moduleManifest)
        if (packageView.limitReached) {
            budget.markLimitReached()
            break
        }
        if (packageView.invalid) {
            diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                "CJDOC1010", "workspace member manifest contains invalid metadata; skipped"))
            continue
        }
        let name = match (packageView.value) {
            case Some(actual) => actual
            case None => Path(moduleRoot).fileName
        }
        let sourceRoot = match (resolvedPackageSourceRoot(moduleRoot,
            packageView.sourceDirectory)) {
            case Some(value) => value
            case None =>
                diagnostics.add(Diagnostic(if (moduleRoot == root) { "error" } else { "warning" },
                    "CJDOC1010",
                    "workspace member has an invalid or unavailable package.src-dir; skipped"))
                continue
        }
        let role = if (moduleRoot == root) { "root" } else { "workspace" }
        let prefix = if (moduleRoot == root) {
            ""
        } else {
            match (relativePath(root, moduleRoot)) {
                case Some(value) => value
                case None =>
                    diagnostics.add(Diagnostic("error", "CJDOC1010",
                        "workspace member cannot form a portable logical prefix; skipped"))
                    continue
            }
        }
        let moduleDoc = SourceModule(moduleId(role, name, prefix), name, role, prefix,
            organization: packageView.organization)
        let module = SourceModuleRoot(moduleRoot, sourceRoot, prefix, moduleDoc)
        if (sourceModuleCollision(modules, module)) {
            diagnostics.add(Diagnostic("error", "CJDOC1010",
                "workspace module identity, source root, or logical prefix collides; skipped"))
            continue
        }
        modules.add(module)
    }
    let initialOwnerCount = modules.size
    addExternalSourceModules(modules, seen, dependencySources, initialOwnerCount, diagnostics,
        budget, auxiliaryBudget)
    let selectedCacheRoot: ?String = if (includeCachedDependencies) {
        selectedCjpmCacheRoot(cjpmCacheRoot, diagnostics)
    } else {
        None
    }
    if (let Some(cacheRoot) <- selectedCacheRoot) {
        if (!budget.limitReached) {
            let owners = ArrayList<SourceModuleRoot>()
            var ownerIndex: Int64 = 0
            while (ownerIndex < initialOwnerCount) {
                owners.add(modules[ownerIndex])
                ownerIndex++
            }
            let locked = readLockedDependencies(root, true, diagnostics,
                budget.remainingDependencyDiscoveries(), auxiliaryBudget)
            budget.consumeDependencyCandidates(locked.entryCount)
            for (dependency in locked.dependencies) {
                if (budget.limitReached) { break }
                addLockedDependency(modules, seen, owners.toArray(), dependency,
                    cacheRoot, dependencySources, diagnostics, budget, auxiliaryBudget)
            }
            if (locked.limitReached) { budget.markLimitReached() }
        }
    }
    if (!includePathDependencies && !includeCachedDependencies) {
        if (budget.limitReached) {
            addSourceLimitDiagnostic(diagnostics, if (auxiliaryBudget.limitReached()) {
                "source metadata or cache exceeded the configured aggregate byte/work safety budget; source discovery stopped"
            } else {
                "source discovery exceeded 4096 modules or 16384 dependency edges; remaining modules skipped"
            })
        }
        return modules
    }

    let selectedTarget: ?String = if (includePathDependencies) {
        currentCjpmTarget()
    } else {
        None<String>
    }
    if (includePathDependencies && findSourceModule(modules, root).isNone() &&
        initialOwnerCount > 0 && !budget.limitReached) {
        let workspaceOwners = ArrayList<SourceModuleRoot>()
        var ownerIndex: Int64 = 0
        while (ownerIndex < initialOwnerCount) {
            workspaceOwners.add(modules[ownerIndex])
            ownerIndex++
        }
        // A pure workspace root may declare public path dependencies even
        // though it is not itself a source module. Those edges are inherited
        // by every initial workspace member.
        addPathDependencies(modules, seen, workspaceOwners.toArray(), root, manifest,
            selectedTarget, diagnostics, budget, auxiliaryBudget)
    }

    var moduleIndex: Int64 = 0
    while (moduleIndex < modules.size && !budget.limitReached) {
        let module = modules[moduleIndex]
        if (let Some(cacheRoot) <- selectedCacheRoot) {
            // The root lock was already attached to every initial module. Each
            // non-root module owns its own lock edges, so newly discovered
            // cached dependencies are traversed breadth-first without network.
            if (module.actualRoot != root) {
                let locked = readLockedDependencies(module.actualRoot, false, diagnostics,
                    budget.remainingDependencyDiscoveries(), auxiliaryBudget)
                budget.consumeDependencyCandidates(locked.entryCount)
                for (dependency in locked.dependencies) {
                    if (budget.limitReached) { break }
                    addLockedDependency(modules, seen, [module], dependency,
                        cacheRoot, dependencySources, diagnostics, budget, auxiliaryBudget)
                }
                if (locked.limitReached) { budget.markLimitReached() }
            }
        }
        if (budget.limitReached) { break }
        if (!includePathDependencies) {
            moduleIndex++
            continue
        }
        let moduleManifest = try {
            readAuxiliaryTextBounded(Path(module.actualRoot).join("cjpm.toml"),
                MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
        } catch (_: Exception) {
            if (auxiliaryBudget.limitReached()) { budget.markLimitReached(); break }
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest is not readable; dependency traversal stopped for one package"))
            moduleIndex++
            continue
        }
        addPathDependencies(modules, seen, [module], module.actualRoot, moduleManifest,
            selectedTarget, diagnostics, budget, auxiliaryBudget)
        moduleIndex++
    }
    if (budget.limitReached) {
        addSourceLimitDiagnostic(diagnostics, if (auxiliaryBudget.limitReached()) {
            "source metadata or cache exceeded the configured aggregate byte/work safety budget; source discovery stopped"
        } else {
            "source discovery exceeded 4096 modules or 16384 dependency edges; remaining modules skipped"
        })
    }
    modules
}

private func packageNameFrom(program: Program, fallback: String): String {
    var value = program.packageHeader.toTokens().toString().trimAscii()
    if (value.isEmpty()) { return fallback }
    if (value.startsWith("macro package ")) { value = value.removePrefix("macro package ") }
    if (value.startsWith("package ")) { value = value.removePrefix("package ") }
    return value.trimAscii()
}

private func sourceAggregationKey(left: String, right: String): String {
    "${left.size}:${left}${right}"
}

private class SourceAggregationIndex {
    private let packages = HashMap<String, SourcePackage>()
    private let modulePackages = HashSet<String>()
    private let packageFiles = HashSet<String>()

    func add(source: SourceSnapshot, input: SourceInputFile, packageName: String): Unit {
        let packageKey = sourceAggregationKey(input.module.id, packageName)
        if (modulePackages.add(packageKey)) { input.module.packageNames.add(packageName) }
        let pkg = match (packages.get(packageKey)) {
            case Some(value) => value
            case None =>
                let value = SourcePackage(packageName, input.module.id)
                packages[packageKey] = value
                source.packages.add(value)
                value
        }
        if (packageFiles.add(sourceAggregationKey(packageKey, input.logicalPath))) {
            pkg.sourceFiles.add(input.logicalPath)
        }
    }
}

private func hasFatalSourceDiagnostics(source: SourceSnapshot): Bool {
    for (diagnostic in source.diagnostics) {
        if (diagnostic.severity == "error" && diagnostic.code != "CJDOC1011" &&
            diagnostic.code != "CJDOC1012" && diagnostic.code != "CJDOC1020" &&
            diagnostic.code != "CJDOC1028") { return true }
    }
    return false
}

private func addSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>, message: String): Unit {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return }
    }
    diagnostics.add(Diagnostic("error", "CJDOC1028", message))
}

private func hasSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return true }
    }
    false
}

// The cache codec is deliberately length-prefixed instead of line based: source
// spellings and documentation may contain arbitrary newlines and Unicode. Every
// entry also carries its SHA-256 content-bound cache key, so a filename-hash
// collision is a safe miss rather than stale documentation.
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

private func cacheAddLocation(writer: SourceCacheWriter, value: SourceLocation): Unit {
    writer.add(value.path)
    writer.add(value.startLine)
    writer.add(value.startColumn)
    writer.add(value.endLine)
    writer.add(value.endColumn)
}

private func cacheReadLocation(reader: SourceCacheReader): SourceLocation {
    SourceLocation(reader.next(), reader.nextInt(), reader.nextInt(), reader.nextInt(), reader.nextInt())
}

private func cacheAddOptionalString(writer: SourceCacheWriter, value: ?String): Unit {
    match (value) {
        case Some(actual) =>
            writer.add(true)
            writer.add(actual)
        case None => writer.add(false)
    }
}

private func cacheReadOptionalString(reader: SourceCacheReader): ?String {
    if (reader.nextBool()) { Some(reader.next()) } else { None }
}

private func cacheAddOptionalBool(writer: SourceCacheWriter, value: ?Bool): Unit {
    match (value) {
        case Some(actual) =>
            writer.add(true)
            writer.add(actual)
        case None => writer.add(false)
    }
}

private func cacheReadOptionalBool(reader: SourceCacheReader): ?Bool {
    if (reader.nextBool()) { Some(reader.nextBool()) } else { None }
}

private func cacheAddTag(writer: SourceCacheWriter, tag: DocTag): Unit {
    writer.add(tag.name)
    writer.add(tag.subject)
    writer.add(tag.description)
}

private func cacheReadTag(reader: SourceCacheReader): DocTag {
    DocTag(reader.next(), reader.next(), reader.next())
}

private func cacheAddTags(writer: SourceCacheWriter, tags: ArrayList<DocTag>): Unit {
    if (!writer.addCount(tags.size)) { return }
    for (tag in tags) {
        cacheAddTag(writer, tag)
        if (!writer.canContinue()) { return }
    }
}

private func cacheReadTags(reader: SourceCacheReader, tags: ArrayList<DocTag>): Unit {
    let count = reader.nextCount()
    var index: Int64 = 0
    while (index < count) {
        tags.add(cacheReadTag(reader))
        index++
    }
}

private func cacheAddStrings(writer: SourceCacheWriter, values: ArrayList<String>): Unit {
    if (!writer.addCount(values.size)) { return }
    for (value in values) {
        writer.add(value)
        if (!writer.canContinue()) { return }
    }
}

private func cacheReadStrings(reader: SourceCacheReader, values: ArrayList<String>): Unit {
    let count = reader.nextCount()
    var index: Int64 = 0
    while (index < count) {
        values.add(reader.next())
        index++
    }
}

private func cacheAddDocComment(writer: SourceCacheWriter, value: ?DocComment): Unit {
    match (value) {
        case None => writer.add(false)
        case Some(doc) =>
            writer.add(true)
            writer.add(doc.raw)
            writer.add(doc.summaryMarkdown)
            writer.add(doc.descriptionMarkdown)
            cacheAddTags(writer, doc.params)
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

private func cacheReadDocComment(reader: SourceCacheReader): ?DocComment {
    if (!reader.nextBool()) { return None }
    let doc = DocComment(reader.next(), reader.next(), reader.next())
    cacheReadTags(reader, doc.params)
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

private func cacheAddDeclaration(writer: SourceCacheWriter, value: SourceDeclaration): Unit {
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

private func cacheReadDeclaration(reader: SourceCacheReader, expectedModuleId: String): SourceDeclaration {
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

private func cacheAddReExport(writer: SourceCacheWriter, value: SourceReExport): Unit {
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

private func cacheReadReExport(reader: SourceCacheReader, expectedModuleId: String): SourceReExport {
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

private class ParsedSourceFile {
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

private func withCapturedSourceIndex(parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex): ParsedSourceFile {
    if (capturedSourceIndex.available) {
        parsed.capturedSourceIndex = Some(capturedSourceIndex)
    }
    parsed
}

private func cacheAddUnsupported(writer: SourceCacheWriter, value: UnsupportedDeclaration): Unit {
    writer.add(value.kind)
    writer.add(value.name)
    writer.add(value.reason)
    cacheAddLocation(writer, value.source)
    writer.add(value.origin.kind)
    cacheAddOptionalString(writer, value.origin.macroSymbolId)
}

private func cacheReadUnsupported(reader: SourceCacheReader): UnsupportedDeclaration {
    UnsupportedDeclaration(reader.next(), reader.next(), reader.next(), cacheReadLocation(reader),
        origin: DeclarationOrigin(reader.next(), macroSymbolId: cacheReadOptionalString(reader)))
}

private func cacheAddOrphanDocComment(writer: SourceCacheWriter, value: OrphanDocComment): Unit {
    writer.add(value.rawText)
    cacheAddLocation(writer, value.source)
}

private func cacheReadOrphanDocComment(reader: SourceCacheReader): OrphanDocComment {
    OrphanDocComment(reader.next(), cacheReadLocation(reader))
}

private func cacheAddMacroInvocation(writer: SourceCacheWriter, value: MacroInvocation): Unit {
    writer.add(value.name)
    cacheAddLocation(writer, value.source)
}

private func cacheReadMacroInvocation(reader: SourceCacheReader): MacroInvocation {
    MacroInvocation(reader.next(), cacheReadLocation(reader))
}

private func cacheAddDiagnostic(writer: SourceCacheWriter, value: Diagnostic): Unit {
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

private func cacheReadDiagnostic(reader: SourceCacheReader): Diagnostic {
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

private func encodeParsedSource(cacheKey: String, parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex, capturedSource: String,
    maxBytes!: Int64 = MAX_SOURCE_CACHE_BYTES,
    maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS): ?Array<UInt8> {
    try {
        validateDecodedSourceCache(parsed, capturedSourceIndex, capturedSource)
    } catch (_: Exception) {
        return None
    }
    let writer = SourceCacheWriter(maxBytes: maxBytes, maxItems: maxItems)
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(cacheKey)
    cacheAddOptionalString(writer, parsed.packageName)
    if (!writer.addCount(parsed.declarations.size)) { return None }
    for (declaration in parsed.declarations) {
        cacheAddDeclaration(writer, declaration)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.reExports.size)) { return None }
    for (reExport in parsed.reExports) {
        cacheAddReExport(writer, reExport)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.orphanDocComments.size)) { return None }
    for (comment in parsed.orphanDocComments) {
        cacheAddOrphanDocComment(writer, comment)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.macroInvocations.size)) { return None }
    for (invocation in parsed.macroInvocations) {
        cacheAddMacroInvocation(writer, invocation)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.unsupportedDeclarations.size)) { return None }
    for (unsupported in parsed.unsupportedDeclarations) {
        cacheAddUnsupported(writer, unsupported)
        if (!writer.canContinue()) { return None }
    }
    if (!writer.addCount(parsed.diagnostics.size)) { return None }
    for (diagnostic in parsed.diagnostics) {
        cacheAddDiagnostic(writer, diagnostic)
        if (!writer.canContinue()) { return None }
    }
    let payload = match (writer.result()) {
        case Some(value) => value
        case None => return None
    }
    writer.add(Sha256Digest.digestBytes(payload))
    writer.result()
}

private func checkedCacheCount(reader: SourceCacheReader): Int64 {
    reader.nextCount()
}

func sourceCacheLocationMatchesCaptured(location: SourceLocation, expectedPath: String,
    capturedSourceIndex: CapturedSourceIndex): Bool {
    location.path == expectedPath && location.startLine > 0 && location.startColumn > 0 &&
        location.endLine > 0 && location.endColumn > 0 &&
        !positionLess(location.endLine, location.endColumn,
            location.startLine, location.startColumn) &&
        capturedSourceIndex.byteOffset(location.startLine, location.startColumn).isSome() &&
        capturedSourceIndex.byteOffset(location.endLine, location.endColumn).isSome()
}

private func validCachedDeclarationKind(kind: String): Bool {
    match (kind) {
        case "class" | "struct" | "interface" | "enum" | "enumCase" | "extend" |
            "typeAlias" | "property" | "variable" | "function" | "constructor" => true
        case _ => false
    }
}

private func validCachedVisibility(visibility: String): Bool {
    match (visibility) {
        case "public" | "protected" | "internal" | "private" => true
        case _ => false
    }
}

private func ignoredDefaultToken(token: Token): Bool {
    token.kind == COMMENT || token.value.isEmpty()
}

private func cachedDefaultMatchesSourceTokens(expression: String, sourceTokens: Tokens,
    start: Int64, end: Int64): Bool {
    if (expression.trimAscii().isEmpty() || start < 0 || end < start || end > sourceTokens.size) {
        return false
    }
    let cachedTokens = cangjieLex(expression)
    var sourceIndex = start
    var cachedIndex: Int64 = 0
    while (true) {
        while (sourceIndex < end && ignoredDefaultToken(sourceTokens[sourceIndex])) {
            sourceIndex++
        }
        while (cachedIndex < cachedTokens.size && ignoredDefaultToken(cachedTokens[cachedIndex])) {
            cachedIndex++
        }
        if (sourceIndex >= end || cachedIndex >= cachedTokens.size) {
            return sourceIndex >= end && cachedIndex >= cachedTokens.size
        }
        if (sourceTokens[sourceIndex].kind != cachedTokens[cachedIndex].kind ||
            sourceTokens[sourceIndex].value != cachedTokens[cachedIndex].value) {
            return false
        }
        sourceIndex++
        cachedIndex++
    }
    false
}

private func cachedParameterNameMatches(sourceTokens: Tokens, start: Int64,
    colon: Int64, expected: String): Bool {
    var index = colon - 1
    while (index >= start) {
        let token = sourceTokens[index]
        if (!ignoredDefaultToken(token) && token.value != "!") {
            return token.value == expected
        }
        index--
    }
    false
}

private func hasMeaningfulDefaultTokens(sourceTokens: Tokens, start: Int64, end: Int64): Bool {
    var index = start
    while (index < end) {
        if (!ignoredDefaultToken(sourceTokens[index])) { return true }
        index++
    }
    false
}

private func cachedParameterDefaultMatches(parameter: SourceParameter, sourceTokens: Tokens,
    assign: Int64, end: Int64): Bool {
    match (parameter.defaultExpression) {
        case None => assign < 0
        case Some(expression) => assign >= 0 &&
            cachedDefaultMatchesSourceTokens(expression, sourceTokens, assign + 1, end)
    }
}

private func cachedParameterDefaultsMatchSignature(declaration: SourceDeclaration): Bool {
    if (declaration.kind != "function" && declaration.kind != "constructor") {
        for (parameter in declaration.parameters) {
            if (parameter.defaultExpression.isSome()) { return false }
        }
        return true
    }

    let tokens = cangjieLex(declaration.sourceSignature)
    var searchFrom: Int64 = 0
    var markerFound = false
    var index: Int64 = 0
    while (index < tokens.size) {
        let value = tokens[index].value
        if (value == "func" || (declaration.kind == "constructor" && value == "init")) {
            searchFrom = index + 1
            markerFound = true
            break
        }
        index++
    }
    if (!markerFound && declaration.kind == "constructor") {
        index = 0
        while (index < tokens.size) {
            let value = tokens[index].value
            if (value == "class" || value == "struct") {
                searchFrom = index + 1
                markerFound = true
                break
            }
            index++
        }
    }

    index = if (markerFound) { searchFrom } else { 0 }
    while (index < tokens.size && tokens[index].kind != LPAREN) { index++ }
    if (index >= tokens.size) { return false }

    let parameterStart = index + 1
    var segmentStart = parameterStart
    var parameterIndex: Int64 = 0
    var colon: Int64 = -1
    var assign: Int64 = -1
    var lastComma: Int64 = -1
    var roundDepth: Int64 = 1
    var squareDepth: Int64 = 0
    var braceDepth: Int64 = 0
    index++
    while (index < tokens.size) {
        let kind = tokens[index].kind
        if (kind == RPAREN && roundDepth == 1) {
            if (declaration.parameters.isEmpty()) {
                return colon < 0 &&
                    !hasMeaningfulDefaultTokens(tokens, parameterStart, index)
            }
            if (colon < 0 || parameterIndex >= declaration.parameters.size) { return false }
            var end = index
            if (lastComma > colon &&
                !hasMeaningfulDefaultTokens(tokens, lastComma + 1, index)) {
                end = lastComma
            }
            if (!cachedParameterDefaultMatches(declaration.parameters[parameterIndex],
                tokens, assign, end)) { return false }
            parameterIndex++
            return parameterIndex == declaration.parameters.size
        }

        if (roundDepth == 1 && squareDepth == 0 && braceDepth == 0) {
            match (kind) {
                case COLON =>
                    if (colon >= 0) {
                        if (lastComma <= colon || parameterIndex >= declaration.parameters.size ||
                            !cachedParameterDefaultMatches(declaration.parameters[parameterIndex],
                                tokens, assign, lastComma)) { return false }
                        parameterIndex++
                        segmentStart = lastComma + 1
                    }
                    if (parameterIndex >= declaration.parameters.size ||
                        !cachedParameterNameMatches(tokens, segmentStart, index,
                            declaration.parameters[parameterIndex].name)) { return false }
                    colon = index
                    assign = -1
                case ASSIGN =>
                    if (colon < 0 || assign >= 0) { return false }
                    assign = index
                case COMMA => lastComma = index
                case _ => ()
            }
        }

        match (kind) {
            case LPAREN => roundDepth++
            case RPAREN => roundDepth--
            case LSQUARE => squareDepth++
            case RSQUARE => if (squareDepth > 0) { squareDepth-- }
            case LCURL => braceDepth++
            case RCURL => if (braceDepth > 0) { braceDepth-- }
            case _ => ()
        }
        index++
    }
    false
}

func validateCachedParameterDefaults(declaration: SourceDeclaration): Unit {
    let matches = try {
        cachedParameterDefaultsMatchSignature(declaration)
    } catch (_: Exception) {
        false
    }
    if (!matches) {
        throw IllegalArgumentException("cached parameter defaults do not match captured source")
    }
}

private func validateCachedDocComment(comment: ?DocComment): Unit {
    if (let Some(value) <- comment) {
        if (!value.raw.startsWith("/**") || value.returnTagCount < 0 ||
            value.returnTagCount > MAX_SOURCE_CACHE_ITEMS) {
            throw IllegalArgumentException("invalid cached documentation")
        }
        let expected = parseDocComment(value.raw)
        let actualWriter = SourceCacheWriter()
        let expectedWriter = SourceCacheWriter()
        cacheAddDocComment(actualWriter, Some(value))
        cacheAddDocComment(expectedWriter, Some(expected))
        let actual = actualWriter.result()
        let canonical = expectedWriter.result()
        if (actual.isNone() || canonical.isNone() ||
            String.fromUtf8(actual.getOrThrow()) != String.fromUtf8(canonical.getOrThrow())) {
            throw IllegalArgumentException("cached documentation does not match its raw source")
        }
    }
}

private func cachedSourceSignatureMatches(declaration: SourceDeclaration,
    source: IndexedSourceBuffer): Bool {
    if (declaration.sourceSignature.isEmpty()) { return false }
    let expectedTokens = sourceApiSignatureTokens(declaration.sourceSignature)
    if (expectedTokens.size != declaration.sourceApiSignatureTokens.size) { return false }
    var tokenIndex: Int64 = 0
    while (tokenIndex < expectedTokens.size) {
        if (expectedTokens[tokenIndex] != declaration.sourceApiSignatureTokens[tokenIndex]) { return false }
        tokenIndex++
    }
    let end = source.byteOffset(declaration.source.endLine, declaration.source.endColumn)
    var cursor = source.byteOffset(declaration.source.startLine,
        declaration.source.startColumn)
    if (cursor < 0 || end <= cursor || end > source.bytes.size) { return false }
    while (cursor < end && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor++ }
    let signature = declaration.sourceSignature.toArray()
    if (signature.size > end - cursor) { return false }
    var signatureIndex: Int64 = 0
    while (signatureIndex < signature.size) {
        if (source.bytes[cursor + signatureIndex] != signature[signatureIndex]) { return false }
        signatureIndex++
    }
    cursor += signature.size
    while (cursor < end && (source.bytes[cursor] == b' ' || source.bytes[cursor] == b'\t' ||
        source.bytes[cursor] == b'\r' || source.bytes[cursor] == b'\n')) { cursor++ }
    cursor == end || source.bytes[cursor] == b'{'
}

private func validateCachedCommentBindings(parsed: ParsedSourceFile,
    source: IndexedSourceBuffer): Unit {
    let comments = collectDocComments(parsed.input.logicalPath, cangjieLex(source.source))
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    var symbolIndex: Int64 = 0
    while (symbolIndex < parsed.declarations.size) {
        let symbol = parsed.declarations[symbolIndex]
        while (commentIndex < comments.size &&
            positionLessOrEqual(comments[commentIndex].source.endLine,
                comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        var expectedRaw: ?String = None
        if (let Some(comment) <- candidate) {
            if (!comment.bound && onlyWhitespaceBetween(source, comment.source, symbol.source)) {
                expectedRaw = Some(comment.raw)
                comment.bound = true
            }
            candidate = None
        }
        var groupedIndex = symbolIndex
        while (groupedIndex < parsed.declarations.size &&
            sameSourceRange(parsed.declarations[groupedIndex].source, symbol.source)) {
            match ((expectedRaw, parsed.declarations[groupedIndex].documentation)) {
                case (Some(expected), Some(actual)) =>
                    if (actual.raw != expected) {
                        throw IllegalArgumentException("cached documentation is bound to the wrong source")
                    }
                case (None, None) => ()
                case _ => throw IllegalArgumentException("cached documentation binding mismatch")
            }
            groupedIndex++
        }
        symbolIndex = groupedIndex
    }
    let expectedOrphans = ArrayList<RawDocComment>()
    for (comment in comments where !comment.bound) { expectedOrphans.add(comment) }
    if (expectedOrphans.size != parsed.orphanDocComments.size) {
        throw IllegalArgumentException("cached orphan documentation mismatch")
    }
    var orphanIndex: Int64 = 0
    while (orphanIndex < expectedOrphans.size) {
        let expected = expectedOrphans[orphanIndex]
        let actual = parsed.orphanDocComments[orphanIndex]
        if (actual.rawText != expected.raw || !sameSourceRange(actual.source, expected.source)) {
            throw IllegalArgumentException("cached orphan documentation is not from captured source")
        }
        orphanIndex++
    }
}

func validateSourceCacheOwnerGraph(declarations: ArrayList<SourceDeclaration>,
    maxDepth!: Int64 = MAX_SOURCE_OWNER_DEPTH): Unit {
    if (maxDepth < 1) { throw IllegalArgumentException("cache owner depth limit must be positive") }
    let declarationsByKey = HashMap<String, SourceDeclaration>()
    for (declaration in declarations) {
        if (declarationsByKey.contains(declaration.sourceKey)) {
            throw IllegalArgumentException("duplicate cached declaration owner key")
        }
        declarationsByKey[declaration.sourceKey] = declaration
    }
    let ownerState = HashMap<String, Int64>()
    let ownerDepth = HashMap<String, Int64>()
    for (declaration in declarations) {
        let alreadyDone = match (ownerState.get(declaration.sourceKey)) {
            case Some(2) => true
            case _ => false
        }
        if (alreadyDone) { continue }
        let path = ArrayList<String>()
        var current = declaration
        var complete = false
        var inheritedDepth: Int64 = 0
        while (!complete) {
            match (ownerState.get(current.sourceKey)) {
                case Some(1) =>
                    throw IllegalArgumentException("cyclic cached declaration ownership")
                case Some(2) =>
                    inheritedDepth = ownerDepth.get(current.sourceKey).getOrThrow()
                    complete = true
                case _ =>
                    ownerState[current.sourceKey] = 1
                    path.add(current.sourceKey)
                    if (path.size > maxDepth) {
                        throw IllegalArgumentException("cached declaration ownership is too deep")
                    }
                    match (current.ownerSourceKey) {
                        case None => complete = true
                        case Some(ownerKey) =>
                            if (ownerKey == current.sourceKey) {
                                throw IllegalArgumentException("cached declaration owns itself")
                            }
                            current = match (declarationsByKey.get(ownerKey)) {
                                case Some(owner) => owner
                                case None => throw IllegalArgumentException(
                                    "unknown cached declaration owner")
                            }
                    }
            }
        }
        if (inheritedDepth > maxDepth || path.size > maxDepth - inheritedDepth) {
            throw IllegalArgumentException("cached declaration ownership is too deep")
        }
        var pathIndex = path.size
        var depth = inheritedDepth
        while (pathIndex > 0) {
            pathIndex--
            depth++
            ownerState[path[pathIndex]] = 2
            ownerDepth[path[pathIndex]] = depth
        }
    }
}

private func validateDecodedSourceCache(parsed: ParsedSourceFile,
    capturedSourceIndex: CapturedSourceIndex, capturedSource: String): Unit {
    let expectedPath = parsed.input.logicalPath
    let sourceBuffer = IndexedSourceBuffer(capturedSource)
    let packageName = match (parsed.packageName) {
        case Some(value) =>
            if (value.isEmpty()) { throw IllegalArgumentException("empty cached package") }
            value
        case None =>
            if (!parsed.declarations.isEmpty() || !parsed.reExports.isEmpty() || !parsed.orphanDocComments.isEmpty() ||
                !parsed.macroInvocations.isEmpty() || !parsed.unsupportedDeclarations.isEmpty()) {
                throw IllegalArgumentException("cached source facts require a package")
            }
            ""
    }
    let declarationsByKey = HashMap<String, SourceDeclaration>()
    var previous: ?SourceDeclaration = None
    for (declaration in parsed.declarations) {
        if (!validCachedDeclarationKind(declaration.kind) || declaration.name.isEmpty() ||
            declaration.packageName != packageName || declaration.moduleId != parsed.input.module.id ||
            !validCachedVisibility(declaration.visibility) ||
            !sourceCacheLocationMatchesCaptured(declaration.source, expectedPath,
                capturedSourceIndex) ||
            !cachedSourceSignatureMatches(declaration, sourceBuffer) ||
            declaration.sourceKey != makeSourceDeclarationKey(declaration.source,
                declaration.kind, declaration.name) ||
            declarationsByKey.contains(declaration.sourceKey)) {
            throw IllegalArgumentException("invalid cached declaration")
        }
        if ((declaration.kind == "enum" && declaration.enumNonExhaustive.isNone()) ||
            (declaration.kind != "enum" && declaration.enumNonExhaustive.isSome())) {
            throw IllegalArgumentException("invalid cached enum exhaustiveness")
        }
        validateCachedParameterDefaults(declaration)
        if (let Some(value) <- previous) {
            if (sourceOrderLess(declaration, value)) {
                throw IllegalArgumentException("cached declarations are not source ordered")
            }
        }
        validateCachedDocComment(declaration.documentation)
        declarationsByKey[declaration.sourceKey] = declaration
        previous = Some(declaration)
    }
    validateCachedCommentBindings(parsed, sourceBuffer)
    for (declaration in parsed.declarations) {
        if (let Some(ownerKey) <- declaration.ownerSourceKey) {
            if (ownerKey == declaration.sourceKey) {
                throw IllegalArgumentException("cached declaration owns itself")
            }
            match (declarationsByKey.get(ownerKey)) {
                case Some(owner) =>
                    if (!owner.isContainer || owner.packageName != declaration.packageName ||
                        owner.moduleId != declaration.moduleId ||
                        !rangeContains(owner.source, declaration.source)) {
                        throw IllegalArgumentException("invalid cached declaration owner")
                    }
                case None => throw IllegalArgumentException("unknown cached declaration owner")
            }
        }
    }
    // The shared validator uses three-state iterative DFS and memoized depth,
    // so every owner edge is visited once and total nesting is still capped.
    validateSourceCacheOwnerGraph(parsed.declarations)
    for (reExport in parsed.reExports) {
        if ((reExport.kind != "single" && reExport.kind != "alias" &&
            reExport.kind != "all" && reExport.kind != "multi") ||
            reExport.packageName != packageName || reExport.moduleId != parsed.input.module.id ||
            reExport.normalizedSpec.isEmpty() ||
            !sourceCacheLocationMatchesCaptured(reExport.source, expectedPath, capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached public import")
        }
        let exact = sourceBuffer.slice(reExport.source)
        if (exact.isEmpty() || cangjieLex(exact).toString().trimAscii() != reExport.normalizedSpec) {
            throw IllegalArgumentException("cached public import does not match source")
        }
    }
    for (comment in parsed.orphanDocComments) {
        if (!comment.rawText.startsWith("/**") ||
            !sourceCacheLocationMatchesCaptured(comment.source, expectedPath,
                capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached orphan documentation")
        }
    }
    for (invocation in parsed.macroInvocations) {
        if (invocation.name.isEmpty() || !sourceCacheLocationMatchesCaptured(invocation.source,
            expectedPath, capturedSourceIndex)) {
            throw IllegalArgumentException("invalid cached macro invocation")
        }
    }
    for (unsupported in parsed.unsupportedDeclarations) {
        if (unsupported.kind.isEmpty() || unsupported.name.isEmpty() ||
            unsupported.reason.isEmpty() || !sourceCacheLocationMatchesCaptured(unsupported.source,
                expectedPath, capturedSourceIndex) ||
            (unsupported.origin.kind != "source" && unsupported.origin.kind != "macro")) {
            throw IllegalArgumentException("invalid cached unsupported declaration")
        }
    }
    for (diagnostic in parsed.diagnostics) {
        if ((diagnostic.severity != "warning" && diagnostic.severity != "error") ||
            !diagnostic.code.startsWith("CJDOC1") || diagnostic.message.isEmpty() ||
            diagnostic.symbolId.isSome()) {
            throw IllegalArgumentException("invalid cached source diagnostic")
        }
        if (let Some(location) <- diagnostic.source) {
            if (!sourceCacheLocationMatchesCaptured(location, expectedPath,
                capturedSourceIndex)) {
                throw IllegalArgumentException("invalid cached diagnostic location")
            }
        }
    }
}

private func decodeParsedSource(input: SourceInputFile, cacheKey: String,
    bytes: Array<UInt8>, capturedSourceIndex: CapturedSourceIndex, capturedSource: String,
    maxItems!: Int64 = MAX_SOURCE_CACHE_ITEMS): ParsedSourceFile {
    let reader = SourceCacheReader(bytes, maxItems: maxItems)
    if (reader.next() != SOURCE_CACHE_FORMAT || reader.next() != cacheKey) {
        throw IllegalArgumentException("cache key mismatch")
    }
    let parsed = ParsedSourceFile(input)
    parsed.packageName = cacheReadOptionalString(reader)
    var count = checkedCacheCount(reader)
    var index: Int64 = 0
    while (index < count) {
        parsed.declarations.add(cacheReadDeclaration(reader, input.module.id))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.reExports.add(cacheReadReExport(reader, input.module.id))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.orphanDocComments.add(cacheReadOrphanDocComment(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.macroInvocations.add(cacheReadMacroInvocation(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.unsupportedDeclarations.add(cacheReadUnsupported(reader))
        index++
    }
    count = checkedCacheCount(reader)
    index = 0
    while (index < count) {
        parsed.diagnostics.add(cacheReadDiagnostic(reader))
        index++
    }
    let payloadEnd = reader.offset
    let expectedChecksum = reader.next()
    if (expectedChecksum != Sha256Digest.digestBytes(bytes[..payloadEnd])) {
        throw IllegalArgumentException("source cache checksum mismatch")
    }
    if (!reader.finished()) { throw IllegalArgumentException("trailing cache data") }
    validateDecodedSourceCache(parsed, capturedSourceIndex, capturedSource)
    parsed.cacheStatus = "hit"
    return parsed
}

private func stableSourceCacheHash(value: String): String {
    var first: Int64 = 0
    var second: Int64 = 0
    for (byte in value.toArray()) {
        first = (first * 131 + Int64(byte)) % 2147483647
        second = (second * 257 + Int64(byte)) % 2147483629
    }
    "${first}-${second}"
}

private func defaultSourceCacheFingerprint(): String {
    let sdkPath = match (getVariable("CANGJIE_HOME")) {
        case Some(value) => value
        case None => match (getVariable("CANGJIE_SDK_ROOT")) {
            case Some(value) => value
            case None => "unknown-sdk"
        }
    }
    let canonicalSdk = try { canonicalize(sdkPath).toString() } catch (_: Exception) { sdkPath }
    let compilerVersion = try {
        let (exitCode, output, _) = executeWithOutput("cjc", ["--version"])
        if (exitCode == 0) { String.fromUtf8(output).trimAscii() } else { "unknown-cjc" }
    } catch (_: Exception) {
        "unknown-cjc"
    }
    "${canonicalSdk}\n${compilerVersion}"
}

private func makeSourceCacheKey(input: SourceInputFile, fallbackPackageName: String,
    source: String, fingerprint: String): ?String {
    let writer = SourceCacheWriter()
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(fingerprint)
    writer.add(input.logicalPath)
    writer.add(input.module.id)
    writer.add(fallbackPackageName)
    writer.add(source)
    match (writer.result()) {
        case Some(bytes) => Some(Sha256Digest.digestBytes(bytes))
        case None => None
    }
}

private func sourceCachePath(directory: String, input: SourceInputFile,
    cacheKey: String): String {
    let pathHash = stableSourceCacheHash(input.logicalPath)
    let contentHash = stableSourceCacheHash(cacheKey)
    Path(directory).join("${pathHash}-${contentHash}.cache").toString()
}

private func writeSourceCache(path: String, content: Array<UInt8>): Bool {
    if (content.size > MAX_SOURCE_CACHE_BYTES) { return false }
    let temporary = try {
        File.createTemp(Path(path).parent)
    } catch (_: Exception) {
        return false
    }
    let temporaryPath = try {
        temporary.info.path
    } catch (_: Exception) {
        try { temporary.close() } catch (_: Exception) {}
        return false
    }
    var closed = false
    var succeeded = false
    try {
        temporary.write(content)
        let written = temporary.info
        if (!written.isRegular() || written.size != content.size ||
            written.size > MAX_SOURCE_CACHE_BYTES) {
            throw IllegalStateException("source cache write did not produce a bounded regular file")
        }
        temporary.close()
        closed = true
        rename(temporaryPath, to: Path(path), overwrite: true)
        succeeded = true
    } catch (_: Exception) {
        succeeded = false
    } finally {
        if (!closed) { try { temporary.close() } catch (_: Exception) {} }
        try { let _ = removeIfExists(temporaryPath) } catch (_: Exception) {}
    }
    succeeded
}

private func encodeAndWriteSourceCache(path: String, cacheKey: String,
    parsed: ParsedSourceFile, capturedSourceIndex: CapturedSourceIndex,
    capturedSource: String, auxiliaryBudget: SourceAuxiliaryBudget): Bool {
    if (auxiliaryBudget.limitReached()) { return false }
    match (encodeParsedSource(cacheKey, parsed, capturedSourceIndex, capturedSource)) {
        case Some(content) =>
            if (!auxiliaryBudget.consumeBytes(content.size)) { return false }
            writeSourceCache(path, content)
        case None => false
    }
}

private func parseSourceText(input: SourceInputFile, fallbackPackageName: String,
    source: String): ParsedSourceFile {
    let result = ParsedSourceFile(input)
    let relative = input.logicalPath
    try {
        let tokens = cangjieLex(source)
        let program = parseProgram(tokens)
        if (exceedsSafeBinaryExpressionDepth(program)) {
            result.diagnostics.add(Diagnostic("error", "CJDOC1012",
                "source exceeds the safe std.ast binary-expression depth; file skipped",
                source: SourceLocation(relative, 1, 1, 1, 1)))
            return result
        }
        let packageName = packageNameFrom(program, fallbackPackageName)
        let sourceBuffer = IndexedSourceBuffer(source)
        let collector = AstDeclarationCollector(relative, packageName, input.module.id, sourceBuffer)
        program.traverse(collector)
        sort(collector.declarations, lessThan: sourceOrderLess, stable: true)
        removeLocalDeclarations(collector.declarations, collector.localScopes)
        collector.declarations.add(all: collector.primaryConstructorMembers)
        sort(collector.declarations, lessThan: sourceOrderLess, stable: true)
        assignOwners(collector.declarations)
        result.orphanDocComments.add(all: bindComments(collector.declarations,
            collectDocComments(relative, tokens), sourceBuffer))
        for (comment in result.orphanDocComments) {
            result.diagnostics.add(Diagnostic("warning", "CJDOC1014",
                "doc comment is not attached to a documentable declaration",
                source: comment.source))
        }
        result.packageName = Some(packageName)
        result.declarations.add(all: collector.declarations)
        result.reExports.add(all: collectPublicReExports(program, relative, packageName, input.module.id))
        result.macroInvocations.add(all: collector.macroInvocations)
        result.unsupportedDeclarations.add(all: collector.unsupportedDeclarations)
        result.diagnostics.add(all: collector.diagnostics)
    } catch (_: Exception) {
        result.diagnostics.add(Diagnostic("error", "CJDOC1011",
            "failed to parse '${relative}'",
            source: SourceLocation(relative, 1, 1, 1, 1)))
    }
    result
}

private func normalizeSourceNewlines(source: String): String {
    source.replace("\r\n", "\n").replace("\r", "\n")
}

func runAstParsePreflight(path: String): Int64 {
    try {
        let source = normalizeSourceNewlines(readTextBounded(Path(path), MAX_SOURCE_FILE_BYTES))
        let tokens = cangjieLex(source)
        if (looksLikeUnsafeBinaryExpressionDepth(tokens, false)) { return 12 }
        let program = parseProgram(tokens)
        if (exceedsSafeBinaryExpressionDepth(program)) { return 12 }
        return 0
    } catch (_: Exception) {
        // Keep ordinary parser exceptions distinct from a native SIGSEGV,
        // which executeWithOutput reports as signal status 11.
        return 10
    }
}

private func astPreflightStatus(executable: String, source: String): Int64 {
    let temporaryDirectory = try {
        Directory.createTemp(getTempDirectory())
    } catch (_: Exception) {
        return -1
    }
    var status: Int64 = -1
    try {
        let temporarySource = temporaryDirectory.join("captured-source.cj")
        File.writeTo(temporarySource, source.toArray())
        let (exitCode, _, _) = executeWithOutput(executable,
            ["--internal-ast-preflight", temporarySource.toString()])
        status = exitCode
    } catch (_: Exception) {
        status = -1
    } finally {
        try { let _ = removeIfExists(temporaryDirectory, recursive: true) } catch (_: Exception) {}
    }
    status
}

private func parseAfterAstPreflight(input: SourceInputFile, fallbackPackageName: String,
    source: String, executable: ?String): ParsedSourceFile {
    if (executable.isNone() || executable.getOrThrow().isEmpty()) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1020",
            "isolated std.ast parser is unavailable for '${input.logicalPath}'; file skipped",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    let actual = executable.getOrThrow()
    let status = astPreflightStatus(actual, source)
    if (status == 10) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1011",
            "failed to parse '${input.logicalPath}'",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    if (status == 12) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1012",
            "source exceeds the safe std.ast binary-expression depth; file skipped",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    if (status == 11 || status == 139) {
        let deepBinary = try {
            looksLikeUnsafeBinaryExpressionDepth(cangjieLex(source), true)
        } catch (_: Exception) {
            false
        }
        if (deepBinary) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1012",
                "source exceeds the safe std.ast binary-expression depth; file skipped",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
    }
    if (status != 0) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1020",
            "isolated std.ast parser failed for '${input.logicalPath}'; file skipped",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    return parseSourceText(input, fallbackPackageName, source)
}

private func parseSourceInput(input: SourceInputFile, fallbackPackageName: String,
    cacheDirectory: ?String, cacheFingerprint: String,
    astPreflightExecutable: ?String, auxiliaryBudget: SourceAuxiliaryBudget): ParsedSourceFile {
    try {
        let inputInfo = FileInfo(input.actualPath)
        if (inputInfo.isRegular() && !inputInfo.isSymbolicLink() &&
            inputInfo.size > MAX_SOURCE_FILE_BYTES) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1026",
                "source file exceeds the 32 MiB safety limit; file skipped",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
        if (!inputInfo.isRegular() || inputInfo.isSymbolicLink() || inputInfo.size < 0 ||
            inputInfo.size != input.discoveredSize) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1011",
                "failed to parse '${input.logicalPath}'",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
    } catch (_: Exception) {
        // The normal read path below reports inaccessible or disappearing files.
    }
    let source = try {
        normalizeSourceNewlines(readTextBounded(Path(input.actualPath), MAX_SOURCE_FILE_BYTES))
    } catch (_: Exception) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1011",
            "failed to parse '${input.logicalPath}'",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    let capturedSourceIndex = CapturedSourceIndex(source)
    if (!capturedSourceIndex.available) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1028",
            "source exceeds the ${MAX_CAPTURED_SOURCE_LINES}-line indexing limit; file skipped",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    match (cacheDirectory) {
        case None => return withCapturedSourceIndex(
            parseAfterAstPreflight(input, fallbackPackageName, source, astPreflightExecutable),
            capturedSourceIndex)
        case Some(directory) =>
            if (auxiliaryBudget.limitReached() || !auxiliaryBudget.consumeWork(source.size)) {
                let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                    astPreflightExecutable)
                parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
                parsed.cacheStatus = "miss-write-failed"
                return withCapturedSourceIndex(parsed, capturedSourceIndex)
            }
            let cacheKeyValue = makeSourceCacheKey(input, fallbackPackageName, source, cacheFingerprint)
            if (cacheKeyValue.isNone()) {
                let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                    astPreflightExecutable)
                parsed.cacheStatus = "miss-write-failed"
                return withCapturedSourceIndex(parsed, capturedSourceIndex)
            }
            let cacheKey = cacheKeyValue.getOrThrow()
            let path = sourceCachePath(directory, input, cacheKey)
            if (exists(path)) {
                try {
                    return withCapturedSourceIndex(decodeParsedSource(input, cacheKey,
                        readAuxiliaryFileBounded(Path(path), MAX_SOURCE_CACHE_BYTES,
                            auxiliaryBudget), capturedSourceIndex,
                        source),
                        capturedSourceIndex)
                } catch (_: Exception) {
                    let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                        astPreflightExecutable)
                    if (auxiliaryBudget.limitReached()) {
                        parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                            "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
                        parsed.cacheStatus = "miss-write-failed"
                        return withCapturedSourceIndex(parsed, capturedSourceIndex)
                    }
                    parsed.cacheStatus = if (encodeAndWriteSourceCache(path, cacheKey, parsed,
                        capturedSourceIndex, source, auxiliaryBudget)) {
                        "corrupt-written"
                    } else {
                        "corrupt-write-failed"
                    }
                    return withCapturedSourceIndex(parsed, capturedSourceIndex)
                }
            }
            let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                astPreflightExecutable)
            parsed.cacheStatus = if (encodeAndWriteSourceCache(path, cacheKey, parsed,
                capturedSourceIndex, source, auxiliaryBudget)) {
                "miss-written"
            } else {
                "miss-write-failed"
            }
            if (auxiliaryBudget.limitReached()) {
                parsed.diagnostics.add(Diagnostic("error", "CJDOC1028",
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; remaining cache work skipped"))
            }
            return withCapturedSourceIndex(parsed, capturedSourceIndex)
    }
}

private func mergeParsedSource(sourceSnapshot: SourceSnapshot, parsed: ParsedSourceFile,
    cacheStats: SourceCacheStats, aggregation: SourceAggregationIndex): Unit {
    sourceSnapshot.sourceFileOrigins.add(SourceFileOrigin(parsed.input.logicalPath,
        parsed.input.actualPath, parsed.input.actualRoot, parsed.input.module.sourcePrefix,
        capturedSourceIndex: parsed.capturedSourceIndex))
    match (parsed.cacheStatus) {
        case "hit" => cacheStats.hits++
        case "miss-written" =>
            cacheStats.misses++
            cacheStats.writes++
        case "miss-write-failed" =>
            cacheStats.misses++
            cacheStats.writeFailures++
        case "corrupt-written" =>
            cacheStats.misses++
            cacheStats.corruptEntries++
            cacheStats.writes++
        case "corrupt-write-failed" =>
            cacheStats.misses++
            cacheStats.corruptEntries++
            cacheStats.writeFailures++
        case _ => ()
    }
    if (let Some(packageName) <- parsed.packageName) {
        aggregation.add(sourceSnapshot, parsed.input, packageName)
    }
    sourceSnapshot.declarations.add(all: parsed.declarations)
    sourceSnapshot.reExports.add(all: parsed.reExports)
    sourceSnapshot.orphanDocComments.add(all: parsed.orphanDocComments)
    sourceSnapshot.macroInvocations.add(all: parsed.macroInvocations)
    sourceSnapshot.unsupportedDeclarations.add(all: parsed.unsupportedDeclarations)
    for (diagnostic in parsed.diagnostics) {
        if (diagnostic.code == "CJDOC1028") {
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics, diagnostic.message)
        } else {
            sourceSnapshot.diagnostics.add(diagnostic)
        }
    }
}

private func parseAllSourceFiles(sourceSnapshot: SourceSnapshot, files: ArrayList<SourceInputFile>,
    jobs: Int64, cacheDirectory: ?String, cacheFingerprint: String,
    cacheStats: SourceCacheStats, astPreflightExecutable: ?String,
    auxiliaryBudget: SourceAuxiliaryBudget): Unit {
    let aggregation = SourceAggregationIndex()
    if (jobs <= 1 || files.size <= 1) {
        for (input in files) {
            mergeParsedSource(sourceSnapshot,
                parseSourceInput(input, input.module.name, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable, auxiliaryBudget),
                cacheStats, aggregation)
        }
        return
    }
    var start: Int64 = 0
    while (start < files.size) {
        let futures = ArrayList<Future<ParsedSourceFile>>()
        let end = if (start + jobs < files.size) { start + jobs } else { files.size }
        var index = start
        while (index < end) {
            let input = files[index]
            let fallbackPackageName = input.module.name
            futures.add(spawn {
                parseSourceInput(input, fallbackPackageName, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable, auxiliaryBudget)
            })
            index++
        }
        for (future in futures) {
            mergeParsedSource(sourceSnapshot, future.get(), cacheStats, aggregation)
        }
        start = end
    }
}

class AstSourceProvider <: SourceProvider {
    private let includePathDependencies: Bool
    private let dependencySources: Array<DependencySourceInput>
    private let jobs: Int64
    private let cacheDirectory: ?String
    private let cacheFingerprint: String
    private let astPreflightExecutable: ?String
    private let includeCachedDependencies: Bool
    private let cjpmCacheRoot: ?String
    private let sourceDirectoryEntryLimit: Int64
    private let sourceAuxiliaryByteLimit: Int64
    private let sourceAuxiliaryWorkLimit: Int64
    public let cacheStats = SourceCacheStats()

    public init(includePathDependencies!: Bool = false,
        dependencySources!: Array<DependencySourceInput> = [], jobs!: Int64 = 1,
        cacheDirectory!: ?String = None, cacheFingerprint!: ?String = None,
        astPreflightExecutable!: ?String = None,
        includeCachedDependencies!: Bool = false, cjpmCacheRoot!: ?String = None,
        sourceDirectoryEntryLimit!: Int64 = MAX_SOURCE_DIRECTORY_ENTRIES,
        sourceAuxiliaryByteLimit!: Int64 = MAX_SOURCE_AUXILIARY_BYTES,
        sourceAuxiliaryWorkLimit!: Int64 = MAX_SOURCE_AUXILIARY_WORK) {
        if (sourceDirectoryEntryLimit < 1 || sourceAuxiliaryByteLimit < 0 ||
            sourceAuxiliaryWorkLimit < 0) {
            throw IllegalArgumentException("source safety limits are invalid")
        }
        this.includePathDependencies = includePathDependencies
        this.dependencySources = dependencySources
        this.jobs = if (jobs < 1) { 1 } else if (jobs > 64) { 64 } else { jobs }
        this.cacheDirectory = cacheDirectory
        this.cacheFingerprint = match (cacheFingerprint) {
            case Some(value) => value
            case None => if (cacheDirectory.isSome()) { defaultSourceCacheFingerprint() } else { "cache-disabled" }
        }
        this.astPreflightExecutable = astPreflightExecutable
        this.includeCachedDependencies = includeCachedDependencies
        this.cjpmCacheRoot = cjpmCacheRoot
        this.sourceDirectoryEntryLimit = sourceDirectoryEntryLimit
        this.sourceAuxiliaryByteLimit = sourceAuxiliaryByteLimit
        this.sourceAuxiliaryWorkLimit = sourceAuxiliaryWorkLimit
    }

    public func collect(projectRoot: String): SourceSnapshot {
        cacheStats.reset()
        let auxiliaryBudget = SourceAuxiliaryBudget(sourceAuxiliaryByteLimit,
            sourceAuxiliaryWorkLimit)
        let root = try {
            canonicalize(projectRoot).toString()
        } catch (_: Exception) {
            let requestedName = Path(projectRoot).fileName
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "project path is not accessible"))
            return source
        }
        let manifestPath = Path(root).join("cjpm.toml")
        let requestedName = Path(root).fileName
        if (!exists(manifestPath)) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "project must contain cjpm.toml"))
            return source
        }
        let manifest = try {
            readAuxiliaryTextBounded(manifestPath, MAX_SOURCE_FILE_BYTES, auxiliaryBudget)
        } catch (_: Exception) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.modules.add(SourceModule(moduleId("root", source.projectName, ""),
                source.projectName, "root", ""))
            if (auxiliaryBudget.limitReached()) {
                addSourceLimitDiagnostic(source.diagnostics,
                    "source metadata or cache exceeded the configured aggregate byte/work safety budget; source parsing skipped")
            } else {
                source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                    "failed to read cjpm.toml"))
            }
            return source
        }
        if (!auxiliaryBudget.consumeWork(manifest.size)) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.modules.add(SourceModule(moduleId("root", source.projectName, ""),
                source.projectName, "root", ""))
            addSourceLimitDiagnostic(source.diagnostics,
                "source metadata or cache exceeded the configured aggregate byte/work safety budget; source parsing skipped")
            return source
        }
        let packageView = parseCjpmPackageNameChecked(manifest)
        let projectName = match (packageView.value) {
            case Some(name) => name
            case None => if (requestedName.isEmpty()) { "project" } else { requestedName }
        }
        let sourceSnapshot = SourceSnapshot(projectName)
        if (packageView.limitReached) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics,
                "source metadata exceeded the configured byte or work safety budget; source parsing skipped")
            return sourceSnapshot
        }
        if (packageView.invalid) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
            sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "cjpm.toml contains an invalid TOML string; source parsing skipped"))
            return sourceSnapshot
        }
        let moduleRoots = discoverSourceModules(root, manifest, includePathDependencies,
            dependencySources,
            includeCachedDependencies, cjpmCacheRoot,
            sourceSnapshot.diagnostics, auxiliaryBudget)
        for (module in moduleRoots) { sourceSnapshot.modules.add(module.documentation) }
        if (sourceSnapshot.modules.isEmpty()) {
            sourceSnapshot.modules.add(SourceModule(moduleId("root", projectName, ""),
                projectName, "root", ""))
        }
        if (auxiliaryBudget.limitReached()) {
            return sourceSnapshot
        }
        if (hasSourceLimitDiagnostic(sourceSnapshot.diagnostics)) { return sourceSnapshot }
        if (hasFatalSourceDiagnostics(sourceSnapshot)) { return sourceSnapshot }
        let files = ArrayList<SourceInputFile>()
        let logicalPaths = HashSet<String>()
        let directoryBudget = SourceDirectoryBudget(maxEntries: sourceDirectoryEntryLimit)
        var scanLimitReached = false
        var logicalPathFailure = false
        var totalSourceBytes: Int64 = 0
        for (module in moduleRoots) {
            if (files.size >= MAX_SOURCE_FILES) { scanLimitReached = true; break }
            try {
                let moduleFiles = ArrayList<String>()
                let complete = collectSourceFiles(module.actualSourceRoot,
                    moduleFiles, MAX_SOURCE_FILES - files.size, directoryBudget)
                if (!complete && directoryBudget.limitReached) { scanLimitReached = true }
                if (directoryBudget.unsafeLogicalPath && !logicalPathFailure) {
                    sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                        "source path cannot be represented by a portable logical path; source scan stopped"))
                    logicalPathFailure = true
                }
                for (file in moduleFiles) {
                    if (logicalPathFailure) { break }
                    let logicalPathValue = logicalSourcePath(root, module, file)
                    if (logicalPathValue.isNone()) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                            "source path cannot be represented by a portable logical path; source scan stopped"))
                        logicalPathFailure = true
                        continue
                    }
                    let logicalPath = logicalPathValue.getOrThrow()
                    if (!logicalPaths.add(logicalPath)) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1010",
                            "source files collide at one logical path; source scan stopped"))
                        logicalPathFailure = true
                        continue
                    }
                    let size: ?Int64 = try {
                        let info = FileInfo(file)
                        if (!info.isRegular() || info.isSymbolicLink() || info.size < 0) {
                            throw IllegalArgumentException("source file is not regular")
                        }
                        Some(info.size)
                    } catch (_: Exception) {
                        sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1011",
                            "failed to inspect '${logicalPath}'",
                            source: SourceLocation(logicalPath, 1, 1, 1, 1)))
                        None
                    }
                    if (size.isNone()) { continue }
                    let actualSize = size.getOrThrow()
                    if (actualSize <= MAX_SOURCE_FILE_BYTES &&
                        actualSize > MAX_TOTAL_SOURCE_BYTES - totalSourceBytes) {
                        scanLimitReached = true
                        break
                    }
                    if (actualSize <= MAX_SOURCE_FILE_BYTES) { totalSourceBytes += actualSize }
                    files.add(SourceInputFile(file, module.actualRoot, logicalPath,
                        module.documentation, actualSize))
                }
            } catch (_: Exception) {
                sourceSnapshot.diagnostics.add(Diagnostic(
                    if (module.documentation.role == "root") { "error" } else { "warning" },
                    "CJDOC1027",
                    "failed to scan source module '${module.documentation.id}'"))
            }
            if (scanLimitReached || logicalPathFailure) { break }
        }
        if (scanLimitReached) {
            addSourceLimitDiagnostic(sourceSnapshot.diagnostics,
                "source scan exceeded the configured file, directory entry, directory depth, " +
                "or readable-byte safety budget; source parsing skipped")
            // Directory iteration order is host dependent. Once discovery is
            // truncated, emitting only the stable module graph and diagnostic
            // avoids making the selected declaration subset nondeterministic.
            return sourceSnapshot
        }
        sort(files, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
        if (hasFatalSourceDiagnostics(sourceSnapshot)) { return sourceSnapshot }
        let usableCacheDirectory: ?String = match (cacheDirectory) {
            case None => None
            case Some(directory) => try {
                let path = Path(directory)
                if (!exists(path)) { Directory.create(path, recursive: true) }
                Some(canonicalize(path).toString())
            } catch (_: Exception) {
                None
            }
        }
        parseAllSourceFiles(sourceSnapshot, files, jobs, usableCacheDirectory,
            cacheFingerprint, cacheStats, astPreflightExecutable, auxiliaryBudget)
        return sourceSnapshot
    }
}
