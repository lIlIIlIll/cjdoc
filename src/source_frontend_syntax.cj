package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.sort.*
import stdx.syntax.*
internal class SyntaxPatternBindingCollector <: ASTVisitor {
    let names = ArrayList<String>()

    public override func preAction(node: SyntaxTreeNode): PreActionMode {
        if (node is VarPattern) {
            let value = (node as VarPattern).getOrThrow()
            if (!value.name.isEmpty()) { names.add(value.name) }
        }
        PreActionMode.Continue
    }
}

internal func syntaxPatternNames(pattern: Pattern): Array<String> {
    let collector = SyntaxPatternBindingCollector()
    collector.walk(pattern)
    collector.names.toArray()
}

internal func parseCapturedSource(source: String): ParsingResult<SourceFile> {
    let temporaryDirectory = Directory.createTemp(getTempDirectory())
    try {
        let temporarySource = temporaryDirectory.join("captured-source.cj")
        File.writeTo(temporarySource, source.toArray())
        try {
            return parseFile(temporarySource.toString())
        } catch (error: Exception) {
            let recovered = syntaxRecoverySource(source)
            if (recovered == source) { throw error }
            File.writeTo(temporarySource, recovered.toArray())
            return parseFile(temporarySource.toString())
        }
    } finally {
        try { let _ = removeIfExists(temporaryDirectory, recursive: true) } catch (_: Exception) {}
    }
}

internal class SyntaxDeclarationCollector {
    let path: String
    let packageName: String
    let moduleId: String
    let source: IndexedSourceBuffer
    let declarations = ArrayList<SourceDeclaration>()
    let reExports = ArrayList<SourceReExport>()
    let imports = ArrayList<String>()
    let comments = ArrayList<RawDocComment>()
    let macroInvocations = ArrayList<MacroInvocation>()
    let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    let diagnostics = ArrayList<Diagnostic>()
    let localScopes = ArrayList<SourceLocation>()
    private let commentKeys = HashSet<String>()

    init(path: String, packageName: String, moduleId: String, source: IndexedSourceBuffer) {
        this.path = path
        this.packageName = packageName
        this.moduleId = moduleId
        this.source = source
    }

    func nodeLocation(node: SyntaxTreeNode): SourceLocation {
        let position = node.nodePos
        var startLine = Int64(position.beginLine)
        var startColumn = Int64(position.beginColumn)
        let tokens = node.toTokens()
        for (token in tokens) {
            let kind = token.kind.toString()
            if (token.value.isEmpty() || kind == "COMMENT" || kind == "NL") { continue }
            if (token.pos.line > 0 && token.pos.column > 0) {
                startLine = Int64(token.pos.line)
                startColumn = Int64(token.pos.column)
                break
            }
        }
        let endLine = if (position.endLine > 0) { Int64(position.endLine) } else { startLine }
        let endColumn = if (position.endColumn > 0) { Int64(position.endColumn) } else { startColumn }
        SourceLocation(path, startLine, startColumn, endLine, endColumn)
    }

    func syntaxText(node: SyntaxTreeNode): String {
        node.toTokens().toString().trimAscii()
    }

    func declarationSignature(node: SyntaxTreeNode, location: SourceLocation,
        hasBody: Bool): String {
        let exact = source.slice(location)
        if (exact.isEmpty()) { return syntaxText(node) }
        if (!hasBody) { return exact.trimAscii() }
        let end = headerEndOffset(exact)
        let bytes = exact.toArray()
        let selected = ArrayList<UInt8>()
        var index: Int64 = 0
        while (index < end && index < bytes.size) {
            selected.add(bytes[index])
            index++
        }
        String.fromUtf8(selected.toArray()).trimAscii()
    }

    func visibility(decl: Decl): String {
        for (modifier in decl.modifiers) {
            let value = modifier.toTokens().toString().trimAscii()
            match (value) {
                case "public" => return "public"
                case "protected" => return "protected"
                case "private" => return "private"
                case "internal" => return "internal"
                case _ => ()
            }
        }
        "internal"
    }

    func addCommonData(symbol: SourceDeclaration, decl: Decl): Unit {
        for (annotation in decl.annotations) {
            symbol.annotations.add(annotation.toTokens().toString().trimAscii())
        }
        for (modifier in decl.modifiers) {
            let value = modifier.toTokens().toString().trimAscii()
            symbol.modifiers.add(value)
            if (value == "override") {
                symbol.symbolRelationships.add(SourceSymbolRelationship("override", symbol.name))
            }
        }
    }

    func addGenericParameters(symbol: SourceDeclaration,
        parameters: Array<GenericParam>): Unit {
        for (parameter in parameters) { symbol.genericParameters.add(parameter.name) }
    }

    func addTypeRelationships(symbol: SourceDeclaration,
        types: Array<TypeAnnotation>, kind: String): Unit {
        for (value in types) {
            let spelling = value.toTokens().toString().trimAscii()
            if (!spelling.isEmpty()) {
                symbol.relationships.add(SourceTypeRelationship(kind, spelling))
            }
        }
    }

    func addReturnType(symbol: SourceDeclaration, value: Option<TypeAnnotation>): Unit {
        if (let Some(annotation) <- value) {
            let spelling = annotation.toTokens().toString().trimAscii()
            if (!spelling.isEmpty()) { symbol.returnTypeSpelling = Some(spelling) }
        }
    }

    func addParameters(symbol: SourceDeclaration, parameters: ParameterList): Unit {
        for (parameter in parameters.params) {
            if (!(parameter is FuncParam)) { continue }
            let value = (parameter as FuncParam).getOrThrow()
            let typeSpelling = value.typeAnnotation.toTokens().toString().trimAscii()
            let defaultExpression: ?String = match (value.defaultValue) {
                case Some(expression) =>
                    let spelling = expression.toTokens().toString().trimAscii()
                    if (spelling.isEmpty()) { None } else { Some(spelling) }
                case None => None
            }
            symbol.parameters.add(SourceParameter(value.name, typeSpelling,
                defaultExpression: defaultExpression))
        }
    }
    func addMemberParameter(parameter: FuncParam): Unit {
        if (!parameter.kind.isSome() || parameter.name.isEmpty()) { return }
        let location = nodeLocation(parameter)
        let typeSpelling = parameter.typeAnnotation.toTokens().toString().trimAscii()
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, "variable", parameter.name),
            "variable", parameter.name, packageName, moduleId, parameterVisibility(parameter),
            location, syntaxText(parameter),
            sourceApiSignatureTokens: sourceApiSignatureTokens(syntaxText(parameter)))
        for (annotation in parameter.annotations) {
            symbol.annotations.add(annotation.toTokens().toString().trimAscii())
        }
        for (modifier in parameter.modifiers) {
            symbol.modifiers.add(modifier.toTokens().toString().trimAscii())
        }
        if (!typeSpelling.isEmpty()) { symbol.returnTypeSpelling = Some(typeSpelling) }
        declarations.add(symbol)
    }

    func parameterVisibility(parameter: FuncParam): String {
        for (modifier in parameter.modifiers) {
            let value = modifier.toTokens().toString().trimAscii()
            if (value == "public" || value == "protected" || value == "private" ||
                value == "internal") { return value }
        }
        "internal"
    }
    func add(decl: Decl, kind: String, name: String, isContainer!: Bool = false,
        hasBody!: Bool = false, enumNonExhaustive!: ?Bool = None): ?SourceDeclaration {
        if (name.isEmpty()) { return None }
        let location = nodeLocation(decl)
        if (location.startLine <= 0 || location.startColumn <= 0) { return None }
        let signature = declarationSignature(decl, location, hasBody)
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, kind, name), kind,
            name, packageName, moduleId, visibility(decl), location, signature,
            isContainer: isContainer, enumNonExhaustive: enumNonExhaustive,
            sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
        addCommonData(symbol, decl)
        declarations.add(symbol)
        return Some(symbol)
    }

    func enumCaseLocation(decl: EnumConstructor): SourceLocation {
        let tokens = decl.toTokens()
        if (tokens.size == 0) { return nodeLocation(decl) }
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
        SourceLocation(path, startLine, startColumn, endLine, endColumn)
    }

    func addEnumCase(owner: SourceDeclaration, decl: EnumConstructor): Unit {
        let name = decl.name
        if (name.isEmpty()) { return }
        let location = enumCaseLocation(decl)
        let signature = declarationSignature(decl, location, false)
        let symbol = SourceDeclaration(makeSourceDeclarationKey(location, "enumCase", name),
            "enumCase", name, packageName, moduleId, owner.visibility, location, signature,
            sourceApiSignatureTokens: sourceApiSignatureTokens(signature))
        var index: Int64 = 0
        for (annotation in decl.annotations) {
            symbol.annotations.add(annotation.toTokens().toString().trimAscii())
        }
        for (value in decl.paramTyAnnotations) {
            symbol.parameters.add(SourceParameter("_" + index.toString(),
                value.toTokens().toString().trimAscii()))
            index++
        }
        declarations.add(symbol)
    }

    func collectComments(node: SyntaxTreeNode): Unit {
        // Lexer comments are the source of truth; syntax comments are only
        // a parser cross-check and must not drop orphan or nested docs.
        let _ = node
    }

    func collectBody(body: Body, ownerName!: ?String = None): Unit {
        for (member in body.memberDecls) {
            collectDeclaration(member, ownerName: ownerName)
        }
    }

    func collectContainer(decl: Decl, kind: String, name: String,
        body: Body, genericParameters: Array<GenericParam>,
        superTypes: Array<TypeAnnotation>, enumNonExhaustive!: ?Bool = None): Unit {
        if (let Some(symbol) <- add(decl, kind, name, isContainer: true, hasBody: true,
            enumNonExhaustive: enumNonExhaustive)) {
            addGenericParameters(symbol, genericParameters)
            addTypeRelationships(symbol, superTypes, "superType")
        }
        collectBody(body, ownerName: Some(name))
    }

    func collectDeclaration(decl: Decl, ownerName!: ?String = None): Unit {
        collectComments(decl)
        if (decl is ClassDecl) {
            let value = (decl as ClassDecl).getOrThrow()
            collectContainer(value, "class", value.name, value.body, value.genericParams,
                value.superTyAnnotations)
            return
        }
        if (decl is StructDecl) {
            let value = (decl as StructDecl).getOrThrow()
            collectContainer(value, "struct", value.name, value.body, value.genericParams,
                value.superTyAnnotations)
            return
        }
        if (decl is InterfaceDecl) {
            let value = (decl as InterfaceDecl).getOrThrow()
            collectContainer(value, "interface", value.name, value.body, value.genericParams,
                value.superTyAnnotations)
            return
        }
        if (decl is EnumDecl) {
            let value = (decl as EnumDecl).getOrThrow()
            if (let Some(owner) <- add(value, "enum", value.name, isContainer: true,
                hasBody: true, enumNonExhaustive: Some(value.isNonExhaustive))) {
                addGenericParameters(owner, value.genericParams)
                addTypeRelationships(owner, value.superTyAnnotations, "superType")
                for (member in value.body.memberDecls) {
                    collectComments(member)
                    if (member is EnumConstructor) {
                        addEnumCase(owner, (member as EnumConstructor).getOrThrow())
                    } else {
                        collectDeclaration(member)
                    }
                }
            }
            return
        }
        if (decl is ExtendDecl) {
            let value = (decl as ExtendDecl).getOrThrow()
            let target = value.extendedTyAnnotation.toTokens().toString().trimAscii()
            if (let Some(owner) <- add(value, "extend", target, isContainer: true, hasBody: true)) {
                addGenericParameters(owner, value.genericParams)
                owner.relationships.add(SourceTypeRelationship("extensionTarget", target))
                addTypeRelationships(owner, value.superTyAnnotations, "superType")
            }
            collectBody(value.body)
            return
        }
        if (decl is TypeAlias) {
            let value = (decl as TypeAlias).getOrThrow()
            if (let Some(symbol) <- add(value, "typeAlias", value.aliasName)) {
                addGenericParameters(symbol, value.typeParameters)
            }
            return
        }
        if (decl is FuncDecl) {
            let value = (decl as FuncDecl).getOrThrow()
            let isPrimaryConstructor = match (ownerName) {
                case Some(owner) => owner == value.name
                case None => false
            }
            let kind = if (value.name == "init" || isPrimaryConstructor) {
                "constructor"
            } else {
                "function"
            }
            if (let Some(symbol) <- add(value, kind, value.name, hasBody: true)) {
                addGenericParameters(symbol, value.genericParams)
                addParameters(symbol, value.params)
                for (parameter in value.params.params) {
                    if (parameter is FuncParam) {
                        addMemberParameter((parameter as FuncParam).getOrThrow())
                    }
                }
                addReturnType(symbol, value.retTyAnnotation)
            }
            return
        }
        if (decl is PropDecl) {
            let value = (decl as PropDecl).getOrThrow()
            if (let Some(symbol) <- add(value, "property", value.name, hasBody: true)) {
                addReturnType(symbol, Some(value.tyAnnotation))
            }
            return
        }
        if (decl is VarDecl) {
            let value = (decl as VarDecl).getOrThrow()
            let names = ArrayList<String>()
            for (name in syntaxPatternNames(value.pattern)) { names.add(name) }
            if (names.isEmpty() && !value.name.isEmpty()) { names.add(value.name) }
            let typeSpelling = if (names.size == 1) {
                match (value.tyAnnotation) {
                    case Some(annotation) => annotation.toTokens().toString().trimAscii()
                    case None => ""
                }
            } else {
                ""
            }
            for (name in names) {
                if (let Some(symbol) <- add(value, "variable", name)) {
                    if (!typeSpelling.isEmpty()) { symbol.returnTypeSpelling = Some(typeSpelling) }
                }
            }
            return
        }
        if (decl is EnumConstructor) {
            recordUnsupported("enumCase", (decl as EnumConstructor).getOrThrow().name,
                "enum constructor has no enum owner", decl)
            return
        }
        if (decl is MacroDecl) {
            let value = (decl as MacroDecl).getOrThrow()
            recordUnsupported("macro", value.name, "macro expansion is not executed", value)
            return
        }
        if (decl is MacroExpandDecl) {
            let value = (decl as MacroExpandDecl).getOrThrow()
            let name = value.calleeMacro.toTokens().toString().trimAscii()
            recordUnsupported("macroInvocation", name, "macro expansion is not executed", value)
            macroInvocations.add(MacroInvocation(name, nodeLocation(value)))
            return
        }
        if (decl is MainDecl) {
            localScopes.add(nodeLocation((decl as MainDecl).getOrThrow()))
            return
        }
        if (decl is StaticInit) {
            localScopes.add(nodeLocation((decl as StaticInit).getOrThrow()))
            return
        }
        if (decl is GenericParam || decl is PropGetterOrSetter) {
            recordUnsupported("declaration", syntaxText(decl), "syntax declaration is not documentable", decl)
            return
        }
        recordUnsupported("declaration", syntaxText(decl), "syntax declaration is not documentable", decl)
    }

    func recordUnsupported(kind: String, name: String, reason: String, node: SyntaxTreeNode): Unit {
        let location = nodeLocation(node)
        diagnostics.add(Diagnostic("warning", "CJDOC1009",
            "unsupported declaration '" + name + "'", source: location))
        unsupportedDeclarations.add(UnsupportedDeclaration(kind, name, reason, location))
    }

    func collectReExportContent(content: ImportContent, items: ArrayList<SourceImportItem>): Unit {
        if (content is ImportSingle) {
            let value = (content as ImportSingle).getOrThrow()
            if (!value.identifier.isEmpty()) { items.add(SourceImportItem(value.identifier)) }
            return
        }
        if (content is ImportAlias) {
            let value = (content as ImportAlias).getOrThrow()
            if (!value.identifier.isEmpty()) {
                items.add(SourceImportItem(value.identifier, alias: Some(value.aliasName)))
            }
            return
        }
        if (content is ImportMulti) {
            let value = (content as ImportMulti).getOrThrow()
            for (item in value.contents) { collectReExportContent(item, items) }
        }
    }
    func collectImports(file: SourceFile): Unit {
        for (importList in file.importLists) {
            let text = source.slice(nodeLocation(importList)).trimAscii()
            if (!text.isEmpty()) { imports.add(text) }
        }
    }

    func collectReExports(file: SourceFile): Unit {
        for (importList in file.importLists) {
            let fullSpec = source.slice(nodeLocation(importList)).trimAscii()
            let isPublic = fullSpec.startsWith("public ")
            if (!isPublic) { continue }
            let content = importList.contents
            let kind = if (content is ImportSingle) {
                "single"
            } else if (content is ImportAlias) {
                "alias"
            } else if (content is ImportAll) {
                "all"
            } else {
                "multi"
            }
            let prefixes = content.prefixes
            let normalizedSpec = if (fullSpec.startsWith("public ")) {
                fullSpec.removePrefix("public ").trimAscii()
            } else {
                fullSpec
            }
            let hasOrganization = normalizedSpec.contains("::")
            var organization: ?String = None
            let prefixPaths = ArrayList<String>()
            var prefixIndex: Int64 = 0
            if (hasOrganization && prefixes.size > 0) {
                organization = Some(prefixes[0])
                prefixIndex = 1
            }
            while (prefixIndex < prefixes.size) {
                prefixPaths.add(prefixes[prefixIndex])
                prefixIndex++
            }
            var identifier = ""
            var alias: ?String = None
            let items = ArrayList<SourceImportItem>()
            if (content is ImportSingle) {
                identifier = (content as ImportSingle).getOrThrow().identifier
            } else if (content is ImportAlias) {
                let value = (content as ImportAlias).getOrThrow()
                identifier = value.identifier
                alias = Some(value.aliasName)
            } else if (content is ImportMulti) {
                collectReExportContent(content, items)
            }
            reExports.add(SourceReExport(kind, organization, identifier, alias,
                nodeLocation(importList), normalizedSpec, packageName, moduleId,
                prefixPaths: prefixPaths.toArray(), items: items.toArray()))
        }
    }

    func collect(file: SourceFile): Unit {
        collectComments(file)
        collectImports(file)
        collectReExports(file)
        for (decl in file.topLevelDecls) { collectDeclaration(decl) }
    }

}

internal func parseSourceTextWithSyntax(input: SourceInputFile, fallbackPackageName: String,
    source: String): ParsedSourceFile {
    let result = ParsedSourceFile(input)
    let relative = input.logicalPath
    let sourceBuffer = IndexedSourceBuffer(source)
    if (hasDeepSourceBinaryExpression(source)) {
        result.diagnostics.add(Diagnostic("error", "CJDOC1012",
            "source expression exceeds the bounded syntax depth",
            source: SourceLocation(relative, 1, 1, 1, 1)))
        return result
    }
    try {
        let parsed = parseCapturedSource(source)
        for (_ in parsed.diags) {
            result.diagnostics.add(Diagnostic("error", "CJDOC1011",
                "stdx.syntax reported a source diagnostic",
                source: SourceLocation(relative, 1, 1, 1, 1)))
        }
        match (parsed.node) {
            case None =>
                result.diagnostics.add(Diagnostic("error", "CJDOC1011",
                    "failed to parse '" + relative + "'",
                    source: SourceLocation(relative, 1, 1, 1, 1)))
                return result
            case Some(file) =>
                let packageName = match (file.pkgHeader) {
                    case Some(header) =>
                        let headerText = header.toTokens().toString().trimAscii()
                        if (headerText.startsWith("package ")) {
                            headerText.removePrefix("package ").trimAscii()
                        } else if (!headerText.isEmpty()) {
                            headerText
                        } else {
                            header.getPackageName()
                        }
                    case None => fallbackPackageName
                }
                let collector = SyntaxDeclarationCollector(relative, packageName,
                    input.module.id, sourceBuffer)
                collector.collect(file)
                sort(collector.declarations, lessThan: sourceOrderLess, stable: true)
                removeLocalDeclarations(collector.declarations, collector.localScopes)
                assignOwners(collector.declarations)
                result.orphanDocComments.add(all: bindComments(collector.declarations,
                    collectDocComments(relative, sourceLexerTokens(source), sourceBuffer), sourceBuffer))
                for (comment in result.orphanDocComments) {
                    result.diagnostics.add(Diagnostic("warning", "CJDOC1014",
                        "doc comment is not attached to a documentable declaration",
                        source: comment.source))
                }
                result.packageName = Some(packageName)
                result.reExports.add(all: collector.reExports)
                result.imports.add(all: collector.imports)
                result.declarations.add(all: collector.declarations)
                result.macroInvocations.add(all: collector.macroInvocations)
                result.unsupportedDeclarations.add(all: collector.unsupportedDeclarations)
                result.diagnostics.add(all: collector.diagnostics)
        }
    } catch (_: Exception) {
        result.diagnostics.add(Diagnostic("warning", "CJDOC1009",
            "syntax parser could not expose all declarations; file retained as partial",
            source: SourceLocation(relative, 1, 1, 1, 1)))
    }
    result
}
