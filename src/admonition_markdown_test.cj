package cjdoc

import cjdoc.model as public_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class AdmonitionMarkdownTest {
    @TestCase
    func sourceBackedTopLevelMarkersBecomeDocumentAdmonitionBlocks(): Unit {
        for ((marker, level) in [("NOTE", "note"), ("WARNING", "warning"), ("CAUTION", "danger")]) {
            let document = parseStandaloneMarkdown("> [!${marker}]\n> Body with **formatting**.\n")
            @Expect(document.kind, "document")
            @Expect(document.children.size, 1)
            let alert = document.children[0]
            @Expect(alert.kind, "admonition")
            @Expect(alert.literal, "")
            @Expect(alert.metadata.getOrThrow().admonitionLevel, Some(level))
            @Expect(alert.children.size, 1)
            @Expect(alert.children[0].kind, "paragraph")
        }
    }

    @TestCase
    func unsafeOrNoncanonicalMarkersRemainOrdinaryQuotes(): Unit {
        for (body in [
            "> [!NOTE] Same-line title\n> Body.\n",
            "> [!DANGER]\n> Unknown level remains ordinary.\n",
            "> [!TIP]\n> Unknown marker remains ordinary.\n",
            "> &#91;!NOTE&#93;\n> Entity marker remains ordinary.\n",
            "> \\[!NOTE]\n> Escaped marker remains ordinary.\n",
            "> > [!NOTE]\n> > Nested marker remains ordinary.\n"
        ]) {
            let document = parseStandaloneMarkdown(body)
            @Expect(document.children.size, 1)
            @Expect(document.children[0].kind, "block_quote")
        }
    }

    @TestCase
    func markerOnlyQuoteIsPreservedAndDiagnosed(): Unit {
        let context = MarkdownGenerationContext(highlightMode: "off")
        let source = public_model.SourceRange("src/alerts.md",
            public_model.SourcePosition(1, 1, 0), public_model.SourcePosition(2, 1, 1))
        let tree = try {
            publicMarkdown("> [!NOTE]\n", LocalAssetCollector(ArrayList<SourceFileOrigin>()),
                "src/alerts.md", source, "cjdoc:fixture", context)
        } finally {
            context.highlightBudget.close()
        }
        @Expect(tree.children.size, 1)
        @Expect(tree.children[0].kind, "block_quote")
        var diagnosed = false
        for (diagnostic in context.collectionDiagnostics()) {
            if (diagnostic.code == "CJDOC3117" && diagnostic.symbolId == Some("cjdoc:fixture")) {
                diagnosed = true
            }
        }
        @Expect(diagnosed, true)
    }

    @TestCase
    func emptyGuideMarkersRetainInputWithoutInventingSymbolIdentity(): Unit {
        let project = i18nTestProject("/** Retained API summary. */")
        let guide = "# Empty markers\n\n> [!NOTE]\n>\n" +
            "> [ref]: https://example.test/reference\n\n## Another marker\n\n" +
            "> [!WARNING]\n\nRemaining guide text.\n"
        File.writeTo(project.join("guide.md"), guide.toArray())
        File.writeTo(project.join("cjdoc.toml"), (
            "[[docs.pages]]\nid = \"empty-markers\"\nsource = \"guide.md\"\n" +
            "route = \"concepts/guides/empty-markers\"\ntitle = \"Empty markers\"\nkind = \"guide\"\n").toArray())
        try {
            let documentation = i18nTestGenerate(project)
            @Expect(documentation.status, "partial")
            @Expect(documentation.declarations.size, 1)
            var guides: Int64 = 0
            var quotes: Int64 = 0
            for (page in documentation.pages where page.id == "empty-markers") {
                @Expect(page.text, guide)
                for (node in page.markdown.children) {
                    if (node.kind == "block_quote") { quotes++ }
                    @Expect(node.kind != "admonition")
                }
                guides++
            }
            @Expect(guides, 1)
            @Expect(quotes, 2)
            var diagnosed: Int64 = 0
            for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3117") {
                @Expect(diagnostic.severity, "error")
                @Expect(diagnostic.symbolId.isNone(), true)
                @Expect(diagnostic.source.isSome(), true)
                @Expect(diagnostic.source.getOrThrow().path, "guide.md")
                diagnosed++
            }
            @Expect(diagnosed, 2)
            let encoded = api_render.encodeDocIr(documentation)
            let decoded = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(decoded), encoded)
            let html = renderedHtmlContent(api_render.renderDocumentationFormatsWithOptions(
                decoded, ["html"], locale: "en"))
            @Expect(html.contains("Remaining guide text."), true)
            @Expect(html.contains("Retained API summary."), true)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
}
