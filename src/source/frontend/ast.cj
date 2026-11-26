protected package cjdoc.source.frontend

import cjdoc.source.model.{
    MacroInvocation, ParsedSourceFile, SourceDeclaration, SourceInputFile, SourceParameter,
    SourceSymbolRelationship, SourceTypeRelationship, UnsupportedDeclaration}
import cjdoc.source.{Diagnostic, MAX_SOURCE_BINARY_DEPTH, SourceLocation}
import cjdoc.source.lexing.{
    IndexedSourceBuffer, enumCaseStart, headerEndOffset, sourceApiSignatureTokens, sourceLexerTokens}
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
    var wrappedDeclarationStart: ?SourceLocation = None
    let wrappedAnnotations = ArrayList<String>()
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
            (startLine <= 0 || startColumn <= 0 ||
                positionLess(Int64(tokens[0].pos.line), Int64(tokens[0].pos.column), startLine, startColumn))) {
            startLine = Int64(tokens[0].pos.line)
            startColumn = Int64(tokens[0].pos.column)
        }
        for (modifier in decl.modifiers) {
            let modifierStartLine = Int64(modifier.beginPos.line)
            let modifierStartColumn = Int64(modifier.beginPos.column)
            if (modifierStartLine > 0 && modifierStartColumn > 0 &&
                (startLine <= 0 || startColumn <= 0 ||
                    positionLess(modifierStartLine, modifierStartColumn, startLine, startColumn))) {
                startLine = modifierStartLine
                startColumn = modifierStartColumn
            }
        }
        // A macro wrapper is part of the source declaration header. Extending
        // only the next declaration preserves its leading doc comment while
        // retaining the original positions of its members.
        if (let Some(wrapper) <- wrappedDeclarationStart) {
            startLine = wrapper.startLine
            startColumn = wrapper.startColumn
            wrappedDeclarationStart = None
        }
        if (startLine <= 0 || startColumn <= 0) { return None }
        let endLine = if (decl.endPos.line > 0) { Int64(decl.endPos.line) } else { startLine }
        let endColumn = if (decl.endPos.column > 0) { Int64(decl.endPos.column) } else { startColumn }
        let location = match (sourceLocationFromAstRange(path, source,
            startLine, startColumn, endLine, endColumn)) {
            case Some(value) => value
            case None =>
                // Nested generic closers can put std.ast's exclusive end column one past the source line.
                let adjustedEnd: ?SourceLocation = if (endLine == startLine && endColumn > startColumn) {
                    sourceLocationFromAstRange(path, source, startLine, startColumn,
                        endLine, endColumn - 1)
                } else {
                    None
                }
                match (adjustedEnd) {
                    case Some(value) => value
                    case None =>
                        if (tokens.size == 0) { return None }
                        let lastToken = tokens[tokens.size - 1]
                        let (tokenEndLine, tokenEndColumn) = tokenEndPosition(lastToken)
                        match (sourceLocationFromAstRange(path, source, startLine, startColumn,
                            tokenEndLine, tokenEndColumn)) {
                            case Some(value) => value
                            case None => return None
                        }
                }
        }
        let signature = declarationSignature(decl, source, location, hasBody)
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, kind, name), kind, name,
            packageName, moduleId, declarationVisibility(decl), location,
            signature, isContainer: isContainer,
            enumNonExhaustive: enumNonExhaustive,
            sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
        symbol.annotations.add(all: wrappedAnnotations)
        wrappedAnnotations.clear()
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
        let wrapperStart = wrappedDeclarationStart
        let wrapperAnnotations = wrappedAnnotations.toArray()
        for (binding in collector.bindings) {
            // Every name in one pattern is declared by the same source header.
            wrappedDeclarationStart = wrapperStart
            wrappedAnnotations.clear()
            wrappedAnnotations.add(all: wrapperAnnotations)
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
        if (let Some(symbol) <- add(decl, "macro", decl.identifier.value, hasBody: true)) {
            addParameters(symbol, decl.funcParams)
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
        breakTraverse()
    }

    public override func visit(decl: MacroExpandDecl): Unit {
        let name = try { decl.fullIdentifier.value } catch (_: Exception) {
            try { decl.identifier.value } catch (_: Exception) { "<macro>" }
        }
        let input: ?Decl = try { Some(decl.macroInputDecl) } catch (_: Exception) { None }
        let previousStart = wrappedDeclarationStart
        let previousAnnotations = wrappedAnnotations.toArray()
        for (annotation in decl.annotations) {
            wrappedAnnotations.add(annotation.toTokens().toString().trimAscii())
        }
        if (let Some(location) <- sourceLocationFromAstRange(path, source,
            Int64(decl.beginPos.line), Int64(decl.beginPos.column),
            Int64(decl.endPos.line), Int64(decl.endPos.column))) {
            macroInvocations.add(MacroInvocation(name, location))
            let detail = if (input.isSome()) {
                "source input is documented; generated declarations are unavailable"
            } else { "source input cannot be recovered as a declaration" }
            diagnostics.add(Diagnostic("warning", "CJDOC1009",
                "macro invocation '${name}' is not expanded: ${detail}", source: location))
            if (input.isNone()) {
                unsupportedDeclarations.add(UnsupportedDeclaration("macroInvocation", name,
                    "macro expansion is not executed; ${detail}", location))
            }
            if (wrappedDeclarationStart.isNone()) { wrappedDeclarationStart = Some(location) }
        }
        if (let Some(declaration) <- input) { declaration.traverse(this) }
        wrappedDeclarationStart = previousStart
        wrappedAnnotations.clear()
        wrappedAnnotations.add(all: previousAnnotations)
        // The explicit traversal preserves nested wrapper context. Do not let
        // std.ast visit the same input again through its default traversal.
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
    // Constraint subjects are generic parameters, not navigation targets. The
    // AST already splits intersections and comma-separated constraints into
    // upper-bound TypeNodes, preserving their declaration scope and spelling.
    for (constraint in decl.genericConstraint) {
        for (bound in constraint.upperBounds) {
            let display = normalizedTokens(bound)
            if (!display.isEmpty()) {
                symbol.relationships.add(SourceTypeRelationship("genericConstraint", display))
            }
        }
    }
}

protected func tokenEndPosition(token: Token): (Int64, Int64) {
    let lines = token.value.split("\n")
    let endLine = Int64(token.pos.line) + lines.size - 1
    let endColumn = if (lines.size == 1) {
        Int64(token.pos.column) + lines[0].toArray().size
    } else {
        lines[lines.size - 1].toArray().size + 1
    }
    (endLine, endColumn)
}

protected func sourceLocationFromAstRange(path: String, source: IndexedSourceBuffer,
    startLine: Int64, startColumn: Int64, endLine: Int64, endColumn: Int64): ?SourceLocation {
    let startOffset = source.byteOffsetFromLexerPosition(startLine, startColumn)
    let endOffset = source.byteOffsetFromLexerPosition(endLine, endColumn)
    if (startOffset < 0 || endOffset < startOffset) { return None }
    Some(SourceLocation(path, startLine, startColumn, endLine, endColumn))
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
protected func hasDeepSourceBinaryExpression(source: String): Bool {
    let tokens = try { sourceLexerTokens(source) } catch (_: Exception) { return false }
    looksLikeUnsafeBinaryExpressionDepth(tokens, true)
}

internal func packageNameFrom(program: Program, fallback: String): String {
    let builder = StringBuilder()
    var inPackageName = false
    for (token in program.packageHeader.toTokens()) {
        if (!inPackageName) {
            inPackageName = token.value == "package"
            continue
        }
        if (token.kind != TokenKind.NL && token.kind != TokenKind.COMMENT) {
            builder.append(token.value)
        }
    }
    let name = builder.toString()
    if (name.isEmpty()) { fallback } else { name }
}

protected func parseSourceTextWithAst(input: SourceInputFile, fallbackPackageName: String,
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
        result.packageImports.add(all: collectImportedPackagePaths(program))
        result.importFacts.add(all: collectImportFacts(program, relative))
        result.declarations.add(all: collector.declarations)
        result.reExports.add(all: collectPublicReExports(program, relative, packageName,
            input.module.id, sourceBuffer))
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
