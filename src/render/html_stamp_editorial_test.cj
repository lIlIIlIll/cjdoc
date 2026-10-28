package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func stampEditorialFixture(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:stamp-editorial"
    let prefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Astamp-editorial::fixture::"
    let ownerId = prefix + "struct:Stamp#g0()"
    let constructorId = prefix + "Stamp::constructor:init#g0(String)"
    let fieldId = prefix + "Stamp::variable:text#g0()"
    let source = SourceRange("src/stamp.cj", SourcePosition(1, 1, 0), SourcePosition(1, 32, 31))
    let semantic = SemanticInfo("partial", "ast")
    let stringType = TypeRef("primitive", "String", SemanticType("unavailable"))
    let owner = SymbolDoc(ownerId, "struct", "Stamp", "fixture.Stamp", "fixture",
        moduleId, "public", source, "public struct Stamp", semantic)
    let constructor = SymbolDoc(constructorId, "constructor", "init", "fixture.Stamp.init", "fixture",
        moduleId, "public", source, "public init(text: String)", semantic,
        ownerId: Some(ownerId), parameters: [ParameterDoc("text", stringType)],
        documentation: Some(DocComment("raw", "", "", MarkdownNode("document"),
            tags: [DocTag("param", "text", "标签文字。"),
                DocTag("see", "fixture.Stamp", "", translationState: "missing"),
                DocTag("see", "fixture.Stamp.text", "",
                    descriptionMarkdown: Some(MarkdownNode("paragraph",
                        children: [MarkdownNode("text", literal: "Field details")])))])))
    let field = SymbolDoc(fieldId, "variable", "text", "fixture.Stamp.text", "fixture",
        moduleId, "public", source, "public let text: String", semantic,
        ownerId: Some(ownerId), returnType: Some(stringType),
        documentation: Some(DocComment("raw", "标签文字。", "", MarkdownNode("document"))))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("stamp-editorial"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "stamp-editorial", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/stamp.cj"],
            symbolIds: [ownerId, constructorId, fieldId])],
        files: [FileDoc("src/stamp.cj", moduleId, "fixture")],
        declarations: [owner, constructor, field])
}

@Test
class HtmlStampEditorialTest {
    @TestCase
    func constructorAndFieldRetainContractsWithoutInventedReturnSection(): Unit {
        let documentation = stampEditorialFixture()
        let original = encodeDocIr(documentation)
        let owner = documentation.declarations[0]
        var html = ""
        for (artifact in HtmlDocumentationRenderer().render(documentation)) {
            if (artifact.path == "html/${symbolPagePath(owner)}") { html = artifact.content }
        }
        @Expect(!html.isEmpty(), true)
        @Expect(html.contains("public struct Stamp"), true)
        // Syntax highlighting inserts spans between tokens, so assert the
        // authoritative member identities instead of an uninterrupted string.
        @Expect(html.contains("data-member-name=\"init\" data-member-kind=\"constructor\""), true)
        @Expect(html.contains("data-member-name=\"text\" data-member-kind=\"variable\""), true)
        @Expect(html.contains("标签文字。"), true)
        @Expect(html.contains("class=\"parameter-declaration\""), true)
        @Expect(!html.contains(">返回值</h3>"), true)
        @Expect(!html.contains("class=\"return-value\""), true)
        @Expect(html.contains("class=\"declaration-summary member-detail member-static\""), true)
        @Expect(html.contains("data-member-name=\"text\""), true)
        @Expect(encodeDocIr(documentation), original)
    }

    @TestCase
    func seeAlsoUsesUnbulletedSemanticListWithoutEmptyTranslationLabel(): Unit {
        let documentation = stampEditorialFixture()
        let owner = documentation.declarations[0]
        var html = ""
        for (artifact in HtmlDocumentationRenderer().render(documentation)) {
            if (artifact.path == "html/${symbolPagePath(owner)}") { html = artifact.content }
        }
        @Expect(html.contains("class=\"see-also-list\""), true)
        @Expect(html.contains("fixture.Stamp</code>"), true)
        @Expect(html.contains("Field details"), true)
        @Expect(!html.contains("译文为空"), true)
    }

    @TestCase
    func memberGridAndBodyShareOneLogicalInset(): Unit {
        @Expect(HTML_REFERENCE_BROWSER_STYLE.contains("--member-content-inset"), true)
        @Expect(HTML_REFERENCE_BROWSER_STYLE.contains("padding-inline:var(--member-content-inset)"), true)
        @Expect(HTML_REFERENCE_BROWSER_STYLE.contains("min-height:3.35rem"), true)
        @Expect(HTML_REFERENCE_BROWSER_STYLE.contains(".see-also-list"), true)
        @Expect(HTML_SEARCH_SCRIPT.contains("expandableMemberRows"), true)
    }
}
