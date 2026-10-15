package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ApiCollectionStateContractTest {
    @TestCase
    func presentationErrorsPreserveDeletionCertaintyAcrossReadingAndCodec(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"api_collection_contract\"\n" +
                "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
            let kept = "package api_collection_contract\n/** Kept.\n * ```python\n * True\n * ```\n */\n" +
                "public func kept(): Unit {}\n"
            File.writeTo(root.join("src/api.cj"), (kept + "public func removed(): Unit {}\n").toArray())
            let baseline = api_render.apiContractSnapshotForDocumentation(DocumentationEngine().generate(
                GenerationRequest(root.toString(), lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                    highlight: Some(HighlightConfig(mode: "off")))))
            File.writeTo(root.join("src/api.cj"), kept.toArray())
            for (mode in ["off", "static"]) {
                let generated = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                    i18n: Some(api_model.DocumentationLanguageOptions("en", languages: ["en", "zh-CN"])),
                    highlight: Some(HighlightConfig(mode: mode, languages: ["python"], onError: "error"))))
                @Expect(generated.apiCollectionState, "resolved")
                if (mode == "static") {
                    @Expect(generated.status, "partial")
                    var errors: Int64 = 0
                    for (diagnostic in generated.diagnostics where diagnostic.code == "CJDOC4027") { errors++ }
                    @Expect(errors, 1)
                }
                for (language in ["en", "zh-CN"]) {
                    let decoded = api_render.decodeDocIr(api_render.encodeDocIr(
                        api_render.projectDocumentationLanguage(generated, language)))
                    @Expect(decoded.apiCollectionState, "resolved")
                    let report = compareApiContracts(baseline, api_render.apiContractSnapshotForDocumentation(decoded))
                    @Expect(report.comparisonState, "resolved")
                    @Expect(report.summary.breaking, 1)
                    @Expect(report.summary.potentiallyBreaking, 0)
                    @Expect(apiDiffExitCode(report, true, false), 1)
                }
            }
            File.writeTo(root.join("src/broken.cj"), "package api_collection_contract\npublic func broken(\n".toArray())
            let incomplete = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(mode: "static", languages: ["python"], onError: "error"))))
            @Expect(incomplete.status, "partial")
            @Expect(incomplete.apiCollectionState, "partial")
            @Expect(api_render.apiContractSnapshotForDocumentation(incomplete).collectionState, "partial")
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func currentFieldIsStrictAndLegacyStatusMigrationIsConservative(): Unit {
        for ((status, state) in [("complete", "resolved"), ("partial", "partial")]) {
            let original = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), status,
                api_model.ProjectInfo("collection-codec"), api_model.ConfigurationSnapshot(lintProfile: "off"))
            @Expect(original.apiCollectionState, state)
            let current = api_render.encodeDocIr(original)
            let field = "  \"apiCollectionState\": \"" + state + "\",\n"
            @Expect(current.contains(field))
            @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(current.replace(field, "")))
            @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(current.replace(field,
                "  \"apiCollectionState\": \"complete\",\n")))
            for (version in 6..14) {
                let legacy = current.replace("cjdoc.doc-ir/14", "cjdoc.doc-ir/" + version.toString())
                    .replace(field, "")
                let compatible = if (version < 9) { legacy.replace(",\n    \"repository\": null", "") } else { legacy }
                let migrated = api_render.decodeDocIr(compatible)
                @Expect(migrated.schemaVersion, "cjdoc.doc-ir/14")
                @Expect(migrated.apiCollectionState, state)
                @Expect(api_render.decodeDocIr(api_render.encodeDocIr(migrated)).apiCollectionState, state)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(legacy.replace(
                    "\"status\":", "\"apiCollectionState\": \"resolved\", \"status\":")))
            }
        }
        let strict = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
            api_model.ProjectInfo("presentation-only"), api_model.ConfigurationSnapshot(lintProfile: "off"),
            apiCollectionState: Some("resolved"),
            diagnostics: [api_model.Diagnostic("error", "CJDOC4027", "Presentation failed")])
        @Expect(api_render.decodeDocIr(api_render.encodeDocIr(strict)).apiCollectionState, "resolved")
        @ExpectThrows[IllegalArgumentException](api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo("invalid"), api_model.ConfigurationSnapshot(),
            apiCollectionState: Some("unknown")))
    }

    @TestCase
    func capturedGuideFailureKeepsApiEvidenceAfterSourceRemoval(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            Directory.create(root.join("docs"))
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"guide_collection\"\n" +
                "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
            File.writeTo(root.join("src/api.cj"), "package guide_collection\npublic func kept(): Unit {}\n".toArray())
            File.writeTo(root.join("docs/guide.md"), "# Guide\n\n~~~python\nTrue\n~~~\n".toArray())
            File.writeTo(root.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"en\"\nlanguages = [\"en\", \"zh-CN\"]\n" +
                "[[docs.pages]]\nid = \"guide\"\nsource = \"docs/guide.md\"\nroute = \"concepts/guide.html\"\n").toArray())
            let generated = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(mode: "static", languages: ["python"], onError: "error"))))
            @Expect(generated.status, "partial")
            @Expect(generated.apiCollectionState, "resolved")
            @Expect(!generated.pages.isEmpty())
            let encoded = api_render.encodeDocIr(generated)
            let _ = removeIfExists(root, recursive: true)
            let imported = api_render.decodeDocIr(encoded)
            for (language in ["en", "zh-CN"]) {
                let reading = api_render.projectDocumentationLanguage(imported, language)
                @Expect(reading.apiCollectionState, "resolved")
                @Expect(api_render.apiContractSnapshotForDocumentation(reading).collectionState, "resolved")
                var guides: Int64 = 0
                for (artifact in api_render.renderDocumentationFormatsWithOptions(reading, ["html"], locale: language)) {
                    if (artifact.path == "html/concepts/guide.html") {
                        @Expect(artifact.content.contains("True"))
                        guides++
                    }
                }
                @Expect(guides, 1)
            }
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func optionalBudgetPreservesCollectionButWholeBundleFallbackDoesNot(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"budget_collection\"\n" +
                "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
            File.writeTo(root.join("src/api.cj"), ("package budget_collection\n/** Kept.\n" +
                " * ~~~python\n * True\n * ~~~\n */\npublic func kept(): Unit {}\n").toArray())
            let revision = String.fromUtf8(Array<Byte>(24 * 1024 * 1024 + 1, repeat: b'x'))
            let fallback = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                repository: Some(api_model.RepositoryInfo("https://github.com/example/repository", revision)),
                highlight: Some(HighlightConfig(mode: "static", languages: ["python"], onError: "error"))))
            @Expect(fallback.status, "partial")
            @Expect(fallback.apiCollectionState, "unavailable")
            @Expect(fallback.declarations.size, 0)
            var backendErrors: Int64 = 0
            for (diagnostic in fallback.diagnostics where diagnostic.code == "CJDOC4027") { backendErrors++ }
            @Expect(backendErrors, 1)
            @Expect(api_render.apiContractSnapshotForDocumentation(
                api_render.decodeDocIr(api_render.encodeDocIr(fallback))).collectionState, "unavailable")
            let source = StringBuilder()
            source.append("package budget_collection\n")
            for (index in 0..1500) {
                source.append("public func item" + index.toString() + "(value: Int64): Int64 { value }\n")
            }
            File.writeTo(root.join("src/api.cj"), source.toString().toArray())
            let budgeted = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(mode: "static", languages: ["cangjie"]))))
            @Expect(budgeted.apiCollectionState, "resolved")
            @Expect(budgeted.declarations.size, 1500)
            var warnings: Int64 = 0
            for (diagnostic in budgeted.diagnostics where diagnostic.code == "CJDOC3028") { warnings++ }
            @Expect(warnings, 1)
            @Expect(api_render.decodeDocIr(api_render.encodeDocIr(budgeted)).apiCollectionState, "resolved")
        } finally { let _ = removeIfExists(root, recursive: true) }
    }
}
