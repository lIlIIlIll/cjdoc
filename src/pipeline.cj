package cjdoc

// Owns orchestration only. Source and semantic providers remain replaceable
// independently, while the binder is the sole place that joins their results.
class DocumentationDriver {
    private let sourceProvider: SourceProvider
    private let semanticProvider: SemanticProvider
    private let cfgProfile: CfgProfile

    public init(sourceProvider: SourceProvider, semanticProvider: SemanticProvider,
        cfgProfile!: CfgProfile = CfgProfile()) {
        this.sourceProvider = sourceProvider
        this.semanticProvider = semanticProvider
        this.cfgProfile = cfgProfile
    }

    public func generate(projectRoot: String): DocumentationSet {
        let source = sourceProvider.collect(projectRoot)
        filterSourceForCfg(source, cfgProfile)
        let semantic = semanticProvider.analyze(source)
        let documentation = DocumentationBinder().bind(source, semantic,
            expectedProvider: Some(semanticProvider.providerName()))
        documentation.cfgProfile = cfgProfile
        return documentation
    }
}

func defaultSemanticProvider(): SemanticProvider {
    AstSemanticProvider()
}

func generateDocumentation(request: GenerationRequest,
    semanticProvider!: SemanticProvider = defaultSemanticProvider()): DocumentationSet {
    let profile = CfgProfile(values: request.cfgValues.toArray())
    DocumentationDriver(
        AstSourceProvider(includePathDependencies: request.includePathDependencies,
            dependencySources: request.dependencySources.toArray(), jobs: request.jobs,
            cacheDirectory: request.cacheDirectory, cacheFingerprint: request.cacheFingerprint,
            astPreflightExecutable: request.astPreflightExecutable,
            includeCachedDependencies: request.includeCachedDependencies,
            cjpmCacheRoot: request.cjpmCacheRoot),
        semanticProvider,
        cfgProfile: profile
    ).generate(request.projectRoot)
}
