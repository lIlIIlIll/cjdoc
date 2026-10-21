package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let REFERENCE_FINGERPRINT_MODULE = "cjdoc:module:v1:reference-fingerprint"
private let REFERENCE_FINGERPRINT_PREFIX = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areference-fingerprint::fixture::function:"
private let REFERENCE_FINGERPRINT_API = REFERENCE_FINGERPRINT_PREFIX + "api#g0()"
private let REFERENCE_FINGERPRINT_A = REFERENCE_FINGERPRINT_PREFIX + "targetA#g0()"
private let REFERENCE_FINGERPRINT_B = REFERENCE_FINGERPRINT_PREFIX + "targetB#g0()"

private func referenceFingerprintMarkdown(text: String): api_model.MarkdownNode {
    api_model.MarkdownNode("document", children: [api_model.MarkdownNode("paragraph",
        children: [api_model.MarkdownNode("text", literal: text)])])
}

private func referenceFingerprintDocumentation(kind: String, changedLanguage: ?String,
    referenceState: String, target: ?String, withLanguageFields!: Bool = true): api_model.DocumentationSet {
    let defaultLanguage = if (changedLanguage == Some("en")) { "zh-CN" } else { "en" }
    let fields = ArrayList<api_model.DocumentationText>()
    if (withLanguageFields) {
        for (language in [Some("en"), Some("zh-CN"), None<String>]) {
            fields.add(api_model.DocumentationText(REFERENCE_FINGERPRINT_API + ":doc:summary:",
                "summary", "", language, "Summary.", referenceFingerprintMarkdown("Summary.")))
            fields.add(api_model.DocumentationText(REFERENCE_FINGERPRINT_API + ":doc:" + kind + ":author-reference",
                kind, "Reference", language, "Reference description.", referenceFingerprintMarkdown("Reference description."),
                referenceState: if (language == changedLanguage) { referenceState } else { "resolved" },
                targetSymbolId: if (language == changedLanguage) { target } else { Some(REFERENCE_FINGERPRINT_A) }))
        }
    }
    let comment = api_model.DocComment("Captured author comment.", "Summary.", "", referenceFingerprintMarkdown("Summary."),
        tags: [api_model.DocTag(kind, "Reference", "Reference description.",
            referenceState: if (!withLanguageFields) { referenceState } else { "resolved" },
            targetSymbolId: if (!withLanguageFields) { target } else { Some(REFERENCE_FINGERPRINT_A) })],
        defaultLanguage: if (withLanguageFields) { Some(defaultLanguage) } else { None },
        localizedTexts: fields.toArray())
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 2, 1))
    let symbols = ArrayList<api_model.SymbolDoc>()
    let ids = ArrayList<String>()
    for (name in ["api", "targetA", "targetB"]) {
        let id = REFERENCE_FINGERPRINT_PREFIX + name + "#g0()"
        ids.add(id)
        symbols.add(api_model.SymbolDoc(id, "function", name, "fixture." + name, "fixture",
            REFERENCE_FINGERPRINT_MODULE, "public", source, "public func " + name + "(): Unit",
            api_model.SemanticInfo("partial", "ast"), documentation: if (name == "api") { Some(comment) } else { None }))
    }
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("fixture"), api_model.ConfigurationSnapshot(),
        providers: [api_model.ProviderInfo("ast", "builtin", REFERENCE_FINGERPRINT_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(REFERENCE_FINGERPRINT_MODULE, "reference-fingerprint", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", REFERENCE_FINGERPRINT_MODULE,
            sourceFiles: ["src/api.cj"], symbolIds: ids.toArray())],
        files: [api_model.FileDoc("src/api.cj", REFERENCE_FINGERPRINT_MODULE, "fixture")], declarations: symbols.toArray())
}

private func referenceFingerprintSnapshot(documentation: api_model.DocumentationSet): api_model.ApiContractSnapshot {
    let imported = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
    let snapshot = api_render.apiContractSnapshotForDocumentation(imported)
    api_render.decodeApiContractSnapshot(api_render.encodeApiContractSnapshot(snapshot))
}

private func referenceFingerprintDeclaration(snapshot: api_model.ApiContractSnapshot): api_model.ApiContractDeclaration {
    for (declaration in snapshot.declarations where declaration.id == REFERENCE_FINGERPRINT_API) { return declaration }
    throw IllegalArgumentException("missing reference-fingerprint API")
}

private func referenceLanguageFingerprint(snapshot: api_model.ApiContractSnapshot, language: ?String): String {
    for (entry in referenceFingerprintDeclaration(snapshot).documentationLanguages where entry.language == language) {
        return entry.fingerprint
    }
    throw IllegalArgumentException("missing reference-fingerprint language")
}

private func expectReferenceLanguageDiff(kind: String, language: ?String, state: String, target: ?String): Unit {
    let before = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, language, "resolved", Some(REFERENCE_FINGERPRINT_A)))
    let after = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, language, state, target))
    @Expect(referenceFingerprintDeclaration(before).documentationFingerprint,
        referenceFingerprintDeclaration(after).documentationFingerprint)
    for (scope in [Some("en"), Some("zh-CN"), None<String>]) {
        @Expect(referenceLanguageFingerprint(before, scope) == referenceLanguageFingerprint(after, scope), scope != language)
    }
    let report = compareApiContracts(before, after)
    @Expect(report.summary.documentationOnly, 1)
    @Expect(report.summary.breaking, 0)
    @Expect(report.summary.potentiallyBreaking, 0)
    var evidenceCount: Int64 = 0
    for (entry in report.entries) {
        for (evidence in entry.evidence where evidence.field == "documentationLanguages") {
            @Expect(entry.classification, "documentation-only")
            @Expect(evidence.language, language)
            @Expect(evidence.before, Some(referenceLanguageFingerprint(before, language)))
            @Expect(evidence.after, Some(referenceLanguageFingerprint(after, language)))
            evidenceCount++
        }
        for (evidence in entry.evidence) { @Expect(evidence.field != "documentationFingerprint") }
    }
    @Expect(evidenceCount, 1)
}

@Test
class I18nReferenceFingerprintTest {
    @TestCase
    func referenceStateDowngradesAreReportedOnlyInTheChangedLanguage(): Unit {
        for (kind in ["see", "throws"]) {
            for (language in [Some("en"), Some("zh-CN"), None<String>]) {
                for (state in ["ambiguous", "unavailable"]) { expectReferenceLanguageDiff(kind, language, state, None) }
            }
        }
    }

    @TestCase
    func changedResolvedTargetIsReportedOnlyInTheChangedLanguage(): Unit {
        for (kind in ["see", "throws"]) {
            for (language in [Some("en"), Some("zh-CN"), None<String>]) {
                expectReferenceLanguageDiff(kind, language, "resolved", Some(REFERENCE_FINGERPRINT_B))
            }
        }
    }

    @TestCase
    func unchangedReferenceStatesAndTargetsKeepAllFingerprintsStable(): Unit {
        for (kind in ["see", "throws"]) {
            let before = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, Some("en"),
                "resolved", Some(REFERENCE_FINGERPRINT_A)))
            let after = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, Some("en"),
                "resolved", Some(REFERENCE_FINGERPRINT_A)))
            @Expect(api_render.encodeApiContractSnapshot(before), api_render.encodeApiContractSnapshot(after))
            let report = compareApiContracts(before, after)
            @Expect(report.summary.documentationOnly, 0)
            @Expect(report.summary.unchanged, 3)
            for (entry in report.entries) { @Expect(entry.evidence.isEmpty()) }
        }
    }

    @TestCase
    func nonLocalizedReferenceResolutionStillChangesCompatibilityAndUnknownFingerprints(): Unit {
        for (kind in ["see", "throws"]) {
            for (state in ["ambiguous", "unavailable"]) {
                let before = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, None,
                    "resolved", Some(REFERENCE_FINGERPRINT_A), withLanguageFields: false))
                let after = referenceFingerprintSnapshot(referenceFingerprintDocumentation(kind, None, state, None,
                    withLanguageFields: false))
                @Expect(referenceFingerprintDeclaration(before).documentationFingerprint !=
                    referenceFingerprintDeclaration(after).documentationFingerprint)
                @Expect(referenceLanguageFingerprint(before, None) != referenceLanguageFingerprint(after, None))
                let report = compareApiContracts(before, after)
                @Expect(report.summary.documentationOnly, 1)
                var compatibility = false
                var unknown = false
                for (entry in report.entries) {
                    for (evidence in entry.evidence) {
                        if (evidence.field == "documentationFingerprint") { compatibility = true }
                        if (evidence.field == "documentationLanguages" && evidence.language.isNone()) { unknown = true }
                    }
                }
                @Expect(compatibility)
                @Expect(unknown)
            }
        }
    }
}
