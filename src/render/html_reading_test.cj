package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let READING_MODULE = "cjdoc:module:v1:reading"
private let READING_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areading::example::function:keep#g0()"
private let READING_OTHER_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areading::example::function:other#g0()"

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

private func readingBindingRange(path: String, line: Int64): SourceRange {
    SourceRange(path, SourcePosition(line, 1, line), SourcePosition(line, 2, line + 1))
}

private func readingMarker(kind: String, path!: ?String = None,
    line!: Int64 = 1): MarkdownNode {
    let source: ?SourceRange = match (path) {
        case Some(value) => Some(readingBindingRange(value, line))
        case None => None
    }
    let marker = MarkdownNode(kind, literal: "<!-- cjdoc-bind -->", source: source)
    if (kind == "html_inline") { MarkdownNode("paragraph", children: [marker]) } else { marker }
}

private func readingBindingAt(line: Int64, target!: String = READING_SYMBOL): DocumentationPageBinding {
    let targetName = if (target == READING_OTHER_SYMBOL) { "example.other" } else { "example.keep" }
    let selector = if (target == READING_OTHER_SYMBOL) {
        "signature:public func other(): Unit"
    } else { "member" }
    DocumentationPageBinding(targetName, selector, "authored", "", line,
        state: "resolved", targetSymbolId: Some(target))
}

private func readingBindingPage(markdown: MarkdownNode,
    bindings: Array<DocumentationPageBinding>,
    targetSymbols!: Array<String> = [READING_SYMBOL]): DocumentationPage {
    DocumentationPage("binding-check", "docs/guide.md", "concepts/binding-check.html",
        "Binding guide", "guide", "", markdown, targetSymbolIds: targetSymbols,
        bindings: bindings)
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

private func readingDocumentationWithPages(pages: Array<DocumentationPage>,
    includeOther!: Bool = false): DocumentationSet {
    let base = readingDocumentation(false)
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let other = SymbolDoc(READING_OTHER_SYMBOL, "function", "other", "example.other",
        "example", READING_MODULE, "public", source, "public func other(): Unit",
        SemanticInfo("partial", "ast"))
    let declarations = if (includeOther) { [base.declarations[0], other] }
        else { base.declarations.toArray() }
    let symbolIds = if (includeOther) { [READING_SYMBOL, READING_OTHER_SYMBOL] }
        else { [READING_SYMBOL] }
    decodeDocIr(encodeDocIr(DocumentationSet(base.generator, base.status, base.project,
        base.configuration, providers: base.providers.toArray(), modules: base.modules.toArray(),
        packages: [PackageDoc("example", READING_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: symbolIds)],
        files: base.files.toArray(), declarations: declarations, pages: pages)))
}

private func readingContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing reading artifact")
}

private func readingSymbolPage(artifacts: Array<RenderArtifact>, name: String): String {
    for (artifact in artifacts where artifact.path.startsWith("html/symbols/") &&
        artifact.content.contains("class=\"page-header api-page-header\"") &&
        artifact.content.contains("<code>" + name + "</code>")) {
        return artifact.content
    }
    throw IllegalArgumentException("missing reading symbol page")
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
    func renderedGuideLinksRequireExactInlineSentinelSourceAndTarget(): Unit {
        let guidePath = "docs/guide.md"
        let tree = MarkdownNode("document", children: [
            readingHeading("Guide", 1),
            readingHeading("Inline table", 2),
            readingMarker("html_inline", path: Some(guidePath), line: 3),
            readingHeading("Wrong source", 2),
            readingMarker("html_inline", path: Some("docs/other.md"), line: 5),
            readingHeading("Code literal", 2),
            MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock(
                "fenced", Some("`"), 3, "", "", ""),
                literal: "<!-- cjdoc-bind -->", source: Some(readingBindingRange(guidePath, 7))),
            readingHeading("Text literal", 2),
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "<!-- cjdoc-bind -->",
                source: Some(readingBindingRange(guidePath, 9)))]),
            readingHeading("Wrong target", 2),
            readingMarker("html_inline", path: Some(guidePath), line: 11),
            readingHeading("Wrong line", 2),
            readingMarker("html_inline", path: Some(guidePath), line: 13),
            readingHeading("Non-exact sentinel", 2),
            MarkdownNode("paragraph", children: [
                MarkdownNode("html_inline", literal: "<!-- cjdoc-bind target=\"example.keep\" -->",
                    source: Some(readingBindingRange(guidePath, 15)))
            ])
        ])
        let page = readingBindingPage(tree, [
            readingBindingAt(3), readingBindingAt(3), readingBindingAt(5),
            readingBindingAt(7), readingBindingAt(9),
            readingBindingAt(11, target: READING_OTHER_SYMBOL), readingBindingAt(12),
            readingBindingAt(15)
        ], targetSymbols: [READING_SYMBOL, READING_OTHER_SYMBOL])
        let artifacts = HtmlDocumentationRenderer().render(
            readingDocumentationWithPages([page], includeOther: true))
        let keep = readingSymbolPage(artifacts, "keep")
        @Expect(keep.contains("href=\"../concepts/binding-check.html#standalone--doc-inline-table\""))
        @Expect(keep.split("href=\"../concepts/binding-check.html#standalone--doc-inline-table\"").size, 2)
        @Expect(!keep.contains("Wrong source"))
        @Expect(!keep.contains("Code literal"))
        @Expect(!keep.contains("Text literal"))
        @Expect(!keep.contains("Wrong line"))
        @Expect(!keep.contains("Non-exact sentinel"))
        let other = readingSymbolPage(artifacts, "other")
        @Expect(other.contains("href=\"../concepts/binding-check.html#standalone--doc-wrong-target\""))
        @Expect(other.contains("Binding guide · Wrong target"))
    }

    @TestCase
    func replayedGuideMarkerWithoutSourceCannotInventASectionTarget(): Unit {
        let tree = MarkdownNode("document", children: [
            readingHeading("Guide", 1), readingHeading("Unproven section", 2),
            readingMarker("html_inline", line: 3)
        ])
        let page = readingBindingPage(tree, [readingBindingAt(3)])
        let replay = readingDocumentationWithPages([page])
        let artifacts = HtmlDocumentationRenderer().render(replay)
        let keep = readingSymbolPage(artifacts, "keep")
        @Expect(keep.contains("href=\"../concepts/binding-check.html\">Binding guide</a>"))
        @Expect(!keep.contains("#standalone--doc-unproven-section"))
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
