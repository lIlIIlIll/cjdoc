package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func signatureTestTokens(): Array<String> {
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

private func signatureTestDocument(raw: String,
    tokens!: Array<String> = signatureTestTokens(), highlight!: ?CodeHighlight = None): DocumentationSet {
    let moduleId = "cjdoc:module:v1:signature-test"
    let tokenId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asignature-test::fixture::class:Token#g0()"
    let functionId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asignature-test::fixture::function:accept#g0(String,Token)"
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, raw.size + 1, raw.size))
    let tokenType = TypeRef("named", "Token",
        SemanticType("resolved", canonical: Some("fixture.Token")))
    let token = SymbolDoc(tokenId, "class", "Token", "fixture.Token", "fixture", moduleId,
        "public", source, "public class Token", SemanticInfo("partial", "ast"))
    let subject = SymbolDoc(functionId, "function", "accept", "fixture.accept", "fixture", moduleId,
        "public", source, raw, SemanticInfo("partial", "ast"),
        parameters: [
            ParameterDoc("label", TypeRef("named", "String", SemanticType("unavailable"))),
            ParameterDoc("item", tokenType)
        ],
        returnType: Some(tokenType),
        sourceApiSignature: SourceApiSignature("available", tokens: tokens), signatureHighlight: highlight)
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("signature-test"),
        ConfigurationSnapshot(lintProfile: "off"),
        modules: [ModuleDoc(moduleId, "signature-test", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, symbolIds: [tokenId, functionId])],
        declarations: [token, subject])
}

@Test
class HtmlSignatureMappingTest {

    @TestCase
    func signatureColourDistinguishesAbsentStaleAndValidHighlight(): Unit {
        let raw = "public func accept(label!: String = \"Token\", item!: Token): Token"
        let prepared = CodeHighlight("cangjie", contractFingerprint(raw), raw.size,
            "cjdoc-cangjie-lexer", "1", "complete", None, [CodeSpan(0, 6, "comment")])
        let stale = CodeHighlight("cangjie", contractFingerprint(raw + " "), raw.size + 1,
            "cjdoc-cangjie-lexer", "1", "complete", None, [CodeSpan(0, 6, "comment")])
        let witnessHtml = "<span class=\"code-keyword\">public</span> " +
            "<span class=\"code-keyword\">func</span> accept(label!: " +
            "<span class=\"code-type\">String</span> = " +
            "<span class=\"code-string\">&quot;Token&quot;</span>, item!: Token): Token"
        let validHtml = "<span class=\"code-comment\">public</span>" + escapeHtml(raw[6..])
        let cases: Array<(?CodeHighlight, String)> = [
            (None, witnessHtml), (Some(stale), escapeHtml(raw)), (Some(prepared), validHtml)
        ]
        for ((highlight, expected) in cases) {
            let document = signatureTestDocument(raw, highlight: highlight)
            let subject = document.declarations[1]
            let out = RenderTextBuffer()
            appendSignatureTextHtml(out, subject)
            @Expect(out.toString(), expected)
            let linked = RenderTextBuffer()
            let links = HtmlTypeLinkIndex(document, RenderProjection(document))
            appendLinkedSignatureHtml(linked, subject, links, "../")
            if (let Some(value) <- highlight) {
                if (!value.matchesSource(raw)) {
                    @Expect(linked.toString(), escapeHtml(raw))
                    continue
                }
            }
            @Expect(linked.toString().contains("class=\"type-link signature-type-link\""))
            @Expect(linked.toString().contains("code-comment"), highlight.isSome())
            @Expect(linked.toString().contains("code-keyword"), highlight.isNone())
            @Expect(linked.toString().contains("code-type"), highlight.isNone())
            @Expect(linked.toString().contains("code-string"), highlight.isNone())
        }
    }

    @TestCase
    func persistedDisplaySpansMergeInsideExistingTypeLinks(): Unit {
        let raw = "public func accept(label!: String = \"Token\", item!: Token): Token"
        let literalStart = raw.indexOf("\"Token\"").getOrThrow()
        let prepared = CodeHighlight("cangjie", contractFingerprint(raw), raw.size,
            "cjdoc-cangjie-lexer", "1", "complete", None,
            [CodeSpan(0, 6, "keyword"), CodeSpan(7, 11, "keyword"),
                CodeSpan(literalStart, literalStart + 7, "string")])
        let document = signatureTestDocument(raw, highlight: Some(prepared))
        let links = HtmlTypeLinkIndex(document, RenderProjection(document))
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, document.declarations[1], links, "../")
        let html = out.toString()
        @Expect(html.contains("<span class=\"code-string\">&quot;Token&quot;</span>"))
        @Expect(html.contains("class=\"type-link signature-type-link\""))
        @Expect(!html.contains("&quot;<a"))
        @Expect(uncoloredCode(html).contains("&quot;Token&quot;"))
        let staleDocument = signatureTestDocument(raw + " ", highlight: Some(prepared))
        let stale = RenderTextBuffer()
        appendSignatureTextHtml(stale, staleDocument.declarations[1])
        @Expect(stale.toString(), escapeHtml(raw + " "))
    }

    @TestCase
    func persistedCommentSpansDoNotDependOnSkippedWitnessTrivia(): Unit {
        let raw = "public /* nested /* inner */ end */ func accept(label!: String = \"Token\", item!: Token): Token"
        let commentStart = raw.indexOf("/*").getOrThrow()
        let commentEnd = raw.indexOf(" func").getOrThrow()
        let prepared = CodeHighlight("cangjie", contractFingerprint(raw), raw.size,
            "cjdoc-cangjie-lexer", "2", "complete", None,
            [CodeSpan(0, 6, "keyword"), CodeSpan(commentStart, commentEnd, "comment")])
        let document = signatureTestDocument(raw, highlight: Some(prepared))
        let out = RenderTextBuffer()
        appendSignatureTextHtml(out, document.declarations[1])
        @Expect(uncoloredCode(out.toString()), escapeHtml(raw))
        @Expect(out.toString().contains("<span class=\"code-comment\">/* nested /* inner */ end */</span>"))
    }

    @TestCase
    func namedParameterAndReturnLinksNeverSelectDefaultLiteral(): Unit {
        let raw = "public func accept(label!: String = \"Token\", item!: Token): Token"
        let documentation = signatureTestDocument(raw)
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(raw[spans[0].start..spans[0].end], "Token")
        @Expect(spans[0].start,
            raw.indexOf("item!: Token").getOrThrow() + "item!: ".size)
        @Expect(spans[1].end, raw.size)
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, documentation.declarations[1], links, "../")
        @Expect(out.toString().contains("&quot;Token&quot;"), true)
        @Expect(out.toString().contains("&quot;<a"), false)
        @Expect(out.toString().contains("<span class=\"code-keyword\">func</span>"), true)
        @Expect(out.toString().contains("<span class=\"code-string\">&quot;Token&quot;</span>"), true)
        @Expect(out.toString().contains("class=\"type-link signature-type-link\""), true)
    }

    @TestCase
    func commentsAndTriviaDoNotCreateTypeLinks(): Unit {
        let raw = "public /* Token /* nested */ */ func accept(label!: String = \"Token\",\n" +
            "/* item!: Token */ item! : Token): Token // Token"
        let documentation = signatureTestDocument(raw)
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(spans[0].start,
            raw.indexOf("item! : Token").getOrThrow() + "item! : ".size)
    }

    @TestCase
    func commaDefaultLiteralHighlightsWithoutBecomingAParameterSeparator(): Unit {
        let raw = "public func accept(label!: String = \",\", item!: Token): Token"
        let tokens = ArrayList<String>(signatureTestTokens())
        tokens[9] = "STRING_LITERAL:3:\",\""
        let documentation = signatureTestDocument(raw, tokens: tokens.toArray())
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(raw[spans[0].start..spans[0].end], "Token")
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, documentation.declarations[1], links, "../")
        let html = out.toString()
        @Expect(html.contains("<span class=\"code-keyword\">public</span>"), true)
        @Expect(html.contains("<span class=\"code-keyword\">func</span>"), true)
        @Expect(html.contains("<span class=\"code-string\">&quot;,&quot;</span>"), true)
        @Expect(html.contains("class=\"type-link signature-type-link\""), true)
    }

    @TestCase
    func sourceLiteralMarkupIsEscapedWhenHighlighted(): Unit {
        let literal = "\"<img src=x onerror=alert(1)>\""
        let raw = "public func accept(label!: String = " + literal + ", item!: Token): Token"
        let tokens = ArrayList<String>(signatureTestTokens())
        tokens[9] = "STRING_LITERAL:${literal.size}:${literal}"
        let documentation = signatureTestDocument(raw, tokens: tokens.toArray())
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let out = RenderTextBuffer()
        appendLinkedSignatureHtml(out, documentation.declarations[1], links, "../")
        let html = out.toString()
        @Expect(html.contains("<img"), false)
        @Expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"), true)
        @Expect(html.contains("<span class=\"code-string\">"), true)
    }

    @TestCase
    func staleTokenWitnessFailsClosed(): Unit {
        let raw = "public func accept(label!: String = \"different\", item!: Token): Token"
        let documentation = signatureTestDocument(raw)
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
        let tokens = ArrayList<String>(signatureTestTokens())
        let literal = "\"中文 Token : ()\""
        tokens[9] = "STRING_LITERAL:${literal.size}:${literal}"
        let documentation = signatureTestDocument(raw, tokens: tokens.toArray())
        let links = HtmlTypeLinkIndex(documentation, RenderProjection(documentation))
        let spans = linkedSignatureSpans(documentation.declarations[1], links)
        @Expect(spans.size, 2)
        @Expect(spans[0].start,
            raw.indexOf("item!: Token").getOrThrow() + "item!: ".size)
    }
}
