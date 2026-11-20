package cjdoc.render

import cjdoc.model.*
import std.collection.*
import markdown.{MarkdownEngine, MarkdownProfile}
import std.unittest.*
import std.unittest.testmacro.*

private let RENDERER_SAFETY_MARKDOWN_PAGE = "markdown/" +
    markdownPackagePagePath("cjdoc:module:v1:renderer-safety", "fixture")

private func rendererSafetyDocumentation(markdown: MarkdownNode,
    tags!: Array<DocTag> = [], annotations!: Array<AnnotationDoc> = []): DocumentationSet {
    let moduleId = "cjdoc:module:v1:renderer-safety"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:api#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment("raw", "summary", "", markdown, tags: tags)), annotations: annotations)
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("renderer-safety"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "renderer-safety", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol])
}

private func rendererSafetyContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts) { if (artifact.path == path) { return artifact.content } }
    throw IllegalArgumentException("missing renderer safety artifact '${path}'")
}

// The published declaration body lives at its canonical directory index. The
// historical `symbols/symbol-*.html` files are redirect aliases, never bodies.
private func rendererSafetyRoutes(documentation: DocumentationSet): RenderProjection {
    RenderProjection(documentation, buildApiRoutes: true)
}

private func rendererSafetyPage(artifacts: Array<RenderArtifact>,
    documentation: DocumentationSet, symbolId: String): String {
    let path = rendererSafetyRoutes(documentation).symbolFileHref(symbolId)
    rendererSafetyContent(artifacts, "html/" + path)
}

private func rendererSafetyText(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        if (!artifact.isBinary && !artifact.path.startsWith("html/agent/") &&
            (artifact.path.endsWith(".html") || artifact.path.endsWith(".md"))) {
            out.append(artifact.content)
        }
    }
    out.toString()
}

private func rendererSafetyFenceMarks(marker!: String = "~",
    count!: Int64 = DOC_IR_MAX_FENCE_LENGTH): String {
    let out = StringBuilder()
    var index: Int64 = 0
    while (index < count) { out.append(marker); index++ }
    out.toString()
}

private func rendererOwnerDocumentation(ownerKind: String,
    ownerDocumentation!: ?DocComment = None,
    memberDocumentation!: ?DocComment = None): DocumentationSet {
    let moduleId = "cjdoc:module:v1:owner-validation"
    let ownerId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aowner-validation::fixture::class:Owner#g0()"
    let memberId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aowner-validation::fixture::Owner::function:member#g0()"
    let source = SourceRange("src/owner.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, 24, 23))
    let owner = SymbolDoc(ownerId, ownerKind, "Owner", "fixture.Owner", "fixture", moduleId,
        "public", source, "public ${ownerKind} Owner", SemanticInfo("partial", "ast"),
        documentation: ownerDocumentation)
    let member = SymbolDoc(memberId, "function", "member", "fixture.Owner.member", "fixture",
        moduleId, "public", source, "public func member(): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        documentation: memberDocumentation)
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("owner-validation"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "owner-validation", "root", "",
            packageNames: ["fixture"])], packages: [PackageDoc("fixture", moduleId,
            sourceFiles: ["src/owner.cj"], symbolIds: [ownerId, memberId])],
        files: [FileDoc("src/owner.cj", moduleId, "fixture")], declarations: [owner, member])
}

private func hiddenAssetDocumentation(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:hidden-asset"
    let publicId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ahidden-asset::fixture::function:visible#g0()"
    let privateId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ahidden-asset::fixture::function:hidden#g0()"
    let assetId =
        "sha256-431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, 24, 23))
    let semantic = SemanticInfo("partial", "ast")
    let visible = SymbolDoc(publicId, "function", "visible", "fixture.visible", "fixture",
        moduleId, "public", source, "public func visible(): Unit", semantic)
    let hiddenMarkdown = MarkdownNode("document", children: [
        MarkdownNode("paragraph", children: [MarkdownNode("image", literal: assetId,
            children: [MarkdownNode("text", literal: "hidden diagram")])])
    ])
    let hidden = SymbolDoc(privateId, "function", "hidden", "fixture.hidden", "fixture",
        moduleId, "private", source, "private func hidden(): Unit", semantic,
        documentation: Some(DocComment("hidden", "hidden", "", hiddenMarkdown)))
    let asset = AssetDoc(assetId, "image/png", "src/images/hidden.png",
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("hidden-asset"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "hidden-asset", "root", "",
            packageNames: ["fixture"])], packages: [PackageDoc("fixture", moduleId,
            sourceFiles: ["src/api.cj"], symbolIds: [publicId, privateId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: [visible, hidden], assets: [asset])
}

@Test
class RendererSafetyTest {
    @TestCase
    func resourceFallbackKeepsItsDiagnosticVisible(): Unit {
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("resource-limited"), ConfigurationSnapshot(),
            diagnostics: [Diagnostic("warning", "CJDOC3027", "Resource limit reached")])
        let index = rendererSafetyContent(HtmlDocumentationRenderer().render(documentation), "html/index.html")
        @Expect(index.contains("No API declarations are available for this audience."))
        // A partial generation opens its status block; diagnostics are listed
        // under the build-status disclosure as before.
        @Expect(index.contains("<details class=\"cj-disclosure cj-generation\" open>"), true)
        @Expect(index.contains("<details id=\"diagnostics\" class=\"cj-disclosure cj-generation\">"), true)
        @Expect(index.contains("<ul class=\"cj-diagnostics\">"), true)
        @Expect(index.contains("CJDOC3027"))
    }

    @TestCase
    func rendererFactorySupportsEveryDocumentedFormat(): Unit {
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"))
        let expectations = [
            ("json", "docs.json"),
            ("markdown", "markdown/index.md"),
            ("html", "html/index.html"),
            ("api-surface", "api-surface/api-surface.json"),
            ("coverage", "coverage/coverage.json"),
            ("symbol-index", "symbol-index/symbol-index.json")
        ]
        for ((format, path) in expectations) {
            let renderer = rendererFor(format)
            @Expect(renderer.format, format)
            @Expect(renderer.render(documentation)[0].path, path)
        }
    }

    @TestCase
    func symbolIndexPublishesStableReferenceTargets(): Unit {
        let targetId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:api#g0()"
        let tags = [DocTag("see", "fixture.api", "", referenceState: "resolved",
            targetSymbolId: Some(targetId))]
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"), tags: tags)
        let artifact = SymbolIndexDocumentationRenderer().render(documentation)[0]
        @Expect(artifact.path, "symbol-index/symbol-index.json")
        @Expect(artifact.content.contains("cjdoc.symbol-index/2"), true)
        @Expect(artifact.content.contains("\"targetId\":\"${targetId}\""), true)
    }

    @TestCase
    func semanticLinkMetadataRendersConsistentlyAndHtmlPublishesIndex(): Unit {
        let targetId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:api#g0()"
        let target = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(
            "fixture.api", "resolved", targetSymbolId: Some(targetId),
            externalUrl: Some("symbols/target-id.html")),
            literal: "fixture.api", children: [MarkdownNode("text", literal: "API")])
        let document = rendererSafetyDocumentation(MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [target])
        ]))
        let pagePath = rendererSafetyRoutes(document).symbolFileHref(
            document.declarations[0].id)
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(document),
            RENDERER_SAFETY_MARKDOWN_PAGE)
        let htmlPages = rendererSafetyText(HtmlDocumentationRenderer().render(document))
        let html = rendererSafetyContent(HtmlDocumentationRenderer().render(document),
            "html/symbol-index.json")
        // The author-supplied external URL is rebased from the body's real depth.
        @Expect(htmlPages.contains("<a class=\"cj-type-link\" href=\"" +
            pageRootPrefix(pagePath) + "symbols/target-id.html\">API</a>"), true)
        @Expect(!htmlPages.contains("data-reference-state"), true)
        @Expect(markdown.contains("<a id=\"symbol-${htmlStableSlug(targetId)}\"></a>"), true)
        @Expect(markdown.contains("[API](#symbol-${htmlStableSlug(targetId)})"), true)
        @Expect(html.contains("\"href\":\"" + pagePath + "\""), true)
        @Expect(rendererSafetyContent(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document"))),
            "html/search-index.json").contains("cjdoc"), true)
    }

    @TestCase
    func semanticLinkStatesRenderLocalizedStatusBesideTheirChildren(): Unit {
        for (state in ["unresolved", "ambiguous", "unavailable"]) {
            for (locale in ["en", "zh-CN"]) {
                let node = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(
                    "fixture.api", state),
                    children: [MarkdownNode("text", literal: "API")])
                let html = renderStandaloneMarkdownHtml(
                    MarkdownNode("document", children: [MarkdownNode("paragraph", children: [node])]),
                    locale: locale)
                @Expect(html.contains("API<span class=\"cj-state-note\" data-reference-state=\"" +
                    state + "\">"), true)
            }
        }
    }

    @TestCase
    func resolvedUnsafeExternalSemanticLinkIsNotMarkedUnresolved(): Unit {
        let node = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(
            "fixture.api", "resolved", externalUrl: Some("javascript:alert(1)")),
            children: [MarkdownNode("text", literal: "API")])
        let html = renderStandaloneMarkdownHtml(
            MarkdownNode("document", children: [MarkdownNode("paragraph", children: [node])]))
        @Expect(html.contains("API"), true)
        @Expect(!html.contains("href=\"javascript:"))
        @Expect(!html.contains("data-reference-state"))
    }

    @TestCase
    func semanticLinkStatusSurvivesInsideTagMarkdown(): Unit {
        let node = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(
            "fixture.api", "ambiguous"),
            children: [MarkdownNode("text", literal: "related API")])
        let tag = DocTag("return", "", "Result details", descriptionMarkdown: Some(
            MarkdownNode("document", children: [MarkdownNode("paragraph", children: [node])])))
        let html = rendererSafetyText(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document"), tags: [tag])))
        @Expect(html.contains("related API<span class=\"cj-state-note\" " +
            "data-reference-state=\"ambiguous\">"), true)
    }
    @TestCase
    func reExportSearchSignaturesUseTokenIdentityAndPreserveUnavailableSource(): Unit {
        let moduleId = "cjdoc:module:v1:renderer-exposure"
        let availableId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-exposure::fixture::function:pub#g0()"
        let unavailableId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-exposure::fixture::function:opaque#g0()"
        let availableRaw = "public func pub(): Unit"
        let unavailableRaw = "public func opaque(): Unit"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0),
            SourcePosition(1, availableRaw.size + 1, availableRaw.size))
        let availableTokens = ["PUBLIC:6:public", "FUNC:4:func", "IDENTIFIER:3:pub",
            "LPAREN:1:(", "RPAREN:1:)", "COLON:1::", "IDENTIFIER:4:Unit"]
        let available = SymbolDoc(availableId, "function", "pub", "fixture.pub", "fixture",
            moduleId, "public", source, availableRaw, SemanticInfo("partial", "ast"),
            sourceApiSignature: SourceApiSignature("available", tokens: availableTokens))
        let unavailable = SymbolDoc(unavailableId, "function", "opaque", "fixture.opaque",
            "fixture", moduleId, "public", source, unavailableRaw, SemanticInfo("partial", "ast"),
            sourceApiSignature: SourceApiSignature("unavailable"))
        let reExport = ReExportDoc(
            "cjdoc:reexport:v1:1111111111111111111111111111111111111111111111111111111111111111",
            "single", "fixture", "resolved", source, targetModuleId: Some(moduleId),
            bindings: [
                ReExportBinding("renamedPub", targetSymbolIds: [availableId]),
                ReExportBinding("renamedOpaque", targetSymbolIds: [unavailableId])])
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("renderer-exposure"), ConfigurationSnapshot(lintProfile: "off"),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                SemanticCapabilities(false, false, false, false, false))],
            modules: [ModuleDoc(moduleId, "renderer-exposure", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
                symbolIds: [availableId, unavailableId], reExports: [reExport])],
            files: [FileDoc("src/api.cj", moduleId, "fixture")],
            declarations: [available, unavailable])
        let searchIndexScript = rendererSafetyContent(
            HtmlDocumentationRenderer().render(documentation), "html/search-index.js")
        @Expect(searchIndexScript.contains("\"public func renamedPub(): Unit\""), true)
        @Expect(searchIndexScript.contains(
            "\"renamedOpaque: public func opaque(): Unit\""), true)
    }
    @TestCase
    func audienceProjectionOmitsAssetsReferencedOnlyByHiddenDeclarations(): Unit {
        let documentation = hiddenAssetDocumentation()
        validateDocumentationSet(documentation)
        for (artifacts in [MarkdownDocumentationRenderer().render(documentation),
            HtmlDocumentationRenderer().render(documentation)]) {
            var binaryArtifacts: Int64 = 0
            for (artifact in artifacts) {
                if (artifact.isBinary) { binaryArtifacts++ }
            }
            @Expect(binaryArtifacts, 0)
            @Expect(!rendererSafetyText(artifacts).contains("hidden diagram"))
        }
    }

    @TestCase
    func ownerMustBeAContainerInTypedAndDecodedDocIr(): Unit {
        let valid = rendererOwnerDocumentation("class")
        validateDocumentationSet(valid)
        @Expect(decodeDocIr(encodeDocIr(valid)).declarations.size, 2)
        @Expect(HtmlDocumentationRenderer().render(valid).size > 0)

        let invalid = rendererOwnerDocumentation("function")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(invalid))
        let invalidJson = encodeDocIr(valid).replace(
            "\"kind\": \"class\"", "\"kind\": \"function\"")
        @Expect(invalidJson != encodeDocIr(valid))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(invalidJson))
    }

    @TestCase
    func headingIdsRemainUniqueWhenNaturalSlugUsesDuplicateSuffix(): Unit {
        let headings = MarkdownNode("document", children: [
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
                children: [MarkdownNode("text", literal: "A")]),
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
                children: [MarkdownNode("text", literal: "A")]),
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
                children: [MarkdownNode("text", literal: "A-1")])
        ])
        let html = rendererSafetyText(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(headings)))

        @Expect(html.contains("--doc-a\""))
        @Expect(html.contains("--doc-a-1\""))
        @Expect(html.contains("--doc-a-1-1\""))
    }

    @TestCase
    func fencedCodeRendersAtTheValidatedUpperBound(): Unit {
        let code = MarkdownNode("document", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("~"), DOC_IR_MAX_FENCE_LENGTH,
                "cangjie", "cangjie", ""), literal: "body")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)), RENDERER_SAFETY_MARKDOWN_PAGE)
        let marks = rendererSafetyFenceMarks()

        @Expect(markdown.contains("${marks}cangjie\nbody\n${marks}"))
    }

    @TestCase
    func markdownCodeUsesAContentSafeDynamicDelimiter(): Unit {
        let code = MarkdownNode("document", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "cangjie", "cangjie", ""), literal: "before ```` after")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)), RENDERER_SAFETY_MARKDOWN_PAGE)

        @Expect(markdown.contains("`````cangjie\nbefore ```` after\n`````"))
    }

    @TestCase
    func markdownCodeFailsClosedWhenNeitherFenceFitsTheBound(): Unit {
        let literal = rendererSafetyFenceMarks(marker: "`") + "\n" +
            rendererSafetyFenceMarks(marker: "~")
        let code = MarkdownNode("document", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "", "", ""), literal: literal)])

        @ExpectThrows[IllegalArgumentException](MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)))
    }

    @TestCase
    func structuredExamplesRenderAsSafeCodeBlocksInBothFormats(): Unit {
        let example = DocTag("example", "Unsafe <input>",
            "Explain the example with <script>alert(2)</script> and " +
            "[run](javascript:alert(5)).\n\n" +
            "```cj\n" +
            "let value = \"<script>alert(1)</script>\"\n" +
            "```")
        let plain = DocTag("example", "Plain text", "<img src=x>")
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"), tags: [example, plain])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(documentation),
            RENDERER_SAFETY_MARKDOWN_PAGE)
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let html = rendererSafetyText(artifacts)
        let css = rendererSafetyContent(artifacts, "html/style.css")

        @Expect(markdown.contains("#### Examples"), true)
        @Expect(markdown.contains("```cj"), true)
        @Expect(markdown.contains(
            "Explain the example with &lt;script&gt;alert\\(2\\)&lt;/script&gt; and"), true)
        @Expect(markdown.contains("\\[run\\]\\(javascript:alert\\(5\\)\\)"), true)
        @Expect(!markdown.contains("[run](javascript:"), true)
        @Expect(markdown.contains("<script>alert(1)</script>"), true)
        @Expect(!markdown.contains("<script>alert(2)</script>"), true)
        @Expect(markdown.contains("&lt;img src\\=x&gt;"), true)
        @Expect(html.contains("<h3>Examples</h3>"), true)
        @Expect(html.contains("class=\"cj-examples\""), true)
        @Expect(html.contains("class=\"cj-example\""), true)
        @Expect(html.contains("class=\"cj-example__title\""), true)
        @Expect(html.contains("data-language=\"cangjie\""), true)
        @Expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), true)
        @Expect(html.contains("&lt;img src=x&gt;"), true)
        @Expect(!html.contains("<code><script>alert(1)"), true)
        @Expect(css.contains(".cj-examples"), true)

        let decoded = decodeDocIr(encodeDocIr(documentation))
        let decodedComment = decoded.declarations[0].documentation.getOrThrow()
        var exampleCount: Int64 = 0
        for (tag in decodedComment.tags) { if (tag.name == "example") { exampleCount++ } }
        @Expect(exampleCount, 2)
    }

    @TestCase
    func exampleFenceIndentationMatchesMarkdownRules(): Unit {
        let valid = DocTag("example", "Three spaces", "   ```cj\nsafe()\n   ```")
        let invalid = DocTag("example", "Four spaces",
            "    ```cj\nsafe()\n<script>alert(3)</script>")
        let invalidInfo = DocTag("example", "Backtick info",
            "```cj`invalid\n<script>alert(4)</script>")
        let unterminated = DocTag("example", "Unterminated", "```cj\nsafe()")
        let hiddenWhitespace = DocTag("example", "Hidden whitespace",
            "\r\t```cj\nsafe()\n<script>alert(6)</script>")
        let carriageReturnBoundary = DocTag("example", "CR boundary",
            "```cj\nsafe()\n```\r<script>alert(7)</script>")
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"),
            tags: [valid, invalid, invalidInfo, unterminated, hiddenWhitespace,
                carriageReturnBoundary,
                DocTag("param", "value", "parameter")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(documentation),
            RENDERER_SAFETY_MARKDOWN_PAGE)
        let html = rendererSafetyText(HtmlDocumentationRenderer().render(documentation))

        @Expect(markdown.contains("   ```cj"), true)
        @Expect(markdown.contains("&lt;script&gt;alert\\(3\\)&lt;/script&gt;"), true)
        @Expect(!markdown.contains("<script>alert(3)</script>"), true)
        @Expect(markdown.contains("&lt;script&gt;alert\\(4\\)&lt;/script&gt;"), true)
        @Expect(!markdown.contains("<script>alert(4)</script>"), true)
        @Expect(markdown.contains("safe()\n```\n\n##### Hidden whitespace"), true)
        @Expect(markdown.contains("&lt;script&gt;alert\\(6\\)&lt;/script&gt;"), true)
        @Expect(!markdown.contains("<script>alert(6)</script>"), true)
        @Expect(markdown.contains("&lt;script&gt;alert\\(7\\)&lt;/script&gt;"), true)
        @Expect(!markdown.contains("<script>alert(7)</script>"), true)
        @Expect(html.contains("<pre class=\"cj-code__pre\"><code"), true)
        @Expect(html.contains("&lt;script&gt;alert(3)&lt;/script&gt;"), true)
        @Expect(!html.contains("<script>alert(3)</script>"), true)
        @Expect(!html.contains("<script>alert(6)</script>"), true)
        @Expect(!html.contains("<script>alert(7)</script>"), true)
    }

    @TestCase
    func htmlPromotesSummaryWithoutRepeatingTheOpeningParagraph(): Unit {
        let markdown = MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [
                MarkdownNode("text", literal: "Unique summary text. "),
                MarkdownNode("text", literal: "<script>alert(9)</script>")
            ]),
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Additional details.")])
        ])
        let documentation = rendererSafetyDocumentation(markdown)
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let symbol = documentation.declarations[0]
        let html = rendererSafetyPage(artifacts, documentation, symbol.id)

        @Expect(html.split("Unique summary text.").size, 2)
        @Expect(html.contains("<p>Additional details.</p>"), true)
        @Expect(html.contains("&lt;script&gt;alert(9)&lt;/script&gt;"), true)
        @Expect(!html.contains("<script>alert(9)</script>"), true)
    }

    @TestCase
    func htmlNavigationMarksCurrentPackageAndHidesEmptyToc(): Unit {
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"))
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let packagePath = "html/${packagePagePath("cjdoc:module:v1:renderer-safety", "fixture")}"
        let packageHtml = rendererSafetyContent(artifacts, packagePath)

        // Currentness is ARIA, not a class: sidebarPageIsCurrent never marks a
        // link that carries a fragment, and the ancestor modifier only marks the
        // package branch that contains the current page.
        @Expect(packageHtml.contains("<a class=\"cj-tree__link\" data-cjdoc-nav-link " +
            "aria-current=\"page\" href=\"../packages/"), true)
        @Expect(packageHtml.contains("data-cjdoc-sidebar-tree"), true)
        let symbol = documentation.declarations[0]
        let symbolPath = rendererSafetyRoutes(documentation).symbolFileHref(symbol.id)
        let functionPage = rendererSafetyContent(artifacts, "html/" + symbolPath)
        // Only the current package's types are server-rendered; the function page
        // keeps the package branch and its own symbol link in that branch.
        @Expect(functionPage.contains("<a class=\"cj-tree__link cj-tree__link--ancestor\" " +
            "data-cjdoc-nav-link href=\"" + pageRootPrefix(symbolPath) + "packages/"), true)
        @Expect(functionPage.contains("<a class=\"cj-tree__link\" data-cjdoc-nav-link " +
            "aria-current=\"page\" href=\"" + pageRootPrefix(symbolPath) + symbolPath + "\""), true)
        @Expect(functionPage.contains("data-cjdoc-tree-item=\"package\""), true)
        @Expect(functionPage.contains("data-cjdoc-tree-item=\"type\""), true)
        // The old "In this package" context rail is gone; the tree replaces it.
        @Expect(!functionPage.contains("data-cjdoc-sidebar-package"), true)
        @Expect(packageHtml.contains("aria-current=\"page\""), true)
        @Expect(packageHtml.contains(
            "<aside class=\"cj-toc\" data-cjdoc-toc aria-label=\"On this page\" hidden>"), true)

        // Package pages keep their declaration-group anchors and expose the
        // compact declaration table instead of the old signature rows.
        @Expect(packageHtml.contains("<section class=\"cj-decl-group\">"), true)
        @Expect(packageHtml.contains("<table class=\"cj-decl-table\">"), true)
        @Expect(packageHtml.contains("<tr class=\"cj-decl-table__row\" data-cjdoc-member " +
            "data-member-symbol-id="), true)
        @Expect(packageHtml.contains("<td class=\"cj-decl-table__summary\">"), true)
        @Expect(!packageHtml.contains("data-cjdoc-source"), true)
        @Expect(!packageHtml.contains("semantic: resolved"), true)
        @Expect(!packageHtml.contains("src/fixture.cj:1:"), true)
        @Expect(packageHtml.contains("data-cjdoc-sidebar-filter"), true)
        @Expect(packageHtml.contains("data-cjdoc-menu"), true)
        @Expect(packageHtml.contains("data-cjdoc-menu-backdrop"), true)

        let containerDocumentation = rendererOwnerDocumentation("class")
        let containerArtifacts = HtmlDocumentationRenderer().render(containerDocumentation)
        let symbolHtml = rendererSafetyPage(containerArtifacts, containerDocumentation,
            containerDocumentation.declarations[0].id)
        @Expect(symbolHtml.contains("<span class=\"cj-kind\" data-kind=\"class\">"), true)
        // The API reference layout must use real projected symbols, never a
        // hardcoded demonstration or repeated public badges.
        @Expect(symbolHtml.contains("data-cjdoc-page=\"symbol\""), true)
        @Expect(symbolHtml.contains("<span class=\"cj-header__project\">" +
            containerDocumentation.project.name + "</span>"), true)
        @Expect(symbolHtml.contains("data-cjdoc-search-trigger"), true)
        @Expect(symbolHtml.contains("<kbd class=\"cj-kbd\" data-cjdoc-search-shortcut>Ctrl K</kbd>"), true)
        @Expect(symbolHtml.contains("data-cjdoc-tree-item=\"type\""), true)
        @Expect(symbolHtml.contains("<a class=\"cj-tree__link\" data-cjdoc-nav-link " +
            "aria-current=\"page\""), true)
        @Expect(symbolHtml.contains("<span id=\"declaration\" class=\"cj-anchor-alias\"></span>"), true)
        @Expect(symbolHtml.contains("<div class=\"cj-member-group__head\">"), true)
        @Expect(symbolHtml.contains("<span class=\"cj-member-group__count\">"), true)
        @Expect(symbolHtml.contains("data-cjdoc-toc-role=\"member\""), true)
        @Expect(!symbolHtml.contains("semantic: resolved"), true)
        @Expect(!symbolHtml.contains("top-source-disabled"), true)
        @Expect(symbolHtml.contains(
            "<h1 class=\"cj-page-header__title\" data-cjdoc-toc-role=\"api-root\" " +
            "data-cjdoc-toc-label=\"class Owner\">"), true)
        @Expect(symbolHtml.contains(
            "<div class=\"cj-member-row\"><details class=\"cj-member\" id=\"symbol-"), true)
        @Expect(symbolHtml.contains("data-cjdoc-member data-member-name=\"member\""), true)
        @Expect(symbolHtml.contains(
            "<div class=\"cj-member-actions\" role=\"group\" aria-label=\"Member actions\""), true)
        @Expect(symbolHtml.contains("class=\"cj-member-actions__item " +
            "cj-member-actions__item--standalone\""), true)
        @Expect(symbolHtml.contains("class=\"cj-member-actions__item " +
            "cj-member-actions__item--copy\""), true)
        @Expect(symbolHtml.contains("aria-label=\"Open standalone API page\" " +
            "title=\"Open standalone API page\""), true)
        @Expect(symbolHtml.contains("aria-label=\"Copy link\" title=\"Copy link\""), true)
        @Expect(symbolHtml.contains("<svg class=\"cj-icon\""), true)
        @Expect(symbolHtml.contains("aria-hidden=\"true\" focusable=\"false\""), true)
        @Expect(symbolHtml.contains("data-cjdoc-copy-status role=\"status\""), true)
        @Expect(symbolHtml.contains("role=\"status\" aria-live=\"polite\""), true)
        @Expect(symbolHtml.contains("</div></details><div class=\"cj-member-actions\""), true)
        @Expect(symbolHtml.contains("data-cjdoc-member-actions-toggle aria-expanded=\"false\""), true)
        @Expect(symbolHtml.contains("aria-controls=\"symbol-"), true)
        @Expect(symbolHtml.contains("<summary class=\"cj-member__summary\" id=\"symbol-"), true)
        @Expect(symbolHtml.contains("-summary\" data-cjdoc-toc-role=\"member\""), true)
        @Expect(symbolHtml.contains("data-cjdoc-toc-label=\"member()"), true)
        @Expect(symbolHtml.contains("aria-labelledby=\"symbol-"), true)
    }

    @TestCase
    func memberActionLabelsKeepUntrustedSummaryAsText(): Unit {
        let attack = "</summary><img src=x onerror=alert(1)>"
        let comment = DocComment(attack, attack, "", MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: attack)])
        ]))
        let documentation = rendererOwnerDocumentation("class",
            memberDocumentation: Some(comment))
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let owner = documentation.declarations[0]
        let member = documentation.declarations[1]
        let html = rendererSafetyPage(artifacts, documentation, owner.id)
        let routes = rendererSafetyRoutes(documentation)
        let canonical = routes.symbolFileHref(owner.id)
        @Expect(html.contains("<img src=x onerror=alert(1)>"), false)
        @Expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"), true)
        // A type page's inline member action names that member's own body,
        // resolved from the type page's real depth rather than its own page.
        let memberDestination = pageRootPrefix(canonical) + routes.symbolFileHref(member.id)
        @Expect(memberDestination != pageRootPrefix(canonical) + canonical, true)
        @Expect(html.contains("data-cjdoc-copy-link=\"" + memberDestination + "\""), true)
    }

    @TestCase
    func readableAliasesKeepStableRoutesAndEscapeSourceNames(): Unit {
        let documentation = rendererOwnerDocumentation("class")
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let owner = documentation.declarations[0]
        let routes = rendererSafetyRoutes(documentation)
        let canonical = routes.symbolFileHref(owner.id)
        let alias = symbolReadablePagePath(owner)
        @Expect(alias.startsWith("symbols/fixture-Owner-"), true)
        @Expect(!rendererSafetyContent(artifacts, "html/" + canonical).isEmpty(), true)
        // Both historical links are redirects to the canonical body, never bodies.
        for (historical in [alias, symbolPagePath(owner)]) {
            let aliasHtml = rendererSafetyContent(artifacts, "html/" + historical)
            @Expect(aliasHtml.contains("data-cjdoc-route=\"symbol-alias\""), true)
            @Expect(!aliasHtml.contains("cj-signature"), true)
            @Expect(aliasHtml.contains(pageRootPrefix(historical) + canonical), true)
        }
        let unsafeName = "中文.<script>\"&Owner"
        let first = SymbolDoc("alias-one", "function", "api", unsafeName, "fixture", owner.moduleId,
            "public", owner.source, "public func api(): Unit", SemanticInfo("partial", "ast"))
        let overload = SymbolDoc("alias-two", "function", "api", unsafeName, "fixture", owner.moduleId,
            "public", owner.source, "public func api(value: Int64): Unit", SemanticInfo("partial", "ast"))
        @Expect(symbolReadablePagePath(first) != symbolReadablePagePath(overload), true)
        for (byte in symbolReadablePagePath(first).toArray()) { @Expect(byte < 0x80, true) }
        let unsafeAlias = renderSymbolAlias(first, "zh-CN", symbolReadablePagePath(first),
            "fixture/api/index.html", "")
        @Expect(unsafeAlias.contains("<script>\"&Owner"), false)
        @Expect(unsafeAlias.contains("&lt;script&gt;&quot;&amp;Owner"), true)
        let longName = rendererSafetyFenceMarks(marker: "a", count: 47) + ".b"
        let longSymbol = SymbolDoc("alias-long", "function", "api", longName, "fixture", owner.moduleId,
            "public", owner.source, "public func api(): Unit", SemanticInfo("partial", "ast"))
        let readable = symbolReadablePagePath(longSymbol).removePrefix("symbols/").removeSuffix(
            "-${stableFileHash(longSymbol.id)}.html")
        @Expect(readable.size <= 48, true)
    }

    @TestCase
    func htmlMemberReadingStartsWithTheTypeAndKeepsOneCompleteInlineSignature(): Unit {
        let introduction = DocComment("raw", "", "", MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "A compact type summary.")]),
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "No internal synchronization.")])
        ]), tags: [DocTag("precondition", "", "Callers coordinate concurrent access."),
            DocTag("example", "", "Example after members.")])
        let documentation = rendererOwnerDocumentation("class", ownerDocumentation: Some(introduction))
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let html = rendererSafetyPage(artifacts, documentation,
            documentation.declarations[0].id)
        let mainHtml = html[html.indexOf("<main ").getOrThrow()..]
        let memberBrowserAt = mainHtml.indexOf("<section class=\"cj-members\" " +
            "data-cjdoc-member-browser").getOrThrow()
        @Expect(mainHtml.contains("sibling-members"), false)
        // The type page shows the member once, as a native disclosure whose
        // summary is the linked signature; no second copy sits above it.
        @Expect(mainHtml.split("data-member-symbol-id=").size, 2)
        @Expect(mainHtml.split("<code class=\"cj-signature-inline cj-member__signature\">").size, 2)
        @Expect(mainHtml.indexOf("<header class=\"cj-page-header cj-page-header--api\">")
            .getOrThrow() < memberBrowserAt, true)
        @Expect(mainHtml.contains("declaration-metadata"), false)
        @Expect(mainHtml.contains("Symbol ID"), false)
        @Expect(mainHtml.contains("Semantic information"), false)
        @Expect(mainHtml.indexOf("No internal synchronization.").getOrThrow() < memberBrowserAt, true)
        @Expect(mainHtml.indexOf("Callers coordinate concurrent access.").getOrThrow() <
            memberBrowserAt, true)
        @Expect(mainHtml.indexOf("Example after members.").getOrThrow() > memberBrowserAt, true)
        @Expect(mainHtml.split("A compact type summary.").size, 2)
        @Expect(html.contains("<a class=\"cj-skip-link\" href=\"#cjdoc-main\">"), true)
        @Expect(html.contains("id=\"cjdoc-main\""), true)
    }

    @TestCase
    func readerPagesShowRelationshipsWithoutRawDeclarationDiagnostics(): Unit {
        let moduleId = "cjdoc:module:v1:reader-relationships"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0),
            SourcePosition(1, 24, 23))
        let contractId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areader-relationships::fixture::interface:Readable#g0()"
        let ownerId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areader-relationships::fixture::class:TextReader#g0()"
        let secretId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areader-relationships::fixture::class:PrivateReader#g0()"
        let contract = SymbolDoc(contractId, "interface", "Readable", "fixture.Readable",
            "fixture", moduleId, "public", source, "public interface Readable",
            SemanticInfo("partial", "ast"))
        let privateReader = SymbolDoc(secretId, "class", "PrivateReader", "fixture.PrivateReader",
            "fixture", moduleId, "private", source, "private class PrivateReader",
            SemanticInfo("partial", "ast"))
        let reader = SymbolDoc(ownerId, "class", "TextReader", "fixture.TextReader",
            "fixture", moduleId, "public", source, "public class TextReader <: Readable",
            SemanticInfo("partial", "ast"), typeRelationships: [
                TypeRelationship("superType", TypeRef("named", "Readable",
                    SemanticType("partial", provider: Some("ast")))),
                // A resolved semantic TypeRef and the symbol edge both point
                // to a filtered declaration. Neither may leak its spelling.
                TypeRelationship("extendedBy", TypeRef("named", "fixture.PrivateReader",
                    SemanticType("resolved", canonical: Some("fixture.PrivateReader"),
                        provider: Some("ast")))),
                // These valid module-qualified canonical names still denote the
                // hidden target although neither display matches its qualified name.
                TypeRelationship("extendedBy", TypeRef("named", "SecretAlias",
                    SemanticType("resolved",
                        canonical: Some("reader-relationships.fixture.PrivateReader"),
                        provider: Some("ast")))),
                TypeRelationship("extendedBy", TypeRef("named", "RelativeAlias",
                    SemanticType("resolved",
                        canonical: Some("reader-relationships.PrivateReader"),
                        provider: Some("ast"))))
            ], symbolRelationships: [
                SymbolRelationship("superType", "Readable", "resolved",
                    targetSymbolId: Some(contractId)),
                SymbolRelationship("implements", "fixture.Readable", "resolved",
                    targetSymbolId: Some(contractId)),
                SymbolRelationship("extendedBy", "fixture.PrivateReader", "resolved",
                    targetSymbolId: Some(secretId))
            ])
        let document = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("reader-relationships"), ConfigurationSnapshot(audience: "external"),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                SemanticCapabilities(false, false, false, true, false, relationships: true))],
            modules: [ModuleDoc(moduleId, "reader-relationships", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
                symbolIds: [contractId, ownerId, secretId])],
            files: [FileDoc("src/api.cj", moduleId, "fixture")],
            declarations: [contract, reader, privateReader])
        // The full index has the private target even though the published
        // projection must not. Identity comparison cannot depend on href.
        let projection = RenderProjection(document, buildApiRoutes: true)
        @Expect(projection.allIndex.contains(secretId), true)
        @Expect(projection.visibleIndex.contains(secretId), false)
        let links = HtmlTypeLinkIndex(document, projection)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[1].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[2].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[3].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[2].target, contractId), false)
        let page = rendererSafetyPage(HtmlDocumentationRenderer().render(document), document,
            reader.id)
        @Expect(page.contains("<section class=\"cj-relations\" " +
            "aria-label=\"Type and member relationships\">"), true)
        @Expect(page.contains("Relationships</h2>"), true)
        @Expect(page.contains("fixture.Readable"), true)
        @Expect(page.contains("Target not present in this documentation"), false)
        @Expect(page.contains("fixture.PrivateReader"), false)
        @Expect(page.contains("SecretAlias"), false)
        @Expect(page.contains("RelativeAlias"), false)
        @Expect(page.contains("Extended by"), false)
        @Expect(page.contains("Parent type"), true)
        // The source TypeRef is partial, but its navigation edge has an exact
        // resolved SymbolId. Render one linked relationship, not both states.
        @Expect(page.split("<dt class=\"cj-relations__term\">Parent type</dt>").size, 2)
        @Expect(page.contains("Relationship not fully established"), false)
        let parentRow = page.split("<dt class=\"cj-relations__term\">Parent type</dt>")[1]
            .split("</dd>")[0]
        @Expect(parentRow.contains("cj-type-link"), true)
        @Expect(parentRow.contains("href=\""), true)
        @Expect(page.contains("Declaration metadata"), false)
        @Expect(page.contains("Symbol ID"), false)
        @Expect(page.contains("Semantic information"), false)
    }

    @TestCase
    func readerRelationshipKindsMatchActualForwardAndReverseEdges(): Unit {
        @Expect(readerRelationshipLabel("override", "en"), "Overrides")
        @Expect(readerRelationshipLabel("overriddenBy", "en"), "Overridden by")
        @Expect(readerRelationshipLabel("implementedBy", "en"), "Implemented by")
        @Expect(readerRelationshipLabel("override", "zh-CN"), "重写")
        @Expect(readerRelationshipLabel("overriddenBy", "zh-CN"), "被重写")
        @Expect(readerRelationshipLabel("implementedBy", "zh-CN"), "被实现")
    }

    @TestCase
    func parameterTypeDisplayCompactsGenericTriviaWithoutChangingSourceSignature(): Unit {
        let moduleId = "cjdoc:module:v1:generic-display"
        let source = SourceRange("src/generic.cj", SourcePosition(1, 1, 0),
            SourcePosition(1, 63, 62))
        let raw = "public func addAll(entries: Array<String>): Unit"
        let symbol = SymbolDoc("cjdoc:v2:cjdoc%3Amodule%3Av1%3Ageneric-display::fixture::function:addAll#g0()",
            "function", "addAll", "fixture.addAll", "fixture", moduleId,
            "public", source, raw, SemanticInfo("partial", "ast"),
            parameters: [ParameterDoc("entries", TypeRef("named", "Array < String >",
                SemanticType("unavailable")), documentation: Some("input array"))],
            documentation: Some(DocComment("raw", "", "", MarkdownNode("document"))))
        let doc = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("generic-display"), ConfigurationSnapshot(),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                SemanticCapabilities(false, false, false, false, false))],
            modules: [ModuleDoc(moduleId, "generic-display", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/generic.cj"],
                symbolIds: [symbol.id])],
            files: [FileDoc("src/generic.cj", moduleId, "fixture")],
            declarations: [symbol])
        let page = rendererSafetyPage(HtmlDocumentationRenderer().render(doc), doc, symbol.id)
        @Expect(page.contains("Array&lt;String&gt;"), true)
        @Expect(page.contains("Array &lt; String &gt;"), false)
        @Expect(page.contains("<pre class=\"cj-signature\" aria-label=\"Signature\"><code"), true)
    }


    @TestCase
    func markdownSerializerPreservesInlineAdjacencyAndEncodesLinkDestinations(): Unit {
        let paragraph = MarkdownNode("paragraph", children: [
            MarkdownNode("text", literal: "left"),
            MarkdownNode("strong", children: [MarkdownNode("text", literal: "mid")]),
            MarkdownNode("text", literal: "right 1. item "),
            MarkdownNode("code_span", literal: "a``b"),
            MarkdownNode("text", literal: " "),
            MarkdownNode("link", literal: "https://example.test/a b)c?q=x y#z",
                children: [MarkdownNode("text", literal: "jump")])
        ])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document", children: [paragraph]))),
            RENDERER_SAFETY_MARKDOWN_PAGE)

        @Expect(markdown.contains("left**mid**right 1\\. item ```a``b```"))
        @Expect(markdown.contains("[jump](https://example.test/a%20b%29c?q=x%20y#z)"))
    }

    @TestCase
    func markdownSerializerPreservesNestedBlocksListsAndTables(): Unit {
        let item = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("notTask"),
            children: [MarkdownNode("paragraph", children: [
                MarkdownNode("text", literal: "alpha")])])
        let list = MarkdownNode("list", MarkdownNodeMetadata.forList(
            "bullet", 0, "none", true), children: [item])
        let blockQuote = MarkdownNode("block_quote", children: [list])
        let cell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("center"),
            children: [MarkdownNode("text", literal: "A"),
                MarkdownNode("strong", children: [MarkdownNode("text", literal: "B")]),
                MarkdownNode("soft_break"), MarkdownNode("text", literal: "C")])
        let row = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
            children: [cell])
        let table = MarkdownNode("table", MarkdownNodeMetadata.forTable(["center"]),
            children: [row])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document", children: [blockQuote, table]))),
            RENDERER_SAFETY_MARKDOWN_PAGE)

        @Expect(markdown.contains("> - alpha"))
        @Expect(markdown.contains("| A**B**<br>C |\n| :---: |"))
    }

    @TestCase
    func tableCodeSpanPreservesPipesAfterEveryBackslashParity(): Unit {
        let engine = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build()
        for (literal in ["left|right", "\\|", "\\\\|", "\\\\\\|", "|start", "end|"]) {
            let codeCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("none"),
                children: [MarkdownNode("code_span", literal: literal)])
            let textCell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("none"),
                children: [MarkdownNode("text", literal: "next")])
            let row = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
                children: [codeCell, textCell])
            let table = MarkdownNode("table", MarkdownNodeMetadata.forTable(["none", "none"]),
                children: [row])
            let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
                rendererSafetyDocumentation(MarkdownNode("document", children: [table]))),
                RENDERER_SAFETY_MARKDOWN_PAGE)
            var tableLine = ""
            for (line in markdown.split("\n")) {
                if (line.contains("<code>")) { tableLine = line; break }
            }
            let escaped = literal.replace("&", "&amp;").replace("<", "&lt;").
                replace(">", "&gt;").replace("|", "&#124;")
            @Expect(tableLine.contains("<code>${escaped}</code>"))

            let parsed = engine.parse("${tableLine}\n| --- | --- |\n")
            let parsedTable = parsed.document.root().children()[0]
            let parsedRows = parsedTable.children()
            @Expect(parsedRows.size, 1)
            @Expect(parsedRows[0].children().size, 2)
        }
    }

    @TestCase
    func rendererBuffersAndArtifactSetsFailBeforeTheirConfiguredLimits(): Unit {
        @Expect(escapeHtmlWithRenderLimitForTest("&", 5), "&amp;")
        @ExpectThrows[RenderResourceLimitException](
            escapeHtmlWithRenderLimitForTest("&&", 9))

        validateRenderArtifactBudgetForTest([4, 4], 5, 8, 2)
        @ExpectThrows[RenderResourceLimitException](
            validateRenderArtifactBudgetForTest([6], 5, 8, 2))
        @ExpectThrows[RenderResourceLimitException](
            validateRenderArtifactBudgetForTest([4, 4, 1], 5, 8, 3))
        @ExpectThrows[RenderResourceLimitException](
            validateRenderArtifactBudgetForTest([1, 1, 1], 5, 8, 2))
    }

    @TestCase
    func artifactReplacementChargesOnlyTheFinalPayloadAndPreservesFailedWrites(): Unit {
        let artifacts = RenderArtifactCollector(artifactLimit: 8, totalLimit: 10, entryLimit: 2)
        let page = artifacts.addText("page.html", "text/html", "old")
        let other = artifacts.addText("other.txt", "text/plain", "12345")
        artifacts.replaceText(page, "newer")
        @Expect(artifacts.readText(page, 8), "newer")
        @ExpectThrows[RenderResourceLimitException](artifacts.replaceText(page, "larger"))
        @Expect(artifacts.readText(page, 8), "newer")
        @Expect(artifacts.readText(other, 8), "12345")
        artifacts.replaceText(page, "")
        artifacts.replaceText(page, "again")
        @Expect(artifacts.readText(page, 8), "again")
        @ExpectThrows[RenderResourceLimitException](
            artifacts.addText("third.txt", "text/plain", ""))
    }

    @TestCase
    func artifactTextReadsRespectUtf8BytesAndNeverInterpretBinaryEntries(): Unit {
        let artifacts = RenderArtifactCollector()
        let text = artifacts.addText("text.txt", "text/plain", "中\u{0}文")
        @Expect(artifacts.readText(text, 7), "中\u{0}文")
        @ExpectThrows[RenderResourceLimitException](artifacts.readText(text, 6))
        let empty = artifacts.addText("empty.txt", "text/plain", "")
        @Expect(artifacts.readText(empty, 0), "")
        for (bytes in [Array<Byte>(), [UInt8(0), UInt8(0xff)]]) {
            let binary = artifacts.addOwnedBytes("asset.bin", "application/octet-stream", bytes)
            @ExpectThrows[IllegalArgumentException](artifacts.readText(binary, 64))
            @ExpectThrows[IllegalArgumentException](artifacts.replaceText(binary, "text"))
        }
    }

    @TestCase
    func binaryRenderArtifactClonesCallerAndReturnedBuffers(): Unit {
        let caller = [UInt8(1), UInt8(2), UInt8(3)]
        let artifact = RenderArtifact("asset.bin", "application/octet-stream", caller)
        caller[0] = UInt8(9)
        @Expect(artifact.bytes[0], UInt8(1))

        let returned = artifact.bytes
        returned[1] = UInt8(9)
        @Expect(artifact.bytes[1], UInt8(2))
        @Expect(artifact.byteSize, 3)
    }

    @TestCase
    func markdownRendererIncludesLifecycleTags(): Unit {
        let body = MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("text", literal: "body")])])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(body, tags: [
                DocTag("deprecated", "", "use replacement"),
                DocTag("since", "", "1.0"),
                DocTag("author", "", "Ada"),
                DocTag("version", "", "2.0")
            ])), RENDERER_SAFETY_MARKDOWN_PAGE)

        @Expect(markdown.contains("> **Deprecated.** use replacement"))
        @Expect(markdown.contains("#### Since\n\n- 1\\.0"))
        @Expect(markdown.contains("#### Authors\n\n- Ada"))
        @Expect(markdown.contains("#### Version\n\n- 2\\.0"))
    }

    @TestCase
    func onlyTheCapturedStandardAnnotationMarksStatusWithoutProse(): Unit {
        for ((spelling, provenance, expected) in [
            ("@Deprecated[message: \"Use fixture.other\"]", "source", true),
            ("@DeprecatedSoon[message: \"Use fixture.other\"]", "source", false),
            ("@Deprecated", "provider", false)
        ]) {
            let annotation = AnnotationDoc(spelling, provenance: provenance,
                provider: if (provenance == "provider") { Some("ast") } else { None<String> })
            let document = rendererSafetyDocumentation(MarkdownNode("document"), annotations: [annotation])
            let page = rendererSafetyPage(HtmlDocumentationRenderer().render(document), document,
                document.declarations[0].id)
            @Expect(page.contains(">Deprecated</span>"), expected)
            @Expect(!page.contains("class=\"cj-deprecation-note\""))
            @Expect(!page.contains("class=\"cj-replacement\""))
        }
    }

    @TestCase
    func deprecationProseUsesTheSameSafeMarkupAsOtherDocumentation(): Unit {
        let raw = "<img src=x onerror=alert(1)>"
        let prose = MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("html_inline", literal: raw)])])
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"), tags: [
            DocTag("deprecated", "", raw, descriptionMarkdown: Some(prose)),
            DocTag("replacement", "fixture.other", "")
        ])
        let page = rendererSafetyPage(HtmlDocumentationRenderer().render(documentation), documentation,
            documentation.declarations[0].id)
        @Expect(page.contains("class=\"cj-deprecation-note\""))
        @Expect(page.contains("&lt;img src=x onerror=alert(1)&gt;"))
        @Expect(!page.contains(raw))
        @Expect(!page.contains("class=\"cj-replacement\""))
    }

    @TestCase
    func htmlTableAlignmentUsesCspCompatibleClasses(): Unit {
        let cell = MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("right"),
            children: [MarkdownNode("text", literal: "value")])
        let row = MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true),
            children: [cell])
        let table = MarkdownNode("table", MarkdownNodeMetadata.forTable(["right"]),
            children: [row])
        let artifacts = HtmlDocumentationRenderer().render(rendererSafetyDocumentation(
            MarkdownNode("document", children: [table])))
        let html = rendererSafetyText(artifacts)
        let css = rendererSafetyContent(artifacts, "html/style.css")

        @Expect(html.contains("<th class=\"cj-align-right\">"), true)
        @Expect(!html.contains(" style=\""))
        // CSP forbids inline styles, so alignment must come from a class rule.
        @Expect(css.contains(".cj-align-right { text-align: right; }"), true)
    }

    @TestCase
    func searchChaptersLinkToRenderedReturnAndParameterBlocks(): Unit {
        let moduleId = "cjdoc:module:v1:renderer-safety"
        let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:unit#g0()"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
        for (hasReturnDocumentation in [false, true]) {
            let tags = ArrayList<DocTag>()
            tags.add(DocTag("param", "orphan", "No corresponding parameter."))
            if (hasReturnDocumentation) { tags.add(DocTag("return", "", "Return documentation.")) }
            let symbol = SymbolDoc(symbolId, "function", "unit", "fixture.unit", "fixture", moduleId,
                "public", source, "public func unit(): Unit", SemanticInfo("partial", "ast"),
                returnType: Some(TypeRef("source", "Unit", SemanticType("unavailable"))),
                documentation: Some(DocComment("raw", "summary", "", MarkdownNode("document"),
                    tags: tags.toArray())))
            let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
                ProjectInfo("renderer-safety"), ConfigurationSnapshot(lintProfile: "off"),
                providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                    SemanticCapabilities(false, false, false, false, false))],
                modules: [ModuleDoc(moduleId, "renderer-safety", "root", "", packageNames: ["fixture"])],
                packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
                files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol])
            let html = rendererSafetyPage(HtmlDocumentationRenderer().render(documentation),
                documentation, symbol.id)
            let projection = buildDocumentationSearchProjection(DocumentationReadSnapshot(documentation),
                searchStaticProfileName())
            var hasReturnChapter = false
            for (entry in projection.entries) {
                for (section in entry.sections) {
                    @Expect(html.contains("id=\"" + section.anchor + "\""), true)
                    @Expect(section.kind != "parameters", true)
                    if (section.kind == "return") { hasReturnChapter = true }
                }
            }
            @Expect(hasReturnChapter, hasReturnDocumentation)
            @Expect(html.contains("id=\"" + docBlockAnchor(symbol, "return") + "\""),
                hasReturnDocumentation)
        }
    }

}
