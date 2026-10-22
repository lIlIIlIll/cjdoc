package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let ENTRYPOINT_EN_IMAGE = "sha256-e878950f8091ec010cf5cc723bdea027a8539cf7147cfea199c2f666232dcd4e"
private let ENTRYPOINT_ZH_IMAGE = "sha256-c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96"
private let ENTRYPOINT_GUIDE = "concepts/guides/deep/start.html"

private func entrypointGuide(language: String): DocumentationPage {
    let english = language == "en"
    let title = if (english) { "English guide" } else { "Chinese guide" }
    let image = if (english) { ENTRYPOINT_EN_IMAGE } else { ENTRYPOINT_ZH_IMAGE }
    let tree = MarkdownNode("document", children: [
        MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
            children: [MarkdownNode("text", literal: title)]),
        MarkdownNode("paragraph", children: [MarkdownNode("image", literal: image,
            children: [MarkdownNode("text", literal: "Safe <diagram>")])]),
        MarkdownNode("html_block", literal: "<script>window.pageNote=true</script>"),
        MarkdownNode("paragraph", children: [MarkdownNode("link", literal: "javascript:alert(1)",
            children: [MarkdownNode("text", literal: "Unsafe destination")])])])
    DocumentationPage("guide", "docs/" + language + "/start.md", ENTRYPOINT_GUIDE,
        title, "guide", "Captured guide", tree,
        language: Some(language), defaultLanguage: Some("zh-CN"))
}

private func entrypointDocumentation(includeEnglish!: Bool = true): DocumentationSet {
    let chinese = entrypointGuide("zh-CN")
    let pages = if (includeEnglish) { [chinese, entrypointGuide("en")] } else { [chinese] }
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("html-entrypoints"), ConfigurationSnapshot(lintProfile: "off"),
        languageOptions: Some(DocumentationLanguageOptions("zh-CN", languages: ["zh-CN", "en"])),
        pages: pages, assets: [
            AssetDoc(ENTRYPOINT_EN_IMAGE, "image/png", "docs/en/diagram.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"),
            AssetDoc(ENTRYPOINT_ZH_IMAGE, "image/png", "docs/zh-CN/diagram.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC")])
    decodeDocIr(encodeDocIr(original))
}

private func entrypointContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing public HTML reading artifact")
}

private func verifyCompleteHtmlEntrypoint(artifacts: Array<RenderArtifact>, locale: String,
    englishContent: Bool): Unit {
    let index = entrypointContent(artifacts, "html/index.html")
    @Expect(index.contains("href=\"" + ENTRYPOINT_GUIDE + "\""))
    let guide = entrypointContent(artifacts, "html/" + ENTRYPOINT_GUIDE)
    @Expect(guide.contains("<html lang=\"" + locale + "\""))
    @Expect(guide.contains(if (englishContent) { "English guide" } else { "Chinese guide" }))
    @Expect(!guide.contains(if (englishContent) { "Chinese guide" } else { "English guide" }))
    @Expect(guide.contains("alt=\"Safe &lt;diagram&gt;\""))
    @Expect(!guide.contains("<script>window.pageNote"))
    @Expect(!guide.contains("href=\"javascript:"))
    var images: Int64 = 0
    for (artifact in artifacts where artifact.path.startsWith("html/assets/")) {
        @Expect(artifact.isBinary)
        @Expect(artifact.bytes.size, 69)
        let expectedByte: Byte = if (englishContent) { 0xf8 } else { 0x60 }
        @Expect(artifact.bytes[44], expectedByte)
        let destination = artifact.path.removePrefix("html/")
        @Expect(guide.contains("src=\"../../../" + destination + "\""))
        images++
    }
    @Expect(images, 1)
}

@Test
class PublicHtmlEntrypointsTest {
    @TestCase
    func factoryAndClassPublishSelectedCapturedPagesWithoutMutatingAuthorIR(): Unit {
        let original = entrypointDocumentation()
        let originalIr = encodeDocIr(original)
        let selected = projectDocumentationLanguage(original, "zh-CN")
        let selectedIr = encodeDocIr(selected)
        let renderers: Array<DocumentationRenderer> = [HtmlDocumentationRenderer(), rendererFor("html")]
        for (renderer in renderers) {
            verifyCompleteHtmlEntrypoint(renderer.render(original), "en", true)
            verifyCompleteHtmlEntrypoint(renderer.render(selected), "zh-CN", false)
            @Expect(encodeDocIr(selected), selectedIr)
            @Expect(encodeDocIr(original), originalIr)
        }
    }

    @TestCase
    func htmlAndMarkdownCombinationReturnsCompleteSites(): Unit {
        let original = entrypointDocumentation()
        let authorIr = encodeDocIr(original)
        verifyCompleteHtmlEntrypoint(renderDocumentationFormatsWithOptions(original, ["html"], locale: "en"), "en", true)
        let mixed = renderDocumentationFormatsWithOptions(original, ["html", "markdown"], locale: "en")
        verifyCompleteHtmlEntrypoint(mixed, "en", true)
        @Expect(!entrypointContent(mixed, "markdown/index.md").isEmpty())
        @Expect(!entrypointContent(mixed, "markdown/" + ENTRYPOINT_GUIDE.removeSuffix(".html") + ".md").isEmpty())
        var markdownImages: Int64 = 0
        for (artifact in mixed where artifact.path.startsWith("markdown/assets/")) {
            @Expect(artifact.isBinary)
            markdownImages++
        }
        @Expect(markdownImages, 1)
        @Expect(encodeDocIr(original), authorIr)
    }

    @TestCase
    func publicHtmlEntrypointsKeepOriginalPageFallbackAndItsImage(): Unit {
        let original = entrypointDocumentation(includeEnglish: false)
        let authorIr = encodeDocIr(original)
        let selected = projectDocumentationLanguage(original, "en")
        let renderers: Array<DocumentationRenderer> = [HtmlDocumentationRenderer(), rendererFor("html")]
        for (renderer in renderers) {
            let artifacts = renderer.render(selected)
            verifyCompleteHtmlEntrypoint(artifacts, "en", false)
            @Expect(entrypointContent(artifacts, "html/" + ENTRYPOINT_GUIDE).contains(
                "data-translation-state=\"fallback\""))
        }
        let convenience = renderDocumentationFormatsWithOptions(original, ["html"], locale: "en")
        verifyCompleteHtmlEntrypoint(convenience, "en", false)
        @Expect(entrypointContent(convenience, "html/" + ENTRYPOINT_GUIDE).contains(
            "data-translation-state=\"fallback\""))
        @Expect(encodeDocIr(original), authorIr)
    }
}
