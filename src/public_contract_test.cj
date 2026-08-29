package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let PUBLIC_FIXTURE_PROJECTS = "tests/fixtures/projects/"

private class ProviderLifecycle {
    var opened: Int64 = 0
    var analyzed: Int64 = 0
    var closed: Int64 = 0
}

private class LifecycleSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) { this.lifecycle = lifecycle }

    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        api_provider.SemanticBatch(api_model.SemanticCapabilities(false, false, false, false, false))
    }

    public func close(): Unit { lifecycle.closed++ }
}

private class LifecycleFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) { this.lifecycle = lifecycle }

    public prop name: String { get() { "lifecycle-test" } }
    public prop version: String { get() { "1" } }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        LifecycleSession(lifecycle)
    }
}

private class UnknownIdSession <: api_provider.SemanticProviderSession {
    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: [api_provider.SemanticDeclaration(
                api_provider.SourceDeclarationId("not-issued-by-cjdoc"), "partial")])
    }

    public func close(): Unit {}
}

private class UnknownIdFactory <: api_provider.SemanticProviderFactory {
    public prop name: String { get() { "unknown-id-test" } }
    public prop version: String { get() { "1" } }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        UnknownIdSession()
    }
}

private func publicHasDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

@Test
class PublicApiContractsTest {
    @TestCase
    func generatedDocIrRoundTripsStrictly(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "standard"))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/5")
        @Expect(documentation.declarations.size, 25)
        @Expect(documentation.files.size, 1)
        @Expect(documentation.declarations[0].source.start.byteOffset > 0)

        let encoded = api_render.encodeDocIr(documentation)
        @Expect(!encoded.contains("/home/"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let unknown = encoded.replace("\"schemaVersion\":", "\"unknown\":true,\"schemaVersion\":")
        @ExpectThrows(api_render.decodeDocIr(unknown))
        let duplicate = encoded.replace("\"schemaVersion\": \"cjdoc.doc-ir/5\",",
            "\"schemaVersion\": \"cjdoc.doc-ir/5\", \"schemaVersion\": \"cjdoc.doc-ir/5\",")
        @ExpectThrows(api_render.decodeDocIr(duplicate))
    }

    @TestCase
    func renderersHonorAudienceWithoutChangingDocIr(): Unit {
        let external = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", audience: "external", lintProfile: "off"))
        let all = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", audience: "all", lintProfile: "off"))
        @Expect(external.declarations.size, all.declarations.size)

        let externalHtml = api_render.HtmlDocumentationRenderer().render(external)[0].content
        let allHtml = api_render.HtmlDocumentationRenderer().render(all)[0].content
        @Expect(!externalHtml.contains("basic.Parser.hidden"))
        @Expect(allHtml.contains("basic.Parser.hidden"))
    }

    @TestCase
    func strictLintAndProviderLifecycleAreObservable(): Unit {
        let strict = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "strict"))
        @Expect(publicHasDiagnostic(strict, "CJDOC3004") ||
            publicHasDiagnostic(strict, "CJDOC3025"))

        let lifecycle = ProviderLifecycle()
        let provided = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [LifecycleFactory(lifecycle)]))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(provided.providers[0].name, "lifecycle-test")

        let unknown = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [UnknownIdFactory()]))
        @Expect(publicHasDiagnostic(unknown, "CJDOC2002"))
        @Expect(unknown.declarations.size, 25)
    }
}
