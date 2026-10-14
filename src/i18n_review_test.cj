package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import cjdoc.schema_data as schemas
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let REVIEW_FINGERPRINT = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

private func reviewContractDeclaration(languages: Array<api_model.ApiDocumentationFingerprint>): api_model.ApiContractDeclaration {
    api_model.ApiContractDeclaration("id", "module", "pkg", "function", "f", "pkg.f", "public", "unavailable",
        documentationLanguages: languages, documentationFingerprint: REVIEW_FINGERPRINT,
        sourceFingerprint: REVIEW_FINGERPRINT, metadataFingerprint: REVIEW_FINGERPRINT)
}

private func reviewMarkdownText(node: api_model.MarkdownNode): String {
    var value = node.literal
    for (child in node.children) { value += reviewMarkdownText(child) }
    value
}

@Test
class I18nReviewTest {
    @TestCase
    func explanationOnlyExamplesDoNotPrepareACompilerContext(): Unit {
        let project = i18nTestProject("/** Summary.\n * @example Explanation without executable code.\n */")
        try {
            let documentation = i18nTestGenerate(project)
            // An absent project cannot be compiled; prose-only examples need no compiler context.
            let report = runDoctests(documentation, DoctestConfig(mode: "warn"), project.join("evidence"),
                projectRoot: project.join("absent-project"))
            @Expect(report.results.size, 1)
            @Expect(report.results[0].status, "skipped")
            @Expect(report.results[0].message, "no executable Cangjie fence")
            @Expect(report.results[0].exitCode.isNone())
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func capturedGuideResourceFailureKeepsABoundedSourceFreePage(): Unit {
        let project = i18nTestProject("/** API remains available. */")
        try {
            Directory.create(project.join("docs"))
            File.writeTo(project.join("docs/limited.md"),
                ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> leaf\n".toArray())
            File.writeTo(project.join("cjdoc.toml"),
                ("[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n" +
                "[[docs.pages]]\nid = \"limited\"\nlanguage = \"en\"\nsource = \"docs/limited.md\"\n" +
                "route = \"concepts/guides/limited.html\"\n").toArray())
            let generated = i18nTestGenerate(project)
            @Expect(generated.declarations.size, 1)
            var failures: Int64 = 0
            for (diagnostic in generated.diagnostics where diagnostic.code == "CJDOC3026") {
                @Expect(diagnostic.severity, "warning")
                @Expect(diagnostic.source.getOrThrow().path, "docs/limited.md"); failures++
            }
            @Expect(failures, 1)
            let encoded = api_render.encodeDocIr(generated)
            let imported = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(imported), encoded)
            var pages: Int64 = 0
            for (page in imported.pages where page.id == "limited") {
                @Expect(page.text, MARKDOWN_FALLBACK_TEXT)
                @Expect(reviewMarkdownText(page.markdown), MARKDOWN_FALLBACK_TEXT); pages++
            }
            @Expect(pages, 1)
            var rendered: Int64 = 0
            for (artifact in api_render.renderDocumentationFormatsWithOptions(imported, ["html"], locale: "en")) {
                if (artifact.path == "html/concepts/guides/limited.html") {
                    @Expect(artifact.content.contains(MARKDOWN_FALLBACK_TEXT)); rendered++
                }
            }
            @Expect(rendered, 1)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func localizedPagesWithoutExplicitIdentityAreOmittedRatherThanPairedByRoute(): Unit {
        let project = i18nTestProject("/** Summary. */")
        try {
            Directory.create(project.join("docs"))
            File.writeTo(project.join("docs/en.md"), "# English guide".toArray())
            File.writeTo(project.join("docs/zh.md"), "# 中文指南".toArray())
            File.writeTo(project.join("cjdoc.toml"),
                ("[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n" +
                "[[docs.pages]]\nlanguage = \"en\"\nsource = \"docs/en.md\"\nroute = \"concepts/guides/shared.html\"\n" +
                "[[docs.pages]]\nlanguage = \"zh-CN\"\nsource = \"docs/zh.md\"\nroute = \"concepts/guides/shared.html\"\n").toArray())
            let documentation = i18nTestGenerate(project)
            var errors: Int64 = 0
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC3110" && diagnostic.severity == "error" &&
                    diagnostic.message.contains("requires an explicit id")) { errors++ }
            }
            @Expect(errors, 2)
            for (page in documentation.pages) {
                @Expect(page.source != "docs/en.md" && page.source != "docs/zh.md")
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func directCoverageRendererIncludesTheSameSingleTranslationReport(): Unit {
        let project = i18nTestProject("/** 中文摘要。\n * @summary[lang=en] English summary.\n */")
        try {
            let documentation = i18nTestGenerate(project)
            let direct = api_render.rendererFor("coverage").render(documentation)
            let composite = api_render.renderDocumentationFormatsWithOptions(documentation, ["coverage"])
            @Expect(direct.size, composite.size)
            var translations: Int64 = 0
            for (artifact in direct) {
                var matches: Int64 = 0
                for (other in composite where other.path == artifact.path) {
                    @Expect(artifact.content, other.content); matches++
                }
                @Expect(matches, 1)
                if (artifact.path == "coverage/translations.json") { translations++ }
            }
            @Expect(translations, 1)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func subjectOnlyReferencesKeepTheirResolvedTargetsInBothReadingLanguages(): Unit {
        let project = i18nTestProject("/** 中文摘要。\n * @see add\n * @throws Failure\n */",
            extra: "public class Failure <: Exception {}\n")
        try {
            let documentation = i18nTestGenerate(project)
            for (locale in ["zh-CN", "en"]) {
                let selected = api_render.projectDocumentationLanguage(documentation, locale)
                var references: Int64 = 0
                for (symbol in selected.declarations where symbol.name == "add") {
                    for (tag in symbol.documentation.getOrThrow().tags where ["see", "throws"].contains(tag.name)) {
                        @Expect(tag.description.isEmpty())
                        @Expect(tag.referenceState, "resolved")
                        @Expect(tag.targetSymbolId.isSome())
                        @Expect(tag.translationState, if (locale == "zh-CN") { "empty" } else { "empty-fallback" })
                        references++
                    }
                }
                @Expect(references, 2)
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func pageTargetCollectionsRejectDuplicates(): Unit {
        @ExpectThrows[IllegalArgumentException](api_model.DocumentationPage("guide", "docs/guide.md", "guide.html",
            "Guide", "guide", "", api_model.MarkdownNode("document"), targetSymbolIds: ["id", "id"]))
        let page = api_model.DocumentationPage("guide", "docs/guide.md", "guide.html", "Guide", "guide", "",
            api_model.MarkdownNode("document"), targetSymbolIds: ["id", "other"])
        @Expect(page.targetSymbolIds.size, 2)
    }

    @TestCase
    func currentArtifactSchemasHaveSeparateResourceIdentifiers(): Unit {
        for ((current, legacy, fileName) in [
            (schemas.API_DIFF_SCHEMA, schemas.API_DIFF_V1_SCHEMA, "api-diff-v2.schema.json"),
            (schemas.VERSIONS_SCHEMA, schemas.VERSIONS_V1_SCHEMA, "versions-v2.schema.json"),
            (schemas.DOCTEST_RESULTS_SCHEMA, schemas.DOCTEST_RESULTS_V1_SCHEMA, "doctest-results-v2.schema.json"),
            (schemas.SEARCH_INDEX_SCHEMA, schemas.SEARCH_INDEX_V8_SCHEMA, "search-index-v9.schema.json")]) {
            let currentId = JsonNode.parse(current).asObject()["$id"].asString()
            let legacyId = JsonNode.parse(legacy).asObject()["$id"].asString()
            @Expect(currentId != legacyId)
            @Expect(currentId.endsWith("/" + fileName))
            @Expect(readTextBounded(Path("docs/schema").join(fileName), 1024 * 1024).trimAscii(), current.trimAscii())
            @Expect(schemaTextForCli(fileName.removeSuffix(".schema.json")), current)
        }
    }

    @TestCase
    func localizedDeprecationKeepsItsParagraphsAndListInsideTheQuote(): Unit {
        let project = i18nTestProject("/** Summary.\n * @deprecated[lang=en] Use the replacement.\n *\n * Upgrade details.\n *\n * - Keep configuration.\n * - Rebuild.\n */")
        try {
            var found = false
            for (artifact in api_render.renderDocumentationFormatsWithOptions(i18nTestGenerate(project), ["markdown"], locale: "en")) {
                if (!artifact.content.contains("**Deprecated.**")) { continue }
                let tree = parseStandaloneMarkdown(artifact.content)
                var quotes: Int64 = 0
                for (node in tree.children) {
                    if (node.kind != "block_quote") {
                        @Expect(!reviewMarkdownText(node).contains("Use the replacement."))
                        @Expect(!reviewMarkdownText(node).contains("Upgrade details."))
                        continue
                    }
                    let text = reviewMarkdownText(node)
                    @Expect(text.contains("Deprecated."))
                    @Expect(text.contains("Use the replacement."))
                    @Expect(text.contains("Upgrade details."))
                    @Expect(text.contains("Keep configuration."))
                    @Expect(text.contains("Rebuild."))
                    var lists: Int64 = 0
                    for (child in node.children where child.kind == "list") {
                        @Expect(child.children.size, 2); lists++
                    }
                    @Expect(lists, 1); quotes++
                }
                @Expect(quotes, 1); found = true
            }
            @Expect(found)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func publicRenderersPreserveTheSelectedReadingLanguage(): Unit {
        let project = i18nTestProject("/** 中文作者摘要。\n * @summary[lang=en] English authored summary.\n */")
        try {
            let selected = api_render.projectDocumentationLanguage(i18nTestGenerate(project), "zh-CN")
            let html = renderedContent(api_render.HtmlDocumentationRenderer().render(selected))
            let markdown = renderedContent(api_render.MarkdownDocumentationRenderer().render(selected))
            @Expect(html.contains("<html lang=\"zh-CN\""))
            @Expect(html.contains("中文作者摘要。"))
            @Expect(!html.contains("English authored summary."))
            @Expect(markdown.contains("中文作者摘要。"))
            @Expect(!markdown.contains("English authored summary."))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func localizedSummaryIndexesContainRenderedWords(): Unit {
        let project = i18nTestProject("/** 中文摘要。\n * @summary[lang=en] **Fast** [API](https://example.test/api).\n */")
        try {
            var indexes: Int64 = 0
            for (artifact in api_render.renderDocumentationFormatsWithOptions(i18nTestGenerate(project), ["html"], locale: "en")) {
                if (!artifact.path.endsWith("symbol-index.json") && !artifact.path.endsWith("search-index.json")) { continue }
                @Expect(artifact.content.contains("Fast"))
                @Expect(artifact.content.contains("API"))
                @Expect(!artifact.content.contains("**Fast**"))
                @Expect(!artifact.content.contains("[API]"))
                indexes++
            }
            @Expect(indexes, 2)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func localizedFieldImagesSelectAndEmitOnlyTheReadingAssets(): Unit {
        let project = i18nTestProject("/** 摘要。\n * @param left ![中文图片](zh.png)\n * @param[lang=en] left ![English image](en.png)\n */")
        try {
            // A captured IR exercises reading projection on every platform;
            // secure source-file capture has its own Linux integration case.
            let original = i18nTestGenerate(project)
            let documentation = api_model.DocumentationSet(original.generator, original.status,
                original.project, original.configuration, files: original.files.toArray(),
                modules: original.modules.toArray(), providers: original.providers.toArray(),
                packages: original.packages.toArray(), declarations: original.declarations.toArray(),
                languageOptions: original.languageOptions, assets: [
                    api_model.AssetDoc("sha256-c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96",
                        "image/png", "zh.png", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC"),
                    api_model.AssetDoc("sha256-e878950f8091ec010cf5cc723bdea027a8539cf7147cfea199c2f666232dcd4e",
                        "image/png", "en.png", "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC")])
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            for (format in ["html", "markdown"]) {
                let artifacts = api_render.renderDocumentationFormatsWithOptions(decoded, [format], locale: "en")
                var emitted: Int64 = 0
                for (artifact in artifacts where artifact.path.contains("/assets/")) { emitted++ }
                @Expect(emitted, 1)
                let rendered = renderedContent(artifacts)
                @Expect(rendered.contains("English image"))
                @Expect(!rendered.contains("中文图片"))
                @Expect(rendered.contains("assets/"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func ambiguousExternalSnapshotsKeepTheirVisibleState(): Unit {
        let project = i18nTestProject("/** 原文。\n * @summary[lang=en] English.\n */")
        try {
            let original = i18nTestGenerate(project)
            let documentation = api_model.DocumentationSet(original.generator, original.status,
                original.project, original.configuration, files: original.files.toArray(),
                modules: original.modules.toArray(), providers: original.providers.toArray(),
                packages: original.packages.toArray(), declarations: original.declarations.toArray(),
                languageOptions: original.languageOptions, externalDocumentation: [
                    api_model.ExternalDocumentationReference(original.declarations[0].id,
                        "dependency", "ambiguous", "")])
            for ((locale, label) in [("en", "Ambiguous reference"), ("zh-CN", "引用不明确")]) {
                let html = renderedContent(api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale))
                @Expect(html.contains("data-state=\"ambiguous\""))
                @Expect(html.contains(label))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func fingerprintLanguagesNormalizeBeforeCodecRoundTrip(): Unit {
        let fingerprint = api_model.ApiDocumentationFingerprint(Some("EN"), REVIEW_FINGERPRINT)
        @Expect(fingerprint.language, Some("en"))
        let declaration = reviewContractDeclaration([fingerprint])
        let snapshot = api_model.ApiContractSnapshot("project", "external", "default", declarations: [declaration])
        let decoded = api_render.decodeApiContractSnapshot(api_render.encodeApiContractSnapshot(snapshot))
        @Expect(decoded.declarations[0].documentationLanguages[0].language, Some("en"))
        @ExpectThrows[IllegalArgumentException](api_model.ApiDocumentationFingerprint(Some("fr"), REVIEW_FINGERPRINT))
    }

    @TestCase
    func fingerprintCollectionsRequireUniqueNormalizedLanguages(): Unit {
        let english = api_model.ApiDocumentationFingerprint(Some("EN"), REVIEW_FINGERPRINT)
        let chinese = api_model.ApiDocumentationFingerprint(Some("zh-cn"), REVIEW_FINGERPRINT)
        let unknown = api_model.ApiDocumentationFingerprint(None, REVIEW_FINGERPRINT)
        for (invalid in [[english, api_model.ApiDocumentationFingerprint(Some("en"), REVIEW_FINGERPRINT)],
            [unknown, unknown], [english, chinese, unknown, english]]) {
            @ExpectThrows[IllegalArgumentException](reviewContractDeclaration(invalid))
        }
        let snapshot = api_model.ApiContractSnapshot("project", "external", "default",
            declarations: [reviewContractDeclaration([english, chinese, unknown])])
        let decoded = api_render.decodeApiContractSnapshot(api_render.encodeApiContractSnapshot(snapshot))
        @Expect(decoded.declarations[0].documentationLanguages.size, 3)
        @Expect(reviewContractDeclaration([]).documentationLanguages.isEmpty())
    }

    @TestCase
    func externalSnapshotStatesAgreeWithTheirUrls(): Unit {
        @ExpectThrows[IllegalArgumentException](api_model.ExternalDocumentationReference("id", "dep", "available", ""))
        for (state in ["unavailable", "ambiguous"]) {
            @ExpectThrows[IllegalArgumentException](api_model.ExternalDocumentationReference("id", "dep", state, "https://example.test/api"))
            @Expect(api_model.ExternalDocumentationReference("id", "dep", state, "").state, state)
        }
        let project = i18nTestProject("/** Summary. */")
        try {
            let original = i18nTestGenerate(project)
            let documentation = api_model.DocumentationSet(original.generator, original.status,
                original.project, original.configuration, files: original.files.toArray(),
                modules: original.modules.toArray(), providers: original.providers.toArray(),
                packages: original.packages.toArray(), declarations: original.declarations.toArray(),
                languageOptions: original.languageOptions, externalDocumentation: [
                    api_model.ExternalDocumentationReference(original.declarations[0].id, "dep", "available", "https://example.test/api")])
            let json = api_render.encodeDocIr(documentation)
            @Expect(api_render.decodeDocIr(json).externalDocumentation[0].url, "https://example.test/api")
            let externalAt = json.indexOf("\"externalDocumentation\"").getOrThrow()
            let external = json[externalAt..]
            let marker = "\"state\": \"available\""
            let stateAt = external.indexOf(marker).getOrThrow()
            let invalid = json[..externalAt] + external[..stateAt] + "\"state\": \"ambiguous\"" +
                external[stateAt + marker.size..]
            @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(invalid))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func removedMembersTryTheTargetDefaultLanguageAtEveryOwner(): Unit {
        let current = VersionSite(VersionComposeSpec("new", "unused"), VersionSymbolIndex())
        let target = VersionSite(VersionComposeSpec("old", "unused"), VersionSymbolIndex())
        target.defaultLanguage = "zh-CN"
        current.parentsByIdentity["en:symbol:member:section:param-left"] = "en:symbol:member"
        current.parentsByIdentity["en:symbol:member"] = "en:symbol:owner"
        current.parentsByIdentity["en:symbol:owner"] = "en:symbol:module"
        target.logicalRoutes["zh-CN:symbol:owner"] = "html/zh-CN/symbols/owner.html"
        let (href, fallback) = versionLanguageTarget(current, "en:symbol:member:section:param-left", target)
        @Expect(href, "html/zh-CN/symbols/owner.html")
        @Expect(fallback)
        let _ = target.logicalRoutes.remove("zh-CN:symbol:owner")
        target.logicalRoutes["zh-CN:symbol:module"] = "html/zh-CN/packages/module.html"
        @Expect(versionLanguageTarget(current, "en:symbol:member", target)[0], "html/zh-CN/packages/module.html")
        let _ = target.logicalRoutes.remove("zh-CN:symbol:module")
        let _ = target.paths.add("html/zh-CN/index.html")
        @Expect(versionLanguageTarget(current, "en:symbol:member", target)[0], "html/zh-CN/index.html")
        let _ = target.paths.add("html/en/index.html")
        @Expect(versionLanguageTarget(current, "en:symbol:member", target)[0], "html/en/index.html")
    }

    @TestCase
    func fingerprintModelsRejectValuesOutsideLowercaseSha256(): Unit {
        for (invalid in [
            "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "short"]) {
            @ExpectThrows[IllegalArgumentException](api_model.ApiDocumentationFingerprint(None, invalid))
        }
        @Expect(api_model.ApiDocumentationFingerprint(None, REVIEW_FINGERPRINT).fingerprint, REVIEW_FINGERPRINT)
    }

    @TestCase
    func diffEvidenceLanguagesUseThePublishedEnum(): Unit {
        @Expect(api_model.ApiDiffEvidence("documentationLanguages", language: Some("EN")).language, Some("en"))
        @Expect(api_model.ApiDiffEvidence("documentationLanguages", language: Some("ZH-cn")).language, Some("zh-CN"))
        @Expect(api_model.ApiDiffEvidence("documentationLanguages").language.isNone())
        @ExpectThrows[IllegalArgumentException](api_model.ApiDiffEvidence("documentationLanguages", language: Some("fr")))
        @ExpectThrows[IllegalArgumentException](api_model.ApiDiffEvidence("documentationLanguages", language: Some("en-US")))
    }

    @TestCase
    func resolvedLocalizedReferencesRequireTargets(): Unit {
        for (kind in ["see", "throws"]) {
            @ExpectThrows[IllegalArgumentException](api_model.DocumentationText("field", kind, "Target",
                Some("en"), "Description", api_model.MarkdownNode("document"), referenceState: "resolved"))
            let text = api_model.DocumentationText("field", kind, "Target", Some("en"), "Description",
                api_model.MarkdownNode("document"), referenceState: "resolved", targetSymbolId: Some("target"))
            @Expect(text.targetSymbolId, Some("target"))
        }
    }
}

@When[os == "Linux"]
@Test
class I18nAssetCaptureTest {
    @TestCase
    func localizedFieldImagesAreCapturedBeforeReadingProjection(): Unit {
        let project = i18nTestProject("/** 摘要。\n * @param left ![中文图片](zh.png)\n * @param[lang=en] left ![English image](en.png)\n */")
        try {
            for (name in ["zh", "en"]) {
                let image: Array<Byte> = if (name == "zh") {
                    [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
                     0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
                     0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 96, 96, 96, 0, 0,
                     0, 4, 0, 1, 246, 23, 56, 85, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
                } else {
                    [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
                     0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 144, 119, 83, 222,
                     0, 0, 0, 12, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
                     5, 254, 2, 254, 13, 239, 70, 184, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
                }
                File.writeTo(project.join("src/" + name + ".png"), image)
            }
            let documentation = i18nTestGenerate(project)
            @Expect(documentation.assets.size, 2)
            for (format in ["html", "markdown"]) {
                let artifacts = api_render.renderDocumentationFormatsWithOptions(documentation, [format], locale: "en")
                var emitted: Int64 = 0
                for (artifact in artifacts where artifact.path.contains("/assets/")) { emitted++ }
                @Expect(emitted, 1)
                let rendered = renderedContent(artifacts)
                @Expect(rendered.contains("English image"))
                @Expect(!rendered.contains("中文图片"))
                @Expect(rendered.contains("assets/"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
}

@Test
class I18nCliReviewTest {
    @TestCase
    func multilineLanguageArraysKeepTheFinalQuotedValueAndComments(): Unit {
        let project = i18nTestProject("/** Summary. */")
        try {
            for (last in ["  \"zh-CN\"", "  \"zh-CN\" # final language", "  \"zh-CN\", # trailing comma"]) {
                File.writeTo(project.join("cjdoc.toml"),
                    ("[i18n] # language configuration\ndefault-language = \"en\" # source language\n" +
                    "languages = [\n  \"en\", # first language\n" + last + "\n] # end\n").toArray())
                let options = loadDocumentationLanguages(project.toString()).getOrThrow()
                @Expect(options.defaultLanguage, "en")
                @Expect(options.languages.size, 2)
                @Expect(options.languages[0], "en")
                @Expect(options.languages[1], "zh-CN")
            }
            @Expect(qualityTomlLine("title = \"# retained\" # removed"), "title = \"# retained\"")
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func multilingualPublicationFlagsRequireGenerateOrRender(): Unit {
        @ExpectThrows[IllegalArgumentException](parseNewCli(["serve", "--all-languages"]))
        @Expect(parseNewCli(["serve", "--locale", "en"]).locale, "en")
        @Expect(parseNewCli(["generate", "--all-languages"]).allLanguages)
        @Expect(parseNewCli(["render", "--input", "docs.json", "--all-languages"]).allLanguages)
    }
}
