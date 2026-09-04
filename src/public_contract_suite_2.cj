package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite2 {
    @TestCase
    func renderersHonorAudienceWithoutChangingDocIr(): Unit {
        let external = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", audience: "external", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let all = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", audience: "all", lintProfile: "off",
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
        @Expect(artifactContent(externalArtifacts, "html/theme-bootstrap.js").contains(
            "globalThis.__CJDOC_THEME__"))
        @Expect(artifactContent(externalArtifacts, "html/search-index.js").startsWith(
            "globalThis.__CJDOC_SEARCH_INDEX__ ="))
        let searchIndex = artifactContent(externalArtifacts, "html/search-index.json")
        @Expect(searchIndex.contains("\"href\": \"symbols/"))
        @Expect(!searchIndex.contains("index.html#"))
        @Expect(!searchIndex.contains("basic.Parser.hidden"))
        @Expect(artifactContent(externalArtifacts, "html/index.html").contains(
            "<script src=\"theme-bootstrap.js\"></script><link rel=\"stylesheet\""))
        @Expect(externalHtml.contains("<h2>Functions</h2>"))
        @Expect(externalHtml.contains("Content-Security-Policy"))
    }

    @TestCase
    func renderersUseMarkdownAstAsTheOnlyDocumentationSource(): Unit {
        let markdown = api_model.MarkdownNode("document",
            children: [api_model.MarkdownNode("paragraph",
                children: [api_model.MarkdownNode("text", literal: "AST truth")])])
        let documentation = rendererFixture(markdown, "SUMMARY-LIE-<script>alert(1)</script>")
        let html = renderedContent(api_render.HtmlDocumentationRenderer().render(documentation))
        let renderedMarkdown = renderedContent(api_render.MarkdownDocumentationRenderer().render(documentation))
        @Expect(html.contains("AST truth"))
        @Expect(renderedMarkdown.contains("AST truth"))
        @Expect(!html.contains("SUMMARY-LIE"))
        @Expect(!html.contains("RAW-FIELD-MUST-NOT-RENDER"))
        @Expect(!html.contains("DESCRIPTION-FIELD-MUST-NOT-RENDER"))
        @Expect(!renderedMarkdown.contains("SUMMARY-LIE"))
    }

    @TestCase
    func htmlRoutesSamePackageNamePerModuleWithoutCollisions(): Unit {
        let artifacts = api_render.HtmlDocumentationRenderer().render(samePackageAcrossModulesFixture())
        var packageCount: Int64 = 0
        var firstPath = ""
        for (artifact in artifacts) {
            if (!artifact.path.startsWith("html/packages/")) {
                continue
            }
            packageCount++
            if (firstPath.isEmpty()) {
                firstPath = artifact.path
            } else {
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
        let markdown = api_model.MarkdownNode("document",
            children: [api_model.MarkdownNode("paragraph",
                children: [api_model.MarkdownNode("image", literal: "images/pixel.png",
                    children: [api_model.MarkdownNode("text", literal: "pixel")])])])
        let png = api_model.AssetDoc("sha256-431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460",
            "image/png", "images/pixel.png",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let documentation = rendererFixture(markdown, "ignored", assets: [png])
        let htmlArtifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        let markdownArtifacts = api_render.MarkdownDocumentationRenderer().render(documentation)
        let assetPath = "assets/asset-7368613235362d34333163656436393136613261323161313536653338373031616665353562626437663838393639666262666335366437666530393964343766323635343630.png"
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

        let invalidBase64 = rendererFixture(markdown, "ignored",
            assets: [api_model.AssetDoc("bad", "image/png", "images/bad.png", "!!!!")])
        @ExpectThrows(api_render.HtmlDocumentationRenderer().render(invalidBase64))
        let invalidMagic = rendererFixture(markdown, "ignored",
            assets: [api_model.AssetDoc("bad", "image/png", "images/bad.png", "AAAA")])
        @ExpectThrows(api_render.MarkdownDocumentationRenderer().render(invalidMagic))
    }

    @TestCase
    func generationBundlesSafeImagesAndReportsMissingAssets(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "local_assets", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        if (!publicLocalAssetEmbeddingEnabled()) {
            @Expect(documentation.assets.size, 0)
            @Expect(publicHasDiagnostic(documentation, "CJDOC4026"))
            return
        }
        @Expect(documentation.assets.size, 1)
        @Expect(documentation.assets[0].mediaType, "image/gif")
        @Expect(documentation.assets[0].sourcePath, "src/images/pixel.gif")
        @Expect(documentation.assets[0].id.startsWith("sha256-"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC4026"))
        var rejectedInvalidContainer = false
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC4026" && diagnostic.message.contains("invalid.gif") &&
                diagnostic.message.contains("container or dimensions are invalid")) {
                rejectedInvalidContainer = true
            }
        }
        @Expect(rejectedInvalidContainer)
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


}
