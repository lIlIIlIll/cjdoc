package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func sectionAnchorHeading(title: String, level: Int64): api_model.MarkdownNode {
    api_model.MarkdownNode("heading", api_model.MarkdownNodeMetadata.forHeading(level),
        children: [api_model.MarkdownNode("text", literal: title)])
}

private func sectionAnchorPage(sections: Array<api_model.DocumentationSection>,
    repeated!: Bool = false, title!: String = "Guide", titleLink!: Bool = false): api_model.DocumentationPage {
    let children = ArrayList<api_model.MarkdownNode>([sectionAnchorHeading("Guide", 1)])
    if (titleLink) {
        children.add(api_model.MarkdownNode("paragraph", children: [api_model.MarkdownNode("link", literal: "#guide",
            children: [api_model.MarkdownNode("text", literal: "Title jump")])]))
    }
    children.add(sectionAnchorHeading("Topic", 2))
    if (repeated) { children.add(sectionAnchorHeading("Topic", 2)) }
    children.add(sectionAnchorHeading("Other", 2))
    api_model.DocumentationPage("guide", "docs/guide.md", "concepts/guides/guide.html", title, "guide", "",
        api_model.MarkdownNode("document", children: children.toArray()), language: Some("en"),
        defaultLanguage: Some("en"), sections: sections)
}

private func sectionAnchorDocumentation(page: api_model.DocumentationPage): api_model.DocumentationSet {
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("section-anchor"), api_model.ConfigurationSnapshot(lintProfile: "off"),
        pages: [page], languageOptions: Some(api_model.DocumentationLanguageOptions("en")))
}

private func sectionAnchorContent(artifacts: Array<api_render.RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing section-anchor artifact")
}

private func expectSectionAnchorArtifacts(documentation: api_model.DocumentationSet,
    expected: Array<(String, String)>): Unit {
    let encoded = api_render.encodeDocIr(documentation)
    let imported = api_render.decodeDocIr(encoded)
    @Expect(api_render.encodeDocIr(imported), encoded)
    let artifacts = api_render.renderDocumentationFormatsWithOptions(imported, ["html"], allLanguages: true)
    let html = sectionAnchorContent(artifacts, "html/en/concepts/guides/guide.html")
    let routes = JsonNode.parse(sectionAnchorContent(artifacts, "site-manifest.json")).asObject()
        .get("routes").getOrThrow().asArray()
    let hrefs = HashSet<String>()
    var matches: Int64 = 0
    for ((id, anchor) in expected) {
        @Expect(html.contains("id=\"" + anchor + "\""))
        @Expect(html.contains("data-semantic-section=\"" + id + "\""))
        var found: Int64 = 0
        for (index in 0..routes.size()) {
            let route = routes.get(index).getOrThrow().asObject()
            if (route.get("sectionId").getOrThrow().isNull) { continue }
            if (route.get("sectionId").getOrThrow().asString() != id) { continue }
            let href = route.get("href").getOrThrow().asString()
            @Expect(href, "html/en/concepts/guides/guide.html#" + anchor)
            @Expect(hrefs.add(href))
            found++; matches++
        }
        @Expect(found, 1)
    }
    @Expect(matches, expected.size)
}

private func sectionAnchorSourceProject(sections: String, markdown: String): Path {
    let project = i18nTestProject("/** Summary. */")
    Directory.create(project.join("docs"))
    File.writeTo(project.join("docs/guide.md"), markdown.toArray())
    File.writeTo(project.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"en\"\nlanguages = [\"en\"]\n" +
        "[[docs.pages]]\nid = \"guide\"\nlanguage = \"en\"\nsource = \"docs/guide.md\"\n" +
        "route = \"concepts/guides/guide.html\"\ntitle = \"Guide\"\n[docs.pages.sections]\n" + sections).toArray())
    project
}

@Test
class I18nSectionAnchorTest {
    @TestCase
    func duplicateResolvedAnchorsAreRejectedForTypedPagesInBothOrders(): Unit {
        for (second in ["topic", "standalone--doc-topic"]) {
            let firstMapping = api_model.DocumentationSection("first", "topic")
            let secondMapping = api_model.DocumentationSection("second", second)
            for (sections in [[firstMapping, secondMapping], [secondMapping, firstMapping]]) {
                let documentation = sectionAnchorDocumentation(sectionAnchorPage(sections))
                @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(documentation))
                @ExpectThrows[IllegalArgumentException](api_render.renderDocumentationFormatsWithOptions(documentation,
                    ["html"], allLanguages: true))
            }
        }
    }

    @TestCase
    func strictImportRejectsRawAndFullAnchorAliasesForOneHeading(): Unit {
        let documentation = sectionAnchorDocumentation(sectionAnchorPage([
            api_model.DocumentationSection("first", "topic"), api_model.DocumentationSection("second", "other")]))
        let encoded = api_render.encodeDocIr(documentation)
        for (anchor in ["topic", "standalone--doc-topic"]) {
            let malformed = encoded.replace("\"anchor\": \"other\"", "\"anchor\": \"" + anchor + "\"")
            @Assert(malformed != encoded)
            @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(malformed))
        }
    }

    @TestCase
    func distinctHeadingsIncludingRepeatedTitleSuffixesRemainAddressable(): Unit {
        let page = sectionAnchorPage([api_model.DocumentationSection("first", "topic"),
            api_model.DocumentationSection("second", "standalone--doc-topic-1"),
            api_model.DocumentationSection("third", "other")], repeated: true)
        expectSectionAnchorArtifacts(sectionAnchorDocumentation(page), [("first", "standalone--doc-topic"),
            ("second", "standalone--doc-topic-1"), ("third", "standalone--doc-other")])
    }

    @TestCase
    func sourceCollisionsWarnAndOmitEveryAmbiguousMappingWithoutDroppingTheGuide(): Unit {
        for (sections in ["first = \"topic\"\nsecond = \"topic\"\n",
            "first = \"topic\"\nsecond = \"standalone--doc-topic\"\n",
            "second = \"standalone--doc-topic\"\nfirst = \"topic\"\n"]) {
            let project = sectionAnchorSourceProject(sections + "third = \"other\"\n",
                "# Guide\n\n## Topic\n\nBody retained.\n\n## Other\n\nOther body.\n")
            try {
                let generated = i18nTestGenerate(project)
                var pages: Int64 = 0
                for (page in generated.pages where page.id == "guide") {
                    @Assert(page.sections.size, 1)
                    @Expect(page.sections[0].id, "third")
                    @Expect(page.sections[0].anchor, "other")
                    pages++
                }
                @Expect(pages, 1)
                var warnings: Int64 = 0
                for (diagnostic in generated.diagnostics where diagnostic.code == "CJDOC3110") {
                    @Expect(diagnostic.severity, "warning")
                    warnings++
                }
                @Expect(warnings >= 2)
                expectSectionAnchorArtifacts(generated, [("third", "standalone--doc-other")])
                let artifacts = api_render.renderDocumentationFormatsWithOptions(generated, ["html"], allLanguages: true)
                let html = sectionAnchorContent(artifacts, "html/en/concepts/guides/guide.html")
                @Expect(html.contains("Body retained."))
                @Expect(!html.contains("data-semantic-section=\"first\""))
                @Expect(!html.contains("data-semantic-section=\"second\""))
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func sourceRepeatedHeadingsKeepTheirDifferentRenderedAnchors(): Unit {
        let project = sectionAnchorSourceProject("first = \"topic\"\nsecond = \"topic-1\"\n",
            "# Guide\n\n## Topic\n\nFirst.\n\n## Topic\n\nSecond.\n")
        try {
            let generated = i18nTestGenerate(project)
            for (diagnostic in generated.diagnostics) { @Expect(diagnostic.code != "CJDOC3110") }
            expectSectionAnchorArtifacts(generated, [("first", "standalone--doc-topic"),
                ("second", "standalone--doc-topic-1")])
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func suppressedLeadingTitleKeepsItsCapturedFragmentAndSemanticMapping(): Unit {
        for (title in ["Guide", "Page title"]) {
            let documentation = sectionAnchorDocumentation(sectionAnchorPage([
                api_model.DocumentationSection("title", "guide"), api_model.DocumentationSection("usage", "topic")],
                title: title, titleLink: true))
            expectSectionAnchorArtifacts(documentation, [("title", "standalone--doc-guide"),
                ("usage", "standalone--doc-topic")])
            let artifacts = api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], allLanguages: true)
            let html = sectionAnchorContent(artifacts, "html/en/concepts/guides/guide.html")
            @Expect(html.contains("href=\"#standalone--doc-guide\">Title jump</a>"))
            if (title == "Guide") { @Expect(html.split(">Guide</h1>").size, 2) }
        }
    }
}
