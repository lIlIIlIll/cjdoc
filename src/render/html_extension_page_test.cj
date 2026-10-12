package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func extensionPageSource(line: Int64): SourceRange {
    SourceRange("src/entry.cj", SourcePosition(line, 1, line * 16),
        SourcePosition(line, 40, line * 16 + 39))
}

private func extensionPageFixture(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:extension-page"
    let targetId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::class:Entry#g1()"
    let textId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::extend:Entry<String>#g0()"
    let otherId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::extend:Entry<Int64>#g0()"
    let emptyId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::extend:Entry<Bool>#g0()"
    let byteId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::Entry<String>::function:byteLength#g0()"
    let otherMemberId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::Entry<Int64>::function:otherOnly#g0()"
    let hiddenId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aextension-page::fixture::Entry<Bool>::function:hidden#g0()"
    let target = SymbolDoc(targetId, "class", "Entry", "fixture.Entry", "fixture",
        moduleId, "public", extensionPageSource(1), "public class Entry<T>",
        SemanticInfo("partial", "ast"), symbolRelationships: [
            SymbolRelationship("extendedBy", "Entry < String >", "resolved",
                targetSymbolId: Some(textId))
        ])
    let text = SymbolDoc(textId, "extend", "Entry < String >",
        "fixture.Entry < String >", "fixture", moduleId, "public",
        extensionPageSource(5), "extend Entry<String>", SemanticInfo("partial", "ast"),
        typeRelationships: [
            TypeRelationship("extensionTarget", TypeRef("source",
                "Entry < String >", SemanticType("partial")))
        ], symbolRelationships: [
            SymbolRelationship("extensionTarget", "Entry < String >", "resolved",
                targetSymbolId: Some(targetId))
        ])
    let other = SymbolDoc(otherId, "extend", "Entry < Int64 >",
        "fixture.Entry < Int64 >", "fixture", moduleId, "public",
        extensionPageSource(8), "extend Entry<Int64>", SemanticInfo("partial", "ast"),
        symbolRelationships: [
            SymbolRelationship("extensionTarget", "Entry < Int64 >", "resolved",
                targetSymbolId: Some(targetId))
        ])
    let empty = SymbolDoc(emptyId, "extend", "Entry < Bool >",
        "fixture.Entry < Bool >", "fixture", moduleId, "public",
        extensionPageSource(11), "extend Entry<Bool>", SemanticInfo("partial", "ast"))
    let byteLength = SymbolDoc(byteId, "function", "byteLength",
        "fixture.Entry < String >.byteLength", "fixture", moduleId,
        "public", extensionPageSource(6), "public func byteLength(): Int64",
        SemanticInfo("partial", "ast"), ownerId: Some(textId),
        returnType: Some(TypeRef("primitive", "Int64", SemanticType("unavailable"))),
        documentation: Some(DocComment("raw", "", "", MarkdownNode("document"),
            tags: [DocTag("return", "", "UTF-8 byte count")])))
    let otherOnly = SymbolDoc(otherMemberId, "function", "otherOnly",
        "fixture.Entry < Int64 >.otherOnly", "fixture", moduleId,
        "public", extensionPageSource(9), "public func otherOnly(): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(otherId))
    let hidden = SymbolDoc(hiddenId, "function", "hidden",
        "fixture.Entry < Bool >.hidden", "fixture", moduleId,
        "private", extensionPageSource(12), "private func hidden(): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(emptyId))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("extension-page"), ConfigurationSnapshot(audience: "external",
            lintProfile: "off"),
        modules: [ModuleDoc(moduleId, "extension-page", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId,
            sourceFiles: ["src/entry.cj"],
            symbolIds: [targetId, textId, otherId, emptyId, byteId, otherMemberId, hiddenId])],
        files: [FileDoc("src/entry.cj", moduleId, "fixture")],
        declarations: [target, text, other, empty, byteLength, otherOnly, hidden])
}

private func renderedExtensionPage(documentation: DocumentationSet, symbol: SymbolDoc,
    locale: String): String {
    let projection = RenderProjection(documentation)
    renderSymbolPage(documentation, projection, indexSymbols(documentation), symbol,
        HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection), locale: locale)
}

@Test
class HtmlExtensionPageTest {
    @TestCase
    func extensionPageContainsExactlyItsVisibleMembersAndCompleteContracts(): Unit {
        let documentation = extensionPageFixture()
        let extension = documentation.declarations[1]
        let target = documentation.declarations[0]
        let member = documentation.declarations[4]
        @Expect(member.ownerId, Some(extension.id))
        for (locale in ["en", "zh-CN"]) {
            let html = renderedExtensionPage(documentation, extension, locale)
            @Expect(html.contains("data-cjdoc-member-browser"), true)
            @Expect(html.split("data-member-name=\"byteLength\"").size, 2)
            @Expect(html.contains("public</span> <span class=\"code-keyword\">func"), true)
            @Expect(html.contains("UTF-8 byte count"), true)
            @Expect(html.contains("data-member-name=\"otherOnly\""), false)
            @Expect(html.contains("data-member-name=\"hidden\""), false)
            @Expect(html.contains("data-member-name=\"value\""), false)
            @Expect(html.contains("href=\"../" + symbolPagePath(member) + "\""), true)
            @Expect(html.contains("data-cjdoc-copy-link=\"../" +
                symbolReadablePagePath(extension) + "\""), true)
            @Expect(html.contains("href=\"../" + symbolPagePath(target) + "\""), true)
            @Expect(html.contains("Entry &lt; String &gt;"), false)
            @Expect(html.contains("Entry&lt;String&gt;"), true)
            @Expect(html.contains("class=\"type-link relation-target\""), true)
        }
    }

    @TestCase
    func extensionPageAndMemberBreadcrumbsIdentifyTheExtension(): Unit {
        let documentation = extensionPageFixture()
        let projection = RenderProjection(documentation)
        let index = indexSymbols(documentation)
        let links = HtmlTypeLinkIndex(documentation, projection)
        let extension = documentation.declarations[1]
        let member = documentation.declarations[4]
        for (locale in ["en", "zh-CN"]) {
            let title = if (locale == "zh-CN") {
                "扩展 Entry&lt;String&gt;"
            } else { "Extension Entry&lt;String&gt;" }
            let extHtml = renderSymbolPage(documentation, projection, index, extension,
                HashMap<String, String>(), links, locale: locale)
            let memberHtml = renderSymbolPage(documentation, projection, index, member,
                HashMap<String, String>(), links, locale: locale)
            @Expect(extHtml.contains("<code>" + title + "</code></h1>"), true)
            @Expect(extHtml.contains("<li aria-current=\"page\"><code>" +
                title + "</code>"), true)
            @Expect(memberHtml.contains("href=\"../" + symbolPagePath(extension) +
                "\"><code>" + title + "</code></a>"), true)
            @Expect(memberHtml.contains("href=\"../" + symbolPagePath(extension) + "\""), true)
        }
    }

    @TestCase
    func emptyExtensionAndHiddenMemberDoNotLeak(): Unit {
        let documentation = extensionPageFixture()
        let empty = documentation.declarations[3]
        let html = renderedExtensionPage(documentation, empty, "en")
        @Expect(html.contains("data-member-name=\"hidden\""), false)
        @Expect(html.contains("No visible members"), true)
        @Expect(html.contains("data-cjdoc-member-browser"), false)
    }

    @TestCase
    func genericDisplayIsOnlyPresentationAndPreservesConstraints(): Unit {
        let documentation = extensionPageFixture()
        let original = documentation.declarations[1]
        @Expect(original.name, "Entry < String >")
        @Expect(original.headerSpelling, "extend Entry<String>")
        @Expect(genericTypeDisplaySpelling("Entry < Map < String, Array < Int64 > > >"),
            "Entry<Map<String, Array<Int64>>>")
        @Expect(genericTypeDisplaySpelling("Entry < T > where T <: Comparable<T>"),
            "Entry < T > where T <: Comparable<T>")
        let raw = "<script>"
        @Expect(escapeHtml(raw), "&lt;script&gt;")
    }
}
