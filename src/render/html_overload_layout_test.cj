package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func overloadLayoutDocumentation(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:overload-layout"
    let ownerId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::class:Catalog#g0()"
    let intId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:add#g0(Int64,Int64)"
    let stringId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:add#g0(String)"
    let arrayId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:addAll#g0(Array)"
    let source = SourceRange("src/catalog.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, 42, 41))
    let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
    let stringType = TypeRef("primitive", "String", SemanticType("unavailable"))
    let arrayType = TypeRef("generic", "Array<String>", SemanticType("unavailable"),
        arguments: [stringType])
    let owner = SymbolDoc(ownerId, "class", "Catalog", "fixture.Catalog", "fixture",
        moduleId, "public", source, "public class Catalog", SemanticInfo("partial", "ast"))
    let intAdd = SymbolDoc(intId, "function", "add", "fixture.Catalog.add", "fixture",
        moduleId, "public", source, "public func add(value: Int64, radix!: Int64 = 10): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [
            ParameterDoc("value", intType, documentation: Some("Integer input")),
            ParameterDoc("radix", intType, documentation: Some("Only base ten is supported"),
                defaultExpression: Some("10"))
        ], documentation: Some(DocComment("raw", "Append an integer", "",
            MarkdownNode("document"), tags: [
                DocTag("throws", "IllegalArgumentException", "radix must equal 10"),
                DocTag("postcondition", "", "new entry matches value.toString()")
            ])))
    let stringAdd = SymbolDoc(stringId, "function", "add", "fixture.Catalog.add", "fixture",
        moduleId, "public", source, "public func add(value: String): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [ParameterDoc("value", stringType, documentation: Some("Text input"))],
        documentation: Some(DocComment("raw", "Append a string", "",
            MarkdownNode("document"))))
    let addAll = SymbolDoc(arrayId, "function", "addAll", "fixture.Catalog.addAll", "fixture",
        moduleId, "public", source, "public func addAll(entries: Array<String>): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [ParameterDoc("entries", arrayType)],
        documentation: Some(DocComment("raw", "Append multiple strings", "",
            MarkdownNode("document"))))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("overload-layout"), ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "overload-layout", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId,
            sourceFiles: ["src/catalog.cj"],
            symbolIds: [ownerId, intId, stringId, arrayId])],
        files: [FileDoc("src/catalog.cj", moduleId, "fixture")],
        declarations: [owner, intAdd, stringAdd, addAll])
}

@Test
class HtmlOverloadContractLayoutTest {
    @TestCase
    func overloadBoundaryDoesNotAbsorbOtherMemberNames(): Unit {
        let documentation = overloadLayoutDocumentation()
        let owner = documentation.declarations[0]
        let addAll = documentation.declarations[3]
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        var html = ""
        for (artifact in artifacts) {
            if (artifact.path == "html/${symbolPagePath(owner)}") { html = artifact.content }
        }
        @Expect(!html.isEmpty(), true)
        @Expect(html.split("data-cjdoc-overload-group").size, 2)
        @Expect(html.contains("data-overload-total=\"2\""), true)
        @Expect(html.contains("aria-labelledby=\"overloads-"), true)
        @Expect(html.split("data-member-name=\"add\"").size, 3)
        @Expect(html.contains("</div>\n<details class=\"declaration-summary member-detail\" id=\"${symbolAnchor(addAll)}\""), true)
        @Expect(html.contains("data-member-name=\"addAll\""), true)
        @Expect(html.contains("class=\"parameter-declaration\""), true)
        @Expect(html.contains("<span class=\"parameter-default\">= <code>10</code></span>"), true)
        @Expect(html.contains("Only base ten is supported"), true)
        @Expect(html.contains("<dl class=\"throws-list\""), true)
        @Expect(html.contains("class=\"throws-row\""), true)
        @Expect(html.contains("radix must equal 10"), true)
        @Expect(html.contains("behavior-contract-single"), true)
        @Expect(html.contains(">Postcondition</h3>"), true)
        @Expect(html.contains("new entry matches value.toString()"), true)
        @Expect(!html.contains(">Behavior contracts</h3>"), true)
        @Expect(!html.contains("class=\"badge reference-state\""), true)
    }

    @TestCase
    func filterKeepsOverloadCountInSyncWithoutExtraToggle(): Unit {
        let script = HTML_SEARCH_SCRIPT
        @Expect(script.contains("data-cjdoc-overload-group"), true)
        @Expect(script.contains("matches === total"), true)
        @Expect(script.contains("group.hidden = matches === 0"), true)
        @Expect(script.contains("matches + \" / \" + total"), true)
        // Other navigation groups legitimately assign group.open. Only the
        // overload filtering block must avoid adding another accordion layer.
        let start = script.indexOf("for (const group of overloadGroups) {").getOrThrow()
        let end = script.indexOf("for (const group of memberGroups) {").getOrThrow()
        @Expect(start < end, true)
        let overloadFilter = script[start..end]
        @Expect(!overloadFilter.contains("group.open ="), true)
    }
}
