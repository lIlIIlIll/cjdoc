package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// Primary reader pages; machine representations are checked separately.
private func suite5ReaderText(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        if (artifact.isBinary || artifact.path.startsWith("html/agent/") ||
            (!artifact.path.endsWith(".html") && !artifact.path.endsWith(".md"))) { continue }
        out.append(artifact.content)
    }
    out.toString()
}

private let CODEC_RENDERER_MODULE = "cjdoc:module:v1:renderer-fixture"

private func codecFixtureProviders(moduleId: String): Array<ProviderInfo> {
    [
        ProviderInfo("ast", "test", moduleId, "partial",
            SemanticCapabilities(true, true, true, false, false)),
        ProviderInfo("types", "test", moduleId, "resolved",
            SemanticCapabilities(false, false, false, true, false))
    ]
}

private func codecRenderedText(artifacts: Array<RenderArtifact>): String {
    suite5ReaderText(artifacts)
}

private func codecRendererFixture(): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-fixture::fixture::function:topic#g0()"
    let heading = MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
        children: [MarkdownNode("text", literal: "Topic")])
    let firstItem = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("checked"),
        children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "First")])])
    let secondItem = MarkdownNode("list_item", MarkdownNodeMetadata.forListItem("notTask"),
        children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Second")])])
    let list = MarkdownNode("list", MarkdownNodeMetadata.forList("ordered", 3, "parenthesis", false),
        children: [firstItem, secondItem])
    let table = MarkdownNode("table", MarkdownNodeMetadata.forTable(["center", "none"]),
        children: [
            MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(true), children: [
                MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("center"),
                    children: [MarkdownNode("text", literal: "Left")]),
                MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("none"),
                    children: [MarkdownNode("text", literal: "Right")])
            ]),
            MarkdownNode("table_row", MarkdownNodeMetadata.forTableRow(false), children: [
                MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("center"),
                    children: [MarkdownNode("text", literal: "one")]),
                MarkdownNode("table_cell", MarkdownNodeMetadata.forTableCell("none"),
                    children: [MarkdownNode("text", literal: "two")])
            ])
        ])
    let code = MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced", Some("~"),
        4, "cangjie {.numberLines}", "cangjie", "{.numberLines}"), literal: "println(1)")
    let markdown = MarkdownNode("document", children: [heading, list, table, code])
    let symbol = SymbolDoc(symbolId, "function", "topic", "fixture.topic", "fixture",
        CODEC_RENDERER_MODULE, "public", source, "public func topic(): Unit",
        SemanticInfo("partial", "ast"),
        returnType: Some(TypeRef("primitive", "Unit", SemanticType("resolved",
            canonical: Some("std.core.Unit"), provider: Some("types")))),
        documentation: Some(DocComment("raw", "summary", "", markdown)))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("renderer-fixture"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: codecFixtureProviders(CODEC_RENDERER_MODULE),
        modules: [ModuleDoc(CODEC_RENDERER_MODULE, "renderer-fixture", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", CODEC_RENDERER_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", CODEC_RENDERER_MODULE, "fixture")],
        declarations: [symbol])
}

private func codecTypeLinkDeclaration(id: String, kind: String, name: String,
    canonical: String): SymbolDoc {
    let moduleId = "cjdoc:module:v1:type-links"
    SymbolDoc(id, kind, name, canonical, "fixture", moduleId, "public",
        SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1)),
        "public ${kind} ${name}", SemanticInfo("partial", "ast"))
}

private func codecTypeLinkDocument(returnType: TypeRef,
    parameters!: Array<ParameterDoc> = [], declarations!: Array<SymbolDoc> = []): DocumentationSet {
    let moduleId = "cjdoc:module:v1:type-links"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let functionId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Atype-links::fixture::function:accept#g0()"
    let function = SymbolDoc(functionId, "function", "accept", "fixture.accept", "fixture",
        moduleId, "public", source, "public func accept", SemanticInfo("partial", "ast"),
        parameters: parameters, returnType: Some(returnType))
    let symbols = ArrayList<SymbolDoc>()
    let ids = ArrayList<String>()
    for (declaration in declarations) {
        symbols.add(declaration)
        ids.add(declaration.id)
    }
    symbols.add(function)
    ids.add(functionId)
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("type-links"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: codecFixtureProviders(moduleId),
        modules: [ModuleDoc(moduleId, "type-links", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: ids.toArray())],
        files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: symbols.toArray())
}

private func codecTypeDocument(returnType: TypeRef, canonicalTypes!: Bool,
    documentation!: ?DocComment = None): DocumentationSet {
    let moduleName = if (canonicalTypes) { "canonical-types" }
        else { "source-types" }
    let moduleId = "cjdoc:module:v1:${moduleName}"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3A${moduleName}::fixture::function:compute#g0()"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let symbol = SymbolDoc(symbolId, "function", "compute", "fixture.compute", "fixture",
        moduleId, "public", source, "public func compute", SemanticInfo("partial", "ast"),
        returnType: Some(returnType), documentation: documentation)
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("type-document"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: codecFixtureProviders(moduleId),
        modules: [ModuleDoc(moduleId, moduleName, "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: [symbolId])],
        files: [FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: [symbol])
}


@Test
class ModelCodecCurrentSuite5 {
    @TestCase
    func renderersPreserveClosedMarkdownMetadata(): Unit {
        let documentation = codecRendererFixture()
        let markdown = codecRenderedText(MarkdownDocumentationRenderer().render(documentation))
        let html = suite5ReaderText(HtmlDocumentationRenderer().render(documentation))
        @Expect(markdown.contains("#### Topic"))
        @Expect(markdown.contains("3) [x] First\n\n4) Second"))
        @Expect(markdown.contains("| :---: |"))
        @Expect(markdown.contains("~~~~cangjie {.numberLines}"))
        @Expect(html.contains("--doc-topic"))
        @Expect(html.contains("<ol start=\"3\">"))
        @Expect(html.contains("type=\"checkbox\" disabled checked"))
        @Expect(html.contains("<th class=\"align-center\">"))
        @Expect(html.contains("data-language=\"cangjie\""))
        @Expect(html.contains("data-cjdoc-attributes=\"{.numberLines}\""))
    }

    @TestCase
    func authoredUnitReturnContractsSurviveAllReaderRepresentations(): Unit {
        let completion = "Publishes updates before returning"
        let ownership = "Preserves ownership of caller resources"
        let comment = DocComment("", "Completes the operation", "", MarkdownNode("document"),
            tags: [DocTag("return", "", completion), DocTag("returns", "", ownership)])
        let documentation = codecTypeDocument(
            TypeRef("primitive", "Unit", SemanticType("resolved", canonical: Some("std.core.Unit"),
                provider: Some("types"))), canonicalTypes: true, documentation: Some(comment))
        let html = suite5ReaderText(HtmlDocumentationRenderer().render(documentation))
        let markdown = codecRenderedText(MarkdownDocumentationRenderer().render(documentation))
        let snapshot = DocumentationReadSnapshot(documentation)
        let declaration = snapshot.renderDeclarationMarkdown(documentation.declarations[0].id).getOrThrow()
        let structured = snapshot.renderDeclarationJson(documentation.declarations[0].id).getOrThrow()
        for (contract in [completion, ownership]) {
            @Expect(html.contains(contract), true)
            @Expect(markdown.contains(contract), true)
            @Expect(declaration.contains(contract), true)
            @Expect(structured.contains(contract), true)
        }
    }

    @TestCase
    func unitReturnDocumentationIsNotAnHtmlExecutionSurface(): Unit {
        let comment = DocComment("", "Completes the operation", "", MarkdownNode("document"),
            tags: [DocTag("return", "", "Caller retains resources " +
                "<script>globalThis.cjdocReturnContractInjected = true</script>")])
        let documentation = codecTypeDocument(
            TypeRef("primitive", "Unit", SemanticType("resolved", canonical: Some("std.core.Unit"),
                provider: Some("types"))), canonicalTypes: true, documentation: Some(comment))
        let html = suite5ReaderText(HtmlDocumentationRenderer().render(documentation))
        @Expect(html.contains("Caller retains resources"), true)
        @Expect(html.contains("<script>globalThis.cjdocReturnContractInjected"), false)
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
        @Expect(html.contains("<dt class=\"parameter-declaration\"><code class=\"parameter-name\">left</code>"))
        @Expect(html.contains("<dt class=\"parameter-declaration\"><code class=\"parameter-name\">right</code>"))
        @Expect(html.contains("<a class=\"type-link\" href=\"../symbols/symbol-"))
        @Expect(html.contains(">Int64</a>"))
        @Expect(html.contains(">Array</a>&lt;<a class=\"type-link\" href=\"../symbols/symbol-"))
        @Expect(html.contains(">String</a>&gt;"))
        @Expect(html.contains("<code class=\"return-type\"><a class=\"type-link\""))
        @Expect(!html.contains(">left</a>"))
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
        @Expect(html.contains("<code class=\"parameter-type-code\" title=\"Documentation link unavailable\">UnknownType</code>"))
        @Expect(html.contains("<code class=\"parameter-type-code\">MaybeType</code>"))
        @Expect(html.contains("<code class=\"return-type\" title=\"Documentation link unavailable\">ExternalType</code>"))
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
        @Expect(html.contains("Returns"))
        @Expect(html.contains("<div class=\"return-value\"><code class=\"return-type\" title=\"Documentation link unavailable\">Int64</code><div class=\"return-description\"><p>The computed result.</p>"))
    }
}
