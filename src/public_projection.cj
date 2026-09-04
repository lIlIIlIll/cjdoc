package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.sort.*

internal class PublicModuleProjection {
    let modules: Array<public_model.ModuleDoc>
    let packages: Array<public_model.PackageDoc>
    let files: Array<public_model.FileDoc>

    init(documentation: DocumentationSet, sourceMapper: PublicSourceMapper) {
        let modules = ArrayList<public_model.ModuleDoc>()
        for (module in documentation.modules) {
            modules.add(
                public_model.ModuleDoc(module.id, module.name, module.role, module.sourcePrefix,
                    packageNames: module.packageNames.toArray(), dependencyIds: module.dependencyIds.toArray(),
                    organization: module.organization))
        }
        let packages = ArrayList<public_model.PackageDoc>()
        let files = ArrayList<public_model.FileDoc>()
        for (pkg in documentation.packages) {
            let reExports = ArrayList<public_model.ReExportDoc>()
            for (reExport in pkg.reExports) {
                let bindings = ArrayList<public_model.ReExportBinding>()
                for (binding in reExport.bindings) {
                    bindings.add(public_model.ReExportBinding(binding.exposedName,
                        targetSymbolIds: binding.targetSymbolIds.toArray()))
                }
                reExports.add(public_model.ReExportDoc(reExport.id, reExport.kind,
                    reExport.targetPackageName, reExport.state, sourceMapper.range(reExport.source),
                    organization: reExport.organization, targetModuleId: reExport.targetModuleId,
                    alias: reExport.alias, bindings: bindings.toArray()))
            }
            packages.add(
                public_model.PackageDoc(pkg.name, pkg.moduleId, sourceFiles: pkg.sourceFiles.toArray(),
                    symbolIds: pkg.symbolIds.toArray(), reExports: reExports.toArray()))
            for (path in pkg.sourceFiles) {
                files.add(public_model.FileDoc(path, pkg.moduleId, pkg.name))
            }
        }
        this.modules = modules.toArray()
        this.packages = packages.toArray()
        this.files = files.toArray()
    }
}

internal class PublicProviderProjection {
    let statesByModule: HashMap<String, String>
    let providers: Array<public_model.ProviderInfo>
    let incomplete: Bool

    init(documentation: DocumentationSet) {
        let summaries = summarizeFinalSemanticStates(documentation)
        let statesByModule = HashMap<String, String>()
        for (binding in documentation.semanticBindings) {
            let summary = match (summaries.get(binding.moduleId)) {
                case Some(value) => value
                case None => FinalSemanticStateSummary()
            }
            statesByModule[binding.moduleId] = aggregateProviderState(binding, summary)
        }
        let providers = ArrayList<public_model.ProviderInfo>()
        var incomplete = false
        for (binding in documentation.semanticBindings) {
            let capabilities = binding.capabilities
            let summary = match (summaries.get(binding.moduleId)) {
                case Some(value) => value
                case None => FinalSemanticStateSummary()
            }
            let providerState = match (statesByModule.get(binding.moduleId)) {
                case Some(value) => value
                case None => "unavailable"
            }
            if (!capabilities.sourceBinding || binding.missing > 0 || binding.ambiguous > 0 ||
                binding.contractViolations > 0 || binding.extraneous > 0 || summary.unavailable > 0 ||
                summary.ambiguous > 0) {
                incomplete = true
            }
            providers.add(
                public_model.ProviderInfo(binding.provider, binding.providerVersion, binding.moduleId, providerState,
                    public_model.SemanticCapabilities(capabilities.sourceBinding, capabilities.ownership,
                        capabilities.visibility, capabilities.canonicalTypes, capabilities.canonicalSignatures,
                        relationships: capabilities.symbolRelationships, annotations: capabilities.annotations)))
        }
        this.statesByModule = statesByModule
        this.providers = providers.toArray()
        this.incomplete = incomplete
    }
}

internal func publicSymbol(value: SymbolDoc, sourceMapper: PublicSourceMapper,
    providerStatesByModule: HashMap<String, String>, assetCollector: LocalAssetCollector,
    markdownContext: MarkdownGenerationContext): public_model.SymbolDoc {
    let providerState = match (providerStatesByModule.get(value.moduleId)) {
        case Some(state) => state
        case None => "unavailable"
    }
    let declarationSource = sourceMapper.range(value.source)
    let parameters = ArrayList<public_model.ParameterDoc>()
    let annotations = ArrayList<public_model.AnnotationDoc>()
    let typeRelationships = ArrayList<public_model.TypeRelationship>()
    let symbolRelationships = ArrayList<public_model.SymbolRelationship>()
    for (parameter in value.parameters) {
        parameters.add(
            public_model.ParameterDoc(parameter.name,
                publicType(parameter.typeRef, value.semanticProvider, providerState),
                documentation: parameter.documentation, defaultExpression: parameter.defaultExpression))
    }
    for (relationship in value.relationships) {
        typeRelationships.add(
            public_model.TypeRelationship(relationship.kind,
                publicType(relationship.target, value.semanticProvider, providerState)))
    }
    for (relationship in value.symbolRelationships) {
        symbolRelationships.add(
            public_model.SymbolRelationship(relationship.kind, relationship.targetDisplay, relationship.state,
                targetSymbolId: relationship.targetSymbolId))
    }
    for (annotation in value.annotations) {
        annotations.add(
            public_model.AnnotationDoc(annotation.spelling, provenance: annotation.provenance,
                provider: annotation.provider))
    }
    public_model.SymbolDoc(value.id, value.kind, value.name, value.qualifiedName, value.packageName,
        value.moduleId, value.visibility, declarationSource, value.sourceSignature,
        public_model.SemanticInfo(value.semanticState, value.semanticProvider,
            canonicalSignature: value.canonicalSignature), value.enumNonExhaustive, ownerId: value.ownerId,
        genericParameters: value.genericParameters.toArray(), parameters: parameters.toArray(),
        returnType: match (value.returnType) {
            case Some(returnType) => Some(publicType(returnType, value.semanticProvider, providerState))
            case None => None
        }, annotations: annotations.toArray(), typeRelationships: typeRelationships.toArray(),
        symbolRelationships: symbolRelationships.toArray(), documentation: match (value.documentation) {
            case Some(comment) => Some(
                publicComment(comment, assetCollector, value.source.path, declarationSource, value.id,
                    markdownContext))
            case None => None
        },
        origin: public_model.DeclarationOrigin(kind: value.origin.kind,
            macroSymbolId: value.origin.macroSymbolId),
        sourceApiSignature: if (value.sourceApiSignatureTokens.isEmpty()) {
            public_model.SourceApiSignature("unavailable")
        } else {
            public_model.SourceApiSignature("available", tokens: value.sourceApiSignatureTokens.toArray())
        })
}

internal class PublicDeclarationProjection {
    let declarations: Array<public_model.SymbolDoc>
    let assetCollector: LocalAssetCollector
    let markdownContext: MarkdownGenerationContext

    init(documentation: DocumentationSet, sourceMapper: PublicSourceMapper,
        providerStatesByModule: HashMap<String, String>) {
        let declarations = ArrayList<public_model.SymbolDoc>()
        let assetCollector = LocalAssetCollector(documentation.sourceFileOrigins)
        let markdownContext = MarkdownGenerationContext()
        for (symbol in documentation.symbols) {
            declarations.add(publicSymbol(symbol, sourceMapper, providerStatesByModule,
                assetCollector, markdownContext))
        }
        this.declarations = declarations.toArray()
        this.assetCollector = assetCollector
        this.markdownContext = markdownContext
    }
}

internal class PublicSourceProjection {
    let unsupported: Array<public_model.UnsupportedDeclaration>
    let orphanDocComments: Array<public_model.OrphanDocComment>
    let macroInvocations: Array<public_model.MacroInvocation>

    init(documentation: DocumentationSet, sourceMapper: PublicSourceMapper) {
        let unsupported = ArrayList<public_model.UnsupportedDeclaration>()
        let orphanDocComments = ArrayList<public_model.OrphanDocComment>()
        for (comment in documentation.orphanDocComments) {
            orphanDocComments.add(
                public_model.OrphanDocComment(comment.rawText, sourceMapper.range(comment.source)))
        }
        let macroInvocations = ArrayList<public_model.MacroInvocation>()
        for (invocation in documentation.macroInvocations) {
            macroInvocations.add(
                public_model.MacroInvocation(invocation.name, sourceMapper.range(invocation.source)))
        }
        for (item in documentation.unsupportedDeclarations) {
            unsupported.add(
                public_model.UnsupportedDeclaration(item.kind, item.name, item.reason,
                    sourceMapper.range(item.source)))
        }
        this.unsupported = unsupported.toArray()
        this.orphanDocComments = orphanDocComments.toArray()
        this.macroInvocations = macroInvocations.toArray()
    }
}

internal class PublicDiagnosticProjection {
    let diagnostics: Array<public_model.Diagnostic>
    let hasError: Bool
    let incompleteSource: Bool

    init(documentation: DocumentationSet, sourceMapper: PublicSourceMapper,
        assetCollector: LocalAssetCollector, markdownContext: MarkdownGenerationContext) {
        let diagnostics = ArrayList<public_model.Diagnostic>()
        var hasError = false
        var incompleteSource = !documentation.orphanDocComments.isEmpty() ||
            !documentation.macroInvocations.isEmpty() || !documentation.unsupportedDeclarations.isEmpty()
        for (diagnostic in documentation.diagnostics) {
            let publicCode = remapDiagnosticCode(diagnostic.code)
            if (diagnostic.severity == "error") {
                hasError = true
            }
            if (publicCode.startsWith("CJDOC1")) {
                incompleteSource = true
            }
            diagnostics.add(
                public_model.Diagnostic(diagnostic.severity, publicCode, diagnostic.message,
                    source: match (diagnostic.source) {
                        case Some(value) => Some(sourceMapper.range(value))
                        case None => None
                    }, symbolId: diagnostic.symbolId))
        }
        if (assetCollector.incomplete) {
            incompleteSource = true
        }
        diagnostics.add(all: assetCollector.diagnostics())
        if (markdownContext.incomplete) {
            incompleteSource = true
        }
        diagnostics.add(all: markdownContext.diagnostics())
        sort(diagnostics, lessThan: {
            left, right => comparePublicDiagnostic(left, right) < 0
        }, stable: true)
        this.diagnostics = diagnostics.toArray()
        this.hasError = hasError
        this.incompleteSource = incompleteSource
    }
}

internal func publicDocumentation(documentation: DocumentationSet,
    request: GenerationRequest): public_model.DocumentationSet {
    let sourceMapper = PublicSourceMapper(origins: documentation.sourceFileOrigins.toArray())
    let moduleProjection = PublicModuleProjection(documentation, sourceMapper)
    let providerProjection = PublicProviderProjection(documentation)
    let declarationProjection = PublicDeclarationProjection(documentation, sourceMapper,
        providerProjection.statesByModule)
    let sourceProjection = PublicSourceProjection(documentation, sourceMapper)
    let diagnosticProjection = PublicDiagnosticProjection(documentation, sourceMapper,
        declarationProjection.assetCollector, declarationProjection.markdownContext)
    let status = if (diagnosticProjection.hasError || diagnosticProjection.incompleteSource ||
        providerProjection.incomplete) {
        "partial"
    } else {
        "complete"
    }
    let candidate = public_model.DocumentationSet(public_model.GeneratorInfo("cjdoc", "0.7.2"), status,
        public_model.ProjectInfo(documentation.projectName),
        public_model.ConfigurationSnapshot(audience: request.audience, lintProfile: request.lintProfile,
            cfgProfile: if (request.cfgValues.isEmpty()) { "default" } else { "custom" }),
        providers: providerProjection.providers, modules: moduleProjection.modules,
        packages: moduleProjection.packages, files: moduleProjection.files,
        declarations: declarationProjection.declarations, assets: declarationProjection.assetCollector.assets(),
        orphanDocComments: sourceProjection.orphanDocComments,
        macroInvocations: sourceProjection.macroInvocations, unsupportedDeclarations: sourceProjection.unsupported,
        diagnostics: diagnosticProjection.diagnostics)
    boundGeneratedDocumentation(candidate, request)
}
