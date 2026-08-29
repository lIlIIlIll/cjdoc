package cjdoc_core

// Owns orchestration only. Source and semantic providers remain replaceable
// independently, while the binder is the sole place that joins their results.
public class DocumentationDriver {
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

public func defaultSemanticProvider(): SemanticProvider {
    AstSemanticProvider()
}

public func generateDocumentation(projectRoot: String, includePathDependencies!: Bool = false,
    dependencySources!: Array<DependencySourceInput> = [],
    cfgValues!: Array<CfgValue> = [],
    jobs!: Int64 = 1,
    cacheDirectory!: ?String = None,
    cacheFingerprint!: ?String = None,
    astPreflightExecutable!: ?String = None,
    includeCachedDependencies!: Bool = false,
    cjpmCacheRoot!: ?String = None,
    semanticProvider!: SemanticProvider = defaultSemanticProvider()): DocumentationSet {
    let profile = CfgProfile(values: cfgValues)
    DocumentationDriver(
        AstSourceProvider(includePathDependencies: includePathDependencies,
            dependencySources: dependencySources, jobs: jobs,
            cacheDirectory: cacheDirectory, cacheFingerprint: cacheFingerprint,
            astPreflightExecutable: astPreflightExecutable,
            includeCachedDependencies: includeCachedDependencies,
            cjpmCacheRoot: cjpmCacheRoot),
        semanticProvider,
        cfgProfile: profile
    ).generate(projectRoot)
}
