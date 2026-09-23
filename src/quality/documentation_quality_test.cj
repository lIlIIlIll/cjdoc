package cjdoc.quality

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func qualitySymbol(summary: String, parameter: String, returned: String): SymbolDoc {
    let location = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
    let body = MarkdownNode("document", children: [MarkdownNode("paragraph",
        children: [MarkdownNode("text", literal: summary)])])
    let typeRef = TypeRef("source", "Int64", SemanticType("partial"))
    SymbolDoc("test", "function", "echo", "fixture.echo", "fixture", "module", "public",
        location, "public func echo(value: Int64): Int64", SemanticInfo("partial", "ast"),
        documentation: Some(DocComment(summary, summary, "", body,
            tags: [DocTag("return", "", returned)])),
        parameters: [ParameterDoc("value", typeRef, documentation: Some(parameter)),
            ParameterDoc("_ignored", typeRef, documentation: Some("参数 _ignored。"))],
        returnType: Some(typeRef))
}

@Test
class DocumentationQualityTest {
    @TestCase
    func recognizesOnlyWholeTemplateDescriptions(): Unit {
        let findings = documentationQualityDiagnostics(
            qualitySymbol("Fixture 公开 API：`echo`。", "参数 `value`。", "返回 Int64。"), "fixture")
        @Expect(findings.size, 3)
        @Expect(documentationQualityDiagnostics(qualitySymbol(
            "Echoes the value after validation.", "参数 value 必须是正数。", "返回 Int64，表示读取的字节数。"),
            "fixture").isEmpty())
        @Expect(documentationQualityDiagnostics(qualitySymbol(
            "Another project API: echo.", "The value to echo.", "The echoed value."),
            "fixture").isEmpty())
    }

    @TestCase
    func emptyDocumentationIsNotMeaningfulOrATemplateWarning(): Unit {
        let empty = qualitySymbol(" \n ", "", "")
        @Expect(!hasDocumentationSummary(empty))
        @Expect(documentationQualityDiagnostics(empty, "fixture").isEmpty())
        let meaningful = qualitySymbol("Returns the input unchanged.", "Input value.", "Input value.")
        @Expect(hasDocumentationSummary(meaningful))
        @Expect(!trivialParameterDocumentation(meaningful.parameters[0]))
    }
}
