package cjdoc.render

import cjdoc.model.*
import markdown.{MarkdownEngine, MarkdownProfile}
import std.unittest.*
import std.unittest.testmacro.*

private func rendererSafetyDocumentation(markdown: MarkdownNode,
    tags!: Array<DocTag> = []): DocumentationSet {
    let moduleId = "cjdoc:module:v1:renderer-safety"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:api#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
        "public", source, "public func api(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment("raw", "summary", "", markdown, tags: tags)))
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

private func rendererSafetyText(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        if (!artifact.isBinary) { out.append(artifact.content) }
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
    ownerDocumentation!: ?DocComment = None): DocumentationSet {
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
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId))
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
        @Expect(index.contains("<details class=\"generation-metadata\" open>"))
        @Expect(index.contains("CJDOC3027"))
    }

    @TestCase
    func rendererFactorySupportsEveryDocumentedFormat(): Unit {
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"))
        let expectations = [
            ("json", "docs.json"),
            ("markdown", "markdown/docs.md"),
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
        @Expect(artifact.content.contains("cjdoc.symbol-index/1"), true)
        @Expect(artifact.content.contains("\"targetId\":\"${targetId}\""), true)
    }

    @TestCase
    func semanticLinkMetadataRendersConsistentlyAndHtmlPublishesIndex(): Unit {
        let targetId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::function:api#g0()"
        let target = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(
            "fixture.api", "resolved", targetSymbolId: Some(targetId),
            externalUrl: Some("symbols/target-id.html")),
            literal: "fixture.api", children: [MarkdownNode("text", literal: "API")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [target])
            ]))), "markdown/docs.md")
        let htmlPages = rendererSafetyText(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [target])
            ]))))
        let html = rendererSafetyContent(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [target])
            ]))), "html/symbol-index.json")
        @Expect(htmlPages.contains("<a href=\"../symbols/target-id.html\">API</a>"), true)
        @Expect(markdown.contains("<a id=\"symbol-${htmlStableSlug(targetId)}\"></a>"), true)
        @Expect(markdown.contains("[API](#symbol-${htmlStableSlug(targetId)})"), true)
        @Expect(html.contains("\"href\":\"symbols/"), true)
        @Expect(rendererSafetyContent(HtmlDocumentationRenderer().render(
            rendererSafetyDocumentation(MarkdownNode("document"))),
            "html/search-index.json").contains("cjdoc"), true)
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
            rendererSafetyDocumentation(code)), "markdown/docs.md")
        let marks = rendererSafetyFenceMarks()

        @Expect(markdown.contains("${marks}cangjie\nbody\n${marks}"))
    }

    @TestCase
    func markdownCodeUsesAContentSafeDynamicDelimiter(): Unit {
        let code = MarkdownNode("document", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "cangjie", "cangjie", ""), literal: "before ```` after")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)), "markdown/docs.md")

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
            "markdown/docs.md")
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
        @Expect(html.contains("class=\"example-block\""), true)
        @Expect(html.contains("data-language=\"cangjie\""), true)
        @Expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), true)
        @Expect(html.contains("&lt;img src=x&gt;"), true)
        @Expect(!html.contains("<code><script>alert(1)"), true)
        @Expect(css.contains(".example-list"), true)

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
            "markdown/docs.md")
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
        @Expect(html.contains("<pre><code"), true)
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
        let artifacts = HtmlDocumentationRenderer().render(rendererSafetyDocumentation(markdown))
        let symbol = rendererSafetyDocumentation(markdown).declarations[0]
        let html = rendererSafetyContent(artifacts, "html/${symbolPagePath(symbol)}")

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
        let css = rendererSafetyContent(artifacts, "html/style.css")

        @Expect(packageHtml.contains("<a class=\"sidebar-package is-current\""), true)
        @Expect(packageHtml.contains("aria-current=\"page\""), true)
        @Expect(packageHtml.contains(
            "<aside class=\"toc-panel\" data-cjdoc-toc aria-label=\"On this page\" hidden>"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("toc.hidden = headings.length === 0;"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("semanticMode"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("aria-expanded"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("toc-children"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("setActive(link.dataset.tocTarget)"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("menu.getAttribute(\"aria-expanded\") !== \"true\""), true)
        @Expect(css.contains(".sidebar-package.is-current"), true)
        @Expect(css.contains(".toc-api-row"), true)
        @Expect(css.contains(".toc-toggle"), true)
        @Expect(css.contains(".toc-children"), true)
        @Expect(css.contains(".parameter-row{padding:0;border-bottom:0}"), true)
        @Expect(css.contains(".parameter-type{white-space:normal;overflow-wrap:anywhere}"), true)

        @Expect(packageHtml.contains("class=\"declaration-group\""), true)
        @Expect(packageHtml.contains("class=\"declaration-signature\">public func api(): Unit"), true)
        @Expect(!packageHtml.contains("semantic: resolved"), true)
        @Expect(!packageHtml.contains("src/fixture.cj:1:"), true)
        @Expect(packageHtml.contains("data-cjdoc-sidebar-filter"), true)
        @Expect(packageHtml.contains("data-cjdoc-menu"), true)
        @Expect(packageHtml.contains("data-cjdoc-menu-backdrop"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("event.key !== \"Tab\""), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("closeMenu(true)"), true)

        let containerDocumentation = rendererOwnerDocumentation("class")
        let containerArtifacts = HtmlDocumentationRenderer().render(containerDocumentation)
        let symbolHtml = rendererSafetyContent(containerArtifacts,
            "html/${symbolPagePath(containerDocumentation.declarations[0])}")
        @Expect(symbolHtml.contains("<a class=\"sidebar-package is-current\""), true)
        @Expect(symbolHtml.contains("class=\"symbol-kind\">class"), true)
        @Expect(!symbolHtml.contains("semantic: resolved"), true)
        @Expect(!symbolHtml.contains("top-source-disabled"), true)
        @Expect(symbolHtml.contains(
            "<h1 data-cjdoc-toc-role=\"api-root\" data-cjdoc-toc-label=\"class Owner\">"), true)
        @Expect(symbolHtml.contains(
            "<details class=\"declaration-summary member-detail\""), true)
        @Expect(symbolHtml.contains("data-cjdoc-member"), true)
        @Expect(symbolHtml.contains("class=\"member-detail-actions\" role=\"group\" aria-label=\"Member actions\""), true)
        @Expect(symbolHtml.contains("class=\"member-action member-permalink\""), true)
        @Expect(symbolHtml.contains("class=\"member-action member-action-copy copy-link\""), true)
        @Expect(symbolHtml.contains("aria-label=\"Open standalone API page\" title=\"Open standalone API page\""), true)
        @Expect(symbolHtml.contains("aria-label=\"Copy link\" title=\"Copy link\""), true)
        @Expect(symbolHtml.contains("class=\"member-action-glyph\""), true)
        @Expect(symbolHtml.contains("aria-hidden=\"true\" focusable=\"false\""), true)
        @Expect(symbolHtml.contains("data-cjdoc-copy-status role=\"status\""), true)
        @Expect(symbolHtml.contains("role=\"status\" aria-live=\"polite\""), true)
        // The full page may contain an unrelated, text-labelled copy button.
        // Check only the member toolbar: its actions must stay icon-only.
        let actionMarkup = symbolHtml.split("<div class=\"member-detail-actions\"")[1].split("</div>")[0]
        @Expect(actionMarkup.contains(">Standalone</a>"), false)
        @Expect(actionMarkup.contains(">Copy link</button>"), false)
        @Expect(symbolHtml.contains("class=\"member-action member-source-link\""), false)
        @Expect(symbolHtml.indexOf("</summary><div class=\"member-detail-body\">").getOrThrow() <
            symbolHtml.indexOf("class=\"member-detail-actions\"").getOrThrow(), true)
        @Expect(css.contains(".member-detail .member-detail-actions .member-action-glyph{"), true)
        @Expect(css.contains("min-width:38px;min-height:38px"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("if (iconOnly) {"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("if (status) status.textContent = message;"), true)
    }

    @TestCase
    func readableAliasesKeepStableRoutesAndEscapeSourceNames(): Unit {
        let documentation = rendererOwnerDocumentation("class")
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let owner = documentation.declarations[0]
        let alias = symbolReadablePagePath(owner)
        @Expect(alias.startsWith("symbols/fixture-Owner-"), true)
        @Expect(!rendererSafetyContent(artifacts, "html/${symbolPagePath(owner)}").isEmpty(), true)
        @Expect(rendererSafetyContent(artifacts, "html/${alias}").contains(
            "href=\"${symbolPagePath(owner)["symbols/".size..]}\""), true)
        let unsafeName = "中文.<script>\"&Owner"
        let first = SymbolDoc("alias-one", "function", "api", unsafeName, "fixture", owner.moduleId,
            "public", owner.source, "public func api(): Unit", SemanticInfo("partial", "ast"))
        let overload = SymbolDoc("alias-two", "function", "api", unsafeName, "fixture", owner.moduleId,
            "public", owner.source, "public func api(value: Int64): Unit", SemanticInfo("partial", "ast"))
        @Expect(symbolReadablePagePath(first) != symbolReadablePagePath(overload), true)
        for (byte in symbolReadablePagePath(first).toArray()) { @Expect(byte < 0x80, true) }
        let unsafeAlias = renderSymbolAlias(first, "zh-CN")
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
        let html = rendererSafetyContent(artifacts,
            "html/${symbolPagePath(documentation.declarations[0])}")
        let mainHtml = html[html.indexOf("<main ").getOrThrow()..]
        @Expect(mainHtml.contains("sibling-members"), false)
        @Expect(mainHtml.split("public func member(): Unit").size, 2)
        @Expect(mainHtml.indexOf("api-page-header").getOrThrow() <
            mainHtml.indexOf("member-browser\"").getOrThrow(), true)
        @Expect(mainHtml.contains("declaration-metadata"), false)
        @Expect(mainHtml.contains("Symbol ID"), false)
        @Expect(mainHtml.contains("Semantic information"), false)
        @Expect(mainHtml.indexOf("No internal synchronization.").getOrThrow() <
            mainHtml.indexOf("member-browser\"").getOrThrow(), true)
        @Expect(mainHtml.indexOf("Callers coordinate concurrent access.").getOrThrow() <
            mainHtml.indexOf("member-browser\"").getOrThrow(), true)
        @Expect(mainHtml.indexOf("Example after members.").getOrThrow() >
            mainHtml.indexOf("member-browser\"").getOrThrow(), true)
        @Expect(mainHtml.split("A compact type summary.").size, 2)
        @Expect(html.contains("class=\"skip-link\" href=\"#cjdoc-main\""), true)
        @Expect(html.contains("id=\"cjdoc-main\""), true)
        @Expect(html.contains("<code>member()</code>"), true)
        @Expect(mainHtml.contains("data-cjdoc-members-expand"), true)
        @Expect(mainHtml.contains("data-cjdoc-members-collapse"), true)
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
        let projection = RenderProjection(document)
        @Expect(projection.allIndex.contains(secretId), true)
        @Expect(projection.visibleIndex.contains(secretId), false)
        let links = HtmlTypeLinkIndex(document, projection)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[1].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[2].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[3].target, secretId), true)
        @Expect(links.sameUnfilteredTarget(reader.typeRelationships[2].target, contractId), false)
        let page = rendererSafetyContent(HtmlDocumentationRenderer().render(document),
            "html/${symbolPagePath(reader)}")
        @Expect(page.contains("class=\"symbol-relationships\""), true)
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
        @Expect(page.split("<dt>Parent type</dt>").size, 2)
        @Expect(page.contains("Relationship not fully established"), false)
        @Expect(page.contains("<dt>Parent type</dt><dd><a href="), true)
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
        let page = rendererSafetyContent(HtmlDocumentationRenderer().render(doc),
            "html/${symbolPagePath(symbol)}")
        @Expect(page.contains("Array&lt;String&gt;"), true)
        @Expect(page.contains("Array &lt; String &gt;"), false)
        @Expect(page.contains("class=\"signature-block\""), true)
    }

    @TestCase
    func htmlChineseLabelsCoverBreadcrumbAndRuntimeControls(): Unit {
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"))
        let collector = RenderArtifactCollector()
        appendHtmlArtifacts(collector, documentation, locale: "zh-CN")
        let packageHtml = rendererSafetyContent(collector.toArray(),
            "html/${packagePagePath("cjdoc:module:v1:renderer-safety", "fixture")}")

        @Expect(packageHtml.contains("aria-label=\"面包屑导航\""), true)
        @Expect(packageHtml.contains("aria-label=\"切换主题\""), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("const isChinese"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("复制代码"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("已复制"), true)
        @Expect(packageHtml.contains("aria-label=\"主题\""), true)
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
            "markdown/docs.md")

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
            "markdown/docs.md")

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
                "markdown/docs.md")
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
            ])), "markdown/docs.md")

        @Expect(markdown.contains("> **Deprecated.** use replacement"))
        @Expect(markdown.contains("#### Since\n\n- 1\\.0"))
        @Expect(markdown.contains("#### Authors\n\n- Ada"))
        @Expect(markdown.contains("#### Version\n\n- 2\\.0"))
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

        @Expect(html.contains("<th class=\"align-right\">"))
        @Expect(!html.contains(" style=\""))
        @Expect(css.contains(".align-right{text-align:right}"))
    }

    @TestCase
    func searchSectionsOnlyCoverRenderedHeadings(): Unit {
        let moduleId = "cjdoc:module:v1:renderer-safety"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
        let markdown = MarkdownNode("document")
        // A return on a Unit function renders no Returns heading, so no section
        // may point at one; a parameter tag on a parameterless function is
        // likewise dropped. A real non-Unit return keeps its section.
        @Expect(searchSectionsFor(markdown, moduleId, source, "unit", "function",
            Some(TypeRef("source", "Unit", SemanticType("unavailable"))), [],
            [DocTag("return", "", "returned value")]).contains("\"sections\""), false)
        @Expect(searchSectionsFor(markdown, moduleId, source, "bare", "function",
            Some(TypeRef("source", "Bool", SemanticType("unavailable"))), [],
            [DocTag("param", "", "a parameter")]).contains("\"sections\""), false)
        @Expect(searchSectionsFor(markdown, moduleId, source, "value", "function",
            Some(TypeRef("source", "Bool", SemanticType("unavailable"))), [],
            [DocTag("return", "", "returned value")]).contains("\"sections\""), true)
    }

    private func searchSectionsFor(markdown: MarkdownNode, moduleId: String, source: SourceRange,
        name: String, kind: String, returnType: ?TypeRef, parameters: Array<ParameterDoc>,
        tags: Array<DocTag>): String {
        let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-safety::fixture::${kind}:${name}#g0()"
        let symbol = SymbolDoc(symbolId, kind, name, "fixture." + name, "fixture", moduleId,
            "public", source, "public func ${name}(): Unit", SemanticInfo("partial", "ast"),
            parameters: parameters, returnType: returnType,
            documentation: Some(DocComment("raw", "summary", "", markdown, tags: tags)))
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("renderer-safety"), ConfigurationSnapshot(lintProfile: "off"),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                SemanticCapabilities(false, false, false, false, false))],
            modules: [ModuleDoc(moduleId, "renderer-safety", "root", "", packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
            files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol])
        rendererSafetyContent(HtmlDocumentationRenderer().render(documentation),
            "html/search-index.json")
    }
}
