package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func externalMarkdownFixture(audience!: String = "external",
    invalidUrl!: Bool = false): DocumentationSet {
    let original = decodeDocIr(V7_CODEC_FIXTURE)
    let symbol = original.declarations[0]
    let hiddenId = symbol.id.replace("function:f", "function:hidden")
    let hidden = SymbolDoc(hiddenId, "function", "hidden", "codec.hidden", "codec", symbol.moduleId,
        "private", symbol.source, "private func hidden(): Unit", symbol.semantic)
    let url = if (invalidUrl) { "javascript:alert(1)" } else { "https://docs.example.test/a (b).html" }
    let references = [
        ExternalDocumentationReference(symbol.id, "support\n\n![owned](javascript:alert(1)) <b>", "available", url,
            version: "v`1", index: "docs/index.json", format: "cjdoc.symbol-index/1", fingerprint: "abc"),
        ExternalDocumentationReference(symbol.id, "local", "available", "./dependencies/ref.html"),
        ExternalDocumentationReference(symbol.id, "missing", "unavailable", "", reason: "Missing\n# <script>"),
        ExternalDocumentationReference(symbol.id, "duplicate", "ambiguous", "", reason: "Two candidates"),
        ExternalDocumentationReference(hiddenId, "private-reference", "available", "https://docs.example.test/private.html")]
    DocumentationSet(original.generator, original.status, original.project,
        ConfigurationSnapshot(audience: audience, lintProfile: "off"),
        providers: original.providers.toArray(), modules: original.modules.toArray(),
        packages: [PackageDoc("codec", symbol.moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbol.id, hiddenId])],
        files: original.files.toArray(), declarations: [symbol, hidden], assets: original.assets.toArray(),
        externalDocumentation: references)
}

private func externalMarkdownText(artifacts: Array<RenderArtifact>): String {
    var text = ""
    for (artifact in artifacts where artifact.path.endsWith(".md")) { text += artifact.content }
    text
}

private func expectExternalMarkdownRoutes(content: String, relativePrefix: String): Unit {
    @Expect(content.split("](https://docs.example.test/a%20%28b%29.html)").size, 2)
    @Expect(content.split("](" + relativePrefix + "dependencies/ref.html)").size, 2)
    @Expect(!content.contains("![owned]"))
    @Expect(!content.contains("<b>"))
    @Expect(!content.contains("<script>"))
    @Expect(content.contains("\\!\\[owned\\]"))
    @Expect(content.contains("docs/index.json"))
    @Expect(content.contains("cjdoc.symbol-index/1"))
    @Expect(content.contains("fingerprint: `abc`"))
}

@Test
class ExternalDocumentationMarkdownTest {
    @TestCase
    func sourceFreeSiteAndSingleLayoutsRenderSafeExternalMetadata(): Unit {
        let original = externalMarkdownFixture()
        let encoded = encodeDocIr(original)
        let imported = decodeDocIr(encoded)
        for (locale in ["en", "zh-CN"]) {
            let content = externalMarkdownText(renderDocumentationFormatsWithOptions(imported, ["markdown"], locale: locale))
            expectExternalMarkdownRoutes(content, "../")
            @Expect(content.contains(if (locale == "en") { "Ambiguous reference" } else { "引用不明确" }))
            @Expect(content.contains(if (locale == "en") { "No external reference" } else { "无外部参考" }))
        }
        for (single in [MarkdownDocumentationRenderer().render(imported),
            renderDocumentationFormatsWithOptions(imported, ["markdown"], locale: "en", markdownLayout: "single")]) {
            expectExternalMarkdownRoutes(externalMarkdownText(single), "")
        }
        @Expect(encodeDocIr(imported), encoded)
        @Expect(encodeDocIr(original), encoded)
    }

    @TestCase
    func importedPrivateReferencesRespectEachAudience(): Unit {
        for (audience in ["external", "package", "all"]) {
            let original = externalMarkdownFixture(audience: audience)
            let encoded = encodeDocIr(original)
            let imported = decodeDocIr(encoded)
            for (layout in ["site", "single"]) {
                let content = externalMarkdownText(renderDocumentationFormatsWithOptions(imported,
                    ["markdown"], locale: "en", markdownLayout: layout))
                @Expect(content.contains("https://docs.example.test/private.html"), audience == "all")
                @Expect(content.contains("private\\-reference"), audience == "all")
            }
            @Expect(encodeDocIr(original), encoded)
        }
    }

    @TestCase
    func unsafeExternalSnapshotUrlsRemainStrictlyRejected(): Unit {
        let documentation = externalMarkdownFixture(invalidUrl: true)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(encodeDocIr(documentation)))
        @ExpectThrows[IllegalArgumentException](renderDocumentationFormatsWithOptions(documentation, ["markdown"]))
    }
}
