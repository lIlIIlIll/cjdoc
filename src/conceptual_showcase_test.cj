package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func showcaseBindingFixture(): api_model.DocumentationSet {
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let moduleId = "cjdoc:module:v1:showcase"
    let prefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ashowcase::"
    let semantic = api_model.SemanticInfo("partial", "ast-fallback")
    let contract = api_model.DocComment("Contract.", "Contract.", "",
        api_model.MarkdownNode("document"),
        tags: [api_model.DocTag("precondition", "", "A documented precondition.")])
    let owner = api_model.SymbolDoc(prefix + "b", "class", "Box", "fixture.Box", "fixture", moduleId,
        "public", source, "public class Box", semantic, documentation: Some(contract))
    let stringMember = api_model.SymbolDoc(prefix + "s", "function", "add", "fixture.Box.add", "fixture", moduleId,
        "public", source, "public func add(value: String): Unit", semantic,
        documentation: Some(contract), ownerId: Some(prefix + "b"))
    let integerMember = api_model.SymbolDoc(prefix + "i", "function", "add", "fixture.Box.add", "fixture", moduleId,
        "public", source, "public func add(value: Int64): Unit", semantic,
        documentation: Some(contract), ownerId: Some(prefix + "b"))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("showcase-binding"), api_model.ConfigurationSnapshot(audience: "external"),
        providers: [api_model.ProviderInfo("ast-fallback", "builtin", moduleId, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(moduleId, "showcase-binding", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [prefix + "b", prefix + "s", prefix + "i"])],
        files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: [owner, stringMember, integerMember])
}

private func createShowcaseBindingProject(): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("docs"))
    File.writeTo(root.join("cjdoc.toml"), """
        [docs]
        index = "docs/index.md"
        [[docs.pages]]
        source = "docs/guide.md"
        route = "concepts/guides/overload"
        title = "Exact String overload"
        [[docs.pages]]
        source = "docs/missing.md"
        route = "concepts/guides/missing"
        title = "Absent signature"
        [external-docs.support]
        index = "docs/support.json"
        base-url = "./dependencies/support-v1"
        version = "support-v1"
        """.toArray())
    File.writeTo(root.join("docs/index.md"), "# Binding fixture\n".toArray())
    File.writeTo(root.join("docs/guide.md"), ("# Exact String overload\n\n" +
        "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: String): Unit\" -->\n").toArray())
    File.writeTo(root.join("docs/missing.md"), ("# Absent signature\n\n" +
        "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: Bool): Unit\" -->\n").toArray())
    File.writeTo(root.join("docs/support.json"), """
        {"schemaVersion":"cjdoc.symbol-index/1","version":"support-v1","symbols":[
          {"qualifiedName":"fixture.Box","href":"symbols/box.html"}
        ]}
        """.toArray())
    root
}

// A guide that carries hostile markup in author-controlled text, so the
// search payload built from it is checked for inline-<script> safety.
private func createHostileGuideProject(): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("docs"))
    File.writeTo(root.join("cjdoc.toml"), """
        [docs]
        index = "docs/index.md"
        [[docs.pages]]
        source = "docs/guide.md"
        route = "concepts/guides/hostile"
        title = "Hostile guide"
        """.toArray())
    File.writeTo(root.join("docs/index.md"), "# Hostile fixture\n".toArray())
    File.writeTo(root.join("docs/guide.md"), ("# Hostile guide\n\n" +
        "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: String): Unit\" " +
        "language=\"</span><a href=phish>click</a>\" -->\n\n" +
        "```html\n<script>alert(1)</script>\n```\n").toArray())
    root
}

@Test
class ConceptualShowcaseTest {
    @TestCase
    func exactOverloadGuidesStayOnTheirMemberInBothLocales(): Unit {
        let root = createShowcaseBindingProject()
        try {
            for (locale in ["en", "zh-CN"]) {
                let documentation = showcaseBindingFixture()
                let pages = conceptualPagesForProject(root.toString(), documentation)
                @Expect(publicHasDiagnostic(documentation, "CJDOC2051"))
                @Expect(!publicHasDiagnostic(documentation, "CJDOC2052"))
                let artifacts = appendConceptualArtifacts(root.toString(), documentation, ["html"],
                    api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale), pages,
                    locale: locale)
                let guide = artifactContent(artifacts, "html/concepts/guides/overload.html")
                @Expect(guide.contains(conceptualSymbolPath(documentation.declarations[1].id)))
                @Expect(!guide.contains(conceptualSymbolPath(documentation.declarations[2].id)))
                let stringPage = artifactContent(artifacts, "html/" + conceptualSymbolPath(documentation.declarations[1].id))
                let integerPage = artifactContent(artifacts, "html/" + conceptualSymbolPath(documentation.declarations[2].id))
                @Expect(stringPage.contains("class=\"conceptual-bindings api-usages\""))
                @Expect(!integerPage.contains("class=\"conceptual-bindings api-usages\""))
                let owner = artifactContent(artifacts, "html/" + conceptualSymbolPath(documentation.declarations[0].id))
                @Expect(owner.split("class=\"conceptual-bindings api-usages\"").size, 2)
                @Expect(owner.contains("conceptual-api-usages-heading-inline-" + conceptualSymbolSlug(documentation.declarations[1].id)))
                @Expect(!owner.contains("conceptual-api-usages-heading-inline-" + conceptualSymbolSlug(documentation.declarations[2].id)))
                @Expect(owner.split("class=\"behavior-contracts\"").size, 4)
                for (symbol in documentation.declarations) {
                    let heading = "symbol-" + conceptualSymbolSlug(symbol.id) + "--behavior-contracts-heading"
                    @Expect(owner.split("id=\"" + heading + "\"").size, 2)
                    @Expect(owner.contains("aria-labelledby=\"" + heading + "\""))
                }
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func localExternalReferencesStayRootedAtTheDocumentationSet(): Unit {
        let root = createShowcaseBindingProject()
        try {
            let documentation = showcaseBindingFixture()
            let pages = conceptualPagesForProject(root.toString(), documentation)
            let artifacts = appendConceptualArtifacts(root.toString(), documentation, ["html"],
                api_render.HtmlDocumentationRenderer().render(documentation), pages)
            let owner = artifactContent(artifacts, "html/" + conceptualSymbolPath(documentation.declarations[0].id))
            @Expect(owner.contains("href=\"../dependencies/support-v1/symbols/box.html\""))
            @Expect(!owner.contains("href=\"./dependencies/support-v1/symbols/box.html\""))
            @Expect(owner.contains("Open external reference"))
            @Expect(!owner.contains("Open official reference"))
            @Expect(owner.contains("version: support-v1"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func conceptualSourceLinksUseConfiguredRoutesAndRenderedFragments(): Unit {
        let index = ConceptualPage("README.md", "concepts/index.html", "Start", "project",
            "# Start\n\n[Guide](docs/guide.md#topic) [Remote](https://example.test/guide.md)\n\n" +
            "`[Code](docs/guide.md)`\n")
        let guide = ConceptualPage("docs/guide.md", "concepts/guides/custom.html", "Guide", "page",
            "# Guide\n\n## Topic\n\n[Back](../README.md) [Escape](../../README.md)\n")
        let pages = ArrayList<ConceptualPage>([index, guide])
        let artifacts = renderConceptualDocumentationArtifacts(showcaseBindingFixture(), ["html"], pages)
        let indexHtml = artifactContent(artifacts, "html/concepts/index.html")
        let guideHtml = artifactContent(artifacts, "html/concepts/guides/custom.html")
        @Expect(indexHtml.contains("href=\"../concepts/guides/custom.html#standalone--doc-topic\""))
        @Expect(guideHtml.contains("id=\"standalone--doc-topic\""))
        @Expect(guideHtml.contains("href=\"../../concepts/index.html\""))
        @Expect(!guideHtml.contains("href=\"../../README.md\""))
        @Expect(indexHtml.contains("href=\"https://example.test/guide.md\""))
        @Expect(indexHtml.contains("<code>[Code](docs/guide.md)</code>"))
    }

    @TestCase
    func conceptualLinksDoNotGuessAmbiguousSourcesOrAcceptUnsafeMappings(): Unit {
        let current = ConceptualPage("docs/index.md", "concepts/index.html", "Index", "project", "")
        let pages = ArrayList<ConceptualPage>([current,
            ConceptualPage("docs/guide.md", "concepts/one.html", "One", "page", "# One"),
            ConceptualPage("docs/guide.md", "concepts/two.html", "Two", "page", "# Two")])
        let parsed = parseStandaloneMarkdown("[Guide](guide.md) [Absent](missing.md)\n")
        @Expect(conceptualSourceLinks(parsed, current, pages).isEmpty())
        let hostile = HashMap<String, String>()
        hostile["guide.md"] = "javascript:alert(1)"
        hostile["missing.md"] = "//example.test/escape"
        let rendered = api_render.renderStandaloneMarkdownHtml(parsed, sourceLinks: hostile)
        @Expect(!rendered.contains("href="))
    }

    @TestCase
    func guideSearchPayloadCannotTerminateTheInlineScriptElement(): Unit {
        let root = createHostileGuideProject()
        try {
            let documentation = showcaseBindingFixture()
            let pages = conceptualPagesForProject(root.toString(), documentation)
            let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
            let rendered = appendConceptualArtifacts(root.toString(), documentation,
                ["html"], artifacts, pages, locale: "en")
            let script = artifactContent(rendered, "html/search-index.js")
            // Author-controlled text must never reach the payload as raw markup.
            @Expect(script.contains("</script>"), false)
            @Expect(script.contains("<a href=phish"), false)
            @Expect(script.contains("\\u003c"), true)
            // Escaping is decode-equivalent: the standalone JSON keeps the value.
            let json = artifactContent(rendered, "html/search-index.json")
            @Expect(json.contains("</span>"), false)
            @Expect(json.contains("\\u003c/span\\u003e"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func bindingChipsRenderBesideTheBlockAndKeepTechnicalDetailCollapsed(): Unit {
        let root = createShowcaseBindingProject()
        try {
            for (locale in ["en", "zh-CN"]) {
                let documentation = showcaseBindingFixture()
                let pages = conceptualPagesForProject(root.toString(), documentation)
                let artifacts = appendConceptualArtifacts(root.toString(), documentation, ["html"],
                    api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale),
                    pages, locale: locale)
                let guide = artifactContent(artifacts, "html/concepts/guides/overload.html")
                // Exactly one reader-facing chip, placed before the page-level index.
                @Expect(guide.split("class=\"inline-binding\"").size, 2)
                let chipAt = guide.indexOf("class=\"inline-binding\"").getOrThrow()
                let indexAt = guide.indexOf("id=\"conceptual-bindings-heading\"").getOrThrow()
                @Expect(chipAt < indexAt, true)
                // The chip carries reader wording, never the raw IR state word.
                let chip = guide[chipAt..]
                // Reader-facing state text is localized, never the raw IR word.
                let valueAt = chip.indexOf("data-state=\"resolved\">").getOrThrow()
                let valueStart = valueAt + "data-state=\"resolved\">".size
                let valueEnd = chip.indexOf("</span>", valueStart).getOrThrow()
                let visible = chip[valueStart..valueEnd]
                @Expect(visible == "resolved", false)
                @Expect(visible.size > 0, true)
                // Maintenance detail stays behind the disclosure, after the chip.
                @Expect(chip.indexOf("binding-details").getOrThrow() >
                    chip.indexOf("</span>").getOrThrow(), true)
                @Expect(guide.contains("state: resolved"), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func bindingMarkerInsideATableKeepsTheTableIntact(): Unit {
        // A marker placed between GFM table rows must not split the table: the
        // chip goes into the cell, and the rows after it stay in one table.
        let root = createShowcaseBindingProject()
        try {
            File.writeTo(root.join("docs/guide.md"), ("# Table binding\n\n" +
                "| A | B |\n| - | - |\n| one | two |\n" +
                "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: String): Unit\" -->\n" +
                "| three | four |\n").toArray())
            let documentation = showcaseBindingFixture()
            let pages = conceptualPagesForProject(root.toString(), documentation)
            let artifacts = appendConceptualArtifacts(root.toString(), documentation, ["html"],
                api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en"),
                pages, locale: "en")
            let guide = artifactContent(artifacts, "html/concepts/guides/overload.html")
            // One table for all three rows, and the chip rendered in place.
            @Expect(guide.split("<table>").size, 2)
            @Expect(guide.contains("class=\"inline-binding\""), true)
            @Expect(guide.contains("cjdoc-inline-binding"), false)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
