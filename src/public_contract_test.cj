package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let PUBLIC_FIXTURE_PROJECTS = "tests/fixtures/projects/"
private let PUBLIC_TEST_AST_PREFLIGHT = Some("target/release/bin/main")

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
    public prop version: String { get() { "2026.08-test" } }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        LifecycleSession(lifecycle)
    }
}

private class UnknownIdSession <: api_provider.SemanticProviderSession {
    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let foreignIssuer = api_provider.SourceDeclarationIssuer()
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: [api_provider.SemanticDeclaration(
                foreignIssuer.issue("not-issued-by-cjdoc"), "partial")])
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

private class WorkspaceTransactionSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle
    private let fail: Bool

    init(lifecycle: ProviderLifecycle, fail: Bool) {
        this.lifecycle = lifecycle
        this.fail = fail
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        if (fail && !declarations.isEmpty()) {
            let foreignId = api_provider.SourceDeclarationIssuer().issue(declarations[0].id.serialize())
            return api_provider.SemanticBatch(
                api_model.SemanticCapabilities(true, false, false, false, false),
                declarations: [api_provider.SemanticDeclaration(foreignId, "partial")])
        }
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit { lifecycle.closed++ }
}

private class WorkspaceTransactionFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) { this.lifecycle = lifecycle }

    public prop name: String { get() { "module-transaction-test" } }
    public prop version: String { get() { "1" } }

    public func open(module: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        WorkspaceTransactionSession(lifecycle, module.name.contains("alpha"))
    }
}

private class CloseFailureSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) { this.lifecycle = lifecycle }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {
        lifecycle.closed++
        throw IllegalStateException("close failed")
    }
}

private class CloseFailureFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) { this.lifecycle = lifecycle }

    public prop name: String { get() { "close-failure-test" } }
    public prop version: String { get() { "1" } }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        CloseFailureSession(lifecycle)
    }
}

private class AnnotationSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        for (declaration in declarations) {
            if (declaration.name == "oldParse") {
                return api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false,
                    false, false, annotations: true), declarations: [api_provider.SemanticDeclaration(
                        declaration.id, "partial", annotations: ["@ProviderMeta"],
                        annotationsProvided: true)])
            }
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false,
            false, false, annotations: true))
    }

    public func close(): Unit {}
}

private class AnnotationFactory <: api_provider.SemanticProviderFactory {
    public prop name: String { get() { "annotation-test" } }
    public prop version: String { get() { "1" } }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        AnnotationSession()
    }
}

private class RelationshipSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        var parser: ?api_provider.SourceDeclarationView = None
        var reader: ?api_provider.SourceDeclarationView = None
        for (declaration in declarations) {
            if (declaration.kind == "class" && declaration.name == "Parser") { parser = Some(declaration) }
            if (declaration.kind == "interface" && declaration.name == "Reader") { reader = Some(declaration) }
        }
        if (parser.isNone() || reader.isNone()) {
            return api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false,
                true, false, relationships: true))
        }
        let relationship = api_provider.SemanticSymbolRelationship("implements", "basic.Reader",
            "resolved", targetSourceId: Some(reader.getOrThrow().id))
        let superType = api_provider.SemanticTypeRelationship("superType", api_model.TypeRef(
            "semantic", "Reader", api_model.SemanticType("resolved",
                canonical: Some("basic.Reader"), provider: Some("relationship-test"))))
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false,
            relationships: true), declarations: [api_provider.SemanticDeclaration(
                parser.getOrThrow().id, "partial", typeRelationships: [superType],
                symbolRelationships: [relationship])])
    }

    public func close(): Unit {}
}

private class RelationshipFactory <: api_provider.SemanticProviderFactory {
    public prop name: String { get() { "relationship-test" } }
    public prop version: String { get() { "1" } }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        RelationshipSession()
    }
}

private func publicHasDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

private func renderedContent(artifacts: Array<api_render.RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        out.append("\n--- ${artifact.path} ---\n")
        out.append(artifact.content)
    }
    out.toString()
}

private func hasArtifactPrefix(artifacts: Array<api_render.RenderArtifact>, prefix: String): Bool {
    for (artifact in artifacts) {
        if (artifact.path.startsWith(prefix)) { return true }
    }
    false
}

private func artifactContent(artifacts: Array<api_render.RenderArtifact>, path: String): String {
    for (artifact in artifacts) {
        if (artifact.path == path) { return artifact.content }
    }
    throw IllegalArgumentException("missing render artifact '${path}'")
}

private func rendererFixture(markdown: api_model.MarkdownNode, summary: String,
    assets!: Array<api_model.AssetDoc> = []): api_model.DocumentationSet {
    let moduleId = "cjdoc:module:v1:renderer-test"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-test::fixture::function:api#g0()"
    let source = api_model.SourceRange("src/api.cj",
        api_model.SourcePosition(1, 1, 0), api_model.SourcePosition(1, 24, 23))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let symbol = api_model.SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture",
        moduleId, "public", source, "public func api(): Unit",
        api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(api_model.DocComment("RAW-FIELD-MUST-NOT-RENDER", summary,
            "DESCRIPTION-FIELD-MUST-NOT-RENDER", markdown)))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("renderer-fixture"), api_model.ConfigurationSnapshot(
            audience: "external", lintProfile: "off"),
        providers: [api_model.ProviderInfo("ast-fallback", "builtin", moduleId, "partial",
            capabilities)],
        modules: [api_model.ModuleDoc(moduleId, "renderer-fixture", "root", "",
            packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: [symbolId])],
        files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: [symbol], assets: assets)
}

private func samePackageAcrossModulesFixture(): api_model.DocumentationSet {
    let firstModule = "cjdoc:module:v1:first"
    let secondModule = "cjdoc:module:v1:second"
    let firstId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Afirst::shared::function:first#g0()"
    let secondId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asecond::shared::function:second#g0()"
    let firstSource = api_model.SourceRange("first/src/api.cj",
        api_model.SourcePosition(1, 1, 0), api_model.SourcePosition(1, 26, 25))
    let secondSource = api_model.SourceRange("second/src/api.cj",
        api_model.SourcePosition(1, 1, 0), api_model.SourcePosition(1, 27, 26))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let markdown = api_model.MarkdownNode("document", children: [api_model.MarkdownNode(
        "paragraph", children: [api_model.MarkdownNode("text", literal: "Module-local API")])])
    let first = api_model.SymbolDoc(firstId, "function", "first", "shared.first", "shared",
        firstModule, "public", firstSource, "public func first(): Unit",
        api_model.SemanticInfo("partial", "ast-fallback"), documentation: Some(
            api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    let second = api_model.SymbolDoc(secondId, "function", "second", "shared.second", "shared",
        secondModule, "public", secondSource, "public func second(): Unit",
        api_model.SemanticInfo("partial", "ast-fallback"), documentation: Some(
            api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("two-modules", kind: "workspace"), api_model.ConfigurationSnapshot(
            audience: "external", lintProfile: "off"),
        providers: [
            api_model.ProviderInfo("ast-fallback", "builtin", firstModule, "partial", capabilities),
            api_model.ProviderInfo("ast-fallback", "builtin", secondModule, "partial", capabilities)
        ],
        modules: [
            api_model.ModuleDoc(firstModule, "first", "workspace", "first",
                packageNames: ["shared"]),
            api_model.ModuleDoc(secondModule, "second", "workspace", "second",
                packageNames: ["shared"])
        ],
        packages: [
            api_model.PackageDoc("shared", firstModule, sourceFiles: ["first/src/api.cj"],
                symbolIds: [firstId]),
            api_model.PackageDoc("shared", secondModule, sourceFiles: ["second/src/api.cj"],
                symbolIds: [secondId])
        ],
        files: [
            api_model.FileDoc("first/src/api.cj", firstModule, "shared"),
            api_model.FileDoc("second/src/api.cj", secondModule, "shared")
        ], declarations: [first, second])
}

@Test
class PublicApiContractsTest {
    @TestCase
    func sourceDeclarationIdsAreSessionLocal(): Unit {
        let firstIssuer = api_provider.SourceDeclarationIssuer()
        let secondIssuer = api_provider.SourceDeclarationIssuer()
        let first = firstIssuer.issue("same-text")
        let sameSession = firstIssuer.issue("same-text")
        let otherSession = secondIssuer.issue("same-text")
        @Expect(first == sameSession)
        @Expect(first != otherSession)
        @Expect(first.serialize() == otherSession.serialize())
        @Expect(firstIssuer.owns(first))
        @Expect(!firstIssuer.owns(otherSession))
    }

    @TestCase
    func generatedDocIrRoundTripsStrictly(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "standard",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/7")
        @Expect(documentation.declarations.size, 25)
        @Expect(documentation.files.size, 1)
        @Expect(documentation.declarations[0].source.start.byteOffset > 0)

        let encoded = api_render.encodeDocIr(documentation)
        @Expect(!encoded.contains("/home/"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let unknown = encoded.replace("\"schemaVersion\":", "\"unknown\":true,\"schemaVersion\":")
        @ExpectThrows(api_render.decodeDocIr(unknown))
        let duplicate = encoded.replace("\"schemaVersion\": \"cjdoc.doc-ir/7\",",
            "\"schemaVersion\": \"cjdoc.doc-ir/7\", \"schemaVersion\": \"cjdoc.doc-ir/7\",")
        @ExpectThrows(api_render.decodeDocIr(duplicate))

        let missingProviderModule = encoded.replace(
            "      \"moduleId\": \"cjdoc:module:v1:root\",\n      \"state\": \"partial\",",
            "      \"state\": \"partial\",")
        @Expect(missingProviderModule != encoded)
        @ExpectThrows(api_render.decodeDocIr(missingProviderModule))

        let unknownOwner = encoded.replace("      \"ownerId\": null,",
            "      \"ownerId\": \"cjdoc:missing\",")
        @Expect(unknownOwner != encoded)
        @ExpectThrows(api_render.decodeDocIr(unknownOwner))
    }

    @TestCase
    func strictV6InputMigratesOnlyWithUniquePackageModuleMapping(): Unit {
        let path = Path("tests/fixtures/golden-v6/basic.docs.json")
        let legacy = String.fromUtf8(File.readFrom(path))
        let migrated = api_render.decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, "cjdoc.doc-ir/7")
        @Expect(migrated.providers.size, 1)
        @Expect(migrated.providers[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].id.startsWith(
            "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::"))
        @Expect(migrated.packages[0].symbolIds[0], migrated.declarations[0].id)
        var migratedAnnotation = false
        var migratedReference = false
        for (declaration in migrated.declarations) {
            if (let Some(ownerId) <- declaration.ownerId) {
                @Expect(ownerId.startsWith("cjdoc:v2:"))
            }
            for (relationship in declaration.symbolRelationships) {
                if (let Some(targetId) <- relationship.targetSymbolId) {
                    @Expect(targetId.startsWith("cjdoc:v2:"))
                    migratedReference = true
                }
            }
            if (let Some(documentation) <- declaration.documentation) {
                for (tag in documentation.tags) {
                    if (let Some(targetId) <- tag.targetSymbolId) {
                        @Expect(targetId.startsWith("cjdoc:v2:"))
                        migratedReference = true
                    }
                }
            }
            for (annotation in declaration.annotations) {
                @Expect(annotation.provenance, "source")
                @Expect(annotation.provider.isNone())
                migratedAnnotation = true
            }
        }
        @Expect(migratedAnnotation)
        @Expect(migratedReference)

        let ambiguous = legacy.replace("  \"modules\": [\n    {",
            "  \"modules\": [\n" +
            "    {\"id\":\"cjdoc:module:v1:other\",\"name\":\"other\"," +
            "\"role\":\"workspace\",\"sourcePrefix\":\"other\"," +
            "\"packageNames\":[\"basic\"],\"dependencyIds\":[]},\n    {")
        @Expect(ambiguous != legacy)
        @ExpectThrows(api_render.decodeDocIr(ambiguous))
    }

    @TestCase
    func renderersHonorAudienceWithoutChangingDocIr(): Unit {
        let external = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", audience: "external", lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let all = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", audience: "all", lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(external.declarations.size, all.declarations.size)

        let externalArtifacts = api_render.HtmlDocumentationRenderer().render(external)
        let allArtifacts = api_render.HtmlDocumentationRenderer().render(all)
        let externalHtml = renderedContent(externalArtifacts)
        let allHtml = renderedContent(allArtifacts)
        @Expect(!externalHtml.contains("basic.Parser.hidden"))
        @Expect(allHtml.contains("basic.Parser.hidden"))
        @Expect(hasArtifactPrefix(externalArtifacts, "html/packages/"))
        @Expect(hasArtifactPrefix(externalArtifacts, "html/symbols/"))
        let searchScript = artifactContent(externalArtifacts, "html/search.js")
        @Expect(searchScript.contains("data-cjdoc-search"))
        @Expect(!searchScript.contains("fetch("))
        @Expect(artifactContent(externalArtifacts, "html/search-index.js").startsWith(
            "globalThis.__CJDOC_SEARCH_INDEX__ ="))
        let searchIndex = artifactContent(externalArtifacts, "html/search-index.json")
        @Expect(searchIndex.contains("\"href\": \"symbols/"))
        @Expect(!searchIndex.contains("index.html#"))
        @Expect(!searchIndex.contains("basic.Parser.hidden"))
        @Expect(artifactContent(externalArtifacts, "html/index.html").contains(
            "<script defer src=\"search-index.js\"></script><script defer src=\"search.js\""))
        @Expect(externalHtml.contains("<h2>Functions</h2>"))
        @Expect(externalHtml.contains("Content-Security-Policy"))
    }

    @TestCase
    func renderersUseMarkdownAstAsTheOnlyDocumentationSource(): Unit {
        let markdown = api_model.MarkdownNode("document", children: [api_model.MarkdownNode(
            "paragraph", children: [api_model.MarkdownNode("text", literal: "AST truth")])])
        let documentation = rendererFixture(markdown, "SUMMARY-LIE-<script>alert(1)</script>")
        let html = renderedContent(api_render.HtmlDocumentationRenderer().render(documentation))
        let renderedMarkdown = renderedContent(
            api_render.MarkdownDocumentationRenderer().render(documentation))
        @Expect(html.contains("AST truth"))
        @Expect(renderedMarkdown.contains("AST truth"))
        @Expect(!html.contains("SUMMARY-LIE"))
        @Expect(!html.contains("RAW-FIELD-MUST-NOT-RENDER"))
        @Expect(!html.contains("DESCRIPTION-FIELD-MUST-NOT-RENDER"))
        @Expect(!renderedMarkdown.contains("SUMMARY-LIE"))
    }

    @TestCase
    func htmlRoutesSamePackageNamePerModuleWithoutCollisions(): Unit {
        let artifacts = api_render.HtmlDocumentationRenderer().render(
            samePackageAcrossModulesFixture())
        var packageCount: Int64 = 0
        var firstPath = ""
        for (artifact in artifacts) {
            if (!artifact.path.startsWith("html/packages/")) { continue }
            packageCount++
            if (firstPath.isEmpty()) { firstPath = artifact.path } else {
                @Expect(artifact.path != firstPath)
            }
        }
        @Expect(packageCount, 2)
        let index = artifactContent(artifacts, "html/index.html")
        @Expect(index.contains("2 modules, 2 packages, 2 visible declarations"))
        let search = artifactContent(artifacts, "html/search-index.json")
        @Expect(search.contains("shared.first"))
        @Expect(search.contains("shared.second"))
    }

    @TestCase
    func renderersEmitStrictlyValidatedLocalImageAssets(): Unit {
        let markdown = api_model.MarkdownNode("document", children: [api_model.MarkdownNode(
            "paragraph", children: [api_model.MarkdownNode("image", literal: "images/pixel.png",
                children: [api_model.MarkdownNode("text", literal: "pixel")])])])
        let png = api_model.AssetDoc("pixel", "image/png", "images/pixel.png",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let documentation = rendererFixture(markdown, "ignored", assets: [png])
        let htmlArtifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        let markdownArtifacts = api_render.MarkdownDocumentationRenderer().render(documentation)
        let assetPath = "assets/asset-706978656c.png"
        @Expect(renderedContent(htmlArtifacts).contains("../${assetPath}"))
        @Expect(artifactContent(markdownArtifacts, "markdown/docs.md").contains(assetPath))
        var htmlBinary = false
        var markdownBinary = false
        for (artifact in htmlArtifacts) {
            if (artifact.path == "html/${assetPath}") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes[0], 0x89)
                htmlBinary = true
            }
        }
        for (artifact in markdownArtifacts) {
            if (artifact.path == "markdown/${assetPath}") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes[0], 0x89)
                markdownBinary = true
            }
        }
        @Expect(htmlBinary)
        @Expect(markdownBinary)

        let invalidBase64 = rendererFixture(markdown, "ignored", assets: [api_model.AssetDoc(
            "bad", "image/png", "images/bad.png", "!!!!")])
        @ExpectThrows(api_render.HtmlDocumentationRenderer().render(invalidBase64))
        let invalidMagic = rendererFixture(markdown, "ignored", assets: [api_model.AssetDoc(
            "bad", "image/png", "images/bad.png", "AAAA")])
        @ExpectThrows(api_render.MarkdownDocumentationRenderer().render(invalidMagic))
    }

    @TestCase
    func generationBundlesSafeImagesAndReportsMissingAssets(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "local_assets", lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        @Expect(documentation.assets.size, 1)
        @Expect(documentation.assets[0].mediaType, "image/gif")
        @Expect(documentation.assets[0].sourcePath, "src/images/pixel.gif")
        @Expect(documentation.assets[0].id.startsWith("sha256-"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC4026"))
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(encoded.contains("\"literal\": \"sha256-"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let html = api_render.HtmlDocumentationRenderer().render(documentation)
        var bundled = false
        for (artifact in html) {
            if (artifact.mediaType == "image/gif") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes.size > 6)
                bundled = true
            }
        }
        @Expect(bundled)
    }

    @TestCase
    func strictLintAndProviderLifecycleAreObservable(): Unit {
        let strict = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "strict",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(strict, "CJDOC3004") ||
            publicHasDiagnostic(strict, "CJDOC3025"))

        let lifecycle = ProviderLifecycle()
        let provided = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [LifecycleFactory(lifecycle)],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(provided.providers[0].name, "lifecycle-test")
        @Expect(provided.providers[0].version, "2026.08-test")

        let unknown = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [UnknownIdFactory()],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(unknown, "CJDOC2001"))
        @Expect(unknown.declarations.size, 25)

        let related = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [RelationshipFactory()],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var verifiedRelationship = false
        for (declaration in related.declarations) {
            if (declaration.kind == "class" && declaration.name == "Parser") {
                @Expect(declaration.typeRelationships.size, 1)
                @Expect(declaration.typeRelationships[0].target.semantic.state, "resolved")
                @Expect(declaration.symbolRelationships.size, 1)
                @Expect(declaration.symbolRelationships[0].state, "resolved")
                @Expect(declaration.symbolRelationships[0].targetSymbolId.isSome())
                verifiedRelationship = true
            }
        }
        @Expect(verifiedRelationship)
    }

    @TestCase
    func providerBatchesCommitPerModuleOnlyAfterClose(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
            providerFactories: [WorkspaceTransactionFactory(lifecycle)],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 2)
        @Expect(lifecycle.analyzed, 2)
        @Expect(lifecycle.closed, 2)
        @Expect(documentation.providers.size, 2)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        var unavailableModules: Int64 = 0
        var partialModules: Int64 = 0
        for (provider in documentation.providers) {
            if (provider.state == "unavailable") { unavailableModules++ }
            if (provider.state == "partial") { partialModules++ }
        }
        @Expect(unavailableModules, 1)
        @Expect(partialModules, 1)

        var unavailableDeclarations: Int64 = 0
        var partialDeclarations: Int64 = 0
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable") { unavailableDeclarations++ }
            if (declaration.semantic.state == "partial") { partialDeclarations++ }
        }
        @Expect(unavailableDeclarations > 0)
        @Expect(partialDeclarations > 0)
    }

    @TestCase
    func providerCloseFailureDiscardsStagedModuleBatch(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [CloseFailureFactory(lifecycle)],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(documentation.providers[0].state, "unavailable")
        for (declaration in documentation.declarations) {
            @Expect(declaration.semantic.state, "unavailable")
        }
    }

    @TestCase
    func providerAnnotationsOverlaySourceFactsWithProvenance(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
            providerFactories: [AnnotationFactory()],
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var checked = false
        for (declaration in documentation.declarations) {
            if (declaration.name != "oldParse") { continue }
            var hasSource = false
            var hasProvider = false
            for (annotation in declaration.annotations) {
                if (annotation.provenance == "source" && annotation.spelling.startsWith("@Deprecated")) {
                    hasSource = true
                }
                if (annotation.provenance == "provider" && annotation.spelling == "@ProviderMeta" &&
                    annotation.provider == Some("annotation-test")) {
                    hasProvider = true
                }
            }
            @Expect(hasSource)
            @Expect(hasProvider)
            checked = true
        }
        @Expect(checked)
    }
}
