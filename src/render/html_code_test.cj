package cjdoc.render

import std.unittest.*
import std.unittest.testmacro.*

private func uncoloredCode(value: String): String {
    var result = value
    for (name in ["keyword", "type", "string", "number", "comment", "punctuation"]) {
        result = result.replace("<span class=\"code-${name}\">", "")
    }
    result.replace("</span>", "")
}

@Test
class HtmlCodePresentationTest {
    @TestCase
    func highlightingPreservesEveryEscapedSourceByteAndNeverCreatesMarkup(): Unit {
        let raw = "let 名称: String = \"<script>alert('中')</script>&\\\"\"\n" +
            "/* comment /* nested */ <img src=x> */\n// comment\nlet count = 42"
        let out = RenderTextBuffer()
        appendHighlightedCodeHtml(out, raw, "cangjie")
        let html = out.toString()
        @Expect(uncoloredCode(html), escapeHtml(raw))
        @Expect(html.contains("<span class=\"code-keyword\">let</span>"), true)
        @Expect(html.contains("<span class=\"code-type\">String</span>"), true)
        @Expect(html.contains("<span class=\"code-number\">42</span>"), true)
        @Expect(html.contains("<span class=\"code-comment\">"), true)
        @Expect(html.contains("<script>"), false)
        @Expect(html.contains("<img"), false)
    }

    @TestCase
    func unsupportedOrUnfinishedCodeFallsBackToEscapedOriginal(): Unit {
        for (raw in ["let value = \"unfinished", "let x = 1 /* unfinished",
            "let text = #\"raw <script>\"#", "let text = \"\"\"multiline\"\"\""]) {
            let out = RenderTextBuffer()
            appendHighlightedCodeHtml(out, raw, "cj")
            @Expect(out.toString(), escapeHtml(raw))
        }
        let out = RenderTextBuffer()
        appendHighlightedCodeHtml(out, "let value = '<script>'", "unknown-language")
        @Expect(out.toString(), "let value = &#39;&lt;script&gt;&#39;")
    }
}
