package cjdoc

import std.ast.*
import std.collection.*
import std.convert.Parsable
import std.env.*
import std.fs.*
import std.process.*
import std.sort.*

private let SOURCE_CACHE_FORMAT = "cjdoc-source-cache-v2"
private let MAX_SOURCE_FILE_BYTES: Int64 = 32 * 1024 * 1024
private let MAX_SOURCE_FILES: Int64 = 100000
private let MAX_SOURCE_DIRECTORY_DEPTH: Int64 = 128

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

private func byteOffset(source: String, line: Int64, column: Int64): Int64 {
    if (line < 1 || column < 1) { return -1 }
    let bytes = source.toArray()
    var offset: Int64 = 0
    var currentLine: Int64 = 1
    while (offset < bytes.size && currentLine < line) {
        if (bytes[offset] == 10u8) { currentLine++ }
        offset++
    }
    if (currentLine != line) { return -1 }
    let result = offset + column - 1
    if (result < 0 || result > bytes.size) { return -1 }
    return result
}

private func sourceSlice(source: String, location: SourceLocation): String {
    let start = byteOffset(source, location.startLine, location.startColumn)
    let end = byteOffset(source, location.endLine, location.endColumn)
    if (start < 0 || end < start) { return "" }
    let bytes = source.toArray()
    let selected = ArrayList<UInt8>()
    var index = start
    while (index < end && index < bytes.size) {
        selected.add(bytes[index])
        index++
    }
    return String.fromUtf8(selected.toArray())
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
                    return byteOffset(source, Int64(token.pos.line), Int64(token.pos.column))
                }
            case _ => ()
        }
    }
    return source.size
}

private func declarationSignature(decl: Decl, source: String, location: SourceLocation,
    hasBody: Bool): String {
    let exact = sourceSlice(source, location)
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

private class AstDeclarationCollector <: Visitor {
    let path: String
    let packageName: String
    let source: String
    let declarations = ArrayList<SourceDeclaration>()
    let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    let diagnostics = ArrayList<Diagnostic>()
    let localScopes = ArrayList<SourceLocation>()

    init(path: String, packageName: String, source: String) {
        this.path = path
        this.packageName = packageName
        this.source = source
    }

    func add(decl: Decl, kind: String, name: String, isContainer!: Bool = false,
        hasBody!: Bool = false): ?SourceDeclaration {
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
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, kind, name), kind, name,
            packageName, declarationVisibility(decl), location,
            declarationSignature(decl, source, location, hasBody), isContainer: isContainer)
        addCommonAstData(symbol, decl)
        declarations.add(symbol)
        return symbol
    }

    func addParameters(symbol: SourceDeclaration, parameters: ArrayList<FuncParam>): Unit {
        for (parameter in parameters) {
            let parameterName = try { parameter.identifier.value } catch (_: Exception) { "_" }
            let display = try { normalizedTokens(parameter.paramType) } catch (_: Exception) { "" }
            symbol.parameters.add(SourceParameter(parameterName, display))
        }
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
        if (let Some(owner) <- add(decl, "enum", decl.identifier.value, isContainer: true, hasBody: true)) {
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
                let location = SourceLocation(path, Int64(first.pos.line), Int64(first.pos.column),
                    endLine, endColumn)
                let exact = sourceSlice(source, location)
                let name = constructor.identifier.value
                let symbol = SourceDeclaration(makeSourceDeclarationKey(location, "enumCase", name),
                    "enumCase", name, packageName, owner.visibility, location,
                    if (exact.isEmpty()) { constructor.toTokens().toString().trimAscii() } else { exact.trimAscii() })
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
    }

    public override func visit(decl: PropDecl): Unit {
        if (let Some(symbol) <- add(decl, "property", decl.identifier.value, hasBody: true)) {
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
    }

    public override func visit(decl: VarDecl): Unit {
        let name = try { decl.identifier.value } catch (_: Exception) { "<pattern>" }
        if (let Some(symbol) <- add(decl, "variable", name)) {
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
    }

    public override func visit(decl: FuncDecl): Unit {
        let name = decl.identifier.value
        let kind = if (name == "init") { "constructor" } else { "function" }
        if (let Some(symbol) <- add(decl, kind, name, hasBody: true)) {
            addParameters(symbol, decl.funcParams)
            let display = try { normalizedTokens(decl.declType) } catch (_: Exception) { "" }
            if (!display.isEmpty()) { symbol.returnTypeSpelling = Some(display) }
        }
    }

    public override func visit(decl: PrimaryCtorDecl): Unit {
        if (let Some(symbol) <- add(decl, "constructor", decl.identifier.value, hasBody: true)) {
            addParameters(symbol, decl.funcParams)
        }
    }

    public override func visit(decl: MainDecl): Unit {
        if (decl.beginPos.line > 0 && decl.beginPos.column > 0 && decl.endPos.line > 0 && decl.endPos.column > 0) {
            localScopes.add(SourceLocation(path, Int64(decl.beginPos.line), Int64(decl.beginPos.column),
                Int64(decl.endPos.line), Int64(decl.endPos.column)))
        }
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

// std.ast in the 2026-08-29 daily reproducibly crashes while serializing a
// BinaryExpr chain at 67 operators. Keep a small safety margin and fail this
// file explicitly instead of allowing a native SIGSEGV to terminate cjdoc.
private func exceedsSafeBinaryExpressionDepth(tokens: Tokens): Bool {
    let safeOperatorLimit: Int64 = 64
    let outerOperators = ArrayList<Int64>()
    var operators: Int64 = 0
    for (token in tokens) {
        if (isBinaryOperator(token.value)) {
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
    return false
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

private func bindComments(symbols: ArrayList<SourceDeclaration>, comments: ArrayList<RawDocComment>): Unit {
    var commentIndex: Int64 = 0
    var candidate: ?RawDocComment = None
    for (symbol in symbols) {
        while (commentIndex < comments.size &&
            positionLess(comments[commentIndex].source.endLine, comments[commentIndex].source.endColumn,
                symbol.source.startLine, symbol.source.startColumn)) {
            if (!comments[commentIndex].bound) { candidate = comments[commentIndex] }
            commentIndex++
        }
        if (let Some(comment) <- candidate) {
            if (!comment.bound) {
                symbol.documentation = parseDocComment(comment.raw)
                comment.bound = true
            }
            candidate = None
        }
    }
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
    let normalized = path.replace("\\", "/")
    if (normalized.endsWith("/") && !normalized.endsWith(":/")) {
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

private func relativePath(root: String, path: String): String {
    let base = normalizedHostPath(canonicalize(root).toString())
    let full = normalizedHostPath(canonicalize(path).toString())
    if (full.startsWith(base + "/")) { return full[(base.size + 1)..] }
    return Path(path).fileName
}

private func collectSourceFiles(directory: String, result: ArrayList<String>,
    limit: Int64, depth!: Int64 = 0): Bool {
    if (depth > MAX_SOURCE_DIRECTORY_DEPTH) { return false }
    let entries = Directory.readFrom(directory)
    sort(entries, lessThan: { left, right =>
        left.path.toString() < right.path.toString()
    }, stable: true)
    for (entry in entries) {
        if (result.size >= limit) { return false }
        if (entry.isSymbolicLink() || entry.isHidden()) { continue }
        if (entry.isDirectory()) {
            if (entry.name != "target" &&
                !collectSourceFiles(entry.path.toString(), result, limit, depth: depth + 1)) {
                return false
            }
        } else if (entry.isRegular() && entry.path.extensionName == "cj" && !entry.name.endsWith("_test.cj")) {
            result.add(entry.path.toString())
        }
    }
    true
}

private class SourceModuleRoot {
    let actualRoot: String
    let logicalPrefix: String
    let documentation: SourceModule

    init(actualRoot: String, logicalPrefix: String, documentation: SourceModule) {
        this.actualRoot = actualRoot
        this.logicalPrefix = logicalPrefix
        this.documentation = documentation
    }
}

private class SourceInputFile {
    let actualPath: String
    let logicalPath: String
    let module: SourceModule

    init(actualPath: String, logicalPath: String, module: SourceModule) {
        this.actualPath = actualPath
        this.logicalPath = logicalPath
        this.module = module
    }
}

private func sortStrings(values: ArrayList<String>): Unit {
    sort(values)
}

func dependencyPrefix(name: String): String {
    "dependencies/" + name.replace("/", "_").replace("\\", "_").replace("..", "_")
}

private func moduleId(role: String, name: String, logicalPrefix: String): String {
    if (role == "root") { return "cjdoc:module:v1:root" }
    if (role == "workspace") { return "cjdoc:module:v1:workspace:${logicalPrefix}" }
    if (role == "externalDependency") { return "cjdoc:module:v1:external:${percentEscapeSymbolPart(name)}" }
    "cjdoc:module:v1:path:${percentEscapeSymbolPart(name)}"
}

private func addUniqueString(values: ArrayList<String>, value: String): Unit {
    for (existing in values) {
        if (existing == value) { return }
    }
    values.add(value)
}

private func findSourceModule(modules: ArrayList<SourceModuleRoot>, actualRoot: String): ?SourceModuleRoot {
    for (module in modules) {
        if (module.actualRoot == actualRoot) { return Some(module) }
    }
    None
}

private func addModuleRoot(workspaceRoot: String, candidate: String, roots: ArrayList<String>,
    seen: HashSet<String>, diagnostics: ArrayList<Diagnostic>): Bool {
    let resolved = try {
        canonicalize(candidate).toString()
    } catch (error: Exception) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace member is not accessible: ${error.message}"))
        return false
    }
    if (!hostPathIsWithin(workspaceRoot, resolved)) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace member escapes project root: ${candidate}"))
        return false
    }
    if (!exists(Path(resolved).join("cjpm.toml")) || !exists(Path(resolved).join("src"))) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "workspace member must contain cjpm.toml and src/: ${relativePath(workspaceRoot, resolved)}"))
        return false
    }
    if (seen.add(resolved)) { roots.add(resolved) }
    return true
}

private func discoverModuleRoots(root: String, manifest: String,
    diagnostics: ArrayList<Diagnostic>): ArrayList<String> {
    let roots = ArrayList<String>()
    let seen = HashSet<String>()
    if (exists(Path(root).join("src"))) { let _ = addModuleRoot(root, root, roots, seen, diagnostics) }
    for (member in parseCjpmManifest(manifest).workspaceMembers) {
        let _ = addModuleRoot(root, Path(root).join(member).toString(), roots, seen, diagnostics)
    }
    if (roots.isEmpty() && diagnostics.isEmpty()) {
        diagnostics.add(Diagnostic("error", "CJDOC1010",
            "project must contain src/ or declare workspace members"))
    }
    sortStrings(roots)
    return roots
}

private func addExternalSourceModule(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, input: DependencySourceInput,
    diagnostics: ArrayList<Diagnostic>): ?SourceModuleRoot {
    let resolved = try {
        canonicalize(input.path).toString()
    } catch (_: Exception) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' is not accessible; skipped"))
        return None
    }
    if (seen.contains(resolved)) { return findSourceModule(modules, resolved) }
    let manifestPath = Path(resolved).join("cjpm.toml")
    if (!exists(manifestPath) || !exists(Path(resolved).join("src"))) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' must contain cjpm.toml and src/; skipped"))
        return None
    }
    let dependencyManifest = try {
        String.fromUtf8(File.readFrom(manifestPath))
    } catch (_: Exception) {
        diagnostics.add(Diagnostic("warning", "CJDOC1018",
            "configured dependency source '${input.name}' manifest is not readable; skipped"))
        return None
    }
    let packageName = match (parseCjpmManifest(dependencyManifest).packageName) {
        case Some(value) => value
        case None => input.name
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
        packageName, "externalDependency", prefix)
    let module = SourceModuleRoot(resolved, prefix, moduleDoc)
    let _ = seen.add(resolved)
    modules.add(module)
    Some(module)
}

private func addExternalSourceModules(modules: ArrayList<SourceModuleRoot>,
    seen: HashSet<String>, inputs: Array<DependencySourceInput>, ownerCount: Int64,
    diagnostics: ArrayList<Diagnostic>): Unit {
    if (inputs.isEmpty() || ownerCount == 0) { return }
    let sortedInputs = ArrayList<DependencySourceInput>()
    sortedInputs.add(all: inputs)
    sort(sortedInputs, lessThan: { left, right =>
        if (left.name == right.name) { left.path < right.path } else { left.name < right.name }
    }, stable: true)
    for (input in sortedInputs) {
        if (let Some(dependency) <- addExternalSourceModule(modules, seen, input, diagnostics)) {
            var ownerIndex: Int64 = 0
            while (ownerIndex < ownerCount) {
                addUniqueString(modules[ownerIndex].documentation.dependencyIds,
                    dependency.documentation.id)
                ownerIndex++
            }
        }
    }
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
    if (!safeDependencyCacheName(dependency.name)) {
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
            if (exists(Path(path).join("cjpm.toml")) && exists(Path(path).join("src"))) {
                Some(DependencySourceInput(dependency.name, path))
            } else {
                diagnostics.add(Diagnostic("warning", "CJDOC1021",
                    "locked dependency '${dependency.name}' is not present in the selected cjpm cache; skipped"))
                None
            }
        case None =>
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "locked dependency '${dependency.name}' cannot be mapped to a safe cjpm cache path; skipped"))
            None
    }
}

private func readLockedDependencies(directory: String, required: Bool,
    diagnostics: ArrayList<Diagnostic>): ArrayList<CjpmLockedDependency> {
    let lockPath = Path(directory).join("cjpm.lock")
    if (!exists(lockPath)) {
        if (required) {
            diagnostics.add(Diagnostic("warning", "CJDOC1021",
                "cached dependency discovery requested but cjpm.lock is missing"))
        }
        return ArrayList<CjpmLockedDependency>()
    }
    let lockText = try {
        String.fromUtf8(File.readFrom(lockPath))
    } catch (_: Exception) {
        diagnostics.add(Diagnostic("warning", "CJDOC1021",
            "cached dependency discovery skipped an unreadable cjpm.lock"))
        return ArrayList<CjpmLockedDependency>()
    }
    let result = ArrayList<CjpmLockedDependency>()
    result.add(all: parseCjpmLock(lockText))
    result
}

private func addLockedDependency(modules: ArrayList<SourceModuleRoot>, seen: HashSet<String>,
    owners: Array<SourceModuleRoot>, dependency: CjpmLockedDependency,
    cacheRoot: String, explicitInputs: Array<DependencySourceInput>,
    diagnostics: ArrayList<Diagnostic>): Unit {
    let input = match (dependencyInputNamed(explicitInputs, dependency.name)) {
        case Some(explicit) => Some(explicit)
        case None => cachedDependencySource(dependency, cacheRoot, diagnostics)
    }
    if (let Some(sourceInput) <- input) {
        if (let Some(dependencyModule) <- addExternalSourceModule(modules, seen,
            sourceInput, diagnostics)) {
            for (owner in owners) {
                addUniqueString(owner.documentation.dependencyIds,
                    dependencyModule.documentation.id)
            }
        }
    }
}

private func discoverSourceModules(root: String, manifest: String, includePathDependencies: Bool,
    dependencySources: Array<DependencySourceInput>,
    includeCachedDependencies: Bool, cjpmCacheRoot: ?String,
    diagnostics: ArrayList<Diagnostic>): ArrayList<SourceModuleRoot> {
    let modules = ArrayList<SourceModuleRoot>()
    let seen = HashSet<String>()
    for (moduleRoot in discoverModuleRoots(root, manifest, diagnostics)) {
        let _ = seen.add(moduleRoot)
        let moduleManifest = try {
            if (moduleRoot == root) { manifest } else {
                String.fromUtf8(File.readFrom(Path(moduleRoot).join("cjpm.toml")))
            }
        } catch (_: Exception) {
            diagnostics.add(Diagnostic("error", "CJDOC1010", "workspace member manifest is not readable"))
            continue
        }
        let name = match (parseCjpmManifest(moduleManifest).packageName) {
            case Some(actual) => actual
            case None => Path(moduleRoot).fileName
        }
        let role = if (moduleRoot == root) { "root" } else { "workspace" }
        let prefix = if (moduleRoot == root) { "" } else { relativePath(root, moduleRoot) }
        let moduleDoc = SourceModule(moduleId(role, name, prefix), name, role, prefix)
        modules.add(SourceModuleRoot(moduleRoot, prefix, moduleDoc))
    }
    let initialOwnerCount = modules.size
    addExternalSourceModules(modules, seen, dependencySources, initialOwnerCount, diagnostics)
    let selectedCacheRoot: ?String = if (includeCachedDependencies) {
        selectedCjpmCacheRoot(cjpmCacheRoot, diagnostics)
    } else {
        None
    }
    if (let Some(cacheRoot) <- selectedCacheRoot) {
        let owners = ArrayList<SourceModuleRoot>()
        var ownerIndex: Int64 = 0
        while (ownerIndex < initialOwnerCount) {
            owners.add(modules[ownerIndex])
            ownerIndex++
        }
        for (dependency in readLockedDependencies(root, true, diagnostics)) {
            addLockedDependency(modules, seen, owners.toArray(), dependency,
                cacheRoot, dependencySources, diagnostics)
        }
    }
    if (!includePathDependencies && !includeCachedDependencies) { return modules }

    var moduleIndex: Int64 = 0
    while (moduleIndex < modules.size) {
        let module = modules[moduleIndex]
        if (let Some(cacheRoot) <- selectedCacheRoot) {
            // The root lock was already attached to every initial module. Each
            // non-root module owns its own lock edges, so newly discovered
            // cached dependencies are traversed breadth-first without network.
            if (module.actualRoot != root) {
                for (dependency in readLockedDependencies(module.actualRoot, false, diagnostics)) {
                    addLockedDependency(modules, seen, [module], dependency,
                        cacheRoot, dependencySources, diagnostics)
                }
            }
        }
        if (!includePathDependencies) {
            moduleIndex++
            continue
        }
        let moduleManifest = try {
            String.fromUtf8(File.readFrom(Path(module.actualRoot).join("cjpm.toml")))
        } catch (_: Exception) {
            diagnostics.add(Diagnostic("warning", "CJDOC1016",
                "path dependency manifest is not readable; dependency traversal stopped for one package"))
            moduleIndex++
            continue
        }
        for (dependencyPath in parseCjpmManifest(moduleManifest).pathDependencies) {
            let resolved = try {
                canonicalize(Path(module.actualRoot).join(dependencyPath)).toString()
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "path dependency is not accessible; skipped"))
                continue
            }
            if (seen.contains(resolved)) {
                if (let Some(existing) <- findSourceModule(modules, resolved)) {
                    addUniqueString(module.documentation.dependencyIds, existing.documentation.id)
                }
                continue
            }
            let dependencyManifestPath = Path(resolved).join("cjpm.toml")
            let dependencySourcePath = Path(resolved).join("src")
            if (!exists(dependencyManifestPath) || !exists(dependencySourcePath)) {
                diagnostics.add(Diagnostic("warning", "CJDOC1015",
                    "path dependency is not a Cangjie source package; skipped"))
                let _ = seen.add(resolved)
                continue
            }
            let dependencyManifest = try {
                String.fromUtf8(File.readFrom(dependencyManifestPath))
            } catch (_: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC1016",
                    "path dependency manifest is not readable; skipped"))
                let _ = seen.add(resolved)
                continue
            }
            let dependencyName = match (parseCjpmManifest(dependencyManifest).packageName) {
                case Some(name) => name
                case None => Path(resolved).fileName
            }
            let prefix = dependencyPrefix(dependencyName)
            let dependencyDoc = SourceModule(moduleId("pathDependency", dependencyName, prefix),
                dependencyName, "pathDependency", prefix)
            let _ = seen.add(resolved)
            modules.add(SourceModuleRoot(resolved, prefix, dependencyDoc))
            addUniqueString(module.documentation.dependencyIds, dependencyDoc.id)
        }
        moduleIndex++
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

private func getSourcePackage(source: SourceSnapshot, name: String): SourcePackage {
    for (pkg in source.packages) {
        if (pkg.name == name) { return pkg }
    }
    let pkg = SourcePackage(name)
    source.packages.add(pkg)
    return pkg
}

private func hasFatalSourceDiagnostics(source: SourceSnapshot): Bool {
    for (diagnostic in source.diagnostics) {
        if (diagnostic.severity == "error" && diagnostic.code != "CJDOC1011" &&
            diagnostic.code != "CJDOC1012" && diagnostic.code != "CJDOC1020") { return true }
    }
    return false
}

// The cache codec is deliberately length-prefixed instead of line based: source
// spellings and documentation may contain arbitrary newlines and Unicode. Every
// entry also carries its complete cache key, so a filename-hash collision is a
// safe miss rather than stale documentation.
private class SourceCacheWriter {
    let bytes = ArrayList<UInt8>()

    func add(value: String): Unit {
        bytes.add(all: value.toArray().size.toString().toArray())
        bytes.add(58u8)
        bytes.add(all: value.toArray())
    }

    func add(value: Int64): Unit { add(value.toString()) }
    func add(value: Bool): Unit { add(if (value) { "1" } else { "0" }) }
    func result(): Array<UInt8> { bytes.toArray() }
}

private class SourceCacheReader {
    let bytes: Array<UInt8>
    var offset: Int64 = 0

    init(bytes: Array<UInt8>) { this.bytes = bytes }

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
        if (length < 0 || offset + length > bytes.size) {
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

private func cacheAddTag(writer: SourceCacheWriter, tag: DocTag): Unit {
    writer.add(tag.name)
    writer.add(tag.subject)
    writer.add(tag.description)
}

private func cacheReadTag(reader: SourceCacheReader): DocTag {
    DocTag(reader.next(), reader.next(), reader.next())
}

private func cacheAddTags(writer: SourceCacheWriter, tags: ArrayList<DocTag>): Unit {
    writer.add(tags.size)
    for (tag in tags) { cacheAddTag(writer, tag) }
}

private func cacheReadTags(reader: SourceCacheReader, tags: ArrayList<DocTag>): Unit {
    let count = reader.nextInt()
    if (count < 0 || count > 1000000) { throw IllegalArgumentException("invalid cache list length") }
    var index: Int64 = 0
    while (index < count) {
        tags.add(cacheReadTag(reader))
        index++
    }
}

private func cacheAddStrings(writer: SourceCacheWriter, values: ArrayList<String>): Unit {
    writer.add(values.size)
    for (value in values) { writer.add(value) }
}

private func cacheReadStrings(reader: SourceCacheReader, values: ArrayList<String>): Unit {
    let count = reader.nextInt()
    if (count < 0 || count > 1000000) { throw IllegalArgumentException("invalid cache list length") }
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
    writer.add(value.visibility)
    cacheAddLocation(writer, value.source)
    writer.add(value.sourceSignature)
    writer.add(value.isContainer)
    cacheAddOptionalString(writer, value.ownerSourceKey)
    cacheAddStrings(writer, value.genericParameters)
    writer.add(value.parameters.size)
    for (parameter in value.parameters) {
        writer.add(parameter.name)
        writer.add(parameter.typeSpelling)
    }
    cacheAddOptionalString(writer, value.returnTypeSpelling)
    cacheAddStrings(writer, value.annotations)
    cacheAddStrings(writer, value.modifiers)
    writer.add(value.relationships.size)
    for (relationship in value.relationships) {
        writer.add(relationship.kind)
        writer.add(relationship.targetSpelling)
    }
    writer.add(value.symbolRelationships.size)
    for (relationship in value.symbolRelationships) {
        writer.add(relationship.kind)
        writer.add(relationship.targetDisplay)
    }
    cacheAddDocComment(writer, value.documentation)
}

private func cacheReadDeclaration(reader: SourceCacheReader): SourceDeclaration {
    let sourceKey = reader.next()
    let kind = reader.next()
    let name = reader.next()
    let packageName = reader.next()
    let visibility = reader.next()
    let source = cacheReadLocation(reader)
    let signature = reader.next()
    let isContainer = reader.nextBool()
    let owner = cacheReadOptionalString(reader)
    let value = SourceDeclaration(sourceKey, kind, name, packageName, visibility,
        source, signature, isContainer: isContainer)
    value.ownerSourceKey = owner
    cacheReadStrings(reader, value.genericParameters)
    let parameterCount = reader.nextInt()
    if (parameterCount < 0 || parameterCount > 1000000) {
        throw IllegalArgumentException("invalid cache parameter count")
    }
    var index: Int64 = 0
    while (index < parameterCount) {
        value.parameters.add(SourceParameter(reader.next(), reader.next()))
        index++
    }
    value.returnTypeSpelling = cacheReadOptionalString(reader)
    cacheReadStrings(reader, value.annotations)
    cacheReadStrings(reader, value.modifiers)
    let relationshipCount = reader.nextInt()
    if (relationshipCount < 0 || relationshipCount > 1000000) {
        throw IllegalArgumentException("invalid cache relationship count")
    }
    index = 0
    while (index < relationshipCount) {
        value.relationships.add(SourceTypeRelationship(reader.next(), reader.next()))
        index++
    }
    let symbolRelationshipCount = reader.nextInt()
    if (symbolRelationshipCount < 0 || symbolRelationshipCount > 1000000) {
        throw IllegalArgumentException("invalid cache symbol relationship count")
    }
    index = 0
    while (index < symbolRelationshipCount) {
        value.symbolRelationships.add(SourceSymbolRelationship(reader.next(), reader.next()))
        index++
    }
    value.documentation = cacheReadDocComment(reader)
    return value
}

private class ParsedSourceFile {
    let input: SourceInputFile
    var packageName: ?String = None
    let declarations = ArrayList<SourceDeclaration>()
    let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    let diagnostics = ArrayList<Diagnostic>()
    var cacheStatus = "disabled"

    init(input: SourceInputFile) { this.input = input }
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

private func encodeParsedSource(cacheKey: String, parsed: ParsedSourceFile): Array<UInt8> {
    let writer = SourceCacheWriter()
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(cacheKey)
    cacheAddOptionalString(writer, parsed.packageName)
    writer.add(parsed.declarations.size)
    for (declaration in parsed.declarations) { cacheAddDeclaration(writer, declaration) }
    writer.add(parsed.unsupportedDeclarations.size)
    for (unsupported in parsed.unsupportedDeclarations) { cacheAddUnsupported(writer, unsupported) }
    writer.add(parsed.diagnostics.size)
    for (diagnostic in parsed.diagnostics) { cacheAddDiagnostic(writer, diagnostic) }
    return writer.result()
}

private func checkedCacheCount(reader: SourceCacheReader): Int64 {
    let count = reader.nextInt()
    if (count < 0 || count > 1000000) { throw IllegalArgumentException("invalid cache list length") }
    count
}

private func decodeParsedSource(input: SourceInputFile, cacheKey: String,
    bytes: Array<UInt8>): ParsedSourceFile {
    let reader = SourceCacheReader(bytes)
    if (reader.next() != SOURCE_CACHE_FORMAT || reader.next() != cacheKey) {
        throw IllegalArgumentException("cache key mismatch")
    }
    let parsed = ParsedSourceFile(input)
    parsed.packageName = cacheReadOptionalString(reader)
    var count = checkedCacheCount(reader)
    var index: Int64 = 0
    while (index < count) {
        parsed.declarations.add(cacheReadDeclaration(reader))
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
    if (!reader.finished()) { throw IllegalArgumentException("trailing cache data") }
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
    source: String, fingerprint: String): String {
    let writer = SourceCacheWriter()
    writer.add(SOURCE_CACHE_FORMAT)
    writer.add(fingerprint)
    writer.add(input.logicalPath)
    writer.add(fallbackPackageName)
    writer.add(source)
    String.fromUtf8(writer.result())
}

private func sourceCachePath(directory: String, input: SourceInputFile,
    cacheKey: String): String {
    let pathHash = stableSourceCacheHash(input.logicalPath)
    let contentHash = stableSourceCacheHash(cacheKey)
    Path(directory).join("${pathHash}-${contentHash}.cache").toString()
}

private func writeSourceCache(path: String, content: Array<UInt8>): Bool {
    try {
        let temporary = path + ".tmp"
        File.writeTo(temporary, content)
        rename(temporary, to: path, overwrite: true)
        return true
    } catch (_: Exception) {
        return false
    }
}

private func parseSourceText(input: SourceInputFile, fallbackPackageName: String,
    source: String): ParsedSourceFile {
    let result = ParsedSourceFile(input)
    let relative = input.logicalPath
    try {
        let tokens = cangjieLex(source)
        if (exceedsSafeBinaryExpressionDepth(tokens)) {
            result.diagnostics.add(Diagnostic("error", "CJDOC1012",
                "source exceeds the safe std.ast binary-expression depth; file skipped",
                source: SourceLocation(relative, 1, 1, 1, 1)))
            return result
        }
        let program = parseProgram(tokens)
        let packageName = packageNameFrom(program, fallbackPackageName)
        let collector = AstDeclarationCollector(relative, packageName, source)
        program.traverse(collector)
        sort(collector.declarations, lessThan: sourceOrderLess, stable: true)
        bindComments(collector.declarations, collectDocComments(relative, tokens))
        removeLocalDeclarations(collector.declarations, collector.localScopes)
        assignOwners(collector.declarations)
        result.packageName = Some(packageName)
        result.declarations.add(all: collector.declarations)
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
        let source = normalizeSourceNewlines(String.fromUtf8(File.readFrom(path)))
        let tokens = cangjieLex(source)
        if (exceedsSafeBinaryExpressionDepth(tokens)) { return 12 }
        let _ = parseProgram(tokens)
        return 0
    } catch (_: Exception) {
        return 11
    }
}

private func astPreflightStatus(executable: String, input: SourceInputFile): Int64 {
    try {
        let (exitCode, _, _) = executeWithOutput(executable,
            ["--internal-ast-preflight", input.actualPath])
        return exitCode
    } catch (_: Exception) {
        return -1
    }
}

private func parseAfterAstPreflight(input: SourceInputFile, fallbackPackageName: String,
    source: String, executable: ?String): ParsedSourceFile {
    if (let Some(actual) <- executable) {
        let status = astPreflightStatus(actual, input)
        if (status == 11) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1011",
                "failed to parse '${input.logicalPath}'",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
        if (status != 0 && status != 12) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1020",
                "isolated std.ast parser failed for '${input.logicalPath}'; file skipped",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
    }
    return parseSourceText(input, fallbackPackageName, source)
}

private func parseSourceInput(input: SourceInputFile, fallbackPackageName: String,
    cacheDirectory: ?String, cacheFingerprint: String,
    astPreflightExecutable: ?String): ParsedSourceFile {
    try {
        if (FileInfo(input.actualPath).size > MAX_SOURCE_FILE_BYTES) {
            let result = ParsedSourceFile(input)
            result.diagnostics.add(Diagnostic("error", "CJDOC1026",
                "source file exceeds the 32 MiB safety limit; file skipped",
                source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
            return result
        }
    } catch (_: Exception) {
        // The normal read path below reports inaccessible or disappearing files.
    }
    let source = try {
        normalizeSourceNewlines(String.fromUtf8(File.readFrom(input.actualPath)))
    } catch (_: Exception) {
        let result = ParsedSourceFile(input)
        result.diagnostics.add(Diagnostic("error", "CJDOC1011",
            "failed to parse '${input.logicalPath}'",
            source: SourceLocation(input.logicalPath, 1, 1, 1, 1)))
        return result
    }
    match (cacheDirectory) {
        case None => return parseAfterAstPreflight(input, fallbackPackageName, source,
            astPreflightExecutable)
        case Some(directory) =>
            let cacheKey = makeSourceCacheKey(input, fallbackPackageName, source, cacheFingerprint)
            let path = sourceCachePath(directory, input, cacheKey)
            if (exists(path)) {
                try {
                    return decodeParsedSource(input, cacheKey, File.readFrom(path))
                } catch (_: Exception) {
                    let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                        astPreflightExecutable)
                    parsed.cacheStatus = if (writeSourceCache(path,
                        encodeParsedSource(cacheKey, parsed))) { "corrupt-written" } else { "corrupt-write-failed" }
                    return parsed
                }
            }
            let parsed = parseAfterAstPreflight(input, fallbackPackageName, source,
                astPreflightExecutable)
            parsed.cacheStatus = if (writeSourceCache(path,
                encodeParsedSource(cacheKey, parsed))) { "miss-written" } else { "miss-write-failed" }
            return parsed
    }
}

private func mergeParsedSource(sourceSnapshot: SourceSnapshot, parsed: ParsedSourceFile,
    cacheStats: SourceCacheStats): Unit {
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
        addUniqueString(parsed.input.module.packageNames, packageName)
        let pkg = getSourcePackage(sourceSnapshot, packageName)
        pkg.sourceFiles.add(parsed.input.logicalPath)
    }
    sourceSnapshot.declarations.add(all: parsed.declarations)
    sourceSnapshot.unsupportedDeclarations.add(all: parsed.unsupportedDeclarations)
    sourceSnapshot.diagnostics.add(all: parsed.diagnostics)
}

private func parseAllSourceFiles(sourceSnapshot: SourceSnapshot, files: ArrayList<SourceInputFile>,
    jobs: Int64, cacheDirectory: ?String, cacheFingerprint: String,
    cacheStats: SourceCacheStats, astPreflightExecutable: ?String): Unit {
    if (jobs <= 1 || files.size <= 1) {
        for (input in files) {
            mergeParsedSource(sourceSnapshot,
                parseSourceInput(input, sourceSnapshot.projectName, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable),
                cacheStats)
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
            let fallbackPackageName = sourceSnapshot.projectName
            futures.add(spawn {
                parseSourceInput(input, fallbackPackageName, cacheDirectory, cacheFingerprint,
                    astPreflightExecutable)
            })
            index++
        }
        for (future in futures) { mergeParsedSource(sourceSnapshot, future.get(), cacheStats) }
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
    public let cacheStats = SourceCacheStats()

    public init(includePathDependencies!: Bool = false,
        dependencySources!: Array<DependencySourceInput> = [], jobs!: Int64 = 1,
        cacheDirectory!: ?String = None, cacheFingerprint!: ?String = None,
        astPreflightExecutable!: ?String = None,
        includeCachedDependencies!: Bool = false, cjpmCacheRoot!: ?String = None) {
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
    }

    public func collect(projectRoot: String): SourceSnapshot {
        cacheStats.reset()
        let root = try {
            canonicalize(projectRoot).toString()
        } catch (error: Exception) {
            let requestedName = Path(projectRoot).fileName
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "project path is not accessible: ${error.message}"))
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
            String.fromUtf8(File.readFrom(manifestPath))
        } catch (error: Exception) {
            let source = SourceSnapshot(if (requestedName.isEmpty()) { "project" } else { requestedName })
            source.diagnostics.add(Diagnostic("error", "CJDOC1010",
                "failed to read cjpm.toml: ${error.message}"))
            return source
        }
        let projectName = match (parseCjpmManifest(manifest).packageName) {
            case Some(name) => name
            case None => if (requestedName.isEmpty()) { "project" } else { requestedName }
        }
        let sourceSnapshot = SourceSnapshot(projectName)
        let moduleRoots = discoverSourceModules(root, manifest, includePathDependencies,
            dependencySources,
            includeCachedDependencies, cjpmCacheRoot,
            sourceSnapshot.diagnostics)
        if (hasFatalSourceDiagnostics(sourceSnapshot)) { return sourceSnapshot }
        for (module in moduleRoots) { sourceSnapshot.modules.add(module.documentation) }
        let files = ArrayList<SourceInputFile>()
        var scanLimitReached = false
        for (module in moduleRoots) {
            if (files.size >= MAX_SOURCE_FILES) { scanLimitReached = true; break }
            try {
                let moduleFiles = ArrayList<String>()
                let complete = collectSourceFiles(Path(module.actualRoot).join("src").toString(),
                    moduleFiles, MAX_SOURCE_FILES - files.size)
                if (!complete) { scanLimitReached = true }
                for (file in moduleFiles) {
                    let moduleRelative = relativePath(module.actualRoot, file)
                    let logicalPath = if (module.logicalPrefix.isEmpty()) {
                        relativePath(root, file)
                    } else {
                        module.logicalPrefix + "/" + moduleRelative
                    }
                    files.add(SourceInputFile(file, logicalPath, module.documentation))
                }
            } catch (error: Exception) {
                sourceSnapshot.diagnostics.add(Diagnostic(
                    if (module.documentation.role == "root") { "error" } else { "warning" },
                    "CJDOC1027",
                    "failed to scan source module '${module.documentation.name}': ${error.message}"))
            }
            if (scanLimitReached) { break }
        }
        if (scanLimitReached) {
            sourceSnapshot.diagnostics.add(Diagnostic("error", "CJDOC1028",
                "source scan exceeded 100000 files or 128 directory levels; remaining files skipped"))
        }
        sort(files, lessThan: { left, right => left.logicalPath < right.logicalPath }, stable: true)
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
            cacheFingerprint, cacheStats, astPreflightExecutable)
        return sourceSnapshot
    }
}
