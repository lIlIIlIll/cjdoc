package provider_plugin_fixture

import cjdoc.*
import cjdoc.model.*
import cjdoc.provider.*
import std.collection.*

class PluginSemanticProviderSession <: SemanticProviderSession {
    public func analyze(source: ReadOnlyList<SourceDeclarationView>): SemanticBatch {
        let declarations = ArrayList<SemanticDeclaration>()
        for (declaration in source) {
            declarations.add(SemanticDeclaration(declaration.id, "partial"))
        }
        SemanticBatch(SemanticCapabilities(true, false, false, false, false),
            declarations: declarations.toArray())
    }

    public func close(): Unit {}
}

class PluginSemanticProviderFactory <: SemanticProviderFactory {
    public prop name: String { get() { "fixture-plugin" } }
    public prop version: String { get() { "1" } }

    public func open(_: SemanticModule): SemanticProviderSession {
        PluginSemanticProviderSession()
    }
}

main(): Int64 {
    let documentation = DocumentationEngine().generate(GenerationRequest(".",
        providerFactories: [PluginSemanticProviderFactory()],
        astPreflightExecutable: Some("../../../../target/release/bin/main")))
    if (documentation.providers.size != 1 || documentation.providers[0].name != "fixture-plugin") {
        return 1
    }
    if (documentation.declarations.isEmpty()) { return 2 }
    println("provider plugin ok")
    return 0
}
