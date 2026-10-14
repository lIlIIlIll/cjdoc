package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let REFERENCE_STATE_MODULE = "cjdoc:module:v1:reference-state"
private let REFERENCE_STATE_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areference-state::fixture::function:api#g0()"

private func referenceStateMarkdown(text: String): api_model.MarkdownNode {
    if (text.isEmpty()) { return api_model.MarkdownNode("document") }
    api_model.MarkdownNode("document", children: [api_model.MarkdownNode("paragraph",
        children: [api_model.MarkdownNode("text", literal: text)])])
}

private func referenceStateText(kind: String, referenceState: String, target: ?String,
    state!: String = "valid", language!: ?String = Some("en")): api_model.DocumentationText {
    let text = if (state == "empty") { "" } else { "Captured reference description." }
    api_model.DocumentationText(REFERENCE_STATE_SYMBOL + ":doc:" + kind + ":" + REFERENCE_STATE_SYMBOL,
        kind, "fixture.api", language, text, referenceStateMarkdown(text), state: state,
        referenceState: referenceState, targetSymbolId: target)
}

private func referenceStateDocumentation(text: api_model.DocumentationText): api_model.DocumentationSet {
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let comment = api_model.DocComment("Captured author comment.", "", "", api_model.MarkdownNode("document"),
        defaultLanguage: Some("en"), localizedTexts: [text])
    let symbol = api_model.SymbolDoc(REFERENCE_STATE_SYMBOL, "function", "api", "fixture.api", "fixture",
        REFERENCE_STATE_MODULE, "public", source, "public func api(): Unit",
        api_model.SemanticInfo("partial", "ast"), documentation: Some(comment))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
        providers: [api_model.ProviderInfo("ast", "builtin", REFERENCE_STATE_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(REFERENCE_STATE_MODULE, "reference-state", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", REFERENCE_STATE_MODULE,
            sourceFiles: ["src/api.cj"], symbolIds: [REFERENCE_STATE_SYMBOL])],
        files: [api_model.FileDoc("src/api.cj", REFERENCE_STATE_MODULE, "fixture")], declarations: [symbol],
        readingLanguage: Some("en"))
}

private func referenceStateHtml(documentation: api_model.DocumentationSet): String {
    let out = StringBuilder()
    for (artifact in api_render.rendererFor("html").render(documentation)) {
        if (artifact.path.endsWith(".html")) { out.append(artifact.content) }
    }
    out.toString()
}

@Test
class I18nReferenceStateTest {
    @TestCase
    func localizedReferencesRejectTargetsWithoutResolution(): Unit {
        for (kind in ["see", "throws"]) {
            for (referenceState in ["partial", "unavailable", "ambiguous"]) {
                for (state in ["valid", "empty", "conflict", "unpaired", "invalid"]) {
                    for (language in [Some("en"), None<String>]) {
                        @ExpectThrows[IllegalArgumentException](referenceStateText(kind, referenceState,
                            Some(REFERENCE_STATE_SYMBOL), state: state, language: language))
                    }
                }
            }
        }
    }

    @TestCase
    func strictImportRejectsUnresolvedLocalizedTargets(): Unit {
        for (kind in ["see", "throws"]) {
            for (language in [Some("en"), None<String>]) {
                let encoded = api_render.encodeDocIr(referenceStateDocumentation(referenceStateText(kind,
                    "resolved", Some(REFERENCE_STATE_SYMBOL), language: language)))
                for (referenceState in ["partial", "unavailable", "ambiguous"]) {
                    let malformed = encoded.replace("\"referenceState\": \"resolved\"",
                        "\"referenceState\": \"" + referenceState + "\"")
                    @Assert(malformed != encoded)
                    @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(malformed))
                }
                let missingTarget = encoded.replace("\"targetSymbolId\": \"" + REFERENCE_STATE_SYMBOL + "\"",
                    "\"targetSymbolId\": null")
                @Assert(missingTarget != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(missingTarget))
            }
        }
    }

    @TestCase
    func consistentReferenceStatesRoundTripAndRenderOnlyResolvedLinks(): Unit {
        for (kind in ["see", "throws"]) {
            for (referenceState in ["resolved", "partial", "unavailable", "ambiguous"]) {
                let target = if (referenceState == "resolved") { Some(REFERENCE_STATE_SYMBOL) } else { None<String> }
                let encoded = api_render.encodeDocIr(referenceStateDocumentation(referenceStateText(kind,
                    referenceState, target)))
                let imported = api_render.decodeDocIr(encoded)
                @Expect(api_render.encodeDocIr(imported), encoded)
                let selected = api_render.projectDocumentationLanguage(imported, "en")
                var matched = false
                for (tag in selected.declarations[0].documentation.getOrThrow().tags where tag.name == kind) {
                    @Expect(tag.referenceState, referenceState)
                    @Expect(tag.targetSymbolId, target)
                    matched = true
                }
                @Expect(matched)
                let html = referenceStateHtml(imported)
                @Expect(html.contains("Captured reference description."))
                @Expect(html.contains("<code>fixture.api</code></a>"), referenceState == "resolved")
                if (kind == "throws" && referenceState == "ambiguous") {
                    @Expect(html.contains("data-state=\"ambiguous\""))
                }
                @Expect(api_render.encodeDocIr(imported), encoded)
            }
        }
    }

    @TestCase
    func nonReferenceFieldsKeepTheirExistingMetadataContract(): Unit {
        for (referenceState in ["resolved", "partial", "unavailable", "ambiguous"]) {
            let field = api_model.DocumentationText(REFERENCE_STATE_SYMBOL + ":doc:performance:opaque",
                "performance", "", Some("en"), "Performance notes.", referenceStateMarkdown("Performance notes."),
                referenceState: referenceState, targetSymbolId: Some(REFERENCE_STATE_SYMBOL))
            let encoded = api_render.encodeDocIr(referenceStateDocumentation(field))
            let imported = api_render.decodeDocIr(encoded)
            let preserved = imported.declarations[0].documentation.getOrThrow().localizedTexts[0]
            @Expect(preserved.referenceState, referenceState)
            @Expect(preserved.targetSymbolId, Some(REFERENCE_STATE_SYMBOL))
            @Expect(api_render.encodeDocIr(imported), encoded)
        }
    }

    @TestCase
    func frozenLegacyInputsKeepUnknownProvenanceAndNoLocalizedReferences(): Unit {
        for (version in [6, 12]) {
            let json = String.fromUtf8(File.readFrom(Path("tests/fixtures/golden-v" + version.toString() + "/basic.docs.json")))
            let imported = api_render.decodeDocIr(json)
            @Expect(imported.schemaVersion, api_model.DOC_IR_SCHEMA_VERSION)
            var comments: Int64 = 0
            for (symbol in imported.declarations) {
                if (let Some(comment) <- symbol.documentation) {
                    @Expect(comment.localizedTexts.isEmpty())
                    @Expect(comment.defaultLanguage.isNone())
                    comments++
                }
            }
            @Expect(comments > 0)
            let encoded = api_render.encodeDocIr(imported)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        }
    }

    @TestCase
    func sourceResolutionKeepsMissingAmbiguousAndHiddenTargetsConservative(): Unit {
        let project = i18nTestProject("/** Summary.\n * @see add Resolved see.\n * @see Missing Missing see.\n" +
            " * @see overload Ambiguous see.\n * @see hidden Hidden see.\n * @throws Failure Resolved throws.\n" +
            " * @throws MissingFailure Missing throws.\n * @throws overload Ambiguous throws.\n */",
            extra: "public class Failure <: Exception {}\npublic func overload(value: Int64): Unit {}\n" +
                "public func overload(value: String): Unit {}\nprivate func hidden(): Unit {}\n")
        try {
            let generated = i18nTestGenerate(project)
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(generated))
            var references: Int64 = 0
            for (symbol in imported.declarations where symbol.name == "add") {
                for (text in symbol.documentation.getOrThrow().localizedTexts where ["see", "throws"].contains(text.kind)) {
                    let expected = if (["add", "Failure"].contains(text.subject)) { "resolved" }
                        else if (text.subject == "overload") { "ambiguous" } else { "unavailable" }
                    @Expect(text.referenceState, expected)
                    @Expect(text.targetSymbolId.isSome(), expected == "resolved")
                    references++
                }
            }
            @Expect(references, 7)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
}
