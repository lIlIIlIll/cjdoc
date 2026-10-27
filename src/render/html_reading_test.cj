package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let READING_MODULE = "cjdoc:module:v1:reading"
private let READING_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areading::example::function:keep#g0()"

private func readingHeading(title: String, level: Int64): MarkdownNode {
    MarkdownNode("heading", MarkdownNodeMetadata.forHeading(level),
        children: [MarkdownNode("text", literal: title)])
}

private func readingGuide(id: String, title: String): DocumentationPage {
    let source = "docs/" + id + ".md"
    let tree = MarkdownNode("document", children: [readingHeading(title, 1),
        readingHeading("Keep the original", 2),
        MarkdownNode("html_block", literal: "<!-- cjdoc-bind -->",
            source: Some(SourceRange(source, SourcePosition(4, 1, 4), SourcePosition(4, 2, 5)))),
        MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "The authored condition.")])])
    DocumentationPage(id, source, "concepts/" + id + ".html", title, "guide", "Guide", tree,
        targetSymbolIds: [READING_SYMBOL], bindings: [DocumentationPageBinding("example.keep", "member",
            "authored", "", 4, state: "resolved", targetSymbolId: Some(READING_SYMBOL))])
}

private func readingDocumentation(includeIntroduction: Bool, fallback!: Bool = false): DocumentationSet {
    let range = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let declaration = SymbolDoc(READING_SYMBOL, "function", "keep", "example.keep", "example",
        READING_MODULE, "public", range, "public func keep(): Unit", SemanticInfo("partial", "ast"))
    let pages = if (includeIntroduction) { [
        DocumentationPage("project", "docs/index.md", "concepts/index.html", "Author introduction",
            "project", "Introduction", MarkdownNode("document", children: [
                readingHeading("Author introduction", 1),
                MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "A real author introduction.")]),
                MarkdownNode("paragraph", children: [MarkdownNode("link", literal: "first.md#keep-the-original",
                    children: [MarkdownNode("text", literal: "Read the first guide")])]),
                MarkdownNode("html_block", literal: "<script>window.untrustedAuthor=true</script>"),
                MarkdownNode("paragraph", children: [MarkdownNode("link", literal: "javascript:alert(1)",
                    children: [MarkdownNode("text", literal: "Unsafe link")])])])),
        readingGuide("first", "First guide"), readingGuide("second", "Second guide")
    ] } else { Array<DocumentationPage>() }
    let selectedPages = if (fallback) {
        [DocumentationPage("project", "docs/index.md", "concepts/index.html", "author-library", "project", "",
            MarkdownNode("document", children: [readingHeading("author-library", 1),
                MarkdownNode("paragraph", children: [MarkdownNode("text", literal:
                    "This site contains the conceptual documentation and generated API reference.")])]))]
    } else { pages }
    let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("author-library"),
        ConfigurationSnapshot(lintProfile: "off"),
        modules: [ModuleDoc(READING_MODULE, "reading", "root", "", packageNames: ["example"])],
        packages: [PackageDoc("example", READING_MODULE, sourceFiles: ["src/api.cj"], symbolIds: [READING_SYMBOL])],
        files: [FileDoc("src/api.cj", READING_MODULE, "example")], declarations: [declaration], pages: selectedPages,
        providers: [ProviderInfo("ast", "builtin", READING_MODULE, "partial",
            SemanticCapabilities(false, false, false, true, false))])
    decodeDocIr(encodeDocIr(documentation))
}

private func readingContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing reading artifact")
}

@Test
class EditorialReadingTest {
    @TestCase
    func homepageUsesCapturedAuthorContentAndRebasesItsLinksSafely(): Unit {
        let documentation = readingDocumentation(true)
        let original = encodeDocIr(documentation)
        let artifacts = rendererFor("html").render(documentation)
        let home = readingContent(artifacts, "html/index.html")
        @Expect(home.contains("<h1>author-library</h1>"))
        @Expect(home.contains("A real author introduction."))
        @Expect(home.contains("href=\"concepts/first.html#standalone--doc-keep-the-original\""))
        @Expect(home.indexOf("A real author introduction.").getOrThrow() < home.indexOf("id=\"packages\"").getOrThrow())
        @Expect(!home.contains("<script>window.untrustedAuthor"))
        @Expect(!home.contains("href=\"javascript:"))
        @Expect(!home.contains("<h2>Author introduction</h2>"))
        @Expect(encodeDocIr(documentation), original)
    }

    @TestCase
    func missingAuthorContentLeavesACompleteNeutralIndex(): Unit {
        let home = readingContent(rendererFor("html").render(readingDocumentation(false)), "html/index.html")
        @Expect(home.contains("id=\"packages\""))
        @Expect(home.contains("id=\"api-overview\""))
        @Expect(!home.contains("Start here"))
        @Expect(!home.contains("class=\"home-introduction"))
        @Expect(home.contains("href=\"#packages\""))
        @Expect(!home.contains("Choose a module or package"))
        @Expect(!home.contains("concepts/packages/"))
    }

    @TestCase
    func generatedFallbackRemainsInIrWithoutBecomingAnAuthorIntroduction(): Unit {
        let documentation = readingDocumentation(true, fallback: true)
        let snapshot = encodeDocIr(documentation)
        let home = readingContent(rendererFor("html").render(documentation), "html/index.html")
        @Expect(!home.contains("class=\"home-introduction"))
        @Expect(!home.contains("This site contains"))
        @Expect(home.contains("id=\"packages\""))
        @Expect(encodeDocIr(documentation), snapshot)
    }

    @TestCase
    func guideAndApiRoundTripPointsToTheActualBoundSection(): Unit {
        let artifacts = rendererFor("html").render(readingDocumentation(true))
        let guide = readingContent(artifacts, "html/concepts/first.html")
        @Expect(guide.contains("id=\"standalone--doc-keep-the-original\""))
        @Expect(guide.contains("The authored condition."))
        @Expect(guide.indexOf("The authored condition.").getOrThrow() <
            guide.indexOf("class=\"guide-related-api\"").getOrThrow())
        var found = false
        for (artifact in artifacts where artifact.path.startsWith("html/symbols/")) {
            if (!artifact.content.contains("data-cjdoc-page=\"symbol\"")) { continue }
            @Expect(artifact.content.contains("href=\"../concepts/first.html#standalone--doc-keep-the-original\""))
            @Expect(artifact.content.contains("First guide · Keep the original"))
            found = true
        }
        @Expect(found)
    }

    @TestCase
    func guideSequenceUsesConfiguredOrderAndKeepsCanonicalRoutes(): Unit {
        let artifacts = rendererFor("html").render(readingDocumentation(true))
        let first = readingContent(artifacts, "html/concepts/first.html")
        let second = readingContent(artifacts, "html/concepts/second.html")
        @Expect(first.contains("rel=\"next\" href=\"../concepts/second.html\""))
        @Expect(!first.contains("rel=\"prev\""))
        @Expect(second.contains("rel=\"prev\" href=\"../concepts/first.html\""))
        @Expect(!second.contains("rel=\"next\""))
        @Expect(first.split("<h1>").size, 2)
    }
}
