package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let MD_NAV_EN_ROUTE = "concepts/guides/读 (en).html"
private let MD_NAV_EN_HREF = "concepts/guides/%E8%AF%BB%20%28en%29.md"
private let MD_NAV_EN_TITLE = "English [safe]\n\n![x](javascript:alert(1)) <b>"
private let MD_NAV_HIDDEN_ID = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Amd-nav::fixture::function:hidden#g0()"

private func markdownNavigationPage(id: String, route: String, title: String,
    language: ?String, targets!: Array<String> = []): DocumentationPage {
    DocumentationPage(id, "docs/" + id + language.getOrDefault({ => "unknown" }) + ".md",
        route, title, "guide", title,
        MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("text", literal: title)])]),
        language: language, defaultLanguage: Some("zh-CN"), targetSymbolIds: targets)
}

private func markdownNavigationDocumentation(localized!: Bool = true): DocumentationSet {
    let moduleId = "cjdoc:module:v1:md-nav"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let hidden = SymbolDoc(MD_NAV_HIDDEN_ID, "function", "hidden", "fixture.hidden", "fixture",
        moduleId, "private", source, "private func hidden(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment("Hidden API secret", "Hidden API secret", "",
            MarkdownNode("document", children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Hidden API secret")])]))))
    let pages = if (localized) { [
        markdownNavigationPage("start", "concepts/guides/zh-start.html", "Chinese selected", Some("zh-CN")),
        markdownNavigationPage("start", MD_NAV_EN_ROUTE, MD_NAV_EN_TITLE, Some("en")),
        markdownNavigationPage("fallback", "concepts/fallback.html", "Original fallback", Some("zh-CN")),
        markdownNavigationPage("standalone", "concepts/standalone.html", "Standalone overview", None,
            targets: [MD_NAV_HIDDEN_ID]),
        markdownNavigationPage("only-en", "concepts/only-en.html", "English only", Some("en"))
    ] } else { [markdownNavigationPage("standalone", "concepts/standalone.html", "Standalone overview",
        None, targets: [MD_NAV_HIDDEN_ID])] }
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("md-navigation"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "md-nav", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [MD_NAV_HIDDEN_ID])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [hidden], pages: pages,
        languageOptions: if (localized) {
            Some(DocumentationLanguageOptions("zh-CN", languages: ["en", "zh-CN"]))
        } else { None })
    decodeDocIr(encodeDocIr(original))
}

private func markdownNavigationContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing captured Markdown navigation artifact")
}

private func expectMarkdownNavigationTarget(artifacts: Array<RenderArtifact>, prefix: String,
    href: String, actualPath: String): Unit {
    let index = markdownNavigationContent(artifacts, prefix + "index.md")
    @Expect(index.split("](" + href + ")").size, 2)
    @Expect(!markdownNavigationContent(artifacts, prefix + actualPath).isEmpty())
}

@Test
class DocumentationPageMarkdownNavigationTest {
    @TestCase
    func sourceFreeSiteLinksSelectedFallbackAndStandalonePagesSafely(): Unit {
        let documentation = markdownNavigationDocumentation()
        let authorIr = encodeDocIr(documentation)
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")
        let index = markdownNavigationContent(values, "markdown/index.md")
        @Expect(index.contains("## Conceptual documentation"))
        expectMarkdownNavigationTarget(values, "markdown/", MD_NAV_EN_HREF,
            MD_NAV_EN_ROUTE.removeSuffix(".html") + ".md")
        expectMarkdownNavigationTarget(values, "markdown/", "concepts/fallback.md", "concepts/fallback.md")
        expectMarkdownNavigationTarget(values, "markdown/", "concepts/standalone.md", "concepts/standalone.md")
        expectMarkdownNavigationTarget(values, "markdown/", "concepts/only-en.md", "concepts/only-en.md")
        @Expect(!index.contains("zh-start.md"))
        @Expect(!index.contains("Chinese selected"))
        @Expect(!index.contains("Hidden API secret"))
        @Expect(!index.contains("![x](javascript:"))
        @Expect(!index.contains("<b>"))
        var safeLabel = false
        for (line in index.split("\n")) {
            if (line.endsWith("](" + MD_NAV_EN_HREF + ")")) {
                safeLabel = line.contains("English \\[safe\\]") && line.contains("\\!\\[x\\]")
            }
        }
        @Expect(safeLabel)
        @Expect(markdownNavigationContent(values, "markdown/concepts/fallback.md").contains("Content language: zh-CN"))
        @Expect(encodeDocIr(documentation), authorIr)
    }

    @TestCase
    func allLanguagesKeepNavigationInsideEachReadingRoot(): Unit {
        let documentation = markdownNavigationDocumentation()
        let authorIr = encodeDocIr(documentation)
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], allLanguages: true)
        expectMarkdownNavigationTarget(values, "markdown/en/", MD_NAV_EN_HREF,
            MD_NAV_EN_ROUTE.removeSuffix(".html") + ".md")
        expectMarkdownNavigationTarget(values, "markdown/zh-CN/", "concepts/guides/zh-start.md", "concepts/guides/zh-start.md")
        for (language in ["en", "zh-CN"]) {
            let prefix = "markdown/" + language + "/"
            expectMarkdownNavigationTarget(values, prefix, "concepts/fallback.md", "concepts/fallback.md")
            expectMarkdownNavigationTarget(values, prefix, "concepts/standalone.md", "concepts/standalone.md")
            let index = markdownNavigationContent(values, prefix + "index.md")
            @Expect(!index.contains("../en/"))
            @Expect(!index.contains("../zh-CN/"))
        }
        let chinese = markdownNavigationContent(values, "markdown/zh-CN/index.md")
        @Expect(chinese.contains("## 概念文档"))
        @Expect(!chinese.contains(MD_NAV_EN_HREF))
        @Expect(!chinese.contains("only-en.md"))
        @Expect(encodeDocIr(documentation), authorIr)
    }

    @TestCase
    func unlocalizedCapturedPagesStayReachableWhileSingleMarkdownStaysUnchanged(): Unit {
        let documentation = markdownNavigationDocumentation(localized: false)
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")
        expectMarkdownNavigationTarget(values, "markdown/", "concepts/standalone.md", "concepts/standalone.md")
        for (single in [MarkdownDocumentationRenderer().render(documentation),
            renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en", markdownLayout: "single")]) {
            @Expect(single.size, 1)
            @Expect(single[0].path, "markdown/docs.md")
            @Expect(!single[0].content.contains("Conceptual documentation"))
            @Expect(!single[0].content.contains("concepts/standalone.md"))
        }
    }
}
