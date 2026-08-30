package cjdoc

import cjdoc.model as public_model
import cjdoc.provider as public_provider
import markdown.{MarkdownEngine, MarkdownProfile, NodeKind, NodeRef, SourceBuffer}
import std.collection.*
import std.fs.*

public class GenerationRequest {
    public let projectRoot: String
    public let includePathDependencies: Bool
    public let includeCachedDependencies: Bool
    public let jobs: Int64
    public let audience: String
    public let lintProfile: String
    public let cacheDirectory: ?String
    public let cacheFingerprint: ?String
    public let astPreflightExecutable: ?String
    public let cjpmCacheRoot: ?String
    private let dependencySourcesStorage: ArrayList<DependencySourceInput>
    private let cfgValuesStorage: ArrayList<CfgValue>
    private let providerFactoriesStorage: ArrayList<public_provider.SemanticProviderFactory>

    public init(projectRoot: String, includePathDependencies!: Bool = false,
        includeCachedDependencies!: Bool = false, jobs!: Int64 = 1,
        audience!: String = "external", lintProfile!: String = "standard",
        dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
        providerFactories!: Array<public_provider.SemanticProviderFactory> = [],
        cacheDirectory!: ?String = None, cacheFingerprint!: ?String = None,
        astPreflightExecutable!: ?String = None, cjpmCacheRoot!: ?String = None) {
        if (projectRoot.isEmpty()) { throw IllegalArgumentException("project root cannot be empty") }
        if (jobs < 1 || jobs > 64) { throw IllegalArgumentException("jobs must be in 1..64") }
        if (audience != "external" && audience != "package" && audience != "all") {
            throw IllegalArgumentException("audience must be external, package, or all")
        }
        if (lintProfile != "off" && lintProfile != "standard" && lintProfile != "strict") {
            throw IllegalArgumentException("lint profile must be off, standard, or strict")
        }
        if (providerFactories.size > 1) {
            throw IllegalArgumentException("cjdoc accepts at most one semantic provider factory")
        }
        for (factory in providerFactories) {
            if (factory.name.isEmpty() || factory.version.isEmpty()) {
                throw IllegalArgumentException("semantic provider name and version cannot be empty")
            }
        }
        this.projectRoot = projectRoot
        this.includePathDependencies = includePathDependencies
        this.includeCachedDependencies = includeCachedDependencies
        this.jobs = jobs
        this.audience = audience
        this.lintProfile = lintProfile
        this.cacheDirectory = cacheDirectory
        this.cacheFingerprint = cacheFingerprint
        this.astPreflightExecutable = astPreflightExecutable
        this.cjpmCacheRoot = cjpmCacheRoot
        this.dependencySourcesStorage = ArrayList<DependencySourceInput>(dependencySources)
        this.cfgValuesStorage = ArrayList<CfgValue>(cfgValues)
        this.providerFactoriesStorage = ArrayList<public_provider.SemanticProviderFactory>(providerFactories)
    }

    public prop dependencySources: ReadOnlyList<DependencySourceInput> { get() { dependencySourcesStorage } }
    public prop cfgValues: ReadOnlyList<CfgValue> { get() { cfgValuesStorage } }
    public prop providerFactories: ReadOnlyList<public_provider.SemanticProviderFactory> {
        get() { providerFactoriesStorage }
    }
}

private func publicByteOffset(source: String, line: Int64, column: Int64): Int64 {
    if (line < 1 || column < 1) { return 0 }
    let bytes = source.toArray()
    var offset: Int64 = 0
    var currentLine: Int64 = 1
    while (offset < bytes.size && currentLine < line) {
        if (bytes[offset] == 10u8) { currentLine++ }
        offset++
    }
    if (currentLine != line) { return 0 }
    let result = offset + column - 1
    if (result < 0 || result > bytes.size) { 0 } else { result }
}

private class PublicSourceMapper {
    private let projectRoot: String
    private let sources = HashMap<String, String>()
    private let unavailable = HashSet<String>()

    init(projectRoot: String) { this.projectRoot = projectRoot }

    private func source(path: String): ?String {
        if (let Some(value) <- sources.get(path)) { return Some(value) }
        if (unavailable.contains(path)) { return None }
        try {
            let value = String.fromUtf8(File.readFrom(Path(projectRoot).join(path)))
            sources[path] = value
            Some(value)
        } catch (_: Exception) {
            unavailable.add(path)
            None
        }
    }

    func range(location: SourceLocation): public_model.SourceRange {
        var startOffset: Int64 = 0
        var endOffset: Int64 = 0
        if (let Some(value) <- source(location.path)) {
            startOffset = publicByteOffset(value, location.startLine, location.startColumn)
            endOffset = publicByteOffset(value, location.endLine, location.endColumn)
        }
        public_model.SourceRange(location.path,
            public_model.SourcePosition(location.startLine, location.startColumn, startOffset),
            public_model.SourcePosition(location.endLine, location.endColumn, endOffset))
    }
}

private func providerType(value: public_model.TypeRef): TypeRef {
    let arguments = ArrayList<TypeRef>()
    for (argument in value.arguments) { arguments.add(providerType(argument)) }
    TypeRef(value.spelling, canonical: value.semantic.canonical, state: value.semantic.state,
        kind: value.kind, nullable: value.nullable, arguments: arguments.toArray())
}

private func moduleOwnsDeclaration(module: SourceModule, declaration: SourceDeclaration): Bool {
    module.id == declaration.moduleId
}

private func validProviderDiagnosticCode(code: String): Bool {
    if (code.size != 9 || !code.startsWith("CJDOC2")) { return false }
    let bytes = code.toArray()
    var index: Int64 = 6
    while (index < bytes.size) {
        if (bytes[index] < b'0' || bytes[index] > b'9') { return false }
        index++
    }
    true
}

private func issuedSourceKey(issuer: public_provider.SourceDeclarationIssuer,
    issued: HashMap<String, public_provider.SourceDeclarationId>,
    candidate: public_provider.SourceDeclarationId): ?String {
    if (!issuer.owns(candidate)) { return None }
    let key = candidate.serialize()
    match (issued.get(key)) {
        case Some(_) => Some(key)
        case None => None
    }
}

private func validProviderVisibility(value: String): Bool {
    value == "public" || value == "protected" || value == "internal" || value == "private"
}

private func validateProviderType(value: public_model.TypeRef,
    capabilities: public_model.SemanticCapabilities): Unit {
    if (!capabilities.canonicalTypes &&
        (value.semantic.canonical.isSome() || value.semantic.state == "resolved")) {
        throw IllegalArgumentException(
            "semantic provider returned canonical type data without canonicalTypes capability")
    }
    for (argument in value.arguments) { validateProviderType(argument, capabilities) }
}

private func fallbackModuleResult(module: SourceModule,
    factory: public_provider.SemanticProviderFactory, message: String): ModuleSemanticResult {
    let result = ModuleSemanticResult(module.id, factory.name, factory.version,
        SemanticCapabilities(false, false, false, false, false))
    result.diagnostics.add(Diagnostic("warning", "CJDOC2001",
        "semantic provider '${factory.name}' failed for module '${module.name}': ${message}; AST fallback retained"))
    return result
}

private class FactorySemanticProviderAdapter <: SemanticProvider {
    private let factory: public_provider.SemanticProviderFactory
    private let sourceMapper: PublicSourceMapper

    init(factory: public_provider.SemanticProviderFactory, projectRoot: String) {
        this.factory = factory
        this.sourceMapper = PublicSourceMapper(projectRoot)
    }

    public func providerName(): String { factory.name }
    public func providerVersion(): String { factory.version }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult()
        for (module in source.modules) {
            try {
                let moduleDeclarations = ArrayList<SourceDeclaration>()
                let declarationsByKey = HashMap<String, SourceDeclaration>()
                let issued = HashMap<String, public_provider.SourceDeclarationId>()
                let issuer = public_provider.SourceDeclarationIssuer()
                for (declaration in source.declarations) {
                    if (!moduleOwnsDeclaration(module, declaration)) { continue }
                    if (issued.contains(declaration.sourceKey)) {
                        throw IllegalArgumentException("duplicate source declaration id in module")
                    }
                    moduleDeclarations.add(declaration)
                    declarationsByKey[declaration.sourceKey] = declaration
                    issued[declaration.sourceKey] = issuer.issue(declaration.sourceKey)
                }
                let views = ArrayList<public_provider.SourceDeclarationView>()
                for (declaration in moduleDeclarations) {
                    let parameters = ArrayList<public_provider.SourceParameterView>()
                    for (parameter in declaration.parameters) {
                        parameters.add(public_provider.SourceParameterView(parameter.name,
                            parameter.typeSpelling))
                    }
                    let id = issued[declaration.sourceKey]
                    let owner: ?public_provider.SourceDeclarationId = match (declaration.ownerSourceKey) {
                        case Some(value) => match (issued.get(value)) {
                            case Some(ownerId) => Some(ownerId)
                            case None => throw IllegalArgumentException(
                                "source owner is outside the provider module transaction")
                        }
                        case None => None
                    }
                    views.add(public_provider.SourceDeclarationView(id, declaration.kind,
                        declaration.name, declaration.packageName, declaration.visibility,
                        declaration.genericParameters.size, sourceMapper.range(declaration.source),
                        declaration.sourceSignature, ownerId: owner, parameters: parameters.toArray(),
                        returnTypeSpelling: declaration.returnTypeSpelling,
                        annotations: declaration.annotations.toArray()))
                }

                let semanticModule = public_provider.SemanticModule(module.id, module.name,
                    module.role, module.sourcePrefix)
                let session = factory.open(semanticModule)
                var stagedResult: ?ModuleSemanticResult = None
                var failureMessage: ?String = None
                try {
                    let batch = session.analyze(views)
                    if (!batch.capabilities.sourceBinding && !batch.declarations.isEmpty()) {
                        throw IllegalArgumentException(
                            "semantic provider returned declarations without sourceBinding capability")
                    }
                    let staged = ModuleSemanticResult(module.id, factory.name, factory.version,
                        SemanticCapabilities(batch.capabilities.sourceBinding,
                            batch.capabilities.ownership, batch.capabilities.visibility,
                            batch.capabilities.canonicalTypes,
                            batch.capabilities.canonicalSignatures,
                            symbolRelationships: batch.capabilities.relationships,
                            annotations: batch.capabilities.annotations))
                    let returned = HashSet<String>()
                    for (item in batch.declarations) {
                        let sourceKey = match (issuedSourceKey(issuer, issued, item.sourceId)) {
                            case Some(value) => value
                            case None => throw IllegalArgumentException(
                                "semantic provider returned an unknown or cross-session source declaration id")
                        }
                        if (!returned.add(sourceKey)) {
                            throw IllegalArgumentException(
                                "semantic provider returned a duplicate source declaration id")
                        }
                        let original = declarationsByKey[sourceKey]
                        let owner = match (item.ownerId) {
                            case Some(candidate) =>
                                if (!batch.capabilities.ownership) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned ownership without ownership capability")
                                }
                                let key = match (issuedSourceKey(issuer, issued, candidate)) {
                                    case Some(value) => value
                                    case None => throw IllegalArgumentException(
                                        "semantic provider returned an unknown or cross-session owner id")
                                }
                                if (original.ownerSourceKey != Some(key)) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed source declaration ownership")
                                }
                                Some(key)
                            case None => original.ownerSourceKey
                        }
                        let visibility = match (item.visibility) {
                            case Some(value) =>
                                if (!batch.capabilities.visibility) {
                                    throw IllegalArgumentException(
                                        "semantic provider returned visibility without visibility capability")
                                }
                                if (!validProviderVisibility(value)) {
                                    throw IllegalArgumentException("semantic provider returned invalid visibility")
                                }
                                value
                            case None => original.visibility
                        }
                        if (item.canonicalSignature.isSome() &&
                            !batch.capabilities.canonicalSignatures) {
                            throw IllegalArgumentException(
                                "semantic provider returned canonical signature without capability")
                        }
                        if (item.annotationsProvided && !batch.capabilities.annotations) {
                            throw IllegalArgumentException(
                                "semantic provider returned annotations without annotations capability")
                        }
                        if ((!item.typeRelationships.isEmpty() || !item.symbolRelationships.isEmpty()) &&
                            !batch.capabilities.relationships) {
                            throw IllegalArgumentException(
                                "semantic provider returned relationships without relationships capability")
                        }
                        let semantic = SemanticDeclaration(sourceKey, original.kind, original.name,
                            original.packageName, original.moduleId, owner, visibility, item.state,
                            factory.name, canonicalSignature: item.canonicalSignature,
                            isContainer: original.isContainer)
                        semantic.genericParameters.add(all: original.genericParameters)
                        if (item.parameters.isEmpty()) {
                            for (parameter in original.parameters) {
                                semantic.parameters.add(SemanticParameter(parameter.name,
                                    TypeRef(parameter.typeSpelling, state: "partial")))
                            }
                        } else {
                            if (item.parameters.size != original.parameters.size) {
                                throw IllegalArgumentException(
                                    "semantic provider changed declaration parameter count")
                            }
                            var parameterIndex: Int64 = 0
                            while (parameterIndex < item.parameters.size) {
                                if (item.parameters[parameterIndex].name !=
                                    original.parameters[parameterIndex].name) {
                                    throw IllegalArgumentException(
                                        "semantic provider changed declaration parameter name")
                                }
                                validateProviderType(item.parameters[parameterIndex].typeRef,
                                    batch.capabilities)
                                semantic.parameters.add(SemanticParameter(
                                    item.parameters[parameterIndex].name,
                                    providerType(item.parameters[parameterIndex].typeRef)))
                                parameterIndex++
                            }
                        }
                        semantic.returnType = match (item.returnType) {
                            case Some(value) =>
                                validateProviderType(value, batch.capabilities)
                                Some(providerType(value))
                            case None => match (original.returnTypeSpelling) {
                                case Some(value) => Some(TypeRef(value, state: "partial"))
                                case None => None
                            }
                        }
                        semantic.annotations.add(all: original.annotations)
                        if (item.annotationsProvided) {
                            semantic.providerAnnotations.add(all: item.annotations)
                        }
                        for (relationship in item.typeRelationships) {
                            validateProviderType(relationship.target, batch.capabilities)
                            semantic.relationships.add(TypeRelationship(relationship.kind,
                                providerType(relationship.target)))
                        }
                        for (relationship in item.symbolRelationships) {
                            let targetSourceKey: ?String = match (relationship.targetSourceId) {
                                case Some(target) => match (issuedSourceKey(issuer, issued, target)) {
                                    case Some(value) => Some(value)
                                    case None => throw IllegalArgumentException(
                                        "semantic provider returned an unknown or cross-session relationship target id")
                                }
                                case None => None
                            }
                            semantic.symbolRelationships.add(SymbolRelationship(relationship.kind,
                                relationship.targetDisplay, relationship.state,
                                targetSymbolId: relationship.targetSymbolId,
                                targetSourceKey: targetSourceKey))
                        }
                        staged.declarations.add(semantic)
                    }
                    for (diagnostic in batch.diagnostics) {
                        if ((diagnostic.severity != "warning" && diagnostic.severity != "error") ||
                            !validProviderDiagnosticCode(diagnostic.code)) {
                            throw IllegalArgumentException(
                                "semantic provider emitted an invalid diagnostic contract")
                        }
                        staged.diagnostics.add(Diagnostic(diagnostic.severity, diagnostic.code,
                            diagnostic.message,
                            source: match (diagnostic.source) {
                                case Some(range) => Some(SourceLocation(range.path, range.start.line,
                                    range.start.column, range.end.line, range.end.column))
                                case None => None
                            }, symbolId: diagnostic.symbolId))
                    }
                    stagedResult = Some(staged)
                } catch (error: Exception) {
                    failureMessage = Some(error.message)
                }
                try {
                    session.close()
                } catch (error: Exception) {
                    failureMessage = Some(match (failureMessage) {
                        case Some(previous) => "${previous}; close failed: ${error.message}"
                        case None => "close failed: ${error.message}"
                    })
                }
                match (failureMessage) {
                    case Some(message) => throw IllegalArgumentException(message)
                    case None => result.modules.add(stagedResult.getOrThrow())
                }
            } catch (error: Exception) {
                result.modules.add(fallbackModuleResult(module, factory, error.message))
            }
        }
        return result
    }
}

private func publicType(value: TypeRef, provider: String): public_model.TypeRef {
    let semanticProvider: ?String = if (value.state == "unavailable") { None } else { Some(provider) }
    let arguments = ArrayList<public_model.TypeRef>()
    for (argument in value.arguments) { arguments.add(publicType(argument, provider)) }
    public_model.TypeRef(value.kind, value.display,
        public_model.SemanticType(value.state, canonical: value.canonical, provider: semanticProvider),
        nullable: value.nullable, arguments: arguments.toArray())
}

private func publicTag(value: DocTag): public_model.DocTag {
    let state = match (value.referenceState) {
        case "resolved" => "resolved"
        case "ambiguous" => "ambiguous"
        case "unresolved" => "unavailable"
        case "broken" => "unavailable"
        case _ => "unavailable"
    }
    public_model.DocTag(value.name, value.subject, value.description,
        referenceState: state, targetSymbolId: value.targetSymbolId)
}

private func publicMarkdownKind(kind: NodeKind): String {
    match (kind) {
        case NodeKind.DocumentNode => "document"
        case NodeKind.BlockQuote => "block_quote"
        case NodeKind.List => "list"
        case NodeKind.ListItem => "list_item"
        case NodeKind.Paragraph => "paragraph"
        case NodeKind.Heading => "heading"
        case NodeKind.ThematicBreak => "thematic_break"
        case NodeKind.CodeBlock => "code_block"
        case NodeKind.HtmlBlock => "html_block"
        case NodeKind.Table => "table"
        case NodeKind.TableRow => "table_row"
        case NodeKind.TableCell => "table_cell"
        case NodeKind.CustomBlock => "custom_block"
        case NodeKind.Text => "text"
        case NodeKind.SoftBreak => "soft_break"
        case NodeKind.HardBreak => "hard_break"
        case NodeKind.CodeSpan => "code_span"
        case NodeKind.Emphasis => "emphasis"
        case NodeKind.Strong => "strong"
        case NodeKind.Strikethrough => "strikethrough"
        case NodeKind.Link => "link"
        case NodeKind.Image => "image"
        case NodeKind.HtmlInline => "html_inline"
        case NodeKind.CustomInline => "custom_inline"
    }
}

private func publicMarkdownNode(node: NodeRef, source: SourceBuffer,
    assetCollector: LocalAssetCollector, sourcePath: String,
    declarationSource: public_model.SourceRange, symbolId: String): public_model.MarkdownNode {
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = node.children()
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(publicMarkdownNode(sourceChildren[index], source, assetCollector,
            sourcePath, declarationSource, symbolId))
        index++
    }
    let literal = match (node.kind) {
        case NodeKind.Text => node.asText().getOrThrow().value
        case NodeKind.CodeBlock => node.asCodeBlock().getOrThrow().literal
        case NodeKind.CodeSpan => node.asCodeSpan().getOrThrow().literal
        case NodeKind.HtmlBlock => node.asHtmlBlock().getOrThrow().literal
        case NodeKind.HtmlInline => node.asHtmlInline().getOrThrow().literal
        case NodeKind.Link => node.asLink().getOrThrow().destination
        case NodeKind.Image =>
            let destination = node.asImage().getOrThrow().destination
            match (assetCollector.reference(sourcePath, destination,
                declarationSource, symbolId)) {
                case Some(assetId) => assetId
                case None => destination
            }
        case _ => if (sourceChildren.isEmpty()) { source.text(node) } else { "" }
    }
    public_model.MarkdownNode(publicMarkdownKind(node.kind), literal: literal, children: children.toArray())
}

private func publicMarkdown(body: String, assetCollector: LocalAssetCollector,
    sourcePath: String, declarationSource: public_model.SourceRange,
    symbolId: String): public_model.MarkdownNode {
    if (body.isEmpty()) { return public_model.MarkdownNode("document") }
    try {
        let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
        publicMarkdownNode(result.document.root(), result.source, assetCollector,
            sourcePath, declarationSource, symbolId)
    } catch (_: Exception) {
        // Documentation generation must survive unsupported or resource-limited Markdown.
        public_model.MarkdownNode("document", children: [public_model.MarkdownNode("text", literal: body)])
    }
}

private func publicComment(value: DocComment, assetCollector: LocalAssetCollector,
    sourcePath: String, declarationSource: public_model.SourceRange,
    symbolId: String): public_model.DocComment {
    let tags = ArrayList<public_model.DocTag>()
    for (tag in value.params) { tags.add(publicTag(tag)) }
    match (value.returns) { case Some(tag) => tags.add(publicTag(tag)) case None => () }
    for (tag in value.throwsTags) { tags.add(publicTag(tag)) }
    for (tag in value.see) { tags.add(publicTag(tag)) }
    match (value.since) {
        case Some(text) => tags.add(public_model.DocTag("since", "", text))
        case None => ()
    }
    match (value.deprecated) {
        case Some(text) => tags.add(public_model.DocTag("deprecated", "", text))
        case None => ()
    }
    for (text in value.authors) { tags.add(public_model.DocTag("author", "", text)) }
    match (value.version) {
        case Some(text) => tags.add(public_model.DocTag("version", "", text))
        case None => ()
    }
    let body = if (value.descriptionMarkdown.isEmpty()) {
        value.summaryMarkdown
    } else {
        "${value.summaryMarkdown}\n\n${value.descriptionMarkdown}"
    }
    public_model.DocComment(value.raw, value.summaryMarkdown, value.descriptionMarkdown,
        publicMarkdown(body, assetCollector, sourcePath, declarationSource, symbolId),
        tags: tags.toArray())
}

private func remapDiagnosticCode(code: String): String {
    match (code) {
        case "CJDOC1001" => "CJDOC3001"
        case "CJDOC1002" => "CJDOC3002"
        case "CJDOC1003" => "CJDOC3003"
        case "CJDOC1004" => "CJDOC3004"
        case "CJDOC1005" => "CJDOC3005"
        case "CJDOC1006" => "CJDOC2006"
        case "CJDOC1007" => "CJDOC2007"
        case "CJDOC1008" => "CJDOC3008"
        case "CJDOC1022" => "CJDOC3022"
        case "CJDOC1023" => "CJDOC3023"
        case "CJDOC1024" => "CJDOC4024"
        case "CJDOC1025" => "CJDOC3025"
        case _ => code
    }
}

private func publicDocumentation(documentation: DocumentationSet,
    request: GenerationRequest): public_model.DocumentationSet {
    let sourceMapper = PublicSourceMapper(request.projectRoot)
    let modules = ArrayList<public_model.ModuleDoc>()
    for (module in documentation.modules) {
        modules.add(public_model.ModuleDoc(module.id, module.name, module.role, module.sourcePrefix,
            packageNames: module.packageNames.toArray(), dependencyIds: module.dependencyIds.toArray()))
    }
    let packages = ArrayList<public_model.PackageDoc>()
    let files = ArrayList<public_model.FileDoc>()
    for (pkg in documentation.packages) {
        packages.add(public_model.PackageDoc(pkg.name, pkg.moduleId,
            sourceFiles: pkg.sourceFiles.toArray(), symbolIds: pkg.symbolIds.toArray()))
        for (path in pkg.sourceFiles) { files.add(public_model.FileDoc(path, pkg.moduleId, pkg.name)) }
    }
    let declarations = ArrayList<public_model.SymbolDoc>()
    let assetCollector = LocalAssetCollector(documentation.sourceFileOrigins)
    for (symbol in documentation.symbols) {
        let declarationSource = sourceMapper.range(symbol.source)
        let parameters = ArrayList<public_model.ParameterDoc>()
        let annotations = ArrayList<public_model.AnnotationDoc>()
        let typeRelationships = ArrayList<public_model.TypeRelationship>()
        let symbolRelationships = ArrayList<public_model.SymbolRelationship>()
        for (parameter in symbol.parameters) {
            parameters.add(public_model.ParameterDoc(parameter.name,
                publicType(parameter.typeRef, symbol.semanticProvider),
                documentation: parameter.documentation))
        }
        for (relationship in symbol.relationships) {
            typeRelationships.add(public_model.TypeRelationship(relationship.kind,
                publicType(relationship.target, symbol.semanticProvider)))
        }
        for (relationship in symbol.symbolRelationships) {
            symbolRelationships.add(public_model.SymbolRelationship(relationship.kind,
                relationship.targetDisplay, relationship.state,
                targetSymbolId: relationship.targetSymbolId))
        }
        for (annotation in symbol.annotations) {
            annotations.add(public_model.AnnotationDoc(annotation.spelling,
                provenance: annotation.provenance, provider: annotation.provider))
        }
        declarations.add(public_model.SymbolDoc(symbol.id, symbol.kind, symbol.name,
            symbol.qualifiedName, symbol.packageName, symbol.moduleId, symbol.visibility,
            declarationSource,
            symbol.sourceSignature,
            public_model.SemanticInfo(symbol.semanticState, symbol.semanticProvider,
                canonicalSignature: symbol.canonicalSignature),
            ownerId: symbol.ownerId, genericParameters: symbol.genericParameters.toArray(),
            parameters: parameters.toArray(),
            returnType: match (symbol.returnType) {
                case Some(value) => Some(publicType(value, symbol.semanticProvider))
                case None => None
            }, annotations: annotations.toArray(),
            typeRelationships: typeRelationships.toArray(),
            symbolRelationships: symbolRelationships.toArray(),
            documentation: match (symbol.documentation) {
                case Some(value) => Some(publicComment(value, assetCollector,
                    symbol.source.path, declarationSource, symbol.id))
                case None => None
            }, origin: public_model.DeclarationOrigin(kind: symbol.origin.kind,
                macroSymbolId: symbol.origin.macroSymbolId)))
    }
    let unsupported = ArrayList<public_model.UnsupportedDeclaration>()
    let orphanDocComments = ArrayList<public_model.OrphanDocComment>()
    for (comment in documentation.orphanDocComments) {
        orphanDocComments.add(public_model.OrphanDocComment(comment.rawText,
            sourceMapper.range(comment.source)))
    }
    let macroInvocations = ArrayList<public_model.MacroInvocation>()
    for (invocation in documentation.macroInvocations) {
        macroInvocations.add(public_model.MacroInvocation(invocation.name,
            sourceMapper.range(invocation.source)))
    }
    for (item in documentation.unsupportedDeclarations) {
        unsupported.add(public_model.UnsupportedDeclaration(item.kind, item.name, item.reason,
            sourceMapper.range(item.source)))
    }
    let diagnostics = ArrayList<public_model.Diagnostic>()
    var hasError = false
    var hasIncompleteSource = !documentation.orphanDocComments.isEmpty() ||
        !documentation.macroInvocations.isEmpty() || !documentation.unsupportedDeclarations.isEmpty()
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.severity == "error") { hasError = true }
        if (diagnostic.code.startsWith("CJDOC1")) { hasIncompleteSource = true }
        diagnostics.add(public_model.Diagnostic(diagnostic.severity,
            remapDiagnosticCode(diagnostic.code), diagnostic.message,
            source: match (diagnostic.source) {
                case Some(value) => Some(sourceMapper.range(value))
                case None => None
            }, symbolId: diagnostic.symbolId))
    }
    if (assetCollector.incomplete) { hasIncompleteSource = true }
    diagnostics.add(all: assetCollector.diagnostics())
    let providers = ArrayList<public_model.ProviderInfo>()
    var hasIncompleteSemantic = false
    for (binding in documentation.semanticBindings) {
        let capabilities = binding.capabilities
        let providerState = if (!capabilities.sourceBinding) {
            "unavailable"
        } else if (binding.missing == 0 && binding.ambiguous == 0 &&
            binding.contractViolations == 0) {
            if (capabilities.canonicalTypes) { "resolved" } else { "partial" }
        } else {
            "partial"
        }
        if (!capabilities.sourceBinding || binding.missing > 0 || binding.ambiguous > 0 ||
            binding.contractViolations > 0 || binding.extraneous > 0) {
            hasIncompleteSemantic = true
        }
        providers.add(public_model.ProviderInfo(binding.provider,
            binding.providerVersion, binding.moduleId, providerState,
            public_model.SemanticCapabilities(capabilities.sourceBinding, capabilities.ownership,
                capabilities.visibility, capabilities.canonicalTypes, capabilities.canonicalSignatures,
                relationships: capabilities.symbolRelationships,
                annotations: capabilities.annotations)))
    }
    return public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.6.0"),
        if (hasError || hasIncompleteSource || hasIncompleteSemantic) { "partial" } else { "complete" },
        public_model.ProjectInfo(documentation.projectName),
        public_model.ConfigurationSnapshot(audience: request.audience,
            lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) { "default" } else { "custom" }),
        providers: providers.toArray(), modules: modules.toArray(), packages: packages.toArray(),
        files: files.toArray(), declarations: declarations.toArray(), assets: assetCollector.assets(),
        orphanDocComments: orphanDocComments.toArray(), macroInvocations: macroInvocations.toArray(),
        unsupportedDeclarations: unsupported.toArray(), diagnostics: diagnostics.toArray())
}

public class DocumentationEngine {
    public func generate(request: GenerationRequest): public_model.DocumentationSet {
        let semanticProvider: SemanticProvider = if (request.providerFactories.isEmpty()) {
            defaultSemanticProvider()
        } else {
            FactorySemanticProviderAdapter(request.providerFactories[0], request.projectRoot)
        }
        let documentation = generateDocumentation(request.projectRoot,
            includePathDependencies: request.includePathDependencies,
            dependencySources: request.dependencySources.toArray(),
            cfgValues: request.cfgValues.toArray(), jobs: request.jobs,
            cacheDirectory: request.cacheDirectory,
            cacheFingerprint: request.cacheFingerprint,
            astPreflightExecutable: request.astPreflightExecutable,
            includeCachedDependencies: request.includeCachedDependencies,
            cjpmCacheRoot: request.cjpmCacheRoot,
            semanticProvider: semanticProvider)
        match (request.lintProfile) {
            case "off" => resolveDocumentationReferences(documentation)
            case "standard" => lintDocumentation(documentation, false)
            case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true)
            case _ => ()
        }
        sortDocumentationDeterministically(documentation)
        let result = publicDocumentation(documentation, request)
        validateGeneratedDocIr(result)
        result
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) { results.add(generate(request)) }
        results.toArray()
    }
}
