package cjdoc

import cjdoc.semantic.{SemanticProvider, SyntaxSemanticProvider}
import cjdoc.binding.{DocumentationBinder, DocumentationSet, captureDocumentationMetadataInventory}
import cjdoc.source.{DependencySourceSelection, SourceRepositoryRegistrationInput}
import cjdoc.source.cfg.{CfgAssignment, CfgProfile}
import cjdoc.source.discovery.SyntaxSourceProvider
import cjdoc.source.frontend.filterSourceForCfg
import std.collection.*

// Joins captured source facts, conditional selection, semantics and documentation binding.
class DocumentationDriver {
    private let sourceProvider: SyntaxSourceProvider
    private let semanticProvider: SemanticProvider
    private let cfgProfile: CfgProfile

    public init(sourceProvider: SyntaxSourceProvider, semanticProvider: SemanticProvider,
        cfgProfile!: CfgProfile = CfgProfile()) {
        this.sourceProvider = sourceProvider
        this.semanticProvider = semanticProvider
        this.cfgProfile = cfgProfile
    }

    public func generate(projectRoot: String): DocumentationSet {
        let source = sourceProvider.collect(projectRoot)
        captureDocumentationMetadataInventory(source)
        filterSourceForCfg(source, cfgProfile)
        source.cfgProfile = cfgProfile
        let semantic = semanticProvider.analyze(source)
        let documentation = DocumentationBinder().bind(source, semantic,
            expectedProvider: Some(semanticProvider.providerName()))
        documentation.cfgProfile = cfgProfile
        documentation.apiCollectionState = capturedApiCollectionState(documentation)
        return documentation
    }
}

func defaultSemanticProvider(): SemanticProvider {
    SyntaxSemanticProvider()
}

func generateDocumentation(request: GenerationRequest,
    semanticProvider!: SemanticProvider = defaultSemanticProvider()): DocumentationSet {
    let values = request.cfgValues
    let profile = CfgProfile(values: Array<CfgAssignment>(values.size, { index =>
        let entry = values[index]
        CfgAssignment(entry.name, entry.value)
    }))
    let sourceInputs = request.dependencySources
    let sources = Array<DependencySourceSelection>(sourceInputs.size, { index =>
        let entry = sourceInputs[index]
        DependencySourceSelection(entry.name, entry.path)
    })
    let repositories = request.sourceRepositories.map({ inputs =>
        let registrations = ArrayList<SourceRepositoryRegistrationInput>(inputs.size)
        for (entry in inputs) {
            registrations.add(SourceRepositoryRegistrationInput(entry.root, entry.repository,
                repositoryPath: entry.repositoryPath, receipt: entry.receipt, receiptSha256: entry.receiptSha256))
        }
        let captured: ReadOnlyList<SourceRepositoryRegistrationInput> = registrations
        captured
    })
    DocumentationDriver(
        SyntaxSourceProvider(includePathDependencies: request.includePathDependencies,
            dependencySources: sources, jobs: request.jobs,
            cacheDirectory: request.cacheDirectory, cacheFingerprint: request.cacheFingerprint,
            astPreflightExecutable: request.astPreflightExecutable,
            includeCachedDependencies: request.includeCachedDependencies,
            cjpmCacheRoot: request.cjpmCacheRoot,
            sourceRepositories: repositories,
            legacyRepository: request.repository, legacyRepositoryRoot: request.repositoryRoot),
        semanticProvider,
        cfgProfile: profile
    ).generate(request.projectRoot)
}
