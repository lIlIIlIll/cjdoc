package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class DeclarationGroupingContracts {
    private func generate(): api_model.DocumentationSet {
        DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "declaration-groups", audience: "external", lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
    }

    @TestCase
    func sharedMetadataSurvivesLocaleSelectionAndSourceFreeReplay(): Unit {
        let original = generate()
        let encoded = api_render.encodeDocIr(original)
        let decoded = api_render.decodeDocIr(encoded)
        @Expect(decoded.declarations.size, original.declarations.size)
        for (locale in ["zh-CN", "en"]) {
            let selected = api_render.projectDocumentationLanguage(decoded, locale)
            for (symbol in selected.declarations where symbol.name == "Application") {
                let doc = symbol.documentation.getOrThrow()
                var groups: Int64 = 0
                for (tag in doc.tags where tag.name == "group") {
                    groups++
                    @Expect(tag.subject, "10-application")
                    @Expect(tag.description, "应用 API")
                    @Expect(tag.contentLanguage.isNone())
                }
                @Expect(groups, 1)
                for (text in doc.localizedTexts) { @Expect(text.kind != "group") }
            }
            let snapshot = api_render.DocumentationReadSnapshot(decoded, locale: Some(locale))
            for (symbol in decoded.declarations where symbol.name == "support") {
                let markdown = snapshot.renderDeclarationMarkdown(symbol.id).getOrThrow()
                @Expect(markdown.contains("20-generated-spi"))
                @Expect(markdown.contains("生成代码 SPI"))
            }
        }
        @Expect(api_render.encodeDocIr(original), encoded)
    }

    @TestCase
    func packageAndMemberGroupsKeepEveryVisibleDeclarationAndLegacyAnchor(): Unit {
        let documentation = generate()
        let artifacts = api_render.renderDocumentationFormatsWithOptions(documentation,
            ["html", "markdown"], locale: "zh-CN", agentFull: true)
        for (artifact in artifacts where artifact.path.startsWith("html/packages/")) {
            let html = artifact.content
            @Expect(html.indexOf("id=\"api-group-10-application\"").getOrThrow() <
                html.indexOf("id=\"api-group-20-generated-spi\"").getOrThrow())
            @Expect(html.contains("id=\"api-ungrouped\""))
            @Expect(html.split("id=\"classes\"", removeEmpty: false).size, 2)
            @Expect(html.split("id=\"declarations\"", removeEmpty: false).size, 2)
            @Expect(!html.contains("90-hidden"))
            @Expect(!html.contains("99-fenced"))
            @Expect(!html.contains("<img src=x onerror=alert(1)>"))
            @Expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        }
        for (artifact in artifacts where artifact.path.startsWith("markdown/packages/")) {
            @Expect(artifact.content.contains("\n### 应用 API\n\n"))
            // A group with several visible kinds keeps a kind heading one level
            // below the group and puts each declaration below that heading.
            @Expect(artifact.content.contains("\n#### 类\n\n"))
            @Expect(artifact.content.contains("\n#### 函数\n\n"))
            @Expect(artifact.content.contains("\n##### `declaration_groups.applicationFunction`\n"))
            @Expect(artifact.content.contains("\n### 生成代码 SPI\n\n"))
            @Expect(artifact.content.contains("\n##### `declaration_groups.generatedFunction`\n"))
            // A group with exactly one visible kind omits the redundant kind
            // heading, so its declaration sits directly under the group.
            @Expect(artifact.content.contains("\n### 第一方内部接口\n\n"))
        }
        var sawMarkdownMember = false
        for (artifact in artifacts where artifact.path.startsWith("markdown/symbols/")) {
            if (!artifact.content.contains("`declaration_groups.Application.apply`")) { continue }
            @Expect(artifact.content.contains("\n#### `declaration_groups.Application.apply`\n"))
            @Expect(artifact.content.contains("\n##### 参数\n\n"))
            @Expect(artifact.content.contains("\n##### 返回值\n\n"))
            @Expect(!artifact.content.contains("\n#### 参数\n"))
            @Expect(!artifact.content.contains("\n#### 返回值\n"))
            sawMarkdownMember = true
        }
        @Expect(sawMarkdownMember)
        var sawMembers = false
        for (artifact in artifacts where artifact.path.startsWith("html/symbols/")) {
            if (!artifact.content.contains("data-cjdoc-member-browser")) { continue }
            @Expect(artifact.content.contains("id=\"api-group-10-application\""))
            @Expect(artifact.content.contains("id=\"api-group-20-generated-spi\""))
            sawMembers = true
        }
        @Expect(sawMembers)
        let search = artifactContent(artifacts, "html/search-index.json")
        @Expect(search.contains("declaration_groups.support") || search.contains("declaration_groups.Application.support"))
        @Expect(!search.contains("declaration_groups.Hidden.hidden"))
        let markdown = renderedContent(artifacts)
        @Expect(markdown.contains("生成代码 SPI"))
    }

    @TestCase
    func groupedMarkdownKeepsContainerNavigationAndDeepAuthoredFragments(): Unit {
        let project = i18nTestProject(
            "/**\n * [jump](#details) [natural](#details-1) [duplicate](#details-2) [missing](#absent)\n" +
            " *\n * # Overview\n * ## Details\n * ## Details-1\n * ## Details\n" +
            " * @param left [parameter](#details)\n *\n * ## Details\n" +
            " * @param right Right value.\n * @group shared API\n */",
            extra: "/** Container.\n * @group shared API\n */\npublic class Container {}")
        try {
            let doc = DocumentationEngine().generate(GenerationRequest(project.toString(),
                lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            let artifacts = api_render.renderDocumentationFormatsWithOptions(doc, ["markdown"],
                locale: "zh-CN")
            var packages: Int64 = 0
            for (artifact in artifacts where artifact.path.startsWith("markdown/packages/")) {
                packages++
                let markdown = artifact.content
                @Expect(markdown.contains("##### [`language_fixture.Container`](../symbols/"))
                @Expect(markdown.contains("\n###### Overview\n"))
                @Expect(!markdown.contains("\n####### "))
                let targets = HashSet<String>()
                for (name in ["jump", "natural", "duplicate", "parameter"]) {
                    let destination = markdown.split("[${name}](", 2)[1].split(")", 2)[0]
                    @Expect(destination.startsWith("#"))
                    @Expect(targets.add(destination))
                    @Expect(markdown.split("id=\"${destination[1..]}\"",
                        removeEmpty: false).size, 2)
                }
                @Expect(markdown.contains("[missing](#absent)"))
                @Expect(!markdown.contains("id=\"absent\""))
            }
            @Expect(packages, 1)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func invalidOrDuplicateGroupsDiagnoseWithoutDroppingDeclarations(): Unit {
        for ((line, diagnostic) in [("@group", "CJDOC3130"),
            ("@group missing-title", "CJDOC3137"), ("@group ../bad Bad", "CJDOC3130"),
            ("@group one First\n * @group one First", "CJDOC3130"),
            ("@group one First\n * @group two Second", "CJDOC3130")]) {
            let project = i18nTestProject("/**\n * 中文摘要。\n * " + line + "\n */")
            try {
                let doc = DocumentationEngine().generate(GenerationRequest(project.toString(),
                    lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
                @Expect(doc.declarations.size, 1)
                @Expect(publicHasDiagnostic(doc, diagnostic))
                let html = renderedHtmlContent(api_render.HtmlDocumentationRenderer().render(doc))
                @Expect(!html.contains("data-cjdoc-declaration-group="))
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func sameContainerTitleConflictDiagnosesAndFallsBackToStableId(): Unit {
        let project = i18nTestProject("/**\n * 中文摘要。\n * @group shared First title\n */",
            extra: "/**\n * 另一个入口。\n * @group shared Second title\n */\npublic func another(): Unit {}")
        try {
            let doc = DocumentationEngine().generate(GenerationRequest(project.toString(),
                lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(publicHasDiagnostic(doc, "CJDOC3131"))
            let artifacts = api_render.HtmlDocumentationRenderer().render(doc)
            for (artifact in artifacts where artifact.path.startsWith("html/packages/")) {
                @Expect(artifact.content.contains("id=\"api-group-shared\">shared"))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func groupQualifierIsRejectedAndDoesNotConsumeTheFollowingParameter(): Unit {
        let project = i18nTestProject("/**\n * 中文摘要。\n * @group[lang=en] invalid Invalid\n * @param left 左值。\n * @param right 右值。\n * @return 结果。\n */")
        try {
            let doc = DocumentationEngine().generate(GenerationRequest(project.toString(),
                lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(publicHasDiagnostic(doc, "CJDOC3112"))
            let comment = doc.declarations[0].documentation.getOrThrow()
            for (text in comment.localizedTexts) { @Expect(text.kind != "group") }
            for (tag in comment.tags) { @Expect(tag.name != "group") }
            let selected = api_render.projectDocumentationLanguage(doc, "zh-CN")
            @Expect(selected.declarations[0].parameters[0].documentation, Some("左值。"))
            let html = renderedHtmlContent(api_render.renderDocumentationFormatsWithOptions(doc, ["html"], locale: "zh-CN"))
            @Expect(html.contains("左值。"))
            @Expect(html.contains("右值。"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
}
