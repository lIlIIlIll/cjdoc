package cjdoc

import cjdoc.model as public_model
import std.collection.*
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
}
