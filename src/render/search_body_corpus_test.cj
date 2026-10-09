package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func searchCorpusSource(line: Int64): SourceRange {
    SourceRange("src/api.cj", SourcePosition(line, 1, line * 10),
        SourcePosition(line, 8, line * 10 + 7))
}

private func searchCorpusDocumentation(declarations: Array<SymbolDoc>): DocumentationSet {
    let moduleId = "cjdoc:module:v1:search-corpus"
    let symbolIds = ArrayList<String>()
    for (symbol in declarations) { symbolIds.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("search-corpus"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "search-corpus", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: symbolIds.toArray())],
        files: [FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: declarations)
}

@Test
class SearchBodyCorpusTest {
    private func corpusIndex(): String {
        let moduleId = "cjdoc:module:v1:search-corpus"
        let contract = DocComment("raw", "", "",
            MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [
                    MarkdownNode("text", literal: "实例不提供内部同步，调用方必须在并发修改与读取之间安排同步。")])]))
        let readReturn = DocComment("raw", "", "",
            MarkdownNode("document", children: []),
            tags: [DocTag("return", "", "下一行，读取结束时返回 None。")])
        let summaryOnly = DocComment("raw", "short summary", "",
            MarkdownNode("document", children: []))
        let catalog = SymbolDoc("fixture::class:TextCatalog#g0()", "class", "TextCatalog",
            "fixture.TextCatalog", "fixture", moduleId, "public", searchCorpusSource(1),
            "public class TextCatalog", SemanticInfo("partial", "ast"),
            documentation: Some(contract))
        let read = SymbolDoc("fixture::function:read#g0()", "function", "read",
            "fixture.TextReader.read", "fixture", moduleId, "public", searchCorpusSource(2),
            "public func read(): ?String", SemanticInfo("partial", "ast"),
            documentation: Some(readReturn))
        let go = SymbolDoc("fixture::function:go#g0()", "function", "go", "fixture.go",
            "fixture", moduleId, "public", searchCorpusSource(3), "public func go(): Unit",
            SemanticInfo("partial", "ast"), documentation: Some(summaryOnly))
        let documentation = searchCorpusDocumentation([catalog, read, go])
        renderSearchIndex(documentation, RenderProjection(documentation))
    }

    @TestCase
    func descriptionProseEntersTheBodyCorpus(): Unit {
        // The contract sentence is unreachable through name/summary before this field existed.
        @Expect(corpusIndex().contains(
            "\"body\": \"实例不提供内部同步，调用方必须在并发修改与读取之间安排同步。\""), true)
    }

    @TestCase
    func contractTagDescriptionsEnterTheBodyCorpus(): Unit {
        let index = corpusIndex()
        @Expect(index.contains("读取结束时返回 None"), true)
        @Expect(index.contains("\"body\": \" 下一行，读取结束时返回 None。\""), true)
    }

    @TestCase
    func entriesWithoutProseCarryAnEmptyBody(): Unit {
        @Expect(corpusIndex().contains(
            "\"summary\": \"short summary\", \"body\": \"\""), true)
    }

    @TestCase
    func bodyTextIsBoundedPerEntry(): Unit {
        let moduleId = "cjdoc:module:v1:search-corpus"
        let builder = StringBuilder()
        var index: Int64 = 0
        while (index < SEARCH_BODY_EXCERPT_LIMIT * 2) { builder.append("字"); index++ }
        builder.append("末尾标记")
        let verbose = SymbolDoc("fixture::class:Verbose#g0()", "class", "Verbose",
            "fixture.Verbose", "fixture", moduleId, "public", searchCorpusSource(4),
            "public class Verbose", SemanticInfo("partial", "ast"),
            documentation: Some(DocComment("raw", "", "",
                MarkdownNode("document", children: [
                    MarkdownNode("paragraph", children: [
                        MarkdownNode("text", literal: builder.toString())])]))))
        let documentation = searchCorpusDocumentation([verbose])
        let rendered = renderSearchIndex(documentation, RenderProjection(documentation))
        // The overflow marker proves truncation; the tail never reaches the payload.
        @Expect(rendered.contains("…"), true)
        @Expect(rendered.contains("末尾标记"), false)
    }
}
