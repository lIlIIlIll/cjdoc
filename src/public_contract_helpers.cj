package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render

@When[os != "Linux"]
import std.posix.*

internal func publicHasDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) {
            return true
        }
    }
    false
}

internal func publicDiagnosticCount(documentation: api_model.DocumentationSet, code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) {
            count++
        }
    }
    count
}

internal func markdownLiteral(node: api_model.MarkdownNode, kind: String): ?String {
    if (node.kind == kind) {
        return Some(node.literal)
    }
    for (child in node.children) {
        if (let Some(value) <- markdownLiteral(child, kind)) {
            return Some(value)
        }
    }
    None
}

internal func renderedContent(artifacts: Array<api_render.RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        out.append("\n--- ${artifact.path} ---\n")
        out.append(artifact.content)
    }
    out.toString()
}

internal func hasArtifactPrefix(artifacts: Array<api_render.RenderArtifact>, prefix: String): Bool {
    for (artifact in artifacts) {
        if (artifact.path.startsWith(prefix)) {
            return true
        }
    }
    false
}

internal func artifactContent(artifacts: Array<api_render.RenderArtifact>, path: String): String {
    for (artifact in artifacts) {
        if (artifact.path == path) {
            return artifact.content
        }
    }
    throw IllegalArgumentException("missing render artifact '${path}'")
}

internal func rendererFixture(markdown: api_model.MarkdownNode, summary: String, assets!: Array<api_model.AssetDoc> = []): api_model.DocumentationSet {
    let moduleId = "cjdoc:module:v1:renderer-test"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-test::fixture::function:api#g0()"
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 24, 23))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let symbol = api_model.SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId, "public", source,
        "public func api(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(
            api_model.DocComment("RAW-FIELD-MUST-NOT-RENDER", summary, "DESCRIPTION-FIELD-MUST-NOT-RENDER", markdown)))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("renderer-fixture"),
        api_model.ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [api_model.ProviderInfo("ast-fallback", "builtin", moduleId, "partial", capabilities)],
        modules: [api_model.ModuleDoc(moduleId, "renderer-fixture", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol], assets: assets)
}

internal func samePackageAcrossModulesFixture(): api_model.DocumentationSet {
    let firstModule = "cjdoc:module:v1:first"
    let secondModule = "cjdoc:module:v1:second"
    let firstId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Afirst::shared::function:first#g0()"
    let secondId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asecond::shared::function:second#g0()"
    let firstSource = api_model.SourceRange("first/src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 26, 25))
    let secondSource = api_model.SourceRange("second/src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 27, 26))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let markdown = api_model.MarkdownNode("document",
        children: [api_model.MarkdownNode("paragraph",
            children: [api_model.MarkdownNode("text", literal: "Module-local API")])])
    let first = api_model.SymbolDoc(firstId, "function", "first", "shared.first", "shared", firstModule, "public",
        firstSource, "public func first(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    let second = api_model.SymbolDoc(secondId, "function", "second", "shared.second", "shared", secondModule, "public",
        secondSource, "public func second(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    api_model.DocumentationSet(
        api_model.GeneratorInfo("cjdoc", "test"),
        "complete",
        api_model.ProjectInfo("two-modules", kind: "workspace"),
        api_model.ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [
            api_model.ProviderInfo("ast-fallback", "builtin", firstModule, "partial", capabilities),
            api_model.ProviderInfo("ast-fallback", "builtin", secondModule, "partial", capabilities)
        ],
        modules: [
            api_model.ModuleDoc(firstModule, "first", "workspace", "first", packageNames: ["shared"]),
            api_model.ModuleDoc(secondModule, "second", "workspace", "second", packageNames: ["shared"])
        ],
        packages: [
            api_model.PackageDoc("shared", firstModule, sourceFiles: ["first/src/api.cj"], symbolIds: [firstId]),
            api_model.PackageDoc("shared", secondModule, sourceFiles: ["second/src/api.cj"], symbolIds: [secondId])
        ],
        files: [
            api_model.FileDoc("first/src/api.cj", firstModule, "shared"),
            api_model.FileDoc("second/src/api.cj", secondModule, "shared")
        ],
        declarations: [first, second]
    )
}
