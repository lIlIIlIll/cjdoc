package cjdoc

import std.ast.*
import std.collection.*
import std.sort.*

internal class AstDeclarationCollector <: Visitor {
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
        let location = match (sourceLocationFromAstRange(path, source,
            startLine, startColumn, endLine, endColumn)) {
            case Some(value) => value
            case None => return None
        }
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
        let location = match (sourceLocationFromAstRange(path, source,
            Int64(first.pos.line), Int64(first.pos.column), endLine, endColumn)) {
            case Some(value) => value
            case None => return
        }
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
                let (endLine, endColumn) = tokenEndPosition(last)
                let (startLine, startColumn) = enumCaseStart(source,
                    Int64(first.pos.line), Int64(first.pos.column))
                let location = match (sourceLocationFromAstRange(path, source,
                    startLine, startColumn, endLine, endColumn)) {
                    case Some(value) => value
                    case None => continue
                }
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
        if (decl.beginPos.line > 0 && decl.beginPos.column > 0 &&
            decl.endPos.line > 0 && decl.endPos.column > 0) {
            if (let Some(location) <- sourceLocationFromAstRange(path, source,
                Int64(decl.beginPos.line), Int64(decl.beginPos.column),
                Int64(decl.endPos.line), Int64(decl.endPos.column))) {
                localScopes.add(location)
            }
        }
        breakTraverse()
    }

    public override func visit(decl: MacroDecl): Unit {
        if (let Some(location) <- sourceLocationFromAstRange(path, source,
            Int64(decl.beginPos.line), Int64(decl.beginPos.column),
            Int64(decl.endPos.line), Int64(decl.endPos.column))) {
            diagnostics.add(Diagnostic("warning", "CJDOC1009",
                "unsupported declaration 'macro ${decl.identifier.value}'", source: location))
            unsupportedDeclarations.add(UnsupportedDeclaration("macro", decl.identifier.value,
                "macro expansion is not executed", location))
        }
        breakTraverse()
    }

    public override func visit(decl: MacroExpandDecl): Unit {
        let name = try { decl.fullIdentifier.value } catch (_: Exception) {
            try { decl.identifier.value } catch (_: Exception) { "<macro>" }
        }
        if (let Some(location) <- sourceLocationFromAstRange(path, source,
            Int64(decl.beginPos.line), Int64(decl.beginPos.column),
            Int64(decl.endPos.line), Int64(decl.endPos.column))) {
            diagnostics.add(Diagnostic("warning", "CJDOC1009",
                "macro invocation '${name}' is not expanded", source: location))
            macroInvocations.add(MacroInvocation(name, location))
            unsupportedDeclarations.add(UnsupportedDeclaration("macroInvocation", name,
                "macro expansion is not executed", location))
        }
        breakTraverse()
    }
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
        Int64(token.pos.column) + lines[0].toArray().size
    } else {
        lines[lines.size - 1].toArray().size + 1
    }
    (endLine, endColumn)
}

internal func sourceLocationFromAstRange(path: String, source: IndexedSourceBuffer,
    startLine: Int64, startColumn: Int64, endLine: Int64, endColumn: Int64): ?SourceLocation {
    let startOffset = source.byteOffsetFromLexerPosition(startLine, startColumn)
    let endOffset = source.byteOffsetFromLexerPosition(endLine, endColumn)
    if (startOffset < 0 || endOffset < startOffset) { return None }
    Some(SourceLocation(path, startLine, startColumn, endLine, endColumn))
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
    if (first >= tokens.size) { return None }
    var last = tokens.size
    while (last > first && (tokens[last - 1].value.isEmpty() || tokens[last - 1].kind == NL)) { last-- }
    if (last <= first) { return None }
    let endToken = tokens[last - 1]
    if (endToken.pos.line <= 0 || endToken.pos.column <= 0) { return None }
    let (endLine, endColumn) = tokenEndPosition(endToken)
    Some(SourceLocation(path, Int64(tokens[first].pos.line), Int64(tokens[first].pos.column),
        endLine, endColumn))
}

internal func collectPublicReExports(program: Program, path: String,
    packageName: String, moduleId: String): Array<SourceReExport> {
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

internal func collectImports(program: Program, path: String,
    source: IndexedSourceBuffer): Array<String> {
    let imports = ArrayList<String>()
    for (importList in program.importLists) {
        let location = match (importLocation(path, importList)) {
            case Some(value) => value
            case None => continue
        }
        let text = source.slice(location).trimAscii()
        if (!text.isEmpty()) { imports.add(text) }
    }
    imports.toArray()
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

internal func isBinaryOperator(value: String): Bool {
    match (value) {
        case "+" | "-" | "*" | "/" | "%" | "&&" | "||" | "==" | "!=" |
            "<" | ">" | "<=" | ">=" | "&" | "|" | "^" | "<<" | ">>" | "??" => true
        case _ => false
    }
}

// The preflight path excludes punctuation that is ambiguous with enum/generic
// syntax. After a worker SIGSEGV, the broader form classifies the known deep
// BinaryExpr failure while the failed parser supplies the additional signal.
internal func looksLikeUnsafeBinaryExpressionDepth(tokens: Tokens,
    includeAmbiguousPunctuation: Bool): Bool {
    let safeOperatorLimit: Int64 = MAX_SOURCE_BINARY_DEPTH
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
internal func binaryExpressionDepthAtLeast(expression: Expr, depth: Int64): Bool {
    let safeOperatorLimit: Int64 = MAX_SOURCE_BINARY_DEPTH
    match (expression) {
        case binary: BinaryExpr =>
            let nextDepth = depth + 1
            if (nextDepth >= safeOperatorLimit) { return true }
            binaryExpressionDepthAtLeast(binary.leftExpr, nextDepth) ||
                binaryExpressionDepthAtLeast(binary.rightExpr, nextDepth)
        case _ => false
    }
}

internal class BinaryExpressionDepthVisitor <: Visitor {
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

internal func exceedsSafeBinaryExpressionDepth(program: Program): Bool {
    let visitor = BinaryExpressionDepthVisitor()
    program.traverse(visitor)
    visitor.exceeded
}
internal func hasDeepSourceBinaryExpression(source: String): Bool {
    let tokens = try { sourceLexerTokens(source) } catch (_: Exception) { return false }
    looksLikeUnsafeBinaryExpressionDepth(tokens, true)
}

internal func packageNameFrom(program: Program, fallback: String): String {
    var value = program.packageHeader.toTokens().toString().trimAscii()
    if (value.isEmpty()) { return fallback }
    if (value.startsWith("macro package ")) { value = value.removePrefix("macro package ") }
    if (value.startsWith("package ")) { value = value.removePrefix("package ") }
    value.trimAscii()
}

internal func parseSourceTextWithAst(input: SourceInputFile, fallbackPackageName: String,
    source: String): ParsedSourceFile {
    let result = ParsedSourceFile(input)
    let relative = input.logicalPath
    try {
        let tokens = sourceLexerTokens(source)
        if (looksLikeUnsafeBinaryExpressionDepth(tokens, false)) {
            result.diagnostics.add(Diagnostic("error", "CJDOC1012",
                "source exceeds the safe std.ast binary-expression depth; file skipped",
                source: SourceLocation(relative, 1, 1, 1, 1)))
            return result
        }
        let program = try {
            parseProgram(tokens)
        } catch (error: Exception) {
            let recovered = syntaxRecoverySource(source)
            if (recovered == source) { throw error }
            let recoveredTokens = sourceLexerTokens(recovered)
            if (looksLikeUnsafeBinaryExpressionDepth(recoveredTokens, false)) {
                result.diagnostics.add(Diagnostic("error", "CJDOC1012",
                    "source exceeds the safe std.ast binary-expression depth; file skipped",
                    source: SourceLocation(relative, 1, 1, 1, 1)))
                return result
            }
            parseProgram(recoveredTokens)
        }
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
            collectDocComments(relative, tokens, sourceBuffer), sourceBuffer))
        for (comment in result.orphanDocComments) {
            result.diagnostics.add(Diagnostic("warning", "CJDOC1014",
                "doc comment is not attached to a documentable declaration",
                source: comment.source))
        }
        result.packageName = Some(packageName)
        result.imports.add(all: collectImports(program, relative, sourceBuffer))
        result.declarations.add(all: collector.declarations)
        result.reExports.add(all: collectPublicReExports(program, relative, packageName,
            input.module.id))
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
