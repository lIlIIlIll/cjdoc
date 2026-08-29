package provider_plugin_fixture

import cjdoc_core.*

class PluginSemanticProvider <: SemanticProvider {
    public func providerName(): String { "fixture-plugin" }

    public func analyze(_: SourceSnapshot): SemanticResult {
        SemanticResult(providerName(), SemanticCapabilities(false, false, false, false, false))
    }
}

main(): Int64 {
    let source = SourceSnapshot("plugin")
    let result = PluginSemanticProvider().analyze(source)
    if (result.provider != "fixture-plugin" || result.capabilities.canonicalTypes) { return 1 }
    println("provider plugin ok")
    return 0
}
