package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let INTRO_MODULE = "cjdoc:module:v1:introduction"

private func introductionId(kind: String): String {
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aintroduction::fixture::${kind}:Catalog#g0()"
}

private func introductionParagraph(text: String): MarkdownNode {
    MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)])
}

private func introductionText(kind: String, field: String, language: String,
    state!: String = "valid", multiple!: Bool = false): DocumentationText {
    let text = if (field == "description") { "Detailed introduction" } else { "Brief summary" }
    let paragraphs = if (multiple) {
        [introductionParagraph(text), introductionParagraph("Second summary paragraph")]
    } else { [introductionParagraph(text)] }
    DocumentationText(introductionId(kind) + ":doc:" + field + ":", field, "", Some(language),
        text, MarkdownNode("document", children: paragraphs), state: state)
}

private func introductionPage(kind: String, comment: DocComment, locale: String): String {
    let id = introductionId(kind)
    let source = SourceRange("src/catalog.cj", SourcePosition(1, 1, 0), SourcePosition(1, 20, 19))
    let header = if (kind == "extend") { "extend Catalog" } else { "public class Catalog" }
    let symbol = SymbolDoc(id, kind, "Catalog", "fixture.Catalog", "fixture", INTRO_MODULE,
        "public", source, header, SemanticInfo("partial", "ast"), documentation: Some(comment))
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("introduction"), ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", INTRO_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(INTRO_MODULE, "introduction", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", INTRO_MODULE, sourceFiles: ["src/catalog.cj"], symbolIds: [id])],
        files: [FileDoc("src/catalog.cj", INTRO_MODULE, "fixture")], declarations: [symbol])
    let selected = projectDocumentationLanguage(original, locale)
    for (artifact in HtmlDocumentationRenderer().render(selected)) {
        if (artifact.path.startsWith("html/symbols/") && artifact.content.contains("api-page-header")) {
            return artifact.content
        }
    }
    throw IllegalArgumentException("missing introduction page")
}

@Test
class HtmlIntroductionTest {
    @TestCase
    func localizedDescriptionWithoutSummaryHasOverviewForTypesAndExtensions(): Unit {
        for (kind in ["class", "extend"]) {
            for (locale in ["en", "zh-CN"]) {
                let comment = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some(locale),
                    localizedTexts: [introductionText(kind, "description", locale)])
                let html = introductionPage(kind, comment, locale)
                let heading = if (locale == "en") { "Overview" } else { "概述" }
                @Expect(html.contains("id=\"overview\" class=\"api-overview-heading\">" + heading))
                @Expect(html.contains("class=\"description\""))
                @Expect(html.contains("Detailed introduction"))
            }
        }
    }

    @TestCase
    func localizedSummaryParagraphsDoNotInventAnEmptyOverview(): Unit {
        for (kind in ["class", "extend"]) {
            for (locale in ["en", "zh-CN"]) {
                let comment = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some(locale),
                    localizedTexts: [introductionText(kind, "summary", locale, multiple: true)])
                let html = introductionPage(kind, comment, locale)
                @Expect(!html.contains("id=\"overview\""))
                @Expect(!html.contains("class=\"description\""))
                @Expect(html.contains("Brief summary"))
                @Expect(html.contains("Second summary paragraph"))
            }
        }
    }

    @TestCase
    func overviewFollowsSelectedDescriptionFallbackAndRejectsUnusableFields(): Unit {
        for (kind in ["class", "extend"]) {
            let fallback = DocComment("", "", "", MarkdownNode("document"),
                defaultLanguage: Some("zh-CN"), localizedTexts: [
                    introductionText(kind, "description", "zh-CN"),
                    introductionText(kind, "description", "en", state: "empty")])
            let html = introductionPage(kind, fallback, "en")
            @Expect(html.contains("id=\"overview\""))
            @Expect(html.contains("Detailed introduction"))
            @Expect(html.contains("data-translation-state=\"empty-fallback\""))
            for (state in ["empty", "invalid", "conflict"]) {
                let unusable = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some("en"), localizedTexts: [
                        introductionText(kind, "summary", "en", multiple: true),
                        introductionText(kind, "description", "en", state: state)])
                let missing = introductionPage(kind, unusable, "en")
                @Expect(!missing.contains("id=\"overview\""))
                @Expect(!missing.contains("class=\"description\""))
            }
        }
    }

    @TestCase
    func legacyOverviewStillExcludesTheLeadingSummaryParagraph(): Unit {
        let summary = introductionParagraph("Legacy summary")
        let description = introductionParagraph("Legacy description")
        for (kind in ["class", "extend"]) {
            let brief = DocComment("", "Legacy summary", "", MarkdownNode("document", children: [summary]))
            let full = DocComment("", "Legacy summary", "Legacy description",
                MarkdownNode("document", children: [summary, description]))
            @Expect(!introductionPage(kind, brief, "en").contains("id=\"overview\""))
            let html = introductionPage(kind, full, "en")
            @Expect(html.contains("id=\"overview\""))
            @Expect(html.contains("<div class=\"description\"><p>Legacy description</p>"))
            @Expect(html.split("Legacy summary").size, 2)
        }
    }
}
