package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let PAGE_ASSET_ZH_ID = "sha256-c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96"
private let PAGE_ASSET_EN_ID = "sha256-e878950f8091ec010cf5cc723bdea027a8539cf7147cfea199c2f666232dcd4e"
private let PAGE_ASSET_HIDDEN_ID = "sha256-431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460"

private func pageAssetTree(title: String, destination: String, alt: String,
    nested!: Bool = false): MarkdownNode {
    let image = MarkdownNode("image", literal: destination,
        children: if (alt.isEmpty()) { Array<MarkdownNode>() } else { [MarkdownNode("text", literal: alt)] })
    let content = if (nested) { MarkdownNode("link", literal: "javascript:alert(1)", children: [image]) } else { image }
    MarkdownNode("document", children: [
        MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
            children: [MarkdownNode("text", literal: title)]),
        MarkdownNode("paragraph", children: [content])])
}

private func capturedPageAssetDocumentation(includeEnglish!: Bool = true,
    kind!: String = "guide", emptyAlt!: Bool = false, nested!: Bool = false): DocumentationSet {
    let moduleId = "cjdoc:module:v1:page-assets"
    let hiddenId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apage-assets::fixture::function:hidden#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let hidden = SymbolDoc(hiddenId, "function", "hidden", "fixture.hidden", "fixture", moduleId,
        "private", source, "private func hidden(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment("hidden", "hidden", "",
            pageAssetTree("Hidden", PAGE_ASSET_HIDDEN_ID, "Private diagram"))))
    let visibleId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apage-assets::fixture::function:visible#g0()"
    let visible = SymbolDoc(visibleId, "function", "visible", "fixture.visible", "fixture", moduleId,
        "public", source, "public func visible(): Unit", SemanticInfo("partial", "ast"))
    let chinese = DocumentationPage("guide", "docs/zh/start.md", "concepts/guides/deep/start.html",
        "Chinese guide", kind, "Chinese diagram",
        pageAssetTree("Chinese guide", "./docs/images/zh.png", if (emptyAlt) { "" } else { "Chinese diagram" }, nested: nested),
        packageName: if (kind == "package") { "fixture" } else { "" }, language: Some("zh-CN"), defaultLanguage: Some("zh-CN"))
    let english = DocumentationPage("guide", "docs/en/start.md", "concepts/guides/deep/start.html",
        "English guide", kind, "English diagram",
        pageAssetTree("English guide", PAGE_ASSET_EN_ID, if (emptyAlt) { "" } else { "English diagram" }, nested: nested),
        packageName: if (kind == "package") { "fixture" } else { "" }, language: Some("en"), defaultLanguage: Some("zh-CN"))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("page-assets"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "page-assets", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [hiddenId, visibleId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [hidden, visible],
        languageOptions: Some(DocumentationLanguageOptions("zh-CN", languages: ["zh-CN", "en"])),
        pages: if (includeEnglish) { [chinese, english] } else { [chinese] }, assets: [
            AssetDoc(PAGE_ASSET_ZH_ID, "image/png", "docs/images/zh.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"),
            AssetDoc(PAGE_ASSET_EN_ID, "image/png", "docs/images/en.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"),
            AssetDoc(PAGE_ASSET_HIDDEN_ID, "image/png", "src/images/hidden.png",
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")])
}

private func capturedPageAssetContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing page asset reading artifact")
}

private func verifyCapturedPageImage(artifacts: Array<RenderArtifact>, root: String,
    page: String, alt: String, expectedByte: Byte): Unit {
    var images: Int64 = 0
    var destination = ""
    for (artifact in artifacts where artifact.path.startsWith(root + "/assets/")) {
        @Expect(artifact.isBinary)
        @Expect(artifact.mediaType, "image/png")
        @Expect(artifact.bytes.size, 69)
        @Expect(artifact.bytes[44], expectedByte)
        destination = artifact.path.removePrefix(root + "/")
        images++
    }
    @Expect(images, 1)
    let content = capturedPageAssetContent(artifacts, root + "/" + page)
    @Expect(content.contains(alt))
    @Expect(!content.contains("Private diagram"))
    if (page.endsWith(".html")) {
        @Expect(content.contains("<img src=\"../../../" + destination + "\""))
    } else {
        @Expect(content.contains("!["))
        @Expect(content.contains("](../../../" + destination + ")"))
    }
}

@Test
class DocumentationPageAssetsTest {
    @TestCase
    func imageOnlyAuthorOverviewsKeepCanonicalBodiesAndReadingEntries(): Unit {
        for (kind in ["project", "package"]) {
            for (nested in [false, true]) {
                for (includeEnglish in [false, true]) {
                    let document = capturedPageAssetDocumentation(kind: kind, emptyAlt: true,
                        nested: nested, includeEnglish: includeEnglish)
                    let imported = decodeDocIr(encodeDocIr(document))
                    let snapshot = encodeDocIr(imported)
                    for (locale in ["en", "zh-CN"]) {
                        let artifacts = renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: locale)
                        let page = capturedPageAssetContent(artifacts, "html/concepts/guides/deep/start.html")
                        @Expect(page.contains("<img src=\"../../../assets/"))
                        @Expect(page.contains("alt=\"\" loading=\"lazy\""))
                        @Expect(!page.contains("An author overview has not been provided."))
                        @Expect(!page.contains("作者尚未提供概述。"))
                        @Expect(!page.contains("href=\"javascript:"))
                        var entry = capturedPageAssetContent(artifacts, "html/index.html")
                        if (kind == "package") {
                            entry = ""
                            for (artifact in artifacts where artifact.path.startsWith("html/packages/")) {
                                entry = artifact.content
                            }
                        }
                        @Assert(!entry.isEmpty())
                        if (kind == "project") {
                            @Expect(entry.contains("<img src=\"assets/"))
                        } else {
                            @Expect(entry.contains("class=\"package-overview-link\" href=\"../concepts/guides/deep/start.html\""))
                        }
                        let expectedByte: Byte = if (locale == "en" && includeEnglish) { 0xf8 } else { 0x60 }
                        verifyCapturedPageImage(artifacts, "html", "concepts/guides/deep/start.html", "alt=\"\"", expectedByte)
                        verifyCapturedPageImage(artifacts, "markdown", "concepts/guides/deep/start.md", "![](", expectedByte)
                    }
                    @Expect(encodeDocIr(imported), snapshot)
                }
            }
        }
    }

    @TestCase
    func sourceFreePagesRenderOnlyTheSelectedLanguageImages(): Unit {
        let imported = decodeDocIr(encodeDocIr(capturedPageAssetDocumentation()))
        for (locale in ["en", "zh-CN"]) {
            let artifacts = renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: locale)
            let alt = if (locale == "en") { "English diagram" } else { "Chinese diagram" }
            let expectedByte: Byte = if (locale == "en") { 0xf8 } else { 0x60 }
            verifyCapturedPageImage(artifacts, "html", "concepts/guides/deep/start.html", alt, expectedByte)
            verifyCapturedPageImage(artifacts, "markdown", "concepts/guides/deep/start.md", alt, expectedByte)
        }
    }

    @TestCase
    func allLanguagesKeepPageImagesInsideTheirReadingRoots(): Unit {
        let imported = decodeDocIr(encodeDocIr(capturedPageAssetDocumentation()))
        let artifacts = renderDocumentationWithLanguageOptions(imported, ["html", "markdown"],
            LanguageRenderOptions(allLanguages: true))
        for (format in ["html", "markdown"]) {
            let page = "concepts/guides/deep/start." + if (format == "html") { "html" } else { "md" }
            verifyCapturedPageImage(artifacts, format + "/en", page, "English diagram", 0xf8)
            verifyCapturedPageImage(artifacts, format + "/zh-CN", page, "Chinese diagram", 0x60)
        }
    }

    @TestCase
    func aFallbackPagePublishesItsOriginalBundledImage(): Unit {
        let imported = decodeDocIr(encodeDocIr(capturedPageAssetDocumentation(includeEnglish: false)))
        let artifacts = renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
        verifyCapturedPageImage(artifacts, "html", "concepts/guides/deep/start.html", "Chinese diagram", 0x60)
        verifyCapturedPageImage(artifacts, "markdown", "concepts/guides/deep/start.md", "Chinese diagram", 0x60)
    }

    @TestCase
    func directMarkdownRendererPublishesOnlySelectedPageAssets(): Unit {
        let imported = decodeDocIr(encodeDocIr(capturedPageAssetDocumentation()))
        let artifacts = MarkdownDocumentationRenderer().render(imported)
        verifyCapturedPageImage(artifacts, "markdown", "concepts/guides/deep/start.md", "English diagram", 0xf8)
    }
}
