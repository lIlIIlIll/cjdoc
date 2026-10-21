package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func externalMarkdownFixture(audience!: String = "external",
    invalidUrl!: Bool = false): DocumentationSet {
    let moduleId = "cjdoc:module:v1:codec"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Acodec::codec::function:f#g0()"
    let hiddenId = symbolId.replace("function:f", "function:hidden")
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let semantic = SemanticInfo("partial", "ast")
    let symbol = SymbolDoc(symbolId, "function", "f", "codec.f", "codec", moduleId,
        "public", source, "public func f(): Unit", semantic)
    let hidden = SymbolDoc(hiddenId, "function", "hidden", "codec.hidden", "codec", moduleId,
        "private", source, "private func hidden(): Unit", semantic)
    let url = if (invalidUrl) { "javascript:alert(1)" } else { "https://docs.example.test/a (b).html" }
    let references = [
        ExternalDocumentationReference(symbolId, "support\n\n![owned](javascript:alert(1)) <b>", "available", url,
            version: "v`1", index: "docs/index.json", format: "cjdoc.symbol-index/1", fingerprint: "abc"),
        ExternalDocumentationReference(symbolId, "local", "available", "./dependencies/ref.html"),
        ExternalDocumentationReference(symbolId, "missing", "unavailable", "", reason: "Missing\n# <script>"),
        ExternalDocumentationReference(symbolId, "duplicate", "ambiguous", "", reason: "Two candidates"),
        ExternalDocumentationReference(hiddenId, "private-reference", "available", "https://docs.example.test/private.html")]
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("codec"),
        ConfigurationSnapshot(audience: audience, lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "codec", "root", "", packageNames: ["codec"])],
        packages: [PackageDoc("codec", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId, hiddenId])],
        files: [FileDoc("src/api.cj", moduleId, "codec")], declarations: [symbol, hidden],
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
    func sourceFreeMarkdownEntrypointsRenderSafeExternalMetadata(): Unit {
        let original = externalMarkdownFixture()
        let encoded = encodeDocIr(original)
        let imported = decodeDocIr(encoded)
        for (locale in ["en", "zh-CN"]) {
            let content = externalMarkdownText(renderDocumentationFormatsWithOptions(imported, ["markdown"], locale: locale))
            expectExternalMarkdownRoutes(content, "../")
            @Expect(content.contains(if (locale == "en") { "Ambiguous reference" } else { "引用不明确" }))
            @Expect(content.contains(if (locale == "en") { "No external reference" } else { "无外部参考" }))
        }
        expectExternalMarkdownRoutes(externalMarkdownText(MarkdownDocumentationRenderer().render(imported)), "../")
        @Expect(encodeDocIr(imported), encoded)
        @Expect(encodeDocIr(original), encoded)
    }

    @TestCase
    func importedPrivateReferencesRespectEachAudience(): Unit {
        for (audience in ["external", "package", "all"]) {
            let original = externalMarkdownFixture(audience: audience)
            let encoded = encodeDocIr(original)
            let imported = decodeDocIr(encoded)
            let content = externalMarkdownText(renderDocumentationFormatsWithOptions(imported,
                ["markdown"], locale: "en"))
            @Expect(content.contains("https://docs.example.test/private.html"), audience == "all")
            @Expect(content.contains("private\\-reference"), audience == "all")
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
