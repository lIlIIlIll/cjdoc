package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func translationEdgeMarkdownText(node: api_model.MarkdownNode): String {
    var text = node.literal
    for (child in node.children) { text += translationEdgeMarkdownText(child) }
    text
}

@Test
class I18nTranslationEdgeTest {
    @TestCase
    func diffRejectsLanguageOptionsItCannotApply(): Unit {
        @ExpectThrows[IllegalArgumentException](parseNewCli(["diff", "old.json", "new.json", "--all-languages"]))
        @ExpectThrows[IllegalArgumentException](parseNewCli(["diff", "old.json", "new.json", "--require-language", "en"]))
    }

    @TestCase
    func authoredUnderscoreParameterTextRemainsInTranslationCoverage(): Unit {
        let project = i18nTestProject("/** Summary. */")
        try {
            File.writeTo(project.join("src/api.cj"), ("package language_fixture\n/** 中文摘要。\n" +
                " * @summary[lang=en] English summary.\n * @param _value 中文参数。\n */\n" +
                "public func api(_value: Int64): Unit {}\n").toArray())
            let report = api_render.translationCoverageFor(i18nTestGenerate(project), "en")
            @Expect(report.total, 2)
            @Expect(report.translated, 1)
            @Expect(report.fallback, 1)
            @Expect(report.percent, 50)
            File.writeTo(project.join("src/api.cj"), ("package language_fixture\n/** 中文摘要。\n" +
                " * @summary[lang=en] English summary.\n */\npublic func api(_value: Int64): Unit {}\n").toArray())
            @Expect(api_render.translationCoverageFor(i18nTestGenerate(project), "en").total, 1)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func independentReferencesEachRemainInTheCoverageDenominator(): Unit {
        for (kind in ["see", "throws"]) {
            let project = i18nTestProject("/** 中文摘要。\n * @param left 左值。\n * @param right 右值。\n * @return 结果。\n * @" + kind +
                " MissingDefault 默认说明。\n * @" + kind + "[lang=en] MissingOther Independent explanation.\n */")
            try {
                let documentation = i18nTestGenerate(project)
                let report = api_render.translationCoverageFor(documentation, "zh-CN")
                var independent: Int64 = 0
                for (entry in report.entries where entry.kind == kind) { independent++ }
                @Expect(independent, 2)
                @Expect(report.total, 6)
                @Expect(report.translated, 5)
                @Expect(report.unpaired, 1)
                @Expect(report.percent, 83)
                let checked = withTranslationDiagnostics(documentation,
                    GenerationRequest(project.toString(), requiredLanguages: ["zh-CN"]))
                var rejected = false
                for (diagnostic in checked.diagnostics where diagnostic.code == "CJDOC3111") { rejected = true }
                @Expect(rejected)
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func markdownExamplesKeepBothLanguageProvenanceAndCodeFences(): Unit {
        let moduleId = "cjdoc:module:v1:example-provenance"
        let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aexample-provenance::fixture::function:api#g0()"
        let example = "```cj\nprintln(1)\n```"
        let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
            api_model.SourcePosition(1, 2, 1))
        for ((state, fieldId, provenance) in [("valid", symbolId + ":doc:example:one", "Original text: zh-CN"),
            ("unpaired", "", "Independent entry: zh-CN")]) {
            let comment = api_model.DocComment("", "", "", api_model.MarkdownNode("document"),
                defaultLanguage: Some("zh-CN"), localizedTexts: [
                    api_model.DocumentationText(fieldId, "example", "Example", Some("zh-CN"),
                        example, parseStandaloneMarkdown(example), state: state)])
            let symbol = api_model.SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId,
                "public", source, "public func api(): Unit", api_model.SemanticInfo("partial", "ast"),
                documentation: Some(comment))
            let documentation = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
                "partial", api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
                providers: [api_model.ProviderInfo("ast", "builtin", moduleId, "partial",
                    api_model.SemanticCapabilities(false, false, false, false, false))],
                modules: [api_model.ModuleDoc(moduleId, "example-provenance", "root", "", packageNames: ["fixture"])],
                packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
                files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")],
                declarations: [symbol], languageOptions: Some(api_model.DocumentationLanguageOptions("zh-CN",
                    languages: ["zh-CN", "en"])))
            var examples: Int64 = 0
            for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")) {
                if (!artifact.content.contains("#### Examples")) { continue }
                let tree = parseStandaloneMarkdown(artifact.content)
                @Expect(translationEdgeMarkdownText(tree).contains(provenance))
                for (node in tree.children where node.kind == "code_block" && node.literal.trimAscii() == "println(1)") {
                    examples++
                }
            }
            @Expect(examples, 1)
        }
    }
}
