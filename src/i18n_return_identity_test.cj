package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let RETURN_IDENTITY_MODULE = "cjdoc:module:v1:return-identity"
private let RETURN_IDENTITY_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areturn-identity::fixture::function:api#g0()"
private let RETURN_IDENTITY_FIELD = RETURN_IDENTITY_SYMBOL + ":doc:return:"

private func returnIdentityMarkdown(text: String): api_model.MarkdownNode {
    if (text.isEmpty()) { return api_model.MarkdownNode("document") }
    api_model.MarkdownNode("document", children: [api_model.MarkdownNode("paragraph",
        children: [api_model.MarkdownNode("text", literal: text)])])
}

private func returnIdentityText(state: String, language: ?String,
    fieldId!: String = RETURN_IDENTITY_FIELD): api_model.DocumentationText {
    let text = if (state == "empty") { "" } else { "Captured return description." }
    api_model.DocumentationText(fieldId, "return", "", language, text, returnIdentityMarkdown(text), state: state)
}

private func returnIdentityDocumentation(field: api_model.DocumentationText): api_model.DocumentationSet {
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let summary = api_model.DocumentationText(RETURN_IDENTITY_SYMBOL + ":doc:summary:", "summary", "", Some("en"),
        "Captured summary.", returnIdentityMarkdown("Captured summary."))
    let comment = api_model.DocComment("Captured author comment.", "", "", api_model.MarkdownNode("document"),
        defaultLanguage: field.language, localizedTexts: [summary, field])
    let symbol = api_model.SymbolDoc(RETURN_IDENTITY_SYMBOL, "function", "api", "fixture.api", "fixture",
        RETURN_IDENTITY_MODULE, "public", source, "public func api(): Int64",
        api_model.SemanticInfo("partial", "ast"), returnType: Some(api_model.TypeRef("primitive", "Int64",
            api_model.SemanticType("unavailable"))), documentation: Some(comment))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
        providers: [api_model.ProviderInfo("ast", "builtin", RETURN_IDENTITY_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(RETURN_IDENTITY_MODULE, "return-identity", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", RETURN_IDENTITY_MODULE,
            sourceFiles: ["src/api.cj"], symbolIds: [RETURN_IDENTITY_SYMBOL])],
        files: [api_model.FileDoc("src/api.cj", RETURN_IDENTITY_MODULE, "fixture")], declarations: [symbol],
        languageOptions: Some(api_model.DocumentationLanguageOptions("en")), readingLanguage: Some("en"))
}

@Test
class I18nReturnIdentityTest {
    @TestCase
    func canonicalPairedReturnsRetainAllStatesAndUnknownLanguage(): Unit {
        for (state in ["valid", "empty", "conflict"]) {
            for (language in [Some("en"), None<String>]) {
                let encoded = api_render.encodeDocIr(returnIdentityDocumentation(returnIdentityText(state, language)))
                let imported = api_render.decodeDocIr(encoded)
                let field = imported.declarations[0].documentation.getOrThrow().localizedTexts[1]
                @Expect(field.fieldId, RETURN_IDENTITY_FIELD)
                @Expect(field.state, state)
                @Expect(field.language, language)
                @Expect(api_render.encodeDocIr(imported), encoded)
            }
        }
    }

    @TestCase
    func pairedReturnsWithWrongSuffixAreRejectedByTypedAndStrictEntrypoints(): Unit {
        for (state in ["valid", "empty", "conflict"]) {
            for (language in [Some("en"), None<String>]) {
                let malformed = returnIdentityDocumentation(returnIdentityText(state, language,
                    fieldId: RETURN_IDENTITY_FIELD + "wrong"))
                @ExpectThrows[IllegalArgumentException](api_render.encodeDocIr(malformed))
                @ExpectThrows[IllegalArgumentException](api_render.rendererFor("html").render(malformed))
                let encoded = api_render.encodeDocIr(returnIdentityDocumentation(returnIdentityText(state, language)))
                let changed = encoded.replace("\"fieldId\": \"" + RETURN_IDENTITY_FIELD + "\"",
                    "\"fieldId\": \"" + RETURN_IDENTITY_FIELD + "wrong\"")
                @Assert(changed != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(changed))
            }
        }
    }

    @TestCase
    func canonicalValidReturnIsVisibleAndCountedAsATranslation(): Unit {
        let documentation = api_render.decodeDocIr(api_render.encodeDocIr(
            returnIdentityDocumentation(returnIdentityText("valid", Some("en")))))
        let coverage = api_render.translationCoverageFor(documentation, "en")
        @Expect(coverage.total, 2)
        @Expect(coverage.translated, 2)
        @Expect(coverage.missing, 0)
        @Expect(coverage.percent, 100)
        var returns: Int64 = 0
        for (entry in coverage.entries where entry.kind == "return") {
            @Expect(entry.fieldId, RETURN_IDENTITY_FIELD)
            @Expect(entry.state, "complete")
            @Expect(entry.actualLanguage, Some("en"))
            returns++
        }
        @Expect(returns, 1)
        var visible = false
        for (artifact in api_render.rendererFor("html").render(documentation)) {
            if (artifact.path.startsWith("html/symbols/") && artifact.content.contains("Captured return description.")) {
                visible = true
            }
        }
        @Expect(visible)
    }

    @TestCase
    func invalidAndIndependentReturnEntriesKeepTheirDiagnosticIdentity(): Unit {
        for (state in ["invalid", "unpaired"]) {
            for (language in [Some("en"), None<String>]) {
                for (id in ["", RETURN_IDENTITY_FIELD + "diagnostic"]) {
                    let encoded = api_render.encodeDocIr(returnIdentityDocumentation(returnIdentityText(state,
                        language, fieldId: id)))
                    let imported = api_render.decodeDocIr(encoded)
                    let field = imported.declarations[0].documentation.getOrThrow().localizedTexts[1]
                    @Expect(field.fieldId, id)
                    @Expect(field.state, state)
                    @Expect(field.language, language)
                    @Expect(api_render.encodeDocIr(imported), encoded)
                }
            }
        }
    }

    @TestCase
    func sourceReturnFieldsKeepCanonicalIdsIncludingConflicts(): Unit {
        for (extra in ["", "\n * @return[lang=en] Duplicate return."]) {
            let project = i18nTestProject("/** Summary.\n * @return[lang=en] Captured return." + extra + "\n */")
            try {
                let generated = i18nTestGenerate(project)
                let imported = api_render.decodeDocIr(api_render.encodeDocIr(generated))
                var fields: Int64 = 0
                for (symbol in imported.declarations where symbol.name == "add") {
                    for (field in symbol.documentation.getOrThrow().localizedTexts where field.kind == "return") {
                        @Expect(field.fieldId, symbol.id + ":doc:return:")
                        @Expect(field.subject, "")
                        @Expect(field.state, if (extra.isEmpty()) { "valid" } else { "conflict" })
                        fields++
                    }
                }
                @Expect(fields, if (extra.isEmpty()) { 1 } else { 2 })
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }
}
