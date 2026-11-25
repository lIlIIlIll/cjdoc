package cjdoc.render

import cjdoc.render.foundation.RenderArtifact
import cjdoc.render.routes.pageRootPrefix
import cjdoc.render.codec.{decodeDocIr, encodeDocIr}
import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let ROUTE_ENCODING_TARGET = "concepts/my guide.html"
private let ROUTE_ENCODING_UNICODE = "concepts/指南 (zh).html"
private let ROUTE_ENCODING_OTHER = "concepts/other.html"

private func routeEncodingHeading(title: String, level: Int64): MarkdownNode {
    MarkdownNode("heading", MarkdownNodeMetadata.forHeading(level),
        children: [MarkdownNode("text", literal: title)])
}

private func routeEncodingLink(labelText: String, destination: String): MarkdownNode {
    MarkdownNode("paragraph", children: [MarkdownNode("link", literal: destination,
        children: [MarkdownNode("text", literal: labelText)])])
}

private func routeEncodingPage(id: String, source: String, route: String,
    language: ?String, body: Array<MarkdownNode>): DocumentationPage {
    DocumentationPage(id, source, route, "Guide " + id, "guide", "Guide " + id,
        MarkdownNode("document", children: body), language: language,
        defaultLanguage: Some(language.getOrDefault({ => "en" })))
}

private func routeEncodingDocumentation(linkDestination: String): DocumentationSet {
    let target = routeEncodingPage("target", "docs/guide.md", ROUTE_ENCODING_TARGET, Some("en"),
        [routeEncodingHeading("Route space", 1), routeEncodingHeading("Topic", 2)])
    let unicode = routeEncodingPage("unicode", "docs/unicode.md", ROUTE_ENCODING_UNICODE, Some("en"),
        [routeEncodingHeading("Unicode route", 1)])
    let other = routeEncodingPage("other", "docs/other.md", ROUTE_ENCODING_OTHER, Some("en"),
        [routeEncodingHeading("Other guide", 1),
            routeEncodingLink("Read route guide", linkDestination),
            routeEncodingLink("Read section", linkDestination + "#topic"),
            routeEncodingLink("Read unicode", "unicode.md")])
    decodeDocIr(encodeDocIr(DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("route-encoding"), ConfigurationSnapshot(lintProfile: "off"),
        pages: [target, unicode, other],
        languageOptions: Some(DocumentationLanguageOptions("en", languages: ["en"])))))
}

private func routeEncodingContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing route encoding artifact '${path}'")
}

private func expectAnchoredHref(html: String, label: String, href: String): Unit {
    @Expect(html.contains("href=\"" + href + "\">" + label + "</a>"))
}

// Every href whose target ends with the captured route, decoded back to a
// comparable spelling. Both the body prose and the surrounding navigation must
// appear here with the same single encoding.
private func routeEncodingHrefs(html: String, suffix: String): Array<String> {
    let result = ArrayList<String>()
    for (part in html.split("href=\"")) {
        let href = part.split("\"", 2)[0]
        if (href.endsWith(suffix)) { result.add(href) }
    }
    result.toArray()
}

@Test
class DocumentationPageRouteEncodingTest {
    @TestCase
    func authorRoutesWithSpacesAndNonAsciiKeepBodyLinksReachable(): Unit {
        let documentation = routeEncodingDocumentation("guide.md")
        let artifacts = renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en")
        let other = routeEncodingContent(artifacts, "html/" + ROUTE_ENCODING_OTHER)
        expectAnchoredHref(other, "Read route guide",
            "../concepts/my%20guide.html")
        expectAnchoredHref(other, "Read section",
            "../concepts/my%20guide.html#standalone--doc-topic")
        expectAnchoredHref(other, "Read unicode",
            "../concepts/%E6%8C%87%E5%8D%97%20%28zh%29.html")
        // Pages are published at their authored paths; each href above is the
        // encoding of exactly that file, and the fragment targets the real id.
        @Expect(routeEncodingContent(artifacts, "html/" + ROUTE_ENCODING_TARGET)
            .contains("id=\"standalone--doc-topic\""))
        @Expect(routeEncodingContent(artifacts, "html/" + ROUTE_ENCODING_UNICODE)
            .contains("id=\"standalone--doc-unicode-route\""))
    }

    @TestCase
    func bodyAndNavigationShareOneEncodingRuleAndEncodeOnlyOnce(): Unit {
        let documentation = routeEncodingDocumentation("guide.md")
        let artifacts = renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en")
        let other = routeEncodingContent(artifacts, "html/" + ROUTE_ENCODING_OTHER)
        // The body and every navigation surface share one encoding pass, so the
        // same captured route never appears as raw space or double-encoded text.
        @Expect(pageRootPrefix(ROUTE_ENCODING_OTHER), "../")
        let hrefs = routeEncodingHrefs(other, "concepts/my%20guide.html")
        @Expect(hrefs.size > 0, true)
        for (href in hrefs) { @Expect(href, "../concepts/my%20guide.html") }
        @Expect(other.contains("%2520"), false)
        @Expect(!other.contains("my guide.html\""))
    }

    @TestCase
    func markdownOutputUsesTheSameEncodingAndOneExtension(): Unit {
        let documentation = routeEncodingDocumentation("guide.md")
        let artifacts = renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")
        let other = routeEncodingContent(artifacts, "markdown/concepts/other.md")
        @Expect(other.contains("[Read route guide](../concepts/my%20guide.md)"))
        @Expect(other.contains("[Read section](../concepts/my%20guide.md#topic)"))
        @Expect(other.contains("[Read unicode](../concepts/%E6%8C%87%E5%8D%97%20%28zh%29.md)"))
        @Expect(other.contains(".md.md"), false)
    }

    @TestCase
    func importedIrWithoutSourcesRetainsEncodedBodyLinksInsideTheReadingRoot(): Unit {
        let documentation = routeEncodingDocumentation("guide.md")
        let imported = decodeDocIr(encodeDocIr(documentation))
        let artifacts = renderDocumentationFormatsWithOptions(imported, ["html", "markdown"],
            allLanguages: true)
        let other = routeEncodingContent(artifacts, "html/en/concepts/other.html")
        expectAnchoredHref(other, "Read route guide", "../concepts/my%20guide.html")
        expectAnchoredHref(other, "Read section",
            "../concepts/my%20guide.html#standalone--doc-topic")
        @Expect(routeEncodingContent(artifacts, "markdown/en/concepts/other.md")
            .contains("](../concepts/my%20guide.md)"))
    }

    @TestCase
    func unsafeAuthorDestinationsStillStayPlainText(): Unit {
        let documentation = routeEncodingDocumentation("javascript:alert(1)")
        let artifacts = renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en")
        let other = routeEncodingContent(artifacts, "html/" + ROUTE_ENCODING_OTHER)
        @Expect(!other.contains("javascript:"))
        @Expect(other.contains("Read route guide"))
    }
}
