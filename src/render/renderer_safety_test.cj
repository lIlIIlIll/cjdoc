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

private func rendererOwnerDocumentation(ownerKind: String): DocumentationSet {
    let moduleId = "cjdoc:module:v1:owner-validation"
    let ownerId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aowner-validation::fixture::class:Owner#g0()"
    let memberId =
        "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aowner-validation::fixture::Owner::function:member#g0()"
    let source = SourceRange("src/owner.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, 24, 23))
    let owner = SymbolDoc(ownerId, ownerKind, "Owner", "fixture.Owner", "fixture", moduleId,
        "public", source, "public ${ownerKind} Owner", SemanticInfo("partial", "ast"))
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
    func rendererFactorySupportsEveryDocumentedFormat(): Unit {
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"))
        let expectations = [
            ("json", "docs.json"),
            ("markdown", "markdown/docs.md"),
            ("html", "html/index.html"),
            ("api-surface", "api-surface/api-surface.json"),
            ("coverage", "coverage/coverage.json")
        ]
        for ((format, path) in expectations) {
            let renderer = rendererFor(format)
            @Expect(renderer.format, format)
            @Expect(renderer.render(documentation)[0].path, path)
        }
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
                "cj", "cj", ""), literal: "body")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)), "markdown/docs.md")
        let marks = rendererSafetyFenceMarks()

        @Expect(markdown.contains("${marks}cj\nbody\n${marks}"))
    }

    @TestCase
    func markdownCodeUsesAContentSafeDynamicDelimiter(): Unit {
        let code = MarkdownNode("document", children: [MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3,
                "cj", "cj", ""), literal: "before ```` after")])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(
            rendererSafetyDocumentation(code)), "markdown/docs.md")

        @Expect(markdown.contains("`````cj\nbefore ```` after\n`````"))
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
            "Explain the example with <script>alert(2)</script>.\n\n" +
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
            "Explain the example with &lt;script&gt;alert(2)&lt;/script&gt;."), true)
        @Expect(markdown.contains("<script>alert(1)</script>"), true)
        @Expect(!markdown.contains("<script>alert(2)</script>"), true)
        @Expect(markdown.contains("&lt;img src=x&gt;"), true)
        @Expect(html.contains("<h3>Examples</h3>"), true)
        @Expect(html.contains("class=\"example-block\""), true)
        @Expect(html.contains("data-language=\"cj\""), true)
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
        let documentation = rendererSafetyDocumentation(MarkdownNode("document"),
            tags: [valid, invalid])
        let markdown = rendererSafetyContent(MarkdownDocumentationRenderer().render(documentation),
            "markdown/docs.md")
        let html = rendererSafetyText(HtmlDocumentationRenderer().render(documentation))

        @Expect(markdown.contains("   ```cj"), true)
        @Expect(markdown.contains("&lt;script&gt;alert(3)&lt;/script&gt;"), true)
        @Expect(!markdown.contains("<script>alert(3)</script>"), true)
        @Expect(html.contains("<pre><code"), true)
        @Expect(html.contains("&lt;script&gt;alert(3)&lt;/script&gt;"), true)
        @Expect(!html.contains("<script>alert(3)</script>"), true)
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
        @Expect(css.contains(".sidebar-package.is-current"), true)
        @Expect(css.contains(".toc-api-row"), true)
        @Expect(css.contains(".toc-toggle"), true)
        @Expect(css.contains(".toc-children"), true)
        @Expect(css.contains(".parameter-row{padding:0;border-bottom:0}"), true)
        @Expect(css.contains(".parameter-type{white-space:normal;overflow-wrap:anywhere}"), true)

        @Expect(packageHtml.contains("data-cjdoc-toc-role=\"api\""), true)
        @Expect(packageHtml.contains("data-cjdoc-toc-label=\"func api(): Unit\""), true)

        let containerDocumentation = rendererOwnerDocumentation("class")
        let containerArtifacts = HtmlDocumentationRenderer().render(containerDocumentation)
        let symbolHtml = rendererSafetyContent(containerArtifacts,
            "html/${symbolPagePath(containerDocumentation.declarations[0])}")
        @Expect(symbolHtml.contains("<a class=\"sidebar-package is-current\""), true)
        @Expect(symbolHtml.contains(
            "<h1 data-cjdoc-toc-role=\"api-root\" data-cjdoc-toc-label=\"class Owner\">"), true)
        @Expect(symbolHtml.contains(
            "<h3 class=\"symbol-title\" data-cjdoc-toc-role=\"member\" data-cjdoc-toc-label=\"func member(): Unit\">"), true)
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
        @Expect(HTML_SEARCH_SCRIPT.contains("themeSwitchLabel"), true)
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
}
