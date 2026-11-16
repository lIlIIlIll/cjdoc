package cjdoc.render

import cjdoc.model.*
import markdown.{MarkdownEngine, MarkdownProfile, NodeKind, NodeRef}
import std.unittest.*
import std.unittest.testmacro.*

private func independentLanguageDocumentation(language: String): DocumentationSet {
    let moduleId = "cjdoc:module:v1:language-marker"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Alanguage-marker::fixture::function:read#g0()"
    let body = "Session has closed."
    let tree = MarkdownNode("document", children: [MarkdownNode("paragraph",
        children: [MarkdownNode("text", literal: body)])])
    let comment = DocComment("", "", "", MarkdownNode("document"),
        defaultLanguage: Some(language), localizedTexts: [DocumentationText("", "throws",
            "IllegalStateException", Some(language), body, tree, state: "unpaired")])
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let symbol = SymbolDoc(symbolId, "function", "read", "fixture.read", "fixture", moduleId,
        "public", source, "public func read(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(comment))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial", ProjectInfo("language-marker"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "language-marker", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol],
        languageOptions: Some(DocumentationLanguageOptions(language, languages: ["zh-CN", "en"])))
}

private func languageMarkerContent(artifacts: Array<RenderArtifact>, prefix: String): String {
    for (artifact in artifacts where artifact.path.startsWith(prefix)) { return artifact.content }
    throw IllegalArgumentException("missing language marker artifact")
}

private func appendLanguageMarkdownText(out: StringBuilder, node: NodeRef): Unit {
    match (node.kind) {
        case NodeKind.Text => out.append(node.asText().getOrThrow().value)
        case _ => ()
    }
    let children = node.children()
    for (index in 0..children.size) { appendLanguageMarkdownText(out, children[index]) }
}


@Test
class HtmlContentLanguageTest {
    @TestCase
    func independentCurrentLanguageTextHasNoVisiblePairingDiagnostic(): Unit {
        for (language in ["zh-CN", "en"]) {
            let document = independentLanguageDocumentation(language)
            let original = encodeDocIr(document)
            let artifacts = renderDocumentationFormatsWithOptions(document, ["html", "markdown"], locale: language)
            let html = languageMarkerContent(artifacts, "html/symbols/symbol-")
            let markdown = languageMarkerContent(artifacts, "markdown/packages/")
            @Expect(html.contains("Session has closed."))
            @Expect(html.contains("data-translation-state=\"unpaired\" hidden lang=\"" + language + "\"></span>"))
            @Expect(!html.contains("独立条目"))
            @Expect(!html.contains("Independent entry"))
            let engine = MarkdownEngine.builder().profile(MarkdownProfile.gfmModernV1()).build()
            let parsed = engine.parse(markdown)
            let markdownText = StringBuilder()
            appendLanguageMarkdownText(markdownText, parsed.document.root())
            let visibleMarkdown = markdownText.toString()
            @Expect(visibleMarkdown.contains("Session has closed."))
            @Expect(!visibleMarkdown.contains("__."))
            @Expect(encodeDocIr(document), original)
        }
    }

    @TestCase
    func foreignIndependentTextStillIdentifiesTheOriginalLanguage(): Unit {
        let document = independentLanguageDocumentation("zh-CN")
        let artifacts = renderDocumentationFormatsWithOptions(document, ["html", "markdown"], locale: "en")
        let html = languageMarkerContent(artifacts, "html/symbols/symbol-")
        @Expect(html.contains("Session has closed."))
        @Expect(html.contains("data-translation-state=\"unpaired\" lang=\"zh-CN\""))
        @Expect(!html.contains("data-translation-state=\"unpaired\" hidden"))
        @Expect(html.contains("Original text: zh-CN"))
    }
}

@Test
class HtmlLocalizedDescriptionNoticeTest {
    @TestCase
    func translatedParameterAndReturnStatesKeepTheirExistingNoticesAndFallbackText(): Unit {
        let moduleId = "cjdoc:module:v1:language-descriptions"
        let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Alanguage-descriptions::fixture::function:run#g0()"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
        let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
        let comment = DocComment("", "Localized description states", "",
            MarkdownNode("document", children: [MarkdownNode("paragraph",
                children: [MarkdownNode("text", literal: "Localized description states")])]),
            tags: [
                DocTag("param", "missing", "", contentLanguage: Some("zh-CN"),
                    translationState: "missing"),
                DocTag("param", "empty", "", contentLanguage: Some("zh-CN"),
                    translationState: "empty"),
                DocTag("param", "conflict", "Conflicting parameter text",
                    contentLanguage: Some("zh-CN"), translationState: "conflict"),
                DocTag("param", "fallback", "Fallback parameter original text",
                    contentLanguage: Some("zh-CN"), translationState: "fallback"),
                DocTag("return", "", "Return source fallback", contentLanguage: Some("zh-CN"),
                    translationState: "empty-fallback")
            ])
        let symbol = SymbolDoc(symbolId, "function", "run", "fixture.run", "fixture", moduleId,
            "public", source,
            "public func run(missing: Int64, empty: Int64, conflict: Int64, fallback: Int64): Int64",
            SemanticInfo("partial", "ast"),
            parameters: [
                ParameterDoc("missing", intType),
                ParameterDoc("empty", intType),
                ParameterDoc("conflict", intType),
                ParameterDoc("fallback", intType)
            ],
            returnType: Some(intType), documentation: Some(comment))
        let document = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("language-descriptions"), ConfigurationSnapshot(lintProfile: "off"),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
                SemanticCapabilities(false, false, false, false, false))],
            modules: [ModuleDoc(moduleId, "language-descriptions", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
                symbolIds: [symbolId])],
            files: [FileDoc("src/api.cj", moduleId, "fixture")],
            declarations: [symbol])
        let html = languageMarkerContent(HtmlDocumentationRenderer().render(document),
            "html/symbols/symbol-")
        @Expect(html.contains("data-translation-state=\"missing\""))
        @Expect(html.contains("Translation missing"))
        @Expect(html.contains("data-translation-state=\"empty\""))
        @Expect(html.contains("Translation is empty"))
        @Expect(html.contains("data-translation-state=\"conflict\""))
        @Expect(html.contains("Translation conflict"))
        @Expect(html.contains("Conflicting parameter text"))
        @Expect(html.contains("data-translation-state=\"fallback\""))
        @Expect(html.contains("Translation missing. Original text: zh-CN"))
        @Expect(html.contains("Fallback parameter original text"))
        @Expect(html.contains("data-translation-state=\"empty-fallback\""))
        @Expect(html.contains("Empty translation; original text: zh-CN"))
        @Expect(html.contains("Return source fallback"))
        @Expect(!html.contains("data-documentation-state="))
        @Expect(!html.contains("No description has been provided."))
        @Expect(!html.contains("Description is empty."))
    }
}

@Test
class HtmlLanguageHomeFallbackTest {
    @TestCase
    func utilityPagePublishesVisibleLanguageHomeFallback(): Unit {
        let documentation = independentLanguageDocumentation("en")
        let route = "utility/report.html"
        let source = "<html lang=\"en\"><body><span class=\"language-label\" lang=\"en\">English</span>" +
            "<main id=\"cjdoc-main\">Utility report</main></body></html>"
        let values = [RenderArtifact("html/en/" + route, "text/html", source)]
        let artifacts = finalizeDocumentationLanguageArtifacts(documentation, values)
        let html = languageMarkerContent(artifacts, "html/en/" + route)
        let fallbackHref = pageRootPrefix(route) + "../zh-CN/index.html"
        let notice = "This page is unavailable; open the language home"
        // The placeholder span is replaced by the toggle; the toggle keeps the
        // language routes, switch state and visible fallback notice contract.
        @Expect(!html.contains("class=\"language-label\""))
        @Expect(html.contains("<details class=\"cj-lang-toggle\">"))
        @Expect(html.contains("class=\"cj-lang-toggle__summary\""))
        @Expect(html.contains("class=\"cj-lang-toggle__current\">English</span>"))
        @Expect(html.contains("href=\"" + fallbackHref + "\""))
        @Expect(html.contains("hreflang=\"zh-CN\""))
        @Expect(html.contains("data-language-routes=\""))
        @Expect(html.contains("data-switch-state=\"language-home\""))
        @Expect(html.contains("data-position-state=\"language-home\""))
        @Expect(html.contains("title=\"" + notice + "\""))
        @Expect(html.contains("<span class=\"cj-lang-toggle__notice\" lang=\"en\">" + notice + "</span>"))
        @Expect(!html.contains("class=\"cj-lang-toggle__notice\" lang=\"en\" hidden>" + notice))
    }
}
