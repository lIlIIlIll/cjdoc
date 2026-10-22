package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

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
        modules: [api_model.ModuleDoc(moduleId, "showcase", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: [prefix + "b", prefix + "s", prefix + "i"])],
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
    File.writeTo(root.join("docs/guide.md"), ("# Hostile guide\n\n" +
        "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: String): Unit\" " +
        "language=\"</span><a href=phish>click</a>\" -->\n\n" +
        "```html\n<script>alert(1)</script>\n```\n").toArray())
    root
}

private func showcaseSearchEntry(artifacts: Array<api_render.RenderArtifact>, id: String): JsonObject {
    let entries = JsonNode.parse(artifactContent(artifacts, "html/search-index.json"))
        .asObject().get("entries").getOrThrow().asArray()
    for (index in 0..entries.size()) {
        let entry = entries.get(index).getOrThrow().asObject()
        if (entry.get("canonicalId").getOrThrow().asString() == id) { return entry }
    }
    throw IllegalStateException("expected search entry: " + id)
}

private func showcaseSymbolPage(artifacts: Array<api_render.RenderArtifact>, id: String): String {
    let href = showcaseSearchEntry(artifacts, id).get("href").getOrThrow().asString().split("#", 2)[0]
    artifactContent(artifacts, "html/" + href)
}

@Test
class CapturedPageShowcaseTest {
    @TestCase
    func capturedPagesDriveSearchAndExactOverloadNavigationInBothLocales(): Unit {
        let root = createShowcaseBindingProject()
        try {
            let documentation = captureDocumentationPages(showcaseBindingFixture(), GenerationRequest(root.toString()))
            @Expect(documentation.pages.isEmpty(), false)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2051"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2052"))
            for (locale in ["en", "zh-CN"]) {
                let artifacts = api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)
                let entries = JsonNode.parse(artifactContent(artifacts, "html/search-index.json"))
                    .asObject().get("entries").getOrThrow().asArray()
                let ids = HashSet<String>()
                var concepts: Int64 = 0
                for (index in 0..entries.size()) {
                    let entry = entries.get(index).getOrThrow().asObject()
                    @Expect(ids.add(entry.get("id").getOrThrow().asString()))
                    if (entry.get("kind").getOrThrow().asString() == "concept") { concepts++ }
                }
                @Expect(concepts, documentation.pages.size)
                let guide = artifactContent(artifacts, "html/concepts/guides/overload.html")
                @Expect(guide.contains("class=\"conceptual-bindings\""))
                @Expect(guide.contains(if (locale == "en") { "Linked" } else { "已关联" }))
                let stringPage = showcaseSymbolPage(artifacts, documentation.declarations[1].id)
                let integerPage = showcaseSymbolPage(artifacts, documentation.declarations[2].id)
                let ownerPage = showcaseSymbolPage(artifacts, documentation.declarations[0].id)
                @Expect(stringPage.contains("class=\"api-usages\""))
                @Expect(stringPage.contains("Exact String overload"))
                @Expect(!integerPage.contains("class=\"api-usages\""))
                @Expect(ownerPage.contains("class=\"api-usages\""))
            }
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func capturedGuideSearchPayloadCannotTerminateTheInlineScript(): Unit {
        let root = createHostileGuideProject()
        try {
            let documentation = captureDocumentationPages(showcaseBindingFixture(), GenerationRequest(root.toString()))
            let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
            let script = artifactContent(artifacts, "html/search-index.js")
            @Expect(script.contains("</script>"), false)
            @Expect(script.contains("<a href=phish"), false)
            @Expect(script.contains("\\u003c"), true)
            let json = artifactContent(artifacts, "html/search-index.json")
            @Expect(json.contains("</span>"), false)
            @Expect(json.contains("\\u003c/span\\u003e"), true)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func capturedHomePageProvidesOneGuideEntry(): Unit {
        let root = createShowcaseBindingProject()
        try {
            let documentation = captureDocumentationPages(showcaseBindingFixture(), GenerationRequest(root.toString()))
            let index = artifactContent(api_render.HtmlDocumentationRenderer().render(documentation), "html/index.html")
            @Expect(index.contains("concepts/index.html"))
            @Expect(index.contains("data-conceptual-entry"))
            @Expect(index.contains("Open conceptual documentation"))
            @Expect(index.split("Start here").size, 2)
            @Expect(!index.contains("Start with the guide"))
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func capturedBindingInsideATableKeepsTheTableIntact(): Unit {
        let root = createShowcaseBindingProject()
        try {
            File.writeTo(root.join("docs/guide.md"), ("# Table binding\n\n" +
                "| A | B |\n| - | - |\n| one | two |\n" +
                "<!-- cjdoc-bind target=\"fixture.Box.add\" selector=\"signature:public func add(value: String): Unit\" -->\n" +
                "| three | four |\n").toArray())
            let documentation = captureDocumentationPages(showcaseBindingFixture(), GenerationRequest(root.toString()))
            let guide = artifactContent(api_render.HtmlDocumentationRenderer().render(documentation),
                "html/concepts/guides/overload.html")
            @Expect(guide.split("<table>").size, 2)
            @Expect(guide.contains("class=\"inline-binding\""))
            @Expect(!guide.contains("cjdoc-inline-binding"))
        } finally { let _ = removeIfExists(root, recursive: true) }
    }
}
