package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func referenceSignatureTokens(): Array<String> {
    // Exact public SourceApiSignature encoding; literal contents are one token.
    let values: Array<(String, String)> = [
        ("PUBLIC", "public"), ("FUNC", "func"), ("IDENTIFIER", "accept"), ("LPAREN", "("),
        ("IDENTIFIER", "label"), ("NOT", "!"), ("COLON", ":"), ("IDENTIFIER", "String"),
        ("ASSIGN", "="), ("STRING_LITERAL", "\"Token\""), ("COMMA", ","),
        ("IDENTIFIER", "item"), ("NOT", "!"), ("COLON", ":"), ("IDENTIFIER", "Token"),
        ("RPAREN", ")"), ("COLON", ":"), ("IDENTIFIER", "Token")
    ]
    let result = ArrayList<String>()
    for ((kind, value) in values) { result.add("${kind}:${value.size}:${value}") }
    result.toArray()
}

private func referenceSignatureDocument(raw: String,
    tokens!: Array<String> = referenceSignatureTokens()): DocumentationSet {
    let moduleId = "cjdoc:module:v1:signature-test"
    let tokenId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asignature-test::fixture::class:Token#g0()"
    let functionId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asignature-test::fixture::function:accept#g0(String,Token)"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, raw.size + 1, raw.size))
    let tokenType = TypeRef("named", "Token", SemanticType("resolved", canonical: Some("fixture.Token")))
    let token = SymbolDoc(tokenId, "class", "Token", "fixture.Token", "fixture", moduleId,
        "public", source, "public class Token", SemanticInfo("partial", "ast"))
    let subject = SymbolDoc(functionId, "function", "accept", "fixture.accept", "fixture", moduleId,
        "public", source, raw, SemanticInfo("partial", "ast"),
        parameters: [ParameterDoc("label", TypeRef("named", "String", SemanticType("unavailable"))),
            ParameterDoc("item", tokenType)], returnType: Some(tokenType),
        sourceApiSignature: SourceApiSignature("available", tokens: tokens))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("signature-test"),
        ConfigurationSnapshot(lintProfile: "off"),
        modules: [ModuleDoc(moduleId, "signature-test", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, symbolIds: [tokenId, functionId])],
        declarations: [token, subject])
}

@Test
class CompactReferenceTest {
    @TestCase
    func namedParameterAndReturnLinksNeverSelectDefaultLiteral(): Unit {
        let raw = "public func accept(label!: String = \"Token\", item!: Token): Token"
        let documentation = referenceSignatureDocument(raw)
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(raw[spans[0].start..spans[0].end], "Token")
        @Expect(spans[0].start, raw.indexOf("item!: Token").getOrThrow() + "item!: ".size)
        @Expect(spans[1].end, raw.size)
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, documentation.declarations[1], links, "../")
        @Expect(out.toString().contains("&quot;Token&quot;"), true)
        @Expect(out.toString().contains("&quot;<a"), false)
    }

    @TestCase
    func sourceTriviaAndCommentsDoNotCreateAdditionalReferences(): Unit {
        let raw = "public /* Token /* nested */ */ func accept(label!: String = \"Token\",\n" +
            "/* item!: Token */ item! : Token): Token // Token"
        let documentation = referenceSignatureDocument(raw)
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(spans[0].start, raw.indexOf("item! : Token").getOrThrow() + "item! : ".size)
    }

    @TestCase
    func staleOrUnalignableTokensFailClosed(): Unit {
        let raw = "public func accept(label!: String = \"different\", item!: Token): Token"
        let documentation = referenceSignatureDocument(raw)
        let subject = documentation.declarations[1]
        @Expect(alignedSignatureTokens(subject).isEmpty(), true)
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        @Expect(linkedSignatureSpans(subject, links).isEmpty(), true)
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, subject, links, "../")
        @Expect(out.toString(), escapeHtml(raw))
    }

    @TestCase
    func utf8LiteralKeepsByteOffsetsWithoutSearchingItsContent(): Unit {
        let original = "public func accept(label!: String = \"Token\", item!: Token): Token"
        let raw = original.replace("\"Token\"", "\"中文 Token : ()\"")
        let tokens = ArrayList<String>(referenceSignatureTokens())
        let literal = "\"中文 Token : ()\""
        tokens[9] = "STRING_LITERAL:${literal.size}:${literal}"
        let documentation = referenceSignatureDocument(raw, tokens: tokens.toArray())
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(spans[0].start, raw.indexOf("item!: Token").getOrThrow() + "item!: ".size)
    }

    @TestCase
    func relatedSlotsAndStandaloneRoutesUseTheSameIdentity(): Unit {
        let id = "cjdoc:v2:fixture::Type::function:read#g0(Int64)"
        @Expect(htmlSymbolPagePath(id), "symbols/symbol-${boundedHtmlSlug(id)}.html")
        @Expect(htmlSymbolAnchor(id), "symbol-${htmlStableSlug(id)}")
        @Expect(htmlRelatedContentMarker(id).contains(":2-->"), true)
        @Expect(htmlRelatedContentMarker(id, headingLevel: 4).contains(":4-->"), true)
        @Expect(htmlRelatedContentMarker("--><script>").contains("<script>"), false)
    }
}
