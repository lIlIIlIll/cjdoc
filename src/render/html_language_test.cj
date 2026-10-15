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
