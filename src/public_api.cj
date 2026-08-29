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
    private let dependencySourcesStorage: ArrayList<DependencySourceInput>
    private let cfgValuesStorage: ArrayList<CfgValue>
    private let providerFactoriesStorage: ArrayList<public_provider.SemanticProviderFactory>

    public init(projectRoot: String, includePathDependencies!: Bool = false,
        includeCachedDependencies!: Bool = false, jobs!: Int64 = 1,
        audience!: String = "external", lintProfile!: String = "standard",
        dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
        providerFactories!: Array<public_provider.SemanticProviderFactory> = []) {
        if (projectRoot.isEmpty()) { throw IllegalArgumentException("project root cannot be empty") }
        if (jobs < 1 || jobs > 64) { throw IllegalArgumentException("jobs must be in 1..64") }
        if (audience != "external" && audience != "package" && audience != "all") {
            throw IllegalArgumentException("audience must be external, package, or all")
        }
        if (lintProfile != "off" && lintProfile != "standard" && lintProfile != "strict") {
            throw IllegalArgumentException("lint profile must be off, standard, or strict")
        }
        if (providerFactories.size > 1) {
            throw IllegalArgumentException("cjdoc 0.4 accepts at most one semantic provider factory")
        }
        this.projectRoot = projectRoot
        this.includePathDependencies = includePathDependencies
        this.includeCachedDependencies = includeCachedDependencies
        this.jobs = jobs
        this.audience = audience
        this.lintProfile = lintProfile
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
    TypeRef(value.spelling, canonical: value.semantic.canonical, state: value.semantic.state)
}

private func sourceByKey(source: SourceSnapshot, key: String): ?SourceDeclaration {
    for (declaration in source.declarations) {
        if (declaration.sourceKey == key) { return Some(declaration) }
    }
    None
}

private func moduleOwnsDeclaration(module: SourceModule, declaration: SourceDeclaration): Bool {
    module.packageNames.contains(declaration.packageName)
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

private class FactorySemanticProviderAdapter <: SemanticProvider {
    private let factory: public_provider.SemanticProviderFactory
    private let sourceMapper: PublicSourceMapper

    init(factory: public_provider.SemanticProviderFactory, projectRoot: String) {
        this.factory = factory
        this.sourceMapper = PublicSourceMapper(projectRoot)
    }

    public func providerName(): String { factory.name }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let converted = ArrayList<SemanticDeclaration>()
        let diagnostics = ArrayList<Diagnostic>()
        var sourceBinding = false
        var ownership = false
        var visibility = false
        var canonicalTypes = false
        var canonicalSignatures = false
        var relationships = false

        for (module in source.modules) {
            let views = ArrayList<public_provider.SourceDeclarationView>()
            for (declaration in source.declarations) {
                if (!moduleOwnsDeclaration(module, declaration)) { continue }
                let parameters = ArrayList<public_provider.SourceParameterView>()
                for (parameter in declaration.parameters) {
                    parameters.add(public_provider.SourceParameterView(parameter.name, parameter.typeSpelling))
                }
                let owner: ?public_provider.SourceDeclarationId = match (declaration.ownerSourceKey) {
                    case Some(value) => Some(public_provider.SourceDeclarationId(value))
                    case None => None
                }
                views.add(public_provider.SourceDeclarationView(
                    public_provider.SourceDeclarationId(declaration.sourceKey), declaration.kind,
                    declaration.name, declaration.packageName, declaration.visibility,
                    declaration.genericParameters.size, sourceMapper.range(declaration.source),
                    declaration.sourceSignature, ownerId: owner, parameters: parameters.toArray(),
                    returnTypeSpelling: declaration.returnTypeSpelling,
                    annotations: declaration.annotations.toArray()))
            }

            let semanticModule = public_provider.SemanticModule(module.id, module.name,
                module.role, module.sourcePrefix)
            try {
                let session = factory.open(semanticModule)
                try {
                    let batch = session.analyze(views)
                    sourceBinding = sourceBinding || batch.capabilities.sourceBinding
                    ownership = ownership || batch.capabilities.ownership
                    visibility = visibility || batch.capabilities.visibility
                    canonicalTypes = canonicalTypes || batch.capabilities.canonicalTypes
                    canonicalSignatures = canonicalSignatures || batch.capabilities.canonicalSignatures
                    relationships = relationships || batch.capabilities.relationships
                    for (item in batch.declarations) {
                        let sourceKey = item.sourceId.serialize()
                        match (sourceByKey(source, sourceKey)) {
                            case Some(original) =>
                                let owner = match (item.ownerId) {
                                    case Some(candidate) =>
                                        let encoded = candidate.serialize()
                                        if (sourceByKey(source, encoded).isSome()) { Some(encoded) } else {
                                            diagnostics.add(Diagnostic("warning", "CJDOC2004",
                                                "semantic provider returned an unknown owner source declaration id"))
                                            original.ownerSourceKey
                                        }
                                    case None => original.ownerSourceKey
                                }
                                let semantic = SemanticDeclaration(sourceKey, original.kind, original.name,
                                    original.packageName,
                                    owner,
                                    match (item.visibility) {
                                        case Some(value) => value
                                        case None => original.visibility
                                    }, item.state, factory.name,
                                    canonicalSignature: item.canonicalSignature,
                                    isContainer: original.isContainer)
                                for (parameter in item.parameters) {
                                    semantic.parameters.add(SemanticParameter(parameter.name,
                                        providerType(parameter.typeRef)))
                                }
                                semantic.returnType = match (item.returnType) {
                                    case Some(value) => Some(providerType(value))
                                    case None => None
                                }
                                semantic.annotations.add(all: item.annotations)
                                converted.add(semantic)
                            case None =>
                                diagnostics.add(Diagnostic("warning", "CJDOC2002",
                                    "semantic provider returned an unknown source declaration id"))
                        }
                    }
                    for (diagnostic in batch.diagnostics) {
                        if ((diagnostic.severity != "warning" && diagnostic.severity != "error") ||
                            !validProviderDiagnosticCode(diagnostic.code)) {
                            diagnostics.add(Diagnostic("warning", "CJDOC2003",
                                "semantic provider emitted an invalid diagnostic contract"))
                        } else {
                            diagnostics.add(Diagnostic(diagnostic.severity, diagnostic.code,
                                diagnostic.message,
                                source: match (diagnostic.source) {
                                    case Some(range) => Some(SourceLocation(range.path, range.start.line,
                                        range.start.column, range.end.line, range.end.column))
                                    case None => None
                                }, symbolId: diagnostic.symbolId))
                        }
                    }
                } finally {
                    session.close()
                }
            } catch (error: Exception) {
                diagnostics.add(Diagnostic("warning", "CJDOC2001",
                    "semantic provider '${factory.name}' failed for module '${module.name}': ${error.message}; AST fallback retained"))
            }
        }

        let result = SemanticResult(factory.name, SemanticCapabilities(sourceBinding, ownership,
            visibility, canonicalTypes, canonicalSignatures, symbolRelationships: relationships))
        result.declarations.add(all: converted)
        result.diagnostics.add(all: diagnostics)
        return result
    }
}

private func publicType(value: TypeRef, provider: String): public_model.TypeRef {
    let semanticProvider: ?String = if (value.state == "unavailable") { None } else { Some(provider) }
    public_model.TypeRef("source", value.display,
        public_model.SemanticType(value.state, canonical: value.canonical, provider: semanticProvider))
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

private func publicMarkdownNode(node: NodeRef, source: SourceBuffer): public_model.MarkdownNode {
    let children = ArrayList<public_model.MarkdownNode>()
    let sourceChildren = node.children()
    var index: Int64 = 0
    while (index < sourceChildren.size) {
        children.add(publicMarkdownNode(sourceChildren[index], source))
        index++
    }
    let literal = match (node.kind) {
        case NodeKind.Text => node.asText().getOrThrow().value
        case NodeKind.CodeBlock => node.asCodeBlock().getOrThrow().literal
        case NodeKind.CodeSpan => node.asCodeSpan().getOrThrow().literal
        case NodeKind.HtmlBlock => node.asHtmlBlock().getOrThrow().literal
        case NodeKind.HtmlInline => node.asHtmlInline().getOrThrow().literal
        case NodeKind.Link => node.asLink().getOrThrow().destination
        case NodeKind.Image => node.asImage().getOrThrow().destination
        case _ => if (sourceChildren.isEmpty()) { source.text(node) } else { "" }
    }
    public_model.MarkdownNode(publicMarkdownKind(node.kind), literal: literal, children: children.toArray())
}

private func publicMarkdown(body: String): public_model.MarkdownNode {
    if (body.isEmpty()) { return public_model.MarkdownNode("document") }
    try {
        let result = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build().parse(body)
        publicMarkdownNode(result.document.root(), result.source)
    } catch (_: Exception) {
        // Documentation generation must survive unsupported or resource-limited Markdown.
        public_model.MarkdownNode("document", children: [public_model.MarkdownNode("text", literal: body)])
    }
}

private func publicComment(value: DocComment): public_model.DocComment {
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
        publicMarkdown(body),
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
        var moduleId = ""
        for (module in documentation.modules) {
            if (module.packageNames.contains(pkg.name)) { moduleId = module.id; break }
        }
        packages.add(public_model.PackageDoc(pkg.name, moduleId,
            sourceFiles: pkg.sourceFiles.toArray(), symbolIds: pkg.symbolIds.toArray()))
        for (path in pkg.sourceFiles) { files.add(public_model.FileDoc(path, moduleId, pkg.name)) }
    }
    let declarations = ArrayList<public_model.SymbolDoc>()
    for (symbol in documentation.symbols) {
        let parameters = ArrayList<public_model.ParameterDoc>()
        for (parameter in symbol.parameters) {
            parameters.add(public_model.ParameterDoc(parameter.name,
                publicType(parameter.typeRef, symbol.semanticProvider),
                documentation: parameter.documentation))
        }
        declarations.add(public_model.SymbolDoc(symbol.id, symbol.kind, symbol.name,
            symbol.qualifiedName, symbol.packageName, symbol.visibility, sourceMapper.range(symbol.source),
            symbol.sourceSignature,
            public_model.SemanticInfo(symbol.semanticState, symbol.semanticProvider,
                canonicalSignature: symbol.canonicalSignature),
            ownerId: symbol.ownerId, genericParameters: symbol.genericParameters.toArray(),
            parameters: parameters.toArray(),
            returnType: match (symbol.returnType) {
                case Some(value) => Some(publicType(value, symbol.semanticProvider))
                case None => None
            }, annotations: symbol.annotations.toArray(),
            documentation: match (symbol.documentation) {
                case Some(value) => Some(publicComment(value))
                case None => None
            }, origin: public_model.DeclarationOrigin(kind: symbol.origin.kind,
                macroSymbolId: symbol.origin.macroSymbolId)))
    }
    let unsupported = ArrayList<public_model.UnsupportedDeclaration>()
    for (item in documentation.unsupportedDeclarations) {
        unsupported.add(public_model.UnsupportedDeclaration(item.kind, item.name, item.reason,
            sourceMapper.range(item.source)))
    }
    let diagnostics = ArrayList<public_model.Diagnostic>()
    var hasError = false
    var hasIncompleteSource = !documentation.unsupportedDeclarations.isEmpty()
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
    let capabilities = documentation.semanticBinding.capabilities
    let providers = [public_model.ProviderInfo(documentation.semanticBinding.provider, "1",
        if (documentation.semanticBinding.missing == 0 && documentation.semanticBinding.ambiguous == 0) {
            if (capabilities.canonicalTypes) { "resolved" } else { "partial" }
        } else { "partial" },
        public_model.SemanticCapabilities(capabilities.sourceBinding, capabilities.ownership,
            capabilities.visibility, capabilities.canonicalTypes, capabilities.canonicalSignatures,
            relationships: capabilities.symbolRelationships))]
    return public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.4.0"),
        if (hasError || hasIncompleteSource) { "partial" } else { "complete" },
        public_model.ProjectInfo(documentation.projectName),
        public_model.ConfigurationSnapshot(audience: request.audience,
            lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) { "default" } else { "custom" }),
        providers: providers, modules: modules.toArray(), packages: packages.toArray(),
        files: files.toArray(), declarations: declarations.toArray(),
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
            includeCachedDependencies: request.includeCachedDependencies,
            semanticProvider: semanticProvider)
        match (request.lintProfile) {
            case "off" => resolveDocumentationReferences(documentation)
            case "standard" => lintDocumentation(documentation, false)
            case "strict" => lintDocumentation(documentation, true, missingSymbolDocs: true)
            case _ => ()
        }
        sortDocumentationDeterministically(documentation)
        publicDocumentation(documentation, request)
    }

    public func generateMatrix(requests: Array<GenerationRequest>): Array<public_model.DocumentationSet> {
        let results = ArrayList<public_model.DocumentationSet>()
        for (request in requests) { results.add(generate(request)) }
        results.toArray()
    }
}
