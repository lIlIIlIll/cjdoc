package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let EXTERNAL_SNAPSHOT_URL = "https://docs.example.test/support-v1/symbols/box.html"

private func externalSnapshotProject(ambiguous: Bool): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"))
    Directory.create(root.join("docs"))
    File.writeTo(root.join("cjpm.toml"),
        "[package]\nname = \"fixture\"\nversion = \"1.0.0\"\noutput-type = \"static\"\n".toArray())
    File.writeTo(root.join("src/api.cj"),
        "package fixture\n/** Box. */\npublic class Box {}\n/** Hidden. */\nprivate class Hidden {}\n".toArray())
    let offline = if (ambiguous) {
        "[external-docs.offline]\nindex = \"docs/missing.json\"\n" +
            "base-url = \"https://docs.example.test/offline\"\nversion = \"support-v1\"\n"
    } else { "" }
    File.writeTo(root.join("cjdoc.toml"),
        ("[external-docs.support]\nindex = \"docs/support.json\"\n" +
            "base-url = \"https://docs.example.test/support-v1\"\nversion = \"support-v1\"\n" + offline).toArray())
    let duplicate = if (ambiguous) {
        ",{\"qualifiedName\":\"fixture.Box\",\"href\":\"symbols/other-box.html\"}"
    } else { "" }
    File.writeTo(root.join("docs/support.json"),
        ("{\"schemaVersion\":\"cjdoc.symbol-index/1\",\"version\":\"support-v1\",\"symbols\":[" +
            "{\"qualifiedName\":\"fixture.Box\",\"href\":\"symbols/box.html\"}" + duplicate +
            ",{\"qualifiedName\":\"fixture.Hidden\",\"href\":\"symbols/hidden.html\"}]}\n").toArray())
    root
}

private func externalSnapshotGenerate(root: Path): api_model.DocumentationSet {
    let binary = getVariable("CJDOC_I18N_BINARY").getOrDefault({ => "target/release/bin/main" })
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
        astPreflightExecutable: Some(binary)))
}

private func externalSnapshotArtifact(artifacts: Array<api_render.RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalStateException("expected rendered artifact: " + path)
}

private func externalSnapshotSearchEntry(artifacts: Array<api_render.RenderArtifact>, id: String): JsonObject {
    let entries = JsonNode.parse(externalSnapshotArtifact(artifacts, "html/search-index.json"))
        .asObject()["entries"].asArray()
    for (index in 0..entries.size()) {
        let entry = entries.get(index).getOrThrow().asObject()
        if (entry["canonicalId"].asString() == id) { return entry }
    }
    throw IllegalStateException("expected external-reference search entry")
}

private func externalSnapshotReference(documentation: api_model.DocumentationSet,
    name: String): api_model.ExternalDocumentationReference {
    for (reference in documentation.externalDocumentation where reference.name == name) { return reference }
    throw IllegalStateException("expected captured external resolver: " + name)
}

private func expectExternalSnapshotSearchMetadata(entry: JsonObject,
    reference: api_model.ExternalDocumentationReference): Unit {
    let values = entry["externalDocs"].asArray()
    var found: Int64 = 0
    for (index in 0..values.size()) {
        let value = values.get(index).getOrThrow().asObject()
        if (value["name"].asString() != reference.name) { continue }
        found++
        @Expect(value["state"].asString(), reference.state)
        @Expect(value["url"].asString(), reference.url)
        @Expect(value["reason"].asString(), reference.reason)
        @Expect(value["version"].asString(), reference.version)
        @Expect(value["index"].asString(), reference.index)
        @Expect(value["format"].asString(), reference.format)
        @Expect(value["fingerprint"].asString(), reference.fingerprint)
    }
    @Expect(found, 1)
}

private func expectExternalSnapshotMarkdown(content: String,
    reference: api_model.ExternalDocumentationReference): Unit {
    @Expect(content.split("](" + reference.url + ")").size, 2)
    @Expect(content.split("External documentation").size, 2)
    for (text in [reference.version, reference.index, reference.format, reference.fingerprint]) {
        @Expect(content.contains(text))
    }
}

@Test
class ExternalDocumentationSnapshotTest {
    @TestCase
    func unlocalizedExternalReferencesSurviveSourceRemoval(): Unit {
        let root = externalSnapshotProject(false)
        try {
            let generated = externalSnapshotGenerate(root)
            @Expect(generated.languageOptions.isNone())
            @Expect(generated.pages.isEmpty())
            @Expect(generated.externalDocumentation.size, 1)
            let reference = externalSnapshotReference(generated, "support")
            @Expect(reference.state, "available")
            @Expect(reference.url, EXTERNAL_SNAPSHOT_URL)
            @Expect(reference.version, "support-v1")
            @Expect(reference.index, "docs/support.json")
            @Expect(reference.format, "cjdoc.symbol-index/1")
            @Expect(reference.fingerprint.size, 64)
            var hidden: Int64 = 0
            for (symbol in generated.declarations where symbol.qualifiedName == "fixture.Hidden") {
                hidden++
                @Expect(symbol.id != reference.symbolId)
            }
            @Expect(hidden, 1)
            let before = api_render.renderDocumentationFormatsWithOptions(generated, ["html", "markdown"], locale: "en")
            let encoded = api_render.encodeDocIr(generated)
            let _ = removeIfExists(root, recursive: true)
            @Expect(!exists(root))
            let imported = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(imported), encoded)
            let after = api_render.renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
            let entry = externalSnapshotSearchEntry(after, reference.symbolId)
            @Expect(entry["externalDocs"].asArray().size(), 1)
            expectExternalSnapshotSearchMetadata(entry, reference)
            let page = "html/" + entry["href"].asString()
            let html = externalSnapshotArtifact(after, page)
            @Expect(html.split("href=\"" + EXTERNAL_SNAPSHOT_URL + "\"").size, 2)
            @Expect(html.split("class=\"external-documentation\"").size, 2)
            @Expect(html.contains("index: docs/support.json"))
            @Expect(html.contains("format: cjdoc.symbol-index/1"))
            @Expect(html.contains("fingerprint: " + reference.fingerprint))
            @Expect(html, externalSnapshotArtifact(before, page))
            @Expect(externalSnapshotArtifact(after, "html/search-index.json"),
                externalSnapshotArtifact(before, "html/search-index.json"))
            let markdownPath = "markdown/" + entry["href"].asString().removeSuffix(".html") + ".md"
            let markdown = externalSnapshotArtifact(after, markdownPath)
            expectExternalSnapshotMarkdown(markdown, reference)
            @Expect(markdown, externalSnapshotArtifact(before, markdownPath))
            let direct = api_render.MarkdownDocumentationRenderer().render(imported)
            expectExternalSnapshotMarkdown(externalSnapshotArtifact(direct, markdownPath), reference)
            @Expect(externalSnapshotArtifact(direct, markdownPath), markdown)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func unlocalizedExternalFailureStatesAndVisibilitySurviveSourceRemoval(): Unit {
        let root = externalSnapshotProject(true)
        try {
            let generated = externalSnapshotGenerate(root)
            @Expect(generated.languageOptions.isNone())
            @Expect(generated.externalDocumentation.size, 2)
            let ambiguous = externalSnapshotReference(generated, "support")
            let unavailable = externalSnapshotReference(generated, "offline")
            @Expect(ambiguous.state, "ambiguous")
            @Expect(ambiguous.url, "")
            @Expect(unavailable.state, "unavailable")
            @Expect(unavailable.url, "")
            @Expect(!unavailable.reason.isEmpty())
            var hidden: Int64 = 0
            for (symbol in generated.declarations where symbol.qualifiedName == "fixture.Hidden") {
                hidden++
                for (reference in generated.externalDocumentation) { @Expect(symbol.id != reference.symbolId) }
            }
            @Expect(hidden, 1)
            let encoded = api_render.encodeDocIr(generated)
            let _ = removeIfExists(root, recursive: true)
            @Expect(!exists(root))
            let imported = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(imported), encoded)
            let rendered = api_render.renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
            let entry = externalSnapshotSearchEntry(rendered, ambiguous.symbolId)
            @Expect(entry["externalDocs"].asArray().size(), 2)
            expectExternalSnapshotSearchMetadata(entry, ambiguous)
            expectExternalSnapshotSearchMetadata(entry, unavailable)
            let html = externalSnapshotArtifact(rendered, "html/" + entry["href"].asString())
            @Expect(html.contains("data-state=\"ambiguous\""))
            @Expect(html.contains("data-state=\"unavailable\""))
            @Expect(!html.contains("href=\"" + EXTERNAL_SNAPSHOT_URL + "\""))
            @Expect(!html.contains("hidden.html"))
            let markdownPath = "markdown/" + entry["href"].asString().removeSuffix(".html") + ".md"
            let markdown = externalSnapshotArtifact(rendered, markdownPath)
            @Expect(markdown.contains("Ambiguous reference"))
            @Expect(markdown.contains("No external reference"))
            @Expect(!markdown.contains(EXTERNAL_SNAPSHOT_URL))
            @Expect(!markdown.contains("hidden.html"))
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func unlocalizedExternalMemberLinksStayInsideTheOwnerInlineDetails(): Unit {
        let root = externalSnapshotProject(false)
        try {
            File.writeTo(root.join("src/api.cj"),
                ("package fixture\n/** Box. */\npublic class Box {\n" +
                    "    /** Touch. */\n    public func touch(): Unit {}\n}\n").toArray())
            File.writeTo(root.join("docs/support.json"),
                ("{\"schemaVersion\":\"cjdoc.symbol-index/1\",\"version\":\"support-v1\",\"symbols\":[" +
                    "{\"qualifiedName\":\"fixture.Box.touch\",\"href\":\"symbols/touch.html\"}]}\n").toArray())
            let generated = externalSnapshotGenerate(root)
            @Expect(generated.languageOptions.isNone())
            @Expect(generated.externalDocumentation.size, 1)
            let reference = externalSnapshotReference(generated, "support")
            let url = "https://docs.example.test/support-v1/symbols/touch.html"
            @Expect(reference.url, url)
            var ownerId = ""
            for (symbol in generated.declarations where symbol.qualifiedName == "fixture.Box") { ownerId = symbol.id }
            @Assert(!ownerId.isEmpty())
            let encoded = api_render.encodeDocIr(generated)
            let _ = removeIfExists(root, recursive: true)
            @Expect(!exists(root))
            let imported = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(imported), encoded)
            let rendered = api_render.renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
            let entry = externalSnapshotSearchEntry(rendered, reference.symbolId)
            expectExternalSnapshotSearchMetadata(entry, reference)
            let canonicalPath = entry["href"].asString().split("#", 2)[0]
            @Expect(externalSnapshotArtifact(rendered, "html/" + canonicalPath)
                .split("href=\"" + url + "\"").size, 2)
            let ownerEntry = externalSnapshotSearchEntry(rendered, ownerId)
            let ownerPath = ownerEntry["href"].asString().split("#", 2)[0]
            let html = externalSnapshotArtifact(rendered, "html/" + ownerPath)
            let start = html.indexOf("<details class=\"declaration-summary member-detail\"").getOrThrow()
            let end = start + html[start..].indexOf("</details>").getOrThrow()
            let member = html[start..end]
            @Expect(member.contains("data-member-name=\"touch\""))
            @Expect(member.split("href=\"" + url + "\"").size, 2)
            @Expect(member.split("class=\"external-documentation\"").size, 2)
            @Expect(member.contains("index: docs/support.json"))
            @Expect(member.contains("format: cjdoc.symbol-index/1"))
            @Expect(member.contains("fingerprint: " + reference.fingerprint))
            let markdownPath = "markdown/" + ownerPath.removeSuffix(".html") + ".md"
            expectExternalSnapshotMarkdown(externalSnapshotArtifact(rendered, markdownPath), reference)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }
}
