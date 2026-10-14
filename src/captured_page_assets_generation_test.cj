package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func capturedPageGenerationPng(english: Bool): Array<Byte> {
    if (english) {
        return [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
            0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
            0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
            5, 254, 2, 254, 13, 239, 70, 184, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
    }
    [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
        0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 96, 96, 0, 0,
        0, 4, 0, 1, 246, 23, 56, 85, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
}

private func capturedPageGenerationProject(missingEnglish!: Bool = false): Path {
    let comment = if (missingEnglish) { "/** Shared API summary. */" } else {
        "/** Shared API summary.\n * @summary[lang=en] English API ![API image](../docs/en/pixel.png)\n */"
    }
    let project = i18nTestProject(comment)
    Directory.create(project.join("docs"))
    let configuration = "[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n"
    let pages = StringBuilder()
    for (locale in ["en", "zh-CN"]) {
        Directory.create(project.join("docs/" + locale))
        let destination = if (locale == "en" && missingEnglish) { "../../../outside.png" } else { "pixel.png" }
        File.writeTo(project.join("docs/" + locale + "/start.md"),
            ("# Guide\n\n![" + locale + " diagram](" + destination + ")\n").toArray())
        File.writeTo(project.join("docs/" + locale + "/pixel.png"), capturedPageGenerationPng(locale == "en"))
        pages.append("\n[[docs.pages]]\nid = \"guide\"\nlanguage = \"" + locale +
            "\"\nsource = \"docs/" + locale + "/start.md\"\nroute = \"concepts/guides/start.html\"\n")
    }
    File.writeTo(project.join("cjdoc.toml"), (configuration + pages.toString()).toArray())
    project
}

private func capturedPageGenerationImages(tree: api_model.MarkdownNode): Int64 {
    var count: Int64 = 0
    if (tree.kind == "image") {
        @Expect(tree.literal.startsWith("sha256-"))
        count++
    }
    for (child in tree.children) { count += capturedPageGenerationImages(child) }
    count
}

@When[os == "Linux"]
@Test
class CapturedPageAssetsGenerationTest {
    @TestCase
    func generatedGuidePngsSurviveRemovalOfTheOriginalProject(): Unit {
        let project = capturedPageGenerationProject()
        try {
            let generated = i18nTestGenerate(project)
            @Expect(generated.assets.size, 2)
            var pages: Int64 = 0
            for (page in generated.pages where page.id == "guide") {
                @Expect(capturedPageGenerationImages(page.markdown), 1)
                pages++
            }
            @Expect(pages, 2)
            let encoded = api_render.encodeDocIr(generated)
            let _ = removeIfExists(project, recursive: true)
            let imported = api_render.decodeDocIr(encoded)
            for (locale in ["en", "zh-CN"]) {
                let artifacts = api_render.renderDocumentationFormatsWithOptions(imported,
                    ["html", "markdown"], locale: locale)
                var images: Int64 = 0
                var html = ""
                var markdown = ""
                for (artifact in artifacts) {
                    if (artifact.mediaType == "image/png") {
                        @Expect(artifact.isBinary)
                        @Expect(artifact.bytes.size, 69)
                        let expectedByte: Byte = if (locale == "en") { 0xf8 } else { 0x60 }
                        @Expect(artifact.bytes[44], expectedByte)
                        images++
                    }
                    if (artifact.path == "html/concepts/guides/start.html") { html = artifact.content }
                    if (artifact.path == "markdown/concepts/guides/start.md") { markdown = artifact.content }
                }
                @Expect(images, 2)
                @Expect(html.contains("<img src=\"../../assets/"))
                @Expect(markdown.contains("!["))
                @Expect(markdown.contains("](../../assets/"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func rejectedGuideImagesKeepPageDiagnosticsWithoutAPseudoSymbol(): Unit {
        let project = capturedPageGenerationProject(missingEnglish: true)
        try {
            let generated = i18nTestGenerate(project)
            @Expect(generated.status, "partial")
            @Expect(generated.assets.size, 1)
            var diagnosed = false
            for (diagnostic in generated.diagnostics where diagnostic.code == "CJDOC4026") {
                @Expect(diagnostic.symbolId.isNone())
                @Expect(diagnostic.source.getOrThrow().path, "docs/en/start.md")
                diagnosed = true
            }
            @Expect(diagnosed)
            let encoded = api_render.encodeDocIr(generated)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func pageAssetCapturePreservesAnExistingPartialError(): Unit {
        let project = capturedPageGenerationProject()
        try {
            let original = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
                "partial", api_model.ProjectInfo("already-partial"), api_model.ConfigurationSnapshot(lintProfile: "off"),
                diagnostics: [api_model.Diagnostic("error", "CJDOC1001", "Generation failed before page capture")])
            let collector = LocalAssetCollector(ArrayList<SourceFileOrigin>())
            collector.incomplete = true
            let captured = captureDocumentationPages(original, GenerationRequest(project.toString()),
                assetCollector: Some(collector))
            @Expect(captured.status, "partial")
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(captured))
            @Expect(imported.status, "partial")
            @Expect(imported.diagnostics[0].code, "CJDOC1001")
            @Expect(imported.diagnostics[0].severity, "error")
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

}
