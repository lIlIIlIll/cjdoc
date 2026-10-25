package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let PROJECTION_MODULE = "cjdoc:module:v1:declaration-projection"
private let PROJECTION_CATALOG = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Adeclaration-projection::fixture::class:Catalog#g0()"
private let PROJECTION_ADD = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Adeclaration-projection::fixture::Catalog::function:add#g0(Int64,Int64)"
private let PROJECTION_UNDOCUMENTED =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Adeclaration-projection::fixture::function:opaque#g0()"
private let PROJECTION_EMPTY =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Adeclaration-projection::fixture::function:blank#g0()"

private let PROJECTION_EXAMPLE = "Full example\n\n```cj\n" +
    "let greeting = \"你好\"\n" +
    "let sample = \"\"\"\n" +
    "line `one`\n" +
    "line two\n" +
    "\"\"\"\n" +
    "```\n\nExpected output:\n\n```text\n你好\n```"

private func projectionSource(line: Int64): SourceRange {
    SourceRange("src/catalog.cj", SourcePosition(line, 1, 0), SourcePosition(line, 40, 39))
}

private func projectionAddTags(): Array<DocTag> {
    let tags = ArrayList<DocTag>([
        DocTag("param", "value", "value to append"),
        DocTag("param", "radix", "base used when formatting"),
        DocTag("return", "", "no return value"),
        DocTag("throws", "IllegalArgumentException", "radix is not 10"),
        DocTag("deprecated", "", "use append instead"),
        DocTag("since", "", "0.2.0"),
        DocTag("see", "fixture.Catalog.append", "the collection append helper"),
        DocTag("example", "Appending", PROJECTION_EXAMPLE)
    ])
    for (tag in [
        DocTag("precondition", "value", "value is a valid integer"),
        DocTag("postcondition", "", "the catalogue length grows by one"),
        DocTag("invariant", "entries", "entries are ordered by insertion"),
        DocTag("performance", "", "amortized constant time"),
        DocTag("state", "", "the catalogue must be open"),
        DocTag("concurrency", "", "callers synchronize externally"),
        DocTag("platform", "", "available on every supported platform"),
        DocTag("compatibility", "", "keeps the 0.1.0 calling convention"),
        DocTag("error", "IllegalArgumentException", "radix other than 10 is rejected")
    ]) {
        tags.add(tag)
    }
    tags.toArray()
}

private func projectionDocumentation(): DocumentationSet {
    let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
    let owner = SymbolDoc(PROJECTION_CATALOG, "class", "Catalog", "fixture.Catalog", "fixture",
        PROJECTION_MODULE, "public", projectionSource(1), "public class Catalog",
        SemanticInfo("partial", "ast"))
    let add = SymbolDoc(PROJECTION_ADD, "function", "add", "fixture.Catalog.add", "fixture",
        PROJECTION_MODULE, "public", projectionSource(40),
        "public func add(value: Int64, radix!: Int64 = 10): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(PROJECTION_CATALOG),
        parameters: [
            ParameterDoc("value", intType),
            ParameterDoc("radix", intType, defaultExpression: Some("10"))
        ],
        documentation: Some(DocComment("raw", "Append a value", "",
            MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [
                    MarkdownNode("text", literal: "Append a value to the catalogue.")
                ])
            ]), tags: projectionAddTags())))
    let undocumented = SymbolDoc(PROJECTION_UNDOCUMENTED, "function", "opaque", "fixture.opaque",
        "fixture", PROJECTION_MODULE, "public", projectionSource(70),
        "public func opaque(): Unit", SemanticInfo("partial", "ast"))
    let empty = SymbolDoc(PROJECTION_EMPTY, "function", "blank", "fixture.blank", "fixture",
        PROJECTION_MODULE, "public", projectionSource(80), "public func blank(): Unit",
        SemanticInfo("partial", "ast"), documentation: Some(DocComment("", "", "",
            MarkdownNode("document"))))
    let ids: Array<String> = [PROJECTION_CATALOG, PROJECTION_ADD, PROJECTION_UNDOCUMENTED,
        PROJECTION_EMPTY]
    let declarations: Array<SymbolDoc> = [owner, add, undocumented, empty]
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("declaration-projection"), ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", PROJECTION_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(PROJECTION_MODULE, "declaration-projection", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", PROJECTION_MODULE, sourceFiles: ["src/catalog.cj"],
            symbolIds: ids)],
        files: [FileDoc("src/catalog.cj", PROJECTION_MODULE, "fixture")],
        declarations: declarations)
}

private func projectionDeclaration(documentation: DocumentationSet, id: String): SymbolDoc {
    for (symbol in documentation.declarations) { if (symbol.id == id) { return symbol } }
    throw IllegalArgumentException("missing projection fixture declaration")
}

private func projectionProjection(documentation: DocumentationSet, locale: String):
    DeclarationMarkdownProjection {
    DeclarationMarkdownProjection(documentation, RenderProjection(documentation), locale)
}

@Test
class DeclarationMarkdownProjectionTest {
    @TestCase
    func allNineContractsAreProjectedWithLocalizedLabels(): Unit {
        let documentation = projectionDocumentation()
        let add = projectionDeclaration(documentation, PROJECTION_ADD)
        let english = projectionProjection(documentation, "en")
        let chinese = projectionProjection(documentation, "zh-CN")
        let en = english.renderSelected(add, "agent/symbols/symbol-add.md", [])
        let zh = chinese.renderSelected(add, "agent/symbols/symbol-add.md", [])
        let contracts = ["precondition", "postcondition", "invariant", "performance", "state",
            "concurrency", "platform", "compatibility", "error"]
        for (name in contracts) {
            @Expect(isBehaviorContractTag(name), true)
            @Expect(en.contains("- **${name}**"), true)
        }
        for (label in ["前置条件", "后置条件", "不变量", "性能", "状态", "并发", "平台", "兼容性",
            "错误行为"]) {
            @Expect(zh.contains("- **${label}**"), true)
        }
        @Expect(en.contains("Behavior contracts"), true)
        @Expect(zh.contains("行为契约"), true)
        @Expect(isBehaviorContractTag("return"), false)
        // Subjects and authored prose survive next to the labels.
        @Expect(en.contains("(`value`)"), true)
        @Expect(en.contains("radix other than 10 is rejected"), true)
        @Expect(en.contains("IllegalArgumentException"), true)
    }

    @TestCase
    func signatureAndExamplesKeepTheirExactSourceStructure(): Unit {
        let documentation = projectionDocumentation()
        let add = projectionDeclaration(documentation, PROJECTION_ADD)
        let markdown = projectionProjection(documentation, "en")
            .renderSelected(add, "agent/symbols/symbol-add.md", [])
        @Expect(markdown.contains(
            "```cangjie\npublic func add(value: Int64, radix!: Int64 = 10): Unit\n```"))
        @Expect(markdown.contains("`radix`"), true)
        @Expect(markdown.contains("= `10`"), true)
        @Expect(markdown.contains("`Int64`"), true)
        // Multiline, fenced and Unicode example content is byte-preserving.
        @Expect(markdown.contains(PROJECTION_EXAMPLE), true)
        @Expect(markdown.contains("let greeting = \"你好\""), true)
        @Expect(markdown.contains("line `one`"), true)
        @Expect(markdown.contains("```text\n你好\n```"), true)
        // No one-lining, truncation markers or fabricated prose.
        @Expect(!markdown.contains("..."), true)
        @Expect(!markdown.contains("\\n"), true)
    }


    @TestCase
    func selectedSectionsRenderOnlyRequestedChapters(): Unit {
        let documentation = projectionDocumentation()
        let add = projectionDeclaration(documentation, PROJECTION_ADD)
        let markdown = projectionProjection(documentation, "en")
        let selected = markdown.renderSelected(add, "agent/symbols/symbol-add.md",
            ["signature", "contracts", "source"])
        @Expect(selected.contains("## Signature"), true)
        @Expect(selected.contains("## Behavior contracts"), true)
        @Expect(selected.contains("## Source"), true)
        @Expect(!selected.contains("## Parameters"), true)
        @Expect(!selected.contains("## Examples"), true)
        @Expect(!selected.contains("## Returns"), true)
        @Expect(!selected.contains("## Relationships"), true)
        @Expect(!selected.contains("Append a value to the catalogue."), true)
        let examples = markdown.renderSelected(add, "agent/symbols/symbol-add.md", ["examples"])
        @Expect(examples.contains("## Examples"), true)
        @Expect(examples.contains(PROJECTION_EXAMPLE), true)
        @Expect(!examples.contains("## Signature"), true)
        // The complete reference stays the default.
        let complete = markdown.renderSelected(add, "agent/symbols/symbol-add.md", [])
        @Expect(complete.contains("## Signature"), true)
        @Expect(complete.contains("## Parameters"), true)
        @Expect(complete.contains("## Examples"), true)
        @Expect(complete.contains("## Relationships"), true)
    }

    @TestCase
    func referencesStayWithinTheDeployedDocumentRoot(): Unit {
        let documentation = projectionDocumentation()
        let add = projectionDeclaration(documentation, PROJECTION_ADD)
        let markdown = projectionProjection(documentation, "en")
        let nested = markdown.renderSelected(add, "agent/symbols/symbol-add.md", [])
        @Expect(nested.contains("../../symbols/"), true)
        @Expect(!nested.contains("../../markdown/"), true)
        let aggregate = markdown.renderSelected(add, "llms-full.txt", [])
        @Expect(aggregate.contains("](symbols/"), true)
        @Expect(!aggregate.contains("../html/"), true)
        // Resolved type navigation also lands on the canonical HTML page.
        let target = projectionDeclaration(documentation, PROJECTION_CATALOG)
        let navigation = TypeNavigation("resolved", "exact", "local declaration",
            symbolKey: target.id, url: symbolPagePath(target))
        let typed = TypeRef("named", "Catalog", SemanticType("unavailable"),
            navigation: Some(navigation))
        let owner = SymbolDoc(PROJECTION_ADD, "function", "add", "fixture.Catalog.add", "fixture",
            PROJECTION_MODULE, "public", projectionSource(40), "public func add(): Unit",
            SemanticInfo("partial", "ast"), returnType: Some(typed),
            documentation: Some(DocComment("", "", "", MarkdownNode("document"))))
        let typedText = projectionProjection(documentation, "en").renderSelected(owner,
            "agent/symbols/symbol-add.md", [])
        @Expect(typedText.contains("](../../symbols/symbol-"), true)
    }
}
