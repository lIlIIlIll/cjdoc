package cjdoc

import cjdoc.semantic.{SemanticResult, SemanticProvider}
import cjdoc.toolchain.ToolchainIdentity
import cjdoc.source.model.SourceSnapshot
import cjdoc.semantic.chir.{ChirExecutionOptions, ChirSemanticProviderFactory}

// CHIR remains an enrichment provider. Source declarations and comments remain
// the binding boundary; this factory only returns records for declarations that
// were present in the source view supplied by the public adapter.
internal class AutoChirSemanticProvider <: SemanticProvider {
    private let options: ChirOptions

    init(options: ChirOptions) {
        this.options = options
    }

    public func providerName(): String { "chir" }

    public func providerVersion(): String {
        "1/" + ToolchainIdentity(compilerExecutable: Some(options.compilerExecutable)).compilerVersion
    }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let execution = ChirExecutionOptions(options.compilerExecutable, options.workerExecutable,
            options.importPaths)
        let factory = ChirSemanticProviderFactory(source, execution, providerVersion())
        try {
            return FactorySemanticProviderAdapter(factory).analyze(source)
        } finally {
            factory.dispose()
        }
    }
}
