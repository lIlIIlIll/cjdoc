package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

internal func uncoloredCode(value: String): String {
    var result = value
    for (name in ["keyword", "type", "string", "number", "literal", "comment", "operator",
        "punctuation", "function", "property", "meta"]) {
        result = result.replace("<span class=\"cj-tok-${name}\">", "")
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
        let out = HtmlWriter()
        appendHighlightedCodeHtml(out, raw, "cangjie", highlight: Some(prepared))
        @Expect(uncoloredCode(out.toString()), escapeHtml(raw))
        @Expect(out.toString().contains(
            "<span class=\"cj-tok-string\">#&quot;&lt;script&gt;&quot;#</span>"))
        let stale = HtmlWriter()
        appendHighlightedCodeHtml(stale, raw + "x", "cangjie", highlight: Some(prepared))
        @Expect(stale.toString(), escapeHtml(raw + "x"))
    }

    @TestCase
    func invalidSpanArraysFailClosedWithoutPartialMarkup(): Unit {
        let out = HtmlWriter()
        appendHighlightedSpansHtml(out, "中<script>", [(0, 1, "cj-tok-keyword")])
        @Expect(out.toString(), escapeHtml("中<script>"))
        let overlaps = HtmlWriter()
        appendHighlightedSpansHtml(overlaps, "abcd",
            [(0, 3, "cj-tok-keyword"), (2, 4, "cj-tok-string")])
        @Expect(overlaps.toString(), "abcd")
        let splitRune = HtmlWriter()
        appendHighlightedSpansHtml(splitRune, "中", [(0, 2, "cj-tok-keyword")])
        @Expect(splitRune.toString(), "中")
    }

    @TestCase
    func spanBoundariesEmitOnlyBalancedTokenElements(): Unit {
        let out = HtmlWriter()
        appendHighlightedSpansHtml(out, "abc",
            [(1, 2, "cj-tok-keyword"), (2, 3, "cj-tok-string")])
        @Expect(out.toString(),
            "a<span class=\"cj-tok-keyword\">b</span><span class=\"cj-tok-string\">c</span>")
        let unclassified = HtmlWriter()
        appendHighlightedSpansHtml(unclassified, "ab", [(0, 1, "")])
        @Expect(unclassified.toString(), "ab")
    }

    @TestCase
    func highlightingPreservesEveryEscapedSourceByteAndNeverCreatesMarkup(): Unit {
        let raw = "let 名称: String = \"<script>alert('中')</script>&\\\"\"\n" +
            "/* comment /* nested */ <img src=x> */\n// comment\nlet count = 42"
        let out = HtmlWriter()
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
            let out = HtmlWriter()
            appendHighlightedCodeHtml(out, raw, "cj")
            @Expect(out.toString(), escapeHtml(raw))
        }
        let out = HtmlWriter()
        appendHighlightedCodeHtml(out, "let value = '<script>'", "unknown-language")
        @Expect(out.toString(), "let value = &#39;&lt;script&gt;&#39;")
    }

    @TestCase
    func copyHookCarriesTheExtractedSourceAsJson(): Unit {
        let writer = HtmlWriter()
        writer.open("code", attrs: [codeSourceAttr("a<b\n\"c\"")])
        writer.close("code")
        @Expect(writer.toString(),
            "<code data-cjdoc-source=\"&quot;a&lt;b\\n\\&quot;c\\&quot;&quot;\"></code>")
    }
}
