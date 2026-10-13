package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

internal func uncoloredCode(value: String): String {
    var result = value
    for (name in ["keyword", "type", "string", "number", "literal", "comment", "operator",
        "punctuation", "function", "property", "meta"]) {
        result = result.replace("<span class=\"code-${name}\">", "")
    }
    result.replace("</span>", "")
}

@Test
class HtmlCodePresentationTest {
    @TestCase
    func preparedOriginalRangesColorRawStringsAndRejectStaleMetadata(): Unit {
        let raw = "let 名称 = #\"<script>\"#"
        let start = raw.indexOf("#").getOrThrow()
        let prepared = CodeHighlight("cangjie", contractFingerprint(raw), raw.size,
            "cjdoc-cangjie-lexer", "1", "complete", None,
            [CodeSpan(0, 3, "keyword"), CodeSpan(start, raw.size, "string")])
        let out = RenderTextBuffer()
        appendHighlightedCodeHtml(out, raw, "cangjie", highlight: Some(prepared))
        @Expect(uncoloredCode(out.toString()), escapeHtml(raw))
        @Expect(out.toString().contains("<span class=\"code-string\">#&quot;&lt;script&gt;&quot;#</span>"))
        let stale = RenderTextBuffer()
        appendHighlightedCodeHtml(stale, raw + "x", "cangjie", highlight: Some(prepared))
        @Expect(stale.toString(), escapeHtml(raw + "x"))
    }

    @TestCase
    func invalidSpanArraysFailClosedWithoutPartialMarkup(): Unit {
        let out = RenderTextBuffer()
        appendHighlightedSpansHtml(out, "中<script>", [(0, 1, "code-keyword")])
        @Expect(out.toString(), escapeHtml("中<script>"))
        let overlaps = RenderTextBuffer()
        appendHighlightedSpansHtml(overlaps, "abcd", [(0, 3, "code-keyword"), (2, 4, "code-string")])
        @Expect(overlaps.toString(), "abcd")
    }

    @TestCase
    func highlightingPreservesEveryEscapedSourceByteAndNeverCreatesMarkup(): Unit {
        let raw = "let 名称: String = \"<script>alert('中')</script>&\\\"\"\n" +
            "/* comment /* nested */ <img src=x> */\n// comment\nlet count = 42"
        let out = RenderTextBuffer()
        appendHighlightedCodeHtml(out, raw, "cangjie")
        let html = out.toString()
        @Expect(uncoloredCode(html), escapeHtml(raw))
        // No persisted metadata: compatible degradation is escaped plain text.
        @Expect(html, escapeHtml(raw))
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
