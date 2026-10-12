package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func languageRoutingCode(raw: String, language: String): String {
    let out = RenderTextBuffer()
    appendHighlightedCodeHtml(out, raw, language)
    out.toString()
}

@Test
class HtmlCodeLanguageRoutingTest {
    @TestCase
    func explicitCangjieAliasesShareOneHighlighter(): Unit {
        let raw = "let 名称: String = \"<code>&\""
        let expected = languageRoutingCode(raw, "cangjie")
        @Expect(expected.contains("class=\"code-keyword\""), true)
        for (language in ["cj", "CJ", "Cangjie", " cangjie\t"]) {
            @Expect(languageRoutingCode(raw, language), expected)
        }
    }

    @TestCase
    func noLanguageAndOutputNeverTriggerLanguageDetection(): Unit {
        let raw = "let value = \"<script>\""
        for (language in ["", "text", "plaintext", "output", "console", "nohighlight",
            "no-highlight", "unknown", "zh-CN", "en", "zsh", "fish", "powershell",
            "cangjie\" onclick=\"bad", "cangjie {run}"]) {
            @Expect(languageRoutingCode(raw, language), escapeHtml(raw))
        }
    }

    @TestCase
    func examplesUseTheSameExplicitLanguageRouting(): Unit {
        let raw = "public func join(separator!: String = \",\"): String"
        let lower = RenderTextBuffer()
        let upper = RenderTextBuffer()
        appendExampleCodeHtml(lower, raw, "cangjie")
        appendExampleCodeHtml(upper, raw, "CJ")
        // The author language attribute is retained; only backend selection is normalized.
        @Expect(upper.toString().contains("data-language=\"CJ\""), true)
        @Expect(upper.toString().contains(languageRoutingCode(raw, "cangjie")), true)
        @Expect(lower.toString().contains(languageRoutingCode(raw, "CJ")), true)
    }
}
