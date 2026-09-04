package cjdoc

import std.ast.*
import std.collection.*

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

internal func commentLocation(path: String, token: Token): SourceLocation {
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

internal func collectDocComments(path: String, tokens: Tokens): ArrayList<RawDocComment> {
    let comments = ArrayList<RawDocComment>()
    for (token in tokens) {
        if (token.kind == COMMENT && token.value.startsWith("/**")) {
            comments.add(RawDocComment(token.value, commentLocation(path, token)))
        }
    }
    return comments
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
internal func binaryExpressionDepthAtLeast(expression: Expr, depth: Int64): Bool {
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

internal func isFunctionLike(symbol: SourceDeclaration): Bool {
    return symbol.kind == "function" || symbol.kind == "constructor"
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
    return left.source.endColumn > right.source.endColumn
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
        if (!activeFunctions.isEmpty()) {
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
    return index == end
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
