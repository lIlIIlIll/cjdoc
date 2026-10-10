package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func exampleEvidenceHtml(symbolId: String, title: String,
    evidence: HashMap<String, String>, locale: String): String {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let symbol = SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture",
        "cjdoc:module:v1:example-evidence", "public", source, "public func api(): Unit",
        SemanticInfo("partial", "ast"))
    let comment = DocComment("raw", "", "", MarkdownNode("document", children: []),
        tags: [DocTag("example", title, "```cj\\nlet a = 1\\n```")])
    let out = RenderTextBuffer()
    appendDocumentationExamplesHtml(out, comment, locale, symbol: Some(symbol),
        exampleEvidence: evidence)
    out.toString()
}

@Test
class HtmlExampleEvidenceTest {
    @TestCase
    func recordedNativeStatusIsShownBesideItsOwnExample(): Unit {
        let symbolId = "cjdoc:v2:example::fixture::function:api#g0()"
        let evidence = HashMap<String, String>()
        evidence[exampleEvidenceKey(symbolId, "verified case")] = "passed"
        let html = exampleEvidenceHtml(symbolId, "verified case", evidence, "en")
        @Expect(html.contains("data-example-state=\"passed\""), true)
        @Expect(html.contains("Verified by execution"), true)
        @Expect(html.contains("Raw execution evidence"), true)
    }

    @TestCase
    func everyStatusKeepsItsOwnMeaning(): Unit {
        let symbolId = "cjdoc:v2:example::fixture::function:api#g0()"
        for ((status, wording) in [("failed", "Execution failed"), ("timeout", "Execution timed out"),
            ("skipped", "Not executed")]) {
            let evidence = HashMap<String, String>()
            evidence[exampleEvidenceKey(symbolId, "case")] = status
            let html = exampleEvidenceHtml(symbolId, "case", evidence, "en")
            @Expect(html.contains("data-example-state=\"" + status + "\""), true)
            @Expect(html.contains(wording), true)
            @Expect(html.contains("Verified by execution"), false)
        }
    }

    @TestCase
    func unrecordedOrMismatchedExamplesCarryNoClaim(): Unit {
        let symbolId = "cjdoc:v2:example::fixture::function:api#g0()"
        let empty = HashMap<String, String>()
        @Expect(exampleEvidenceHtml(symbolId, "no result", empty, "en").contains("example-evidence"), false)
        // A status recorded for a different title or symbol must not be reused.
        let other = HashMap<String, String>()
        other[exampleEvidenceKey(symbolId, "other title")] = "passed"
        @Expect(exampleEvidenceHtml(symbolId, "this title", other, "en").contains("example-evidence"), false)
        let otherSymbol = HashMap<String, String>()
        otherSymbol[exampleEvidenceKey("cjdoc:v2:example::other#g0()", "this title")] = "passed"
        @Expect(exampleEvidenceHtml(symbolId, "this title", otherSymbol, "en").contains("example-evidence"), false)
    }

    @TestCase
    func wordingIsLocalizedWithoutChangingTheMachineState(): Unit {
        let symbolId = "cjdoc:v2:example::fixture::function:api#g0()"
        let evidence = HashMap<String, String>()
        evidence[exampleEvidenceKey(symbolId, "用例")] = "passed"
        let html = exampleEvidenceHtml(symbolId, "用例", evidence, "zh-CN")
        @Expect(html.contains("已执行验证"), true)
        @Expect(html.contains("data-example-state=\"passed\""), true)
    }
}
