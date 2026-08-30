package cjdoc

import cjdoc.model as api_model
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PublicResourceBudgetTest {
    @TestCase
    func projectionReplacesOversizedFieldsAndAggregateOutput(): Unit {
        let request = GenerationRequest("unused", lintProfile: "off")
        let oversizedField = String.fromUtf8(Array<Byte>(
            api_model.DOC_IR_MAX_JSON_STRING_BYTES + 1, repeat: b'x'))
        let singleField = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo(oversizedField),
            api_model.ConfigurationSnapshot(lintProfile: "off"))
        let singleFallback = boundGeneratedDocumentation(singleField, request)
        @Expect(singleFallback.status, "partial")
        @Expect(singleFallback.project.name, "resource-limited")
        @Expect(singleFallback.diagnostics.size, 1)
        @Expect(singleFallback.diagnostics[0].code, "CJDOC3027")

        // One shared 1 MiB allocation expands to more than the 64 MiB output
        // artifact limit when encoded at each diagnostic occurrence.
        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'y'))
        let diagnostics = ArrayList<api_model.Diagnostic>()
        for (_ in 0..70) {
            diagnostics.add(api_model.Diagnostic("warning", "CJDOC3999", chunk))
        }
        let aggregate = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo("aggregate-budget"),
            api_model.ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        let aggregateFallback = boundGeneratedDocumentation(aggregate, request)
        @Expect(aggregateFallback.status, "partial")
        @Expect(aggregateFallback.project.name, "resource-limited")
        @Expect(aggregateFallback.diagnostics.size, 1)
        @Expect(aggregateFallback.diagnostics[0].code, "CJDOC3027")

        let small = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"),
            "partial", api_model.ProjectInfo("small"),
            api_model.ConfigurationSnapshot(lintProfile: "off"))
        @Expect(boundGeneratedDocumentation(small, request).project.name, "small")
    }
}
