package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCodecV8Suite5 {
    @TestCase
    func renderersPreserveClosedMarkdownMetadataAndSuppressUnitReturns(): Unit {
        let documentation = codecRendererFixture()
        let markdown = codecRenderedText(MarkdownDocumentationRenderer().render(documentation))
        let html = codecRenderedText(HtmlDocumentationRenderer().render(documentation))
        @Expect(markdown.contains("##### Topic"))
        @Expect(markdown.contains("3) [x] First\n\n4) Second"))
        @Expect(markdown.contains("| :---: |"))
        @Expect(markdown.contains("~~~~cj {.numberLines}"))
        @Expect(html.contains("--doc-topic"))
        @Expect(html.contains("<ol start=\"3\">"))
        @Expect(html.contains("type=\"checkbox\" disabled checked"))
        @Expect(html.contains("<th class=\"align-center\">"))
        @Expect(html.contains("data-language=\"cj\""))
        @Expect(html.contains("data-cjdoc-attributes=\"{.numberLines}\""))
        @Expect(!html.contains("<h3>Returns</h3>"))
        @Expect(!html.contains("MUST-NOT-RENDER"))
    }

    @TestCase
    func rendererLinksResolvedTypesThroughSymbolIdsAndSplitsGenerics(): Unit {
        let intType = TypeRef("primitive", "Int64", SemanticType("resolved",
            canonical: Some("type-links.fixture.Int64"), provider: Some("types")))
        let stringType = TypeRef("primitive", "String", SemanticType("resolved",
            canonical: Some("type-links.fixture.String"), provider: Some("types")))
        let arrayType = TypeRef("generic", "Array<String>", SemanticType("resolved",
            canonical: Some("type-links.fixture.Array"), provider: Some("types")),
            arguments: [stringType])
        let declarations = [
            codecTypeLinkDeclaration("cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-links::fixture::struct:Array#g0()", "struct", "Array", "fixture.Array"),
            codecTypeLinkDeclaration("cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-links::fixture::struct:String#g0()", "struct", "String", "fixture.String"),
            codecTypeLinkDeclaration("cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-links::fixture::struct:Int64#g0()", "struct", "Int64", "fixture.Int64")
        ]
        let documentation = codecTypeLinkDocument(intType,
            parameters: [ParameterDoc("left", intType), ParameterDoc("right", arrayType)],
            declarations: declarations)
        let html = codecRenderedText(HtmlDocumentationRenderer().render(documentation))
        @Expect(html.contains("<dt><code>left</code></dt>"))
        @Expect(html.contains("<dt><code>right</code></dt>"))
        @Expect(html.contains("<a class=\"type-link\" href=\"../symbols/symbol-"))
        @Expect(html.contains(">Int64</a>"))
        @Expect(html.contains(">Array</a>&lt;<a class=\"type-link\" href=\"../symbols/symbol-"))
        @Expect(html.contains(">String</a>&gt;"))
        @Expect(html.contains("<code class=\"return-type\"><a class=\"type-link\""))
        @Expect(!html.contains(">left</a>"))
        @Expect(html.contains(".type-link:hover"))
        @Expect(html.contains("text-decoration:underline"))
    }

    @TestCase
    func rendererKeepsUnavailableAndAmbiguousTypesAsCode(): Unit {
        let externalType = TypeRef("semantic", "ExternalType", SemanticType("resolved",
            canonical: Some("external.DependencyType"), provider: Some("types")))
        let unavailableType = TypeRef("source", "UnknownType", SemanticType("unavailable"))
        let ambiguousType = TypeRef("source", "MaybeType", SemanticType("ambiguous",
            provider: Some("types")))
        let documentation = codecTypeLinkDocument(externalType,
            parameters: [ParameterDoc("unknown", unavailableType), ParameterDoc("maybe", ambiguousType)])
        let html = codecRenderedText(HtmlDocumentationRenderer().render(documentation))
        @Expect(html.contains("<code class=\"parameter-type-code\" title=\"Definition unavailable\">UnknownType</code>"))
        @Expect(html.contains("<code class=\"parameter-type-code\">MaybeType</code>"))
        @Expect(html.contains("<code class=\"return-type\" title=\"Definition unavailable\">ExternalType</code>"))
        @Expect(!html.contains(">UnknownType</a>"))
        @Expect(!html.contains(">MaybeType</a>"))
        @Expect(!html.contains(">ExternalType</a>"))
    }

    @TestCase
    func rendererKeepsReturnTypeAndDescriptionOnOneRow(): Unit {
        let markdown = MarkdownNode("document", children: [MarkdownNode("paragraph",
            children: [MarkdownNode("text", literal: "Overview")])])
        let documentation = Some(DocComment("raw", "summary", "", markdown,
            tags: [DocTag("return", "", "The computed result.")]))
        let returnType = TypeRef("primitive", "Int64", SemanticType("resolved",
            canonical: Some("std.core.Int64"), provider: Some("types")))
        let html = codecRenderedText(HtmlDocumentationRenderer().render(codecTypeDocument(
            returnType, canonicalTypes: true, documentation: documentation)))
        @Expect(html.contains("<h3>Returns</h3><div class=\"return-value\">"))
        @Expect(html.contains("<code class=\"return-type\" title=\"Definition unavailable\">Int64</code><div class=\"return-description\"><p>The computed result.</p>"))
    }
}
