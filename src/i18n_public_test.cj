package cjdoc

import cjdoc.render as api_render
import cjdoc.model as api_model
import std.env.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

internal func i18nTestProject(comment: String, extra!: String = ""): Path {
    let directory = Directory.createTemp(getTempDirectory())
    Directory.create(directory.join("src"))
    File.writeTo(directory.join("cjpm.toml"),
        "[package]\nname = \"language_fixture\"\nversion = \"0.1.0\"\noutput-type = \"static\"\n".toArray())
    File.writeTo(directory.join("cjdoc.toml"),
        "[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n".toArray())
    File.writeTo(directory.join("src/api.cj"),
        ("package language_fixture\n" + comment +
        "\npublic func add(left: Int64, right: Int64): Int64 { left + right }\n" + extra).toArray())
    directory
}

internal func i18nTestGenerate(project: Path): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "off",
        astPreflightExecutable: i18nTestPreflight()))
}

private func i18nTestPreflight(): ?String {
    Some(getVariable("CJDOC_I18N_BINARY").getOrDefault({ => "target/release/bin/main" }))
}

private func i18nMarkdownText(node: api_model.MarkdownNode): String {
    var text = node.literal
    for (child in node.children) { text += i18nMarkdownText(child) }
    text
}

@Test
class I18nPublicApiTest {
    @TestCase
    func anUnpublishedInputLanguageDoesNotCreateAPhantomPublicationDefault(): Unit {
        let documentation = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
            api_model.ProjectInfo("publication-default"), api_model.ConfigurationSnapshot(lintProfile: "off"),
            languageOptions: Some(api_model.DocumentationLanguageOptions("zh-CN", languages: ["en"])))
        var manifest = ""
        var authorIr = ""
        for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["json", "html"], allLanguages: true)) {
            @Expect(!artifact.path.startsWith("html/zh-CN/"))
            if (artifact.path == "site-manifest.json") { manifest = artifact.content }
            if (artifact.path == "docs.json") { authorIr = artifact.content }
        }
        @Expect(manifest.contains("\"defaultLanguage\":\"en\""))
        @Expect(api_render.decodeDocIr(authorIr).languageOptions.getOrThrow().defaultLanguage, "zh-CN")
    }
    @TestCase
    func workspaceAndDependencyLanguageMetadataBelongToTheirOwnInputs(): Unit {
        let project = i18nTestProject("/** Unused workspace root. */")
        try {
            File.writeTo(project.join("cjpm.toml"), "[workspace]\nmembers = [\"alpha\", \"beta\"]\n".toArray())
            for (name in ["alpha", "beta", "dep"]) {
                Directory.create(project.join(name)); Directory.create(project.join(name + "/src"))
                let dependency = if (name == "alpha") { "\n[dependencies]\ndep = {path = \"../dep\"}\n" } else { "" }
                File.writeTo(project.join(name + "/cjpm.toml"), ("[package]\nname = \"" + name + "\"\nversion = \"0.1.0\"\noutput-type = \"static\"\n" + dependency).toArray())
                File.writeTo(project.join(name + "/src/api.cj"), ("package " + name + "\n/** Original " + name + ". */\npublic func value(): Int64 { 1 }\n").toArray())
            }
            File.writeTo(project.join("alpha/cjdoc.toml"), "[i18n]\ndefault-language = \"en\"\n".toArray())
            let first = DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "off",
                includePathDependencies: true, astPreflightExecutable: i18nTestPreflight()))
            let defaults = HashMap<String, ?String>()
            for (symbol in first.declarations where symbol.name == "value") { defaults[symbol.packageName] = symbol.documentation.getOrThrow().defaultLanguage }
            @Expect(defaults["alpha"], Some("en"))
            @Expect(defaults["beta"], Some("zh-CN"))
            @Expect(defaults["dep"].isNone())
            File.writeTo(project.join("dep/cjdoc.toml"), "[i18n]\ndefault-language = \"en\"\n".toArray())
            let second = DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "off",
                includePathDependencies: true, astPreflightExecutable: i18nTestPreflight(),
                i18n: Some(api_model.DocumentationLanguageOptions("en"))))
            for (symbol in second.declarations where symbol.name == "value") {
                @Expect(symbol.documentation.getOrThrow().defaultLanguage, Some("en"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func languageConfigurationAcceptsMultilineListsAndNormalizesOnlyCase(): Unit {
        let project = i18nTestProject("/** 中文。 */")
        try {
            File.writeTo(project.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"ZH-cn\"\n" +
                "languages = [\n  \"EN\", # English\n  \"zh-CN\",\n]\n").toArray())
            let profile = loadDocumentationLanguages(project.toString()).getOrThrow()
            @Expect(profile.defaultLanguage, "zh-CN")
            @Expect(profile.languages.toArray(), ["en", "zh-CN"])
            File.writeTo(project.join("cjdoc.toml"), "[i18n]\ndefault-language = \"en\"\n".toArray())
            @Expect(loadDocumentationLanguages(project.toString()).getOrThrow().languages.toArray(), ["en"])
            for (languages in ["[\"en\", \"EN\"]", "[\"en-US\"]", "[]", "[\"en\",,\"zh-CN\"]", "[\n\"en\""]) {
                File.writeTo(project.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"en\"\nlanguages = " + languages + "\n").toArray())
                var rejected = false
                try { let _ = loadDocumentationLanguages(project.toString()) } catch (_: IllegalArgumentException) { rejected = true }
                @Expect(rejected)
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func emptyTranslationAndEnglishOnlyDeprecationRetainSharedFacts(): Unit {
        let project = i18nTestProject("/**\n * 中文。\n * @summary[lang=en] English.\n * @param left 左。\n * @param[lang=en] left\n * @deprecated[lang=en] Use the replacement.\n */")
        try {
            let documentation = i18nTestGenerate(project)
            let english = api_render.projectDocumentationLanguage(documentation, "en")
            let chinese = api_render.projectDocumentationLanguage(documentation, "zh-CN")
            var emptyFallback = false
            var deprecated = false
            for (tag in english.declarations[0].documentation.getOrThrow().tags) {
                if (tag.name == "param" && tag.subject == "left") {
                    @Expect(tag.description, "左。")
                    @Expect(tag.translationState, "empty-fallback")
                    emptyFallback = true
                }
            }
            for (tag in chinese.declarations[0].documentation.getOrThrow().tags) {
                if (tag.name == "deprecated") {
                    deprecated = true
                    @Expect(tag.translationState, "missing")
                }
            }
            @Expect(emptyFallback)
            @Expect(deprecated)
            @Expect(api_render.translationCoverageFor(documentation, "en").empty, 1)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func englishDocumentationEditsAreLanguageScopedInApiDiff(): Unit {
        let project = i18nTestProject("/**\n * 中文。\n * @summary[lang=en] First English summary.\n */")
        try {
            let first = api_render.apiContractSnapshotForDocumentation(i18nTestGenerate(project))
            File.writeTo(project.join("src/api.cj"), "package language_fixture\n/**\n * 中文。\n * @summary[lang=en] Updated English summary.\n */\npublic func add(left: Int64, right: Int64): Int64 { left + right }\n".toArray())
            let second = api_render.decodeApiContractSnapshot(api_render.encodeApiContractSnapshot(
                api_render.apiContractSnapshotForDocumentation(i18nTestGenerate(project))))
            let report = compareApiContracts(first, second)
            @Expect(report.summary.breaking, 0)
            @Expect(report.summary.documentationOnly, 1)
            var englishChanged = false
            var chineseChanged = false
            for (entry in report.entries) {
                for (evidence in entry.evidence where evidence.field == "documentationLanguages") {
                    if (evidence.language == Some("en")) { englishChanged = true }
                    if (evidence.language == Some("zh-CN")) { chineseChanged = true }
                }
            }
            @Expect(englishChanged)
            @Expect(!chineseChanged)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func addedAndRemovedDocumentationRetainLanguageEvidence(): Unit {
        let project = i18nTestProject("")
        try {
            let empty = api_render.apiContractSnapshotForDocumentation(i18nTestGenerate(project))
            File.writeTo(project.join("src/api.cj"), ("package language_fixture\n" +
                "/** @summary[lang=en] English documentation. */\n" +
                "public func add(left: Int64, right: Int64): Int64 { left + right }\n").toArray())
            let documented = api_render.apiContractSnapshotForDocumentation(i18nTestGenerate(project))
            for ((before, after, added) in [(empty, documented, true), (documented, empty, false)]) {
                let report = compareApiContracts(before, after)
                @Expect(report.summary.documentationOnly, 1)
                @Expect(report.summary.breaking, 0)
                var found = false
                for (entry in report.entries) {
                    for (evidence in entry.evidence where evidence.field == "documentationLanguages") {
                        @Expect(evidence.language, Some("en"))
                        @Expect(evidence.before.isNone(), added)
                        @Expect(evidence.after.isNone(), !added)
                        found = true
                    }
                }
                @Expect(found)
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func localizedMarkdownKeepsMultilineFieldsInsideTheirListItems(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @summary[lang=en] English summary.
             * @param left 左参数第一段。
             *
             * 左参数第二段。
             *
             * - 左参数嵌套条目。
             *
             * @param[lang=en] right
             *
             * ```cangjie
             * let right: Int64 = 1
             * ```
             *
             * Its second paragraph.
             * @throws[lang=en] Exception First condition.
             * @throws[lang=en] Exception Second condition.
             * @precondition[lang=en] First requirement.
             * @precondition[lang=en] Second requirement.
             * @see[lang=en] add First reference.
             * @see[lang=en] add Second reference.
             */
            """)
        try {
            let documentation = i18nTestGenerate(project)
            var found = false
            for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")) {
                if (!artifact.content.contains("#### Parameters")) { continue }
                let tree = parseStandaloneMarkdown(artifact.content)
                let lists = ArrayList<api_model.MarkdownNode>()
                // Select documentation fields, not the signature or footer lists.
                for (node in tree.children where node.kind == "list") {
                    let text = i18nMarkdownText(node)
                    if (text.contains("左参数第一段。") || text.contains("First condition.") ||
                        text.contains("First requirement.") || text.contains("First reference.")) {
                        lists.add(node)
                    }
                }
                @Expect(lists.size, 4)
                for (index in 0..2) { @Expect(lists[index].children.size, 2) }
                @Expect(lists[3].children.size >= 2, true)
                @Expect(i18nMarkdownText(lists[0].children[0]).contains("左参数第二段。"))
                @Expect(i18nMarkdownText(lists[0].children[0]).contains("左参数嵌套条目。"))
                @Expect(!i18nMarkdownText(lists[0].children[0]).contains("let right: Int64"))
                @Expect(i18nMarkdownText(lists[0].children[1]).contains("Its second paragraph."))
                var codeFound = false
                for (child in lists[0].children[1].children where child.kind == "code_block") {
                    @Expect(child.literal.trimAscii(), "let right: Int64 = 1")
                    @Expect(child.metadata.getOrThrow().language, Some("cangjie"))
                    codeFound = true
                }
                @Expect(codeFound)
                @Expect(i18nMarkdownText(lists[3].children[0]).contains("First reference."))
                @Expect(i18nMarkdownText(lists[3].children[1]).contains("Second reference."))
                found = true
            }
            @Expect(found)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func capturedGuidesRenderBothLanguagesWithoutSource(): Unit {
        let project = i18nTestProject("/** 中文摘要。 */")
        try {
            Directory.create(project.join("docs"))
            File.writeTo(project.join("docs/cn.md"), "# 指南\n\n中文指南正文。\n\n## 使用\n\n中文操作。\n".toArray())
            File.writeTo(project.join("docs/en.md"), ("# Guide\n\nEnglish guide content.\n\n## Usage\n\nEnglish steps.\n" +
                "<!-- cjdoc-bind target=\"language_fixture.add\" selector=\"member\" provenance=\"authored\" version=\"v1\" -->\n").toArray())
            File.writeTo(project.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n" +
                "[[docs.pages]]\nid = \"getting-started\"\nlanguage = \"zh-CN\"\nsource = \"docs/cn.md\"\nroute = \"concepts/guides/cn.html\"\n[docs.pages.sections]\nusage = \"使用\"\n" +
                "[[docs.pages]]\nid = \"getting-started\"\nlanguage = \"en\"\nsource = \"docs/en.md\"\nroute = \"concepts/guides/en.html\"\n[docs.pages.sections]\nusage = \"usage\"\n").toArray())
            let generated = i18nTestGenerate(project)
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(generated))
            var captured = false
            for (page in imported.pages where page.language == Some("en")) {
                @Expect(page.id, "getting-started")
                @Expect(page.bindings.size, 1)
                @Expect(page.bindings[0].target, "language_fixture.add")
                @Expect(page.bindings[0].provenance, "authored")
                @Expect(page.bindings[0].version, "v1")
                @Expect(page.bindings[0].state, "resolved")
                @Expect(page.bindings[0].sourceLine, 8)
                captured = true
            }
            @Expect(captured)
            let _ = removeIfExists(project, recursive: true)
            var chinese = ""
            var english = ""
            var manifest = ""
            for (artifact in api_render.renderDocumentationFormatsWithOptions(imported, ["html", "json"], allLanguages: true)) {
                if (artifact.path == "html/en/concepts/guides/en.html") { english = artifact.content }
                if (artifact.path == "html/zh-CN/concepts/guides/cn.html") { chinese = artifact.content }
                if (artifact.path == "site-manifest.json") { manifest = artifact.content }
            }
            @Expect(english.contains("English guide content."))
            @Expect(!english.contains("中文指南正文。"))
            @Expect(chinese.contains("中文指南正文。"))
            @Expect(english.contains("../../../zh-CN/concepts/guides/cn.html"))
            @Expect(english.contains("data-semantic-section=\"usage\""))
            let routes = JsonNode.parse(manifest).asObject()["routes"].asArray()
            var englishIdentity: ?String = None
            var chineseIdentity: ?String = None
            for (index in 0..routes.size()) {
                let route = routes.get(index).getOrThrow().asObject()
                if (!route["sectionId"].isNull) { continue }
                let href = route["href"].asString()
                if (href == "html/en/concepts/guides/en.html") {
                    englishIdentity = Some(route["pageId"].asString())
                }
                if (href == "html/zh-CN/concepts/guides/cn.html") {
                    chineseIdentity = Some(route["pageId"].asString())
                }
            }
            @Assert(englishIdentity.isSome())
            @Expect(!englishIdentity.getOrThrow().isEmpty())
            @Expect(chineseIdentity, englishIdentity)
            @Expect(englishIdentity != Some("api-home"))
            @Expect(manifest.contains("standalone--doc-usage"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func translationCoverageAndRequirementUseAuthorFields(): Unit {
        let project = i18nTestProject("/**\n * 中文。\n * @summary[lang=en] English.\n * @param left 左。\n * @param[lang=en] left Left.\n * @param right 右。\n * @return 结果。\n * @return[lang=en] Result.\n */")
        try {
            let documentation = DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "off",
                requiredLanguages: ["en"], astPreflightExecutable: i18nTestPreflight()))
            let report = api_render.translationCoverageFor(documentation, "en")
            @Expect(report.total, 4)
            @Expect(report.translated, 3)
            @Expect(report.fallback, 1)
            @Expect(report.percent, 75)
            @Expect(publicHasDiagnostic(documentation, "CJDOC3111"))
            @Expect(documentation.status, "partial")
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func richParameterFallbackHasVisibleLanguageAndSafeMarkdown(): Unit {
        let project = i18nTestProject("/**\n * 中文。\n * @summary[lang=en] English.\n * @param left **左**。\n *\n * - 条目一\n * - 条目二\n *\n * @param[lang=en] right <script>alert(1)</script>\n * @return 结果。\n */")
        try {
            let documentation = i18nTestGenerate(project)
            var rendered = ""
            for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en")) {
                if (artifact.path.endsWith(".html")) { rendered += artifact.content }
            }
            @Expect(rendered.contains("data-translation-state=\"fallback\""))
            @Expect(rendered.contains("Original text: zh-CN"))
            @Expect(rendered.contains("<strong>左</strong>"))
            @Expect(rendered.contains("<ul>"))
            @Expect(!rendered.contains("<script>alert(1)</script>"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
    @TestCase
    func markdownBlocksAndMultilineCodeSpansDoNotCreateTags(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @description[lang=en] First paragraph.
             *
             * Second paragraph.
             *
             * - @param[lang=en] ghost-list stays prose
             *
             * > @return[lang=en] quoted prose
             *
             * ```text
             * @param[lang=en] ghost-fence stays code
             * ```
             *
             * `multiline
             * @param[lang=en] ghost-span stays inline code
             * end`
             *
             * @param left 左值。
             * @param right 右值。
             * @return 结果。
             */
            """)
        try {
            let documentation = i18nTestGenerate(project)
            @Assert(documentation.declarations.size, 1)
            @Expect(!publicHasDiagnostic(documentation, "CJDOC3109"))
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(comment.summary, "中文摘要。")
            var sawDescription = false
            for (text in comment.localizedTexts) {
                if (text.kind != "description" || text.language != Some("en")) { continue }
                @Expect(text.text.contains("Second paragraph."))
                @Expect(text.text.contains("ghost-list"))
                @Expect(text.text.contains("ghost-fence"))
                @Expect(text.text.contains("ghost-span"))
                sawDescription = true
            }
            @Expect(sawDescription)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func malformedQualifiersRecoverAtTheNextTag(): Unit {
        for ((head, code) in [("@param[en] left Bad.", "CJDOC3101"),
            ("@param [lang=en] left Bad.", "CJDOC3101"),
            ("@param[lang=] left Bad.", "CJDOC3102"),
            ("@param[lang=../en] left Bad.", "CJDOC3102"),
            ("@param[lang=en-US] left Bad.", "CJDOC3103"),
            ("@param[lang=fr] left Bad.", "CJDOC3103"),
            ("@param[lang=en,lang=zh-CN] left Bad.", "CJDOC3101"),
            ("@param[lang=\"en\"] left Bad.", "CJDOC3101"),
            ("@param[other=en] left Bad.", "CJDOC3101"),
            ("@param[lang=en left Bad.", "CJDOC3101"),
            ("@since[lang=en] 1.0.0", "CJDOC3112")]) {
            let project = i18nTestProject("/**\n * 中文摘要。\n * @example Intro\n * prose\n * " +
                head + "\n * @return[lang=en] Recovered return.\n */")
            try {
                let documentation = i18nTestGenerate(project)
                @Assert(documentation.declarations.size, 1)
                @Expect(publicHasDiagnostic(documentation, code))
                let english = renderedContent(api_render.renderDocumentationFormatsWithOptions(documentation,
                    ["html"], locale: "en"))
                @Expect(english.contains("Recovered return."))
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func aBadParameterInAnUnselectedLanguageStillFailsValidation(): Unit {
        let project = i18nTestProject("/**\n * 中文摘要。\n * @param[lang=en] renamed Wrong parameter.\n */")
        try {
            let documentation = i18nTestGenerate(project)
            @Expect(publicHasDiagnostic(documentation, "CJDOC3109"))
            @Expect(documentation.declarations[0].parameters.size, 2)
            var located = false
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code != "CJDOC3109") { continue }
                @Expect(diagnostic.message.contains("en"))
                @Expect(diagnostic.source.getOrThrow().path, "src/api.cj")
                @Expect(diagnostic.source.getOrThrow().start.line, 4)
                located = true
            }
            @Expect(located)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func implicitSummaryCanHaveAnExplicitDescriptionButNotAnotherSummary(): Unit {
        for ((field, conflict) in [("description", false), ("summary", true)]) {
            let project = i18nTestProject("/**\n * 中文摘要。\n * @" + field + " 补充说明。\n */")
            try {
                let documentation = i18nTestGenerate(project)
                @Expect(publicHasDiagnostic(documentation, "CJDOC3106"), conflict)
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func legacySourceDoesNotAcquireAnEnglishTranslationFromLocale(): Unit {
        let project = i18nTestProject("/** 保留原文。 */")
        try {
            let _ = removeIfExists(project.join("cjdoc.toml"))
            let documentation = i18nTestGenerate(project)
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            @Expect(decoded.languageOptions.isNone())
            @Expect(decoded.declarations[0].documentation.getOrThrow().defaultLanguage.isNone())
            for (language in ["zh-CN", "en"]) {
                let html = renderedContent(api_render.renderDocumentationFormatsWithOptions(decoded, ["html"], locale: language))
                @Expect(html.contains("保留原文。"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func repeatedContractsRetainBothLanguagesWithoutPositionalPairing(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @precondition 条件甲。
             * @precondition 条件乙。
             * @precondition[lang=en] Condition B.
             * @precondition[lang=en] Condition A.
             */
            """)
        try {
            let documentation = i18nTestGenerate(project)
            @Expect(publicHasDiagnostic(documentation, "CJDOC3107"))
            let english = renderedContent(api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: "en"))
            for (text in ["条件甲。", "条件乙。", "Condition A.", "Condition B."]) { @Expect(english.contains(text)) }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func languageSelectionPreservesApiAndFallsBackPerParameter(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @summary[lang=en] Adds two integers.
             * @param left 中文左值。
             * @param[lang=en] left The left operand.
             * @param right 中文右值。
             * @return 中文返回值。
             * @return[lang=en] The sum.
             */
            """)
        try {
            let documentation = DocumentationEngine().generate(GenerationRequest(project.toString(),
                lintProfile: "off", astPreflightExecutable: i18nTestPreflight()))
            @Expect(documentation.declarations.size, 1)
            @Expect(documentation.declarations[0].parameters.size, 2)
            let serialized = api_render.encodeDocIr(documentation)
            let english = renderedContent(api_render.renderDocumentationFormatsWithOptions(
                api_render.decodeDocIr(serialized), ["html"], locale: "en"))
            @Expect(english.contains("Adds two integers."))
            @Expect(english.contains("The left operand."))
            @Expect(english.contains("中文右值。"))
            @Expect(!english.contains("中文摘要。"))
            @Expect(!english.contains("中文左值。"))
            @Expect(!english.contains("中文返回值。"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC1003"))
            @Expect(api_render.encodeDocIr(documentation), serialized)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func duplicateLanguageIsDiagnosedEvenWhenNotRendered(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @param left 左值。
             * @param right 右值。
             * @return 结果。
             * @return[lang=en] First.
             * @return[lang=EN] Second.
             */
            """)
        try {
            let documentation = DocumentationEngine().generate(GenerationRequest(project.toString(),
                lintProfile: "off", astPreflightExecutable: i18nTestPreflight()))
            @Expect(publicHasDiagnostic(documentation, "CJDOC3106"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
}
