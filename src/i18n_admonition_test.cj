package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func admonitionOnlyProject(comment: String): Path {
    let project = i18nTestProject(comment)
    File.writeTo(project.join("cjdoc.toml"), "".toArray())
    project
}

private func admonitionTagCount(comment: api_model.DocComment, kind: String): Int64 {
    var count: Int64 = 0
    for (tag in comment.tags where tag.name == kind) { count++ }
    count
}

@Test
class I18nAdmonitionTest {
    @TestCase
    func promptOnlyContainersRetainOrdinaryOverviewAnchors(): Unit {
        let project = i18nTestProject("/** Retained API summary. */", extra:
            "\n/** Plain summary.\n *\n * Ordinary container description.\n */\n" +
            "public class Plain { public func run(): Unit {} }\n" +
            "/** Prompt summary.\n *\n * Ordinary container description.\n * @note Authored note.\n */\n" +
            "public class Prompt { public func run(): Unit {} }\n" +
            "/** Summary only.\n * @note Summary-only note.\n */\n" +
            "public class SummaryOnly { public func run(): Unit {} }\n")
        File.writeTo(project.join("cjdoc.toml"), "".toArray())
        try {
            let documentation = i18nTestGenerate(project)
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            for (locale in ["en", "zh-CN"]) {
                var descriptions: Int64 = 0
                var summaries: Int64 = 0
                let artifacts = api_render.renderDocumentationFormatsWithOptions(decoded, ["html"], locale: locale)
                for (artifact in artifacts where artifact.path.startsWith("html/symbols/")) {
                    if (artifact.content.contains("Ordinary container description.")) {
                        @Expect(artifact.content.contains("id=\"overview\""), true)
                        descriptions++
                    }
                    if (artifact.content.contains("Summary-only note.")) {
                        @Expect(artifact.content.contains("id=\"overview\""), false)
                        summaries++
                    }
                }
                @Expect(descriptions, 2)
                @Expect(summaries, 1)
            }
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func promptOnlyScopePreservesOrdinaryDocumentationAndUsesCapturedSources(): Unit {
        let project = admonitionOnlyProject("/**\n" +
            " * Original summary.\n" +
            " *\n" +
            " * Original description.\n" +
            " * > [!NOTE]\n" +
            " * > Body-only alert.\n" +
            " *\n" +
            " * @param left Left value.\n" +
            " * @deprecated Keep this ordinary documentation.\n" +
            " * @warning[lang=en,id=guard] English warning.\n" +
            " * @warning[lang=zh-CN,id=guard] 中文警告。\n" +
            " */")
        try {
            let documentation = i18nTestGenerate(project)
            let original = documentation.declarations[0]
            let comment = original.documentation.getOrThrow()
            @Expect(comment.localizationScope, "admonitions")
            @Expect(comment.defaultLanguage, None<String>)
            @Expect(comment.summary, "Original summary.")
            @Expect(comment.description.contains("Original description."), true)
            @Expect(comment.description.contains("Body-only alert."), true)
            var preservedParameterTag = false
            for (tag in comment.tags where tag.name == "param" && tag.subject == "left") {
                @Expect(tag.description, "Left value.")
                preservedParameterTag = true
            }
            @Expect(preservedParameterTag, true)
            var preservedOrdinaryTag = false
            for (tag in comment.tags where tag.name == "deprecated") {
                @Expect(tag.description, "Keep this ordinary documentation.")
                preservedOrdinaryTag = true
            }
            @Expect(preservedOrdinaryTag, true)
            var bodyAlert = false
            for (node in comment.markdown.children where node.kind == "admonition") {
                bodyAlert = node.metadata.getOrThrow().admonitionLevel == Some("note") &&
                    node.children.size > 0
            }
            @Expect(bodyAlert, true)
            var pairedId = ""
            for (text in comment.localizedTexts where text.kind == "warning" && text.language == Some("en")) {
                pairedId = text.fieldId
                @Expect(text.entryId, Some("guard"))
                @Expect(text.source.isSome(), true)
                @Expect(text.source.getOrThrow().path, "src/api.cj")
                @Expect(text.source.getOrThrow().start.line, 11)
                @Expect(text.source.getOrThrow().start.column, 4)
            }
            @Expect(pairedId, original.id + ":doc:warning:author-guard")
            var defaultVariants: Int64 = 0
            for (tag in comment.tags where tag.name == "warning") {
                @Expect(tag.fieldId, pairedId)
                @Expect(tag.entryId, Some("guard"))
                @Expect(tag.translationState, "unknown")
                @Expect(tag.contentLanguage.isSome(), true)
                defaultVariants++
            }
            @Expect(defaultVariants, 2)
            let selected = api_render.projectDocumentationLanguage(documentation, "en")
            let selectedSymbol = selected.declarations[0]
            let selectedComment = selectedSymbol.documentation.getOrThrow()
            @Expect(selectedComment.localizationScope, "admonitions")
            @Expect(selectedComment.summary, "Original summary.")
            @Expect(selectedComment.description.contains("Original description."), true)
            @Expect(selectedComment.description.contains("Body-only alert."), true)
            var selectedPrompt = false
            for (tag in selectedComment.tags where tag.name == "warning") {
                @Expect(tag.fieldId, pairedId)
                @Expect(tag.entryId, Some("guard"))
                @Expect(tag.contentLanguage, Some("en"))
                @Expect(tag.translationState, "complete")
                @Expect(tag.source.isSome(), true)
                selectedPrompt = true
            }
            @Expect(selectedPrompt, true)
            var selectedParameterTag = false
            for (tag in selectedComment.tags where tag.name == "param" && tag.subject == "left") {
                @Expect(tag.description, "Left value.")
                selectedParameterTag = true
            }
            @Expect(selectedParameterTag, true)
            var selectedOrdinaryTag = false
            for (tag in selectedComment.tags where tag.name == "deprecated") {
                @Expect(tag.description, "Keep this ordinary documentation.")
                selectedOrdinaryTag = true
            }
            @Expect(selectedOrdinaryTag, true)
            var summaryUnknown = false
            var parameterUnknown = false
            var promptComplete = false
            for (entry in api_render.translationCoverageFor(documentation, "en").entries) {
                if (entry.kind == "summary") { summaryUnknown = entry.state == "unknown" }
                if (entry.kind == "param" && entry.subject == "left") { parameterUnknown = entry.state == "unknown" }
                if (entry.kind == "warning") {
                    promptComplete = entry.state == "complete" && entry.actualLanguage == Some("en")
                }
            }
            @Expect(summaryUnknown, true)
            @Expect(parameterUnknown, true)
            @Expect(promptComplete, true)
            for (diagnostic in documentation.diagnostics) {
                @Expect(diagnostic.code != "CJDOC3115")
                @Expect(diagnostic.code != "CJDOC3116")
                @Expect(diagnostic.code != "CJDOC3117")
                @Expect(diagnostic.code != "CJDOC3118")
            }
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func referenceOnlyPromptsRetainAuthorTextWithoutInvalidWrappers(): Unit {
        let raw = StringBuilder("/**\n * Summary.\n")
        for (level in ["note", "warning", "danger"]) {
            raw.append(" * @${level} [ref-${level}]: https://example.test/${level}\n")
        }
        raw.append(" * @note [visible]: https://example.test/visible\n * Visible authored note.\n */")
        let project = i18nTestProject(raw.toString(),
            extra: "\n/** Survivor summary. */\npublic func survivor(): Unit {}\n")
        File.writeTo(project.join("cjdoc.toml"), "".toArray())
        try {
            let documentation = i18nTestGenerate(project)
            @Expect(documentation.status, "partial")
            @Expect(documentation.declarations.size, 2)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(comment.summary, "Summary.")
            var invalid: Int64 = 0
            for (text in comment.localizedTexts where text.text.startsWith("[ref-")) {
                @Expect(text.state, "invalid")
                @Expect(text.fieldId, "")
                @Expect(text.markdown.kind, "document")
                @Expect(text.markdown.children.size, 0)
                @Expect(comment.rawText.contains(text.text), true)
                invalid++
            }
            @Expect(invalid, 3)
            @Expect(admonitionTagCount(comment, "note"), 1)
            @Expect(admonitionTagCount(comment, "warning"), 0)
            @Expect(admonitionTagCount(comment, "danger"), 0)
            var diagnosed: Int64 = 0
            for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3117") {
                @Expect(diagnostic.severity, "error")
                @Expect(diagnostic.source.isSome(), true)
                @Expect(diagnostic.source.getOrThrow().path, "src/api.cj")
                @Expect(diagnostic.symbolId, Some(documentation.declarations[0].id))
                diagnosed++
            }
            @Expect(diagnosed, 3)
            @Expect(!publicHasDiagnostic(documentation, "CJDOC3026"))
            let encoded = api_render.encodeDocIr(documentation)
            let decoded = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(decoded), encoded)
            let html = renderedHtmlContent(api_render.renderDocumentationFormatsWithOptions(
                decoded, ["html"], locale: "en"))
            @Expect(html.contains("Visible authored note."), true)
            @Expect(html.contains("Survivor summary."), true)
            @Expect(html.contains("data-admonition-level=\"warning\""), false)
            @Expect(html.contains("data-admonition-level=\"danger\""), false)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func referenceOnlyTranslationsUseExistingEmptyFallbackState(): Unit {
        let raw = StringBuilder("/**\n * Summary.\n")
        for (level in ["note", "warning", "danger"]) {
            raw.append(" * @${level}[lang=en,id=${level}] Visible ${level}.\n")
            raw.append(" * @${level}[lang=zh-CN,id=${level}] [ref-${level}]: https://example.test/${level}\n")
        }
        raw.append(" */")
        let project = i18nTestProject(raw.toString())
        try {
            let documentation = i18nTestGenerate(project)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            var empty: Int64 = 0
            for (text in comment.localizedTexts where text.language == Some("zh-CN") &&
                text.text.startsWith("[ref-")) {
                @Expect(text.state, "empty")
                @Expect(text.fieldId.isEmpty(), false)
                @Expect(text.entryId, Some(text.kind))
                @Expect(text.markdown.children.size, 0)
                @Expect(comment.rawText.contains(text.text), true)
                empty++
            }
            @Expect(empty, 3)
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            let selected = api_render.projectDocumentationLanguage(decoded, "zh-CN")
            let selectedComment = selected.declarations[0].documentation.getOrThrow()
            var fallbacks: Int64 = 0
            for (tag in selectedComment.tags where ["note", "warning", "danger"].contains(tag.name)) {
                @Expect(tag.description, "Visible ${tag.name}.")
                @Expect(tag.contentLanguage, Some("en"))
                @Expect(tag.translationState, "empty-fallback")
                fallbacks++
            }
            @Expect(fallbacks, 3)
            var coverage: Int64 = 0
            for (entry in api_render.translationCoverageFor(decoded, "zh-CN").entries where
                ["note", "warning", "danger"].contains(entry.kind)) {
                @Expect(entry.state, "empty-fallback")
                @Expect(entry.actualLanguage, Some("en"))
                coverage++
            }
            @Expect(coverage, 3)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func referenceOnlyConflictedPromptCannotRecreatePairedIdentity(): Unit {
        let project = admonitionOnlyProject("/**\n * Summary.\n" +
            " * @warning[lang=en,id=repeated] [ref]: https://example.test/reference\n" +
            " * @warning[lang=en,id=repeated] Visible independent warning.\n */")
        try {
            let documentation = i18nTestGenerate(project)
            @Expect(publicHasDiagnostic(documentation, "CJDOC3117"))
            @Expect(publicHasDiagnostic(documentation, "CJDOC3118"))
            let comment = documentation.declarations[0].documentation.getOrThrow()
            var invalid: Int64 = 0
            var unpaired: Int64 = 0
            for (text in comment.localizedTexts where text.kind == "warning") {
                @Expect(text.fieldId, "")
                @Expect(text.entryId, Some("repeated"))
                if (text.text.startsWith("[ref]")) {
                    @Expect(text.state, "invalid")
                    @Expect(text.markdown.children.size, 0)
                    invalid++
                } else {
                    @Expect(text.state, "unpaired")
                    unpaired++
                }
            }
            @Expect(invalid, 1)
            @Expect(unpaired, 1)
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            let selected = api_render.projectDocumentationLanguage(decoded, "en")
            let selectedComment = selected.declarations[0].documentation.getOrThrow()
            @Expect(admonitionTagCount(selectedComment, "warning"), 1)
            for (tag in selectedComment.tags where tag.name == "warning") {
                @Expect(tag.description, "Visible independent warning.")
                @Expect(tag.fieldId, "")
                @Expect(tag.translationState, "unpaired")
            }
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func emptyTranslationsFallbackWithoutPairingUnidentifiedOrConflictedPrompts(): Unit {
        let project = admonitionOnlyProject("/**\n" +
            " * Summary.\n" +
            " * @warning[lang=en,id=guard] English warning.\n" +
            " * @warning[lang=zh-CN,id=guard]\n" +
            " * @note Chinese note without identity.\n" +
            " * @note[lang=en] English note without identity.\n" +
            " * @warning[id=shared] Conflicted warning.\n" +
            " * @danger[lang=en,id=shared] Conflicted danger.\n" +
            " * @note[lang=en,id=repeated] Duplicate note one.\n" +
            " * @note[lang=en,id=repeated] Duplicate note two.\n" +
            " */")
        try {
            let documentation = i18nTestGenerate(project)
            let authorComment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(authorComment.localizationScope, "admonitions")
            var sawEmpty = false
            var sawDuplicateId = false
            var sawUnpairedWarning = false
            var sawUnpairedNote = false
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC3117") { sawEmpty = true }
                if (diagnostic.code == "CJDOC3118") { sawDuplicateId = true }
                if (diagnostic.code == "CJDOC3107") { sawUnpairedWarning = true }
            }
            @Expect(sawEmpty, true)
            @Expect(sawDuplicateId, true)
            @Expect(sawUnpairedWarning, true)
            let zh = api_render.projectDocumentationLanguage(documentation, "zh-CN")
            let selectedComment = zh.declarations[0].documentation.getOrThrow()
            @Expect(selectedComment.summary, "Summary.")
            var fallback = false
            var unpairedNotes: Int64 = 0
            var unpairedConflicts: Int64 = 0
            for (tag in selectedComment.tags) {
                if (tag.name == "warning" && tag.entryId == Some("guard")) {
                    @Expect(tag.description, "English warning.")
                    @Expect(tag.contentLanguage, Some("en"))
                    @Expect(tag.translationState, "empty-fallback")
                    fallback = true
                }
                if (tag.name == "note") {
                    @Expect(tag.fieldId.isEmpty(), true)
                    @Expect(tag.translationState, "unpaired")
                    unpairedNotes++
                }
                if ((tag.name == "warning" || tag.name == "danger") && tag.entryId == Some("shared")) {
                    @Expect(tag.fieldId.isEmpty(), true)
                    @Expect(tag.translationState, "unpaired")
                    unpairedConflicts++
                }
            }
            @Expect(fallback, true)
            @Expect(unpairedNotes, 4)
            @Expect(unpairedConflicts, 2)
            var fallbackCoverage = false
            var unpairedCoverage: Int64 = 0
            for (entry in api_render.translationCoverageFor(documentation, "zh-CN").entries) {
                if (entry.kind == "warning" && entry.fieldId.endsWith(":author-guard")) {
                    @Expect(entry.state, "empty-fallback")
                    @Expect(entry.actualLanguage, Some("en"))
                    fallbackCoverage = true
                }
                if (entry.kind == "note" || (entry.kind == "warning" && entry.fieldId.isEmpty()) ||
                    entry.kind == "danger") {
                    if (entry.state == "unpaired") { unpairedCoverage++ }
                }
            }
            @Expect(fallbackCoverage, true)
            @Expect(unpairedCoverage, 6)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func nonPromptLocalizationTriggerKeepsFullScopeAndLegacyUnqualifiedError(): Unit {
        let project = admonitionOnlyProject("/**\n" +
            " * Summary.\n" +
            " * @param[lang=en] left English parameter.\n" +
            " * @warning Unqualified warning.\n" +
            " */")
        try {
            let documentation = i18nTestGenerate(project)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(comment.localizationScope, "all")
            var oldLanguageError = false
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC3105") { oldLanguageError = true }
            }
            @Expect(oldLanguageError, true)
            @Expect(comment.summary, "Summary.")
            var prompt = false
            for (text in comment.localizedTexts where text.kind == "warning") { prompt = true }
            @Expect(prompt, true)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
}
