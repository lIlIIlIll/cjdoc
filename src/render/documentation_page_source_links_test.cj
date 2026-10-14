package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func sourceLinkNode(label: String, destination: String): MarkdownNode {
    MarkdownNode("paragraph", children: [MarkdownNode("link", literal: destination,
        children: [MarkdownNode("text", literal: label)])])
}

private func sourceLinkPage(id: String, source: String, route: String,
    links: Array<MarkdownNode>, language!: String = "en"): DocumentationPage {
    let children = ArrayList<MarkdownNode>([
        MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
            children: [MarkdownNode("text", literal: "Guide")]),
        MarkdownNode("heading", MarkdownNodeMetadata.forHeading(2),
            children: [MarkdownNode("text", literal: "Topic")])
    ])
    children.add(all: links)
    DocumentationPage(id, source, route, "Guide", "guide", "Guide\nTopic",
        MarkdownNode("document", children: children.toArray()),
        language: Some(language), defaultLanguage: Some(language),
        sections: [DocumentationSection("topic", "topic")])
}

private func sourceLinkDocumentation(pages: Array<DocumentationPage>): DocumentationSet {
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("source-links"), ConfigurationSnapshot(lintProfile: "off"), pages: pages)
    decodeDocIr(encodeDocIr(original))
}

private func sourceLinkContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing source link reading artifact")
}

private func selfSourceLinks(): Array<MarkdownNode> {
    [sourceLinkNode("Self fragment", "#topic"),
        sourceLinkNode("Self normalized", "#standalone--doc-topic"),
        sourceLinkNode("Self source", "shared.md#topic")]
}

private func verifyLocalSourceFragments(artifacts: Array<RenderArtifact>, route: String): Unit {
    let html = sourceLinkContent(artifacts, "html/" + route)
    let markdown = sourceLinkContent(artifacts, "markdown/" + route.removeSuffix(".html") + ".md")
    @Expect(html.contains("id=\"standalone--doc-topic\""))
    @Expect(html.contains("href=\"#standalone--doc-topic\">Self fragment</a>"))
    @Expect(html.contains("href=\"#standalone--doc-topic\">Self normalized</a>"))
    @Expect(markdown.contains("[Self fragment](#topic)"))
    @Expect(markdown.contains("[Self normalized](#topic)"))
}

@Test
class DocumentationPageSourceLinksTest {
    @TestCase
    func differentPageIdentitiesSharingASourceNeverSelectAnArrayPosition(): Unit {
        let current = sourceLinkPage("current", "docs/current.md", "concepts/guides/current.html",
            [sourceLinkNode("Cross duplicate", "shared.md#topic")])
        let first = sourceLinkPage("first", "docs/shared.md", "concepts/guides/first.html", selfSourceLinks())
        let second = sourceLinkPage("second", "docs/shared.md", "concepts/guides/second.html", selfSourceLinks())
        let orders = [[current, first, second], [current, second, first]]
        for (pages in orders) {
            let artifacts = renderDocumentationFormatsWithOptions(sourceLinkDocumentation(pages),
                ["html", "markdown"], locale: "en")
            let html = sourceLinkContent(artifacts, "html/concepts/guides/current.html")
            let markdown = sourceLinkContent(artifacts, "markdown/concepts/guides/current.md")
            @Expect(html.contains("Cross duplicate"))
            @Expect(!html.contains("first.html#standalone--doc-topic"))
            @Expect(!html.contains("second.html#standalone--doc-topic"))
            @Expect(markdown.contains("[Cross duplicate]"))
            @Expect(!markdown.contains("first.md#topic"))
            @Expect(!markdown.contains("second.md#topic"))
            for (route in ["concepts/guides/first.html", "concepts/guides/second.html"]) {
                verifyLocalSourceFragments(artifacts, route)
                let page = sourceLinkContent(artifacts, "markdown/" + route.removeSuffix(".html") + ".md")
                @Expect(page.contains("[Self source]"))
                @Expect(!page.contains("](../../concepts/guides/"))
            }
        }
    }

    @TestCase
    func uniqueSourceLinksRetainTheirDeclaredRouteAndActualHeading(): Unit {
        let current = sourceLinkPage("current", "docs/current.md", "concepts/guides/current.html",
            [sourceLinkNode("Unique source", "shared.md#topic")])
        let target = sourceLinkPage("target", "docs/shared.md", "concepts/guides/target.html", selfSourceLinks())
        let artifacts = renderDocumentationFormatsWithOptions(sourceLinkDocumentation([current, target]),
            ["html", "markdown"], locale: "en")
        let html = sourceLinkContent(artifacts, "html/concepts/guides/current.html")
        let markdown = sourceLinkContent(artifacts, "markdown/concepts/guides/current.md")
        @Expect(html.contains("href=\"../../concepts/guides/target.html#standalone--doc-topic\">Unique source</a>"))
        @Expect(markdown.contains("[Unique source](../../concepts/guides/target.md#topic)"))
        verifyLocalSourceFragments(artifacts, "concepts/guides/target.html")
        @Expect(sourceLinkContent(artifacts, "markdown/concepts/guides/target.md").contains(
            "[Self source](../../concepts/guides/target.md#topic)"))
    }

    @TestCase
    func oneSelectedLogicalPageMayReuseItsSourceAcrossLanguageVariants(): Unit {
        let current = sourceLinkPage("current", "docs/current.md", "concepts/guides/current.html",
            [sourceLinkNode("Shared identity", "shared.md#topic")])
        let english = sourceLinkPage("shared", "docs/shared.md", "concepts/guides/shared.html", [])
        let chinese = sourceLinkPage("shared", "docs/shared.md", "concepts/guides/shared.html", [], language: "zh-CN")
        let orders = [[current, english, chinese], [current, chinese, english]]
        for (pages in orders) {
            let artifacts = renderDocumentationFormatsWithOptions(sourceLinkDocumentation(pages),
                ["html", "markdown"], locale: "en")
            @Expect(sourceLinkContent(artifacts, "html/concepts/guides/current.html").contains(
                "href=\"../../concepts/guides/shared.html#standalone--doc-topic\">Shared identity</a>"))
            @Expect(sourceLinkContent(artifacts, "markdown/concepts/guides/current.md").contains(
                "[Shared identity](../../concepts/guides/shared.md#topic)"))
        }
    }
}
