package cjdoc

import cjdoc.model.*
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ConceptTitleDedupTest {
    private func headings(html: String): Array<String> {
        let out = ArrayList<String>()
        for (line in html.split("\n")) {
            let trimmed = line.trimAscii()
            if (trimmed.startsWith("<h1") || trimmed.startsWith("<h2") ||
                trimmed.startsWith("<h3")) {
                out.add(trimmed)
            }
        }
        out.toArray()
    }

    @TestCase
    func leadingTitleHeadingIsSuppressedWhenItMatchesThePageTitle(): Unit {
        let html = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "# Guide title\n\nIntro text.\n\n## Scope\n\nMore.\n"), pageTitle: Some("Guide title"))
        let rendered = headings(html)
        @Expect(rendered.size, 1)
        @Expect(rendered[0].startsWith("<h1"), false)
        @Expect(rendered[0].contains("Scope"), true)
        @Expect(html.contains("Intro text."), true)
        @Expect(html.contains("Guide title"), false)
    }

    @TestCase
    func differentlyTitledOrAbsentLeadingHeadingIsKeptInFull(): Unit {
        let distinct = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "# Another title\n\nBody.\n"), pageTitle: Some("Guide title"))
        @Expect(headings(distinct).size, 1)
        @Expect(distinct.contains("Another title"), true)

        let untitled = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "Body without a heading.\n"), pageTitle: Some("Guide title"))
        @Expect(headings(untitled).size, 0)

        let noTitle = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "# Guide title\n\nBody.\n"))
        @Expect(headings(noTitle).size, 1)
    }

    @TestCase
    func laterHeadingRepeatingTheTitleKeepsItsShareableAnchor(): Unit {
        let html = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "# Guide title\n\n## Guide title\n\nBody.\n"), pageTitle: Some("Guide title"))
        let rendered = headings(html)
        @Expect(rendered.size, 1)
        // The surviving heading is the second one, so its anchor stays the
        // occurrence-suffixed slug a reader may already have shared.
        @Expect(rendered[0].contains("standalone--doc-guide-title-1"), true)
    }

    @TestCase
    func nonHeadingLeadingBlockDoesNotHideALaterTitle(): Unit {
        let html = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "Skipped heading level starts with prose.\n\n# Guide title\n\n## Scope\n"),
            pageTitle: Some("Guide title"))
        let rendered = headings(html)
        @Expect(rendered.size, 2)
        @Expect(rendered[0].contains("Guide title"), true)
        @Expect(rendered[1].contains("Scope"), true)
    }
}
