package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let FIELD_IDENTITY_MODULE = "cjdoc:module:v1:field-identity"
private let FIELD_IDENTITY_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Afield-identity::fixture::function:api#g0(Int64)"

private func fieldIdentityMarkdown(text: String): api_model.MarkdownNode {
    if (text.isEmpty()) { return api_model.MarkdownNode("document") }
    api_model.MarkdownNode("document", children: [api_model.MarkdownNode("paragraph",
        children: [api_model.MarkdownNode("text", literal: text)])])
}

private func fieldIdentityText(state: String, language: ?String,
    fieldId!: String = FIELD_IDENTITY_SYMBOL + ":doc:summary:",
    text!: String = "Authored summary."): api_model.DocumentationText {
    let content = if (state == "empty") { "" } else { text }
    api_model.DocumentationText(fieldId, "summary", "", language, content,
        fieldIdentityMarkdown(content), state: state)
}

private func fieldIdentityDocumentation(fields: Array<api_model.DocumentationText>,
    defaultLanguage!: ?String = None): api_model.DocumentationSet {
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let comment = api_model.DocComment("", "", "", api_model.MarkdownNode("document"),
        defaultLanguage: defaultLanguage, localizedTexts: fields)
    let symbol = api_model.SymbolDoc(FIELD_IDENTITY_SYMBOL, "function", "api", "fixture.api", "fixture",
        FIELD_IDENTITY_MODULE, "public", source, "public func api(_value: Int64): Unit",
        api_model.SemanticInfo("partial", "ast"), parameters: [api_model.ParameterDoc("_value",
            api_model.TypeRef("primitive", "Int64", api_model.SemanticType("unavailable")))],
        documentation: Some(comment))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
        providers: [api_model.ProviderInfo("ast", "builtin", FIELD_IDENTITY_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(FIELD_IDENTITY_MODULE, "field-identity", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", FIELD_IDENTITY_MODULE,
            sourceFiles: ["src/api.cj"], symbolIds: [FIELD_IDENTITY_SYMBOL])],
        files: [api_model.FileDoc("src/api.cj", FIELD_IDENTITY_MODULE, "fixture")], declarations: [symbol])
}

@Test
class I18nFieldIdentityTest {
    @TestCase
    func pairedStatesRequireAnIdentityRegardlessOfLanguage(): Unit {
        for (state in ["valid", "empty", "conflict"]) {
            for (language in [Some("en"), None<String>]) {
                @ExpectThrows[IllegalArgumentException](fieldIdentityText(state, language, fieldId: ""))
            }
        }
    }

    @TestCase
    func strictImportRejectsPairedFieldsWithAnEmptyIdentity(): Unit {
        for (state in ["valid", "empty", "conflict"]) {
            for (language in [Some("en"), None<String>]) {
                let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([fieldIdentityText(state, language)]))
                let malformed = encoded.replace("\"fieldId\": \"" + FIELD_IDENTITY_SYMBOL + ":doc:summary:\"",
                    "\"fieldId\": \"\"")
                @Assert(malformed != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(malformed))
            }
        }
    }

    @TestCase
    func pairedStatesWithIdentityAndUnknownLanguageRemainValid(): Unit {
        for (state in ["valid", "empty", "conflict"]) {
            for (language in [Some("en"), None<String>]) {
                let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([fieldIdentityText(state, language)]))
                let imported = api_render.decodeDocIr(encoded)
                let text = imported.declarations[0].documentation.getOrThrow().localizedTexts[0]
                @Expect(text.state, state)
                @Expect(text.language, language)
                @Expect(text.fieldId, FIELD_IDENTITY_SYMBOL + ":doc:summary:")
                @Expect(api_render.encodeDocIr(imported), encoded)
                if (state == "valid") {
                    let selected = api_render.projectDocumentationLanguage(imported, "en")
                    @Expect(selected.declarations[0].documentation.getOrThrow().summary, "Authored summary.")
                }
            }
        }
    }

    @TestCase
    func canonicalSingletonFieldsRenderAndWrongSuffixesAreRejected(): Unit {
        for ((kind, subject) in [("summary", ""), ("description", ""), ("param", "_value")]) {
            for (language in [Some("en"), None<String>]) {
                let id = FIELD_IDENTITY_SYMBOL + ":doc:" + kind + ":" + subject
                let text = api_model.DocumentationText(id, kind, subject, language, "Captured author text.",
                    fieldIdentityMarkdown("Captured author text."))
                let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([text]))
                let imported = api_render.decodeDocIr(encoded)
                let selected = api_render.projectDocumentationLanguage(imported, "en")
                let symbol = selected.declarations[0]
                match (kind) {
                    case "summary" => @Expect(symbol.documentation.getOrThrow().summary, "Captured author text.")
                    case "description" => @Expect(symbol.documentation.getOrThrow().description, "Captured author text.")
                    case _ => @Expect(symbol.parameters[0].documentation, Some("Captured author text."))
                }
                var visible = false
                for (artifact in api_render.renderDocumentationFormatsWithOptions(imported, ["markdown"], locale: "en")) {
                    if (artifact.content.contains("Captured author text")) { visible = true }
                }
                @Expect(visible)
                let malformed = encoded.replace("\"fieldId\": \"" + id + "\"",
                    "\"fieldId\": \"" + id + "unexpected\"")
                @Assert(malformed != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(malformed))
            }
        }
    }

    @TestCase
    func validParameterTargetsMustBelongToTheSignature(): Unit {
        for (language in [Some("en"), None<String>]) {
            let prefix = FIELD_IDENTITY_SYMBOL + ":doc:param:"
            let text = api_model.DocumentationText(prefix + "_value", "param", "_value", language,
                "Captured parameter text.", fieldIdentityMarkdown("Captured parameter text."))
            let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([text]))
            let malformed = encoded.replace("\"fieldId\": \"" + prefix + "_value\"",
                "\"fieldId\": \"" + prefix + "_missing\"")
                .replace("\"subject\": \"_value\"", "\"subject\": \"_missing\"")
            @Assert(malformed != encoded)
            @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(malformed))
        }
    }

    @TestCase
    func repeatedConflictsKeepTheirPairedIdentityAndFallback(): Unit {
        let original = fieldIdentityText("valid", Some("zh-CN"), text: "Original summary.")
        let first = fieldIdentityText("conflict", Some("en"), text: "First translation.")
        let second = fieldIdentityText("conflict", Some("en"), text: "Second translation.")
        let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([original, first, second],
            defaultLanguage: Some("zh-CN")))
        let imported = api_render.decodeDocIr(encoded)
        @Expect(imported.declarations[0].documentation.getOrThrow().localizedTexts.size, 3)
        @Expect(api_render.encodeDocIr(imported), encoded)
        let selected = api_render.projectDocumentationLanguage(imported, "en")
        let comment = selected.declarations[0].documentation.getOrThrow()
        @Expect(comment.summary, "Original summary.")
        @Expect(comment.tags[0].translationState, "conflict-fallback")
    }

    @TestCase
    func independentAndInvalidEntriesKeepTheirEmptyIdentity(): Unit {
        for (language in [Some("en"), None<String>]) {
            let independent = api_model.DocumentationText("", "example", "Independent", language,
                "Independent author entry.", fieldIdentityMarkdown("Independent author entry."), state: "unpaired")
            let invalid = api_model.DocumentationText("", "see", "", language,
                "Malformed author entry.", fieldIdentityMarkdown("Malformed author entry."), state: "invalid")
            let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([independent, invalid]))
            let imported = api_render.decodeDocIr(encoded)
            let fields = imported.declarations[0].documentation.getOrThrow().localizedTexts
            @Expect(fields.size, 2)
            @Expect(fields[0].fieldId.isEmpty())
            @Expect(fields[0].state, "unpaired")
            @Expect(fields[1].fieldId.isEmpty())
            @Expect(fields[1].state, "invalid")
            @Expect(api_render.encodeDocIr(imported), encoded)
            let selected = api_render.projectDocumentationLanguage(imported, "en")
            var retained = false
            for (tag in selected.declarations[0].documentation.getOrThrow().tags) {
                if (tag.name == "example" && tag.description == "Independent author entry.") { retained = true }
            }
            @Expect(retained)
        }
    }

    @TestCase
    func repeatableFieldsKeepTheirExplicitOpaqueSuffix(): Unit {
        let id = FIELD_IDENTITY_SYMBOL + ":doc:performance:author-entry"
        let field = api_model.DocumentationText(id, "performance", "", Some("en"), "Performance notes.",
            fieldIdentityMarkdown("Performance notes."))
        let encoded = api_render.encodeDocIr(fieldIdentityDocumentation([field]))
        let imported = api_render.decodeDocIr(encoded)
        @Expect(imported.declarations[0].documentation.getOrThrow().localizedTexts[0].fieldId, id)
        @Expect(api_render.encodeDocIr(imported), encoded)
        let selected = api_render.projectDocumentationLanguage(imported, "en")
        var retained = false
        for (tag in selected.declarations[0].documentation.getOrThrow().tags) {
            if (tag.name == "performance" && tag.description == "Performance notes.") { retained = true }
        }
        @Expect(retained)
    }

    @TestCase
    func unknownParameterDiagnosticsKeepInvalidAndConflictingAuthorEntries(): Unit {
        for ((extra, state, count) in [("", "invalid", 1), ("\n * @param missing Duplicate.", "conflict", 2)]) {
            let project = i18nTestProject("/** Summary.\n * @param missing Text." + extra + "\n */")
            try {
                let documentation = i18nTestGenerate(project)
                @Expect(documentation.status, "partial")
                var diagnosed = false
                for (diagnostic in documentation.diagnostics) {
                    if (diagnostic.code == "CJDOC3109" && diagnostic.severity == "error") { diagnosed = true }
                }
                @Expect(diagnosed)
                let imported = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
                var retained: Int64 = 0
                for (symbol in imported.declarations) {
                    if (let Some(comment) <- symbol.documentation) {
                        for (text in comment.localizedTexts) {
                            if (text.kind == "param" && text.subject == "missing" && text.state == state) { retained++ }
                        }
                    }
                }
                @Expect(retained, count)
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func malformedReferenceTagsRetainPartialDocumentation(): Unit {
        for (kind in ["see", "throws"]) {
            let project = i18nTestProject("/** Summary.\n * @" + kind + "\n */")
            try {
                let documentation = i18nTestGenerate(project)
                @Expect(documentation.status, "partial")
                var diagnosed = false
                for (diagnostic in documentation.diagnostics) {
                    if (diagnostic.code == "CJDOC3109" && diagnostic.severity == "error") { diagnosed = true }
                }
                @Expect(diagnosed)
                var retained = false
                let imported = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
                for (symbol in imported.declarations) {
                    if (let Some(comment) <- symbol.documentation) {
                        for (text in comment.localizedTexts) {
                            if (text.kind == kind && text.state == "invalid" && text.fieldId.isEmpty()) { retained = true }
                        }
                    }
                }
                @Expect(retained)
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }
}
