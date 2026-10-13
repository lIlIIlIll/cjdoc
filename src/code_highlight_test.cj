package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func highlightedSpellings(source: String, kind: String): Array<String> {
    let value = highlightCode(source, "cangjie", "builtin")
    let result = ArrayList<String>()
    var previousEnd: Int64 = 0
    @Assert(match (value.state) { case CodeHighlightState.Complete => true; case _ => false })
    @Assert(value.byteLength, source.size)
    for (span in value.spans()) {
        @Assert(span.startByte >= previousEnd && span.endByte > span.startByte && span.endByte <= source.size)
        @Assert(highlightByteBoundary(source, span.startByte) && highlightByteBoundary(source, span.endByte))
        if (codeKindName(span.kind) == kind) { result.add(source[span.startByte..span.endByte]) }
        previousEnd = span.endByte
    }
    result.toArray()
}

@Test
class CodeHighlightLexerTest {
    @TestCase
    func originalLiteralDelimitersEscapesAndSuffixesArePreserved(): Unit {
        let literals = ["\"hi\\n\\\"q\\\"\"", "\"\"", "#\"raw\"#", "##\"a #\" b\"##", "'x'", "'\\n'"]
        for (literal in literals) {
            let source = "let s = " + literal + "  \n"
            let texts = highlightedSpellings(source, "string")
            @Assert(texts.size, 1)
            @Expect(texts[0], literal)
        }
        for (literal in ["0xFF", "0b1010", "1_000", "1.5e-3", "10i8", "1.0f32"]) {
            let texts = highlightedSpellings("let n = " + literal, "number")
            @Assert(texts.size, 1)
            @Expect(texts[0], literal)
        }
    }

    @TestCase
    func booleanLiteralsKeepTheirOriginalLiteralColour(): Unit {
        let source = "let a = true\nlet b = false"
        let literals = highlightedSpellings(source, "literal")
        @Assert(literals.size, 2)
        @Expect(literals[0], "true")
        @Expect(literals[1], "false")
        let html = api_render.renderStandaloneMarkdownHtml(
            parseStandaloneMarkdown("~~~cj\n" + source + "\n~~~\n"))
        @Expect(html.contains("<span class=\"code-literal\">true</span>"))
        @Expect(html.contains("<span class=\"code-literal\">false</span>"))
    }


    @TestCase
    func interpolationIsOneOriginalLiteral(): Unit {
        let literal = "\"a $" + "{x + 1} b\""
        let texts = highlightedSpellings("let s = " + literal, "string")
        @Assert(texts.size, 1)
        @Expect(texts[0], literal)
        @Expect(highlightedSpellings("let s = " + literal, "number").size, 0)
    }

    @TestCase
    func commentsAndIdentifiersUseOnlyLexerFacts(): Unit {
        let source = "// c\n/* a /* b */ c */ let 名称 = 1\nf<Int64>(x: 1) { a: 2, b: 3 }\n@M\npublic macro m() { 0 }"
        let comments = highlightedSpellings(source, "comment")
        @Assert(comments.size, 2)
        @Expect(comments[0], "// c")
        @Expect(comments[1], "/* a /* b */ c */")
        let types = highlightedSpellings(source, "type")
        @Assert(types.size, 1)
        @Expect(types[0], "Int64")
        @Expect(highlightCode("名称 f Foo T myVar M", "cangjie", "builtin").spans().size, 0)
        @Expect(highlightedSpellings("String Array Char", "type").size, 3)
        @Expect(highlightedSpellings(source, "keyword").contains("macro"))
        @Expect(highlightedSpellings(source, "punctuation").contains("@"))
    }

    @TestCase
    func lexerFailuresAndResourceLimitsPreserveFullSource(): Unit {
        for (source in ["/* open", "let s = \"open", "let s = \"\"\"line1"]) {
            let value = highlightCode(source, "cangjie", "builtin")
            @Expect(match (value.state) { case CodeHighlightState.Plain => true; case _ => false })
            @Expect(value.reason, Some("unterminated-token"))
            @Expect(value.spans().size, 0)
            @Expect(value.byteLength, source.size)
            let tree = parseStandaloneMarkdown("~~~cj\n" + source + "\n~~~\n")
            let html = api_render.renderStandaloneMarkdownHtml(tree)
            @Expect(html.contains(source.replace("\"", "&quot;")))
            @Expect(!html.contains("<span class=\"code-"))
        }
        let oversized = String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_BLOCK_BYTES + 1, repeat: b'a'))
        let value = highlightCode(oversized, "cangjie", "builtin")
        @Expect(value.reason, Some("resource-limit"))
        @Expect(value.spans().size, 0)
        @Expect(value.byteLength, oversized.size)
        let manySpans = String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_SPANS_PER_BLOCK + 1, repeat: b'('))
        @Expect(highlightCode(manySpans, "cangjie", "builtin").reason, Some("resource-limit"))
    }

    @TestCase
    func invalidPreparedRangesCannotEscapeConstructorValidation(): Unit {
        @ExpectThrows[IllegalArgumentException](CodeHighlight("中", "cangjie",
            [CodeSpan(0, 1, CodeKind.Keyword)], CodeHighlightState.Complete, None))
        @ExpectThrows[IllegalArgumentException](CodeHighlight("let", "cangjie",
            [CodeSpan(0, 2, CodeKind.Keyword), CodeSpan(1, 3, CodeKind.Keyword)], CodeHighlightState.Complete, None))
        @ExpectThrows[IllegalArgumentException](CodeHighlight("let", "cangjie",
            [CodeSpan(0, 4, CodeKind.Keyword)], CodeHighlightState.Complete, None))
    }

    @TestCase
    func backendDegradationIsExplicit(): Unit {
        @Expect(highlightCode("x", "", "plain").reason, Some("no-language"))
        @Expect(highlightCode("x", "unknown", "plain").reason, Some("unsupported"))
        @Expect(highlightCode("x", "javascript", "external").reason, Some("backend-unavailable"))
    }

    @TestCase
    func disabledGenerationLeavesMetadataAbsentAndSourceEscaped(): Unit {
        let tree = parseStandaloneMarkdown("~~~cj\nlet x = #\"raw <script>\"#\n~~~\n", highlightMode: "off")
        let code = tree.children[0]
        @Expect(code.metadata.getOrThrow().codeHighlight.isNone())
        let html = api_render.renderStandaloneMarkdownHtml(tree)
        @Expect(!html.contains("<span class=\"code-"))
        @Expect(html.contains("#&quot;raw &lt;script&gt;&quot;#"))
    }

    @TestCase
    func generatedMarkdownUsesLexerSpansAcrossRealRendering(): Unit {
        let body = "~~~cj\nlet 名称 = #\"raw <script>\"#\nlet other = ##\"a #\" b\"##\n/* a /* b */ c */ let n = 0xFF\n~~~\n"
        let tree = parseStandaloneMarkdown(body)
        let code = tree.children[0]
        let prepared = code.metadata.getOrThrow().codeHighlight.getOrThrow()
        @Expect(prepared.matchesSource(code.literal))
        @Expect(prepared.state, "complete")
        let html = api_render.renderStandaloneMarkdownHtml(tree)
        @Expect(html.contains("<span class=\"code-string\">#&quot;raw &lt;script&gt;&quot;#</span>"))
        @Expect(html.contains("<span class=\"code-comment\">/* a /* b */ c */</span>"))
        @Expect(html.contains("<span class=\"code-number\">0xFF</span>"))
        @Expect(!html.contains("<script>"))
    }
}
