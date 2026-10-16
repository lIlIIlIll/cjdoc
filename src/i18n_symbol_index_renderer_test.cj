package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let READING_INDEX_MODULE = "cjdoc:module:v1:reading-index"
private let READING_INDEX_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areading-index::fixture::function:api#g0()"

private func readingIndexMarkdown(text: String): api_model.MarkdownNode {
    api_model.MarkdownNode("document", children: [api_model.MarkdownNode("paragraph",
        children: [api_model.MarkdownNode("text", literal: text)])])
}

private func readingIndexDocumentation(readingLanguage: ?String, defaultLanguage!: String = "en",
    chineseSummary!: Bool = true, chineseReference!: Bool = true,
    localized!: Bool = true): api_model.DocumentationSet {
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let summary = if (defaultLanguage == "en") { "English summary." } else { "中文摘要。" }
    let description = if (defaultLanguage == "en") { "English reference." } else { "中文引用说明。" }
    let texts = ArrayList<api_model.DocumentationText>()
    if (localized) {
        for ((language, content) in [("en", "English summary."), ("zh-CN", "中文摘要。")]) {
            if (language == "zh-CN" && !chineseSummary) { continue }
            texts.add(api_model.DocumentationText(READING_INDEX_SYMBOL + ":doc:summary:",
                "summary", "", Some(language), content, readingIndexMarkdown(content), source: Some(source)))
        }
        for ((language, content) in [("en", "English reference."), ("zh-CN", "中文引用说明。")]) {
            if (language == "zh-CN" && !chineseReference) { continue }
            texts.add(api_model.DocumentationText(READING_INDEX_SYMBOL + ":doc:see:" + READING_INDEX_SYMBOL,
                "see", "fixture.api", Some(language), content, readingIndexMarkdown(content), source: Some(source),
                referenceState: "resolved", targetSymbolId: Some(READING_INDEX_SYMBOL)))
        }
    }
    let comment = api_model.DocComment("Captured author comment.", summary, "", readingIndexMarkdown(summary),
        tags: [api_model.DocTag("see", "fixture.api", description, referenceState: "resolved",
            targetSymbolId: Some(READING_INDEX_SYMBOL), descriptionMarkdown: Some(readingIndexMarkdown(description)))],
        defaultLanguage: Some(defaultLanguage), localizedTexts: texts.toArray())
    let symbol = api_model.SymbolDoc(READING_INDEX_SYMBOL, "function", "api", "fixture.api", "fixture",
        READING_INDEX_MODULE, "public", source, "public func api(): Unit",
        api_model.SemanticInfo("partial", "ast"), documentation: Some(comment))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
        providers: [api_model.ProviderInfo("ast", "builtin", READING_INDEX_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(READING_INDEX_MODULE, "reading-index", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", READING_INDEX_MODULE,
            sourceFiles: ["src/api.cj"], symbolIds: [READING_INDEX_SYMBOL])],
        files: [api_model.FileDoc("src/api.cj", READING_INDEX_MODULE, "fixture")], declarations: [symbol],
        languageOptions: Some(api_model.DocumentationLanguageOptions(defaultLanguage, languages: ["en", "zh-CN"])),
        readingLanguage: readingLanguage)
}

private func expectReadingIndex(documentation: api_model.DocumentationSet,
    summary: String, referenceDescription: String): Unit {
    let before = api_render.encodeDocIr(documentation)
    let imported = api_render.decodeDocIr(before)
    let renderer = api_render.rendererFor("symbol-index")
    @Expect(renderer.format, "symbol-index")
    let artifacts = renderer.render(imported)
    @Assert(artifacts.size, 1)
    @Expect(artifacts[0].path, "symbol-index/symbol-index.json")
    let index = JsonNode.parse(artifacts[0].content).asObject()
    @Expect(index.get("schemaVersion").getOrThrow().asString(), "cjdoc.symbol-index/2")
    let entries = index.get("entries").getOrThrow().asArray()
    @Assert(entries.size(), 1)
    let entry = entries.get(0).getOrThrow().asObject()
    @Expect(entry.get("summary").getOrThrow().asString(), summary)
    @Expect(entry.get("id").getOrThrow().asString(), READING_INDEX_SYMBOL)
    @Expect(entry.get("canonicalId").getOrThrow().asString(), READING_INDEX_SYMBOL)
    @Expect(entry.get("href").getOrThrow().asString().startsWith("html/"))
    let source = entry.get("source").getOrThrow().asObject()
    @Expect(source.get("path").getOrThrow().asString(), "src/api.cj")
    let references = entry.get("references").getOrThrow().asArray()
    @Assert(references.size(), 1)
    let reference = references.get(0).getOrThrow().asObject()
    @Expect(reference.get("description").getOrThrow().asString(), referenceDescription)
    @Expect(reference.get("subject").getOrThrow().asString(), "fixture.api")
    @Expect(reference.get("state").getOrThrow().asString(), "resolved")
    @Expect(reference.get("targetId").getOrThrow().asString(), READING_INDEX_SYMBOL)
    let combined = api_render.renderDocumentationFormatsWithOptions(imported, ["symbol-index"],
        locale: imported.readingLanguage.getOrDefault({ => "en" }))
    @Assert(combined.size, 1)
    @Expect(artifacts[0].content, combined[0].content)
    @Expect(imported.readingLanguage, documentation.readingLanguage)
    @Expect(api_render.encodeDocIr(imported), before)
    @Expect(api_render.encodeDocIr(documentation), before)
}

@Test
class I18nSymbolIndexRendererTest {
    @TestCase
    func absentReadingLanguageSelectsEnglishInsteadOfTheAuthorDefault(): Unit {
        expectReadingIndex(readingIndexDocumentation(None, defaultLanguage: "zh-CN"),
            "English summary.", "English reference.")
    }

    @TestCase
    func explicitChineseSelectsSummaryAndReferenceDescription(): Unit {
        expectReadingIndex(readingIndexDocumentation(Some("zh-CN")), "中文摘要。", "中文引用说明。")
    }

    @TestCase
    func missingChineseFieldsFallBackIndependentlyToEnglish(): Unit {
        expectReadingIndex(readingIndexDocumentation(Some("zh-CN"), chineseReference: false),
            "中文摘要。", "English reference.")
        expectReadingIndex(readingIndexDocumentation(Some("zh-CN"), chineseSummary: false),
            "English summary.", "中文引用说明。")
        expectReadingIndex(readingIndexDocumentation(Some("zh-CN"), chineseSummary: false, chineseReference: false),
            "English summary.", "English reference.")
    }

    @TestCase
    func legacyCommentsWithoutLocalizedFieldsKeepTheirAuthorContent(): Unit {
        expectReadingIndex(readingIndexDocumentation(Some("en"), defaultLanguage: "zh-CN", localized: false),
            "中文摘要。", "中文引用说明。")
        expectReadingIndex(readingIndexDocumentation(Some("zh-CN"), localized: false),
            "English summary.", "English reference.")
    }
}
