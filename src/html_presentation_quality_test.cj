package cjdoc

import cjdoc.render as api_render
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlPresentationQualityTest {
    @TestCase
    func qualityWarningsRemainSeparateFromPresenceCoverage(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest("tests/fixtures/projects/documentation_quality",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3040"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3041"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3042"))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/8")
        let artifacts = api_render.DocumentationCoverageRenderer().render(documentation)
        let presence = artifactContent(artifacts, "coverage/coverage.json")
        let quality = artifactContent(artifacts, "coverage/quality.json")
        @Expect(presence.contains("cjdoc.documentation-coverage/1"))
        @Expect(quality.contains("cjdoc.documentation-quality/1"))
        @Expect(quality.contains("\"meaningful\": 1"))
        @Expect(!quality.contains("hidden"))
        let off = DocumentationEngine().generate(
            GenerationRequest("tests/fixtures/projects/documentation_quality", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(off, "CJDOC3040"))
        @Expect(!publicHasDiagnostic(off, "CJDOC3041"))
        @Expect(!publicHasDiagnostic(off, "CJDOC3042"))
    }

    @TestCase
    func htmlOffersGroupsAndKeepsMetadataCollapsed(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest("tests/fixtures/projects/documentation_quality",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        let index = artifactContent(artifacts, "html/index.html")
        @Expect(index.contains("API overview"))
        @Expect(!index.contains("visible declarations</p>"))
        @Expect(!index.contains("top-source-disabled"))
        var packageHtml = ""
        for (artifact in artifacts) {
            if (artifact.path.startsWith("html/packages/")) { packageHtml += artifact.content }
        }
        @Expect(packageHtml.contains("id=\"functions\""))
        @Expect(packageHtml.contains("<details class=\"declaration-metadata\"><summary>"))
        @Expect(!packageHtml.contains("<details class=\"declaration-metadata\" open"))
        @Expect(packageHtml.contains("semantic: partial"))
        @Expect(packageHtml.contains("<details class=\"package-sources\">"))
        @Expect(packageHtml.contains("&lt;script&gt;"))
        @Expect(!packageHtml.contains("<script>alert"))
    }
    @TestCase
    func reexportsRemainAvailableWithoutDominatingThePackage(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            "tests/fixtures/projects/reexports", includePathDependencies: true,
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let html = renderedContent(api_render.HtmlDocumentationRenderer().render(documentation))
        @Expect(html.contains("<details class=\"reexports\"><summary"))
        @Expect(!html.contains("<details class=\"reexports\" open"))
        @Expect(html.contains("data-cjdoc-toc-role=\"group\""))
    }

}
