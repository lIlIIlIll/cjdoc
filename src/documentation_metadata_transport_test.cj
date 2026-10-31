package cjdoc

import cjdoc.model as api_model
import std.unittest.*
import std.unittest.testmacro.*

private func metadataTransportFixture(): api_model.DocumentationSet {
    let metadata = api_model.DocumentationMetadata(
        groups: [api_model.DocumentationGroupDefinition("cjdoc:module:v1:transport", "fixture",
            "20-query", "Query", titles: [api_model.DocumentationTitle("en", "Query")], order: Some(20))],
        tags: [api_model.DocumentationTagDefinition("cjdoc:module:v1:transport", "stream", "Stream",
            titles: [api_model.DocumentationTitle("zh-CN", "流式")])])
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "partial",
        api_model.ProjectInfo("metadata-transport"), api_model.ConfigurationSnapshot(
            audience: "external", lintProfile: "off"), metadata: metadata,
        modules: [api_model.ModuleDoc("cjdoc:module:v1:transport", "metadata-transport", "root", "",
            packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", "cjdoc:module:v1:transport")])
}

@Test
class DocumentationMetadataTransportTest {
    @TestCase
    func hardResourceFallbackIntentionallyDropsMetadata(): Unit {
        let original = metadataTransportFixture()
        let fallback = boundGeneratedDocumentation(original,
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off"), force: true)
        @Expect(fallback.status, "partial")
        @Expect(fallback.metadata.groups.isEmpty(), true)
        @Expect(fallback.metadata.tags.isEmpty(), true)
        var preservedDiagnostic = false
        for (diagnostic in fallback.diagnostics where diagnostic.code == "CJDOC3027") {
            preservedDiagnostic = true
        }
        @Expect(preservedDiagnostic)
    }
}
