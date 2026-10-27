package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlExternalStatusTest {
    @TestCase
    func sharedIndexFailuresAreReportedOnceWithoutDroppingMemberLinks(): Unit {
        let moduleId = "cjdoc:module:v1:external-status"
        let prefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aexternal-status::fixture::"
        let ownerId = prefix + "class:Box#g0()"
        let firstId = prefix + "Box::function:first#g0()"
        let secondId = prefix + "Box::function:second#g0()"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
        let semantic = SemanticInfo("partial", "ast")
        let owner = SymbolDoc(ownerId, "class", "Box", "fixture.Box", "fixture", moduleId,
            "public", source, "public class Box", semantic)
        let first = SymbolDoc(firstId, "function", "first", "fixture.Box.first", "fixture", moduleId,
            "public", source, "public func first(): Unit", semantic, ownerId: Some(ownerId))
        let second = SymbolDoc(secondId, "function", "second", "fixture.Box.second", "fixture", moduleId,
            "public", source, "public func second(): Unit", semantic, ownerId: Some(ownerId))
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("library"),
            ConfigurationSnapshot(lintProfile: "off"),
            providers: [ProviderInfo("ast", "builtin", moduleId, "partial", SemanticCapabilities(false, false, false, false, false))],
            modules: [ModuleDoc(moduleId, "library", "root", "", packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [ownerId, firstId, secondId])],
            files: [FileDoc("src/api.cj", moduleId, "fixture")], declarations: [owner, first, second],
            externalDocumentation: [
                ExternalDocumentationReference(firstId, "support", "unavailable", "", reason: "Shared dependency index failure", index: "docs/support.json"),
                ExternalDocumentationReference(secondId, "support", "unavailable", "", reason: "Shared dependency index failure", index: "docs/support.json"),
                ExternalDocumentationReference(secondId, "other", "ambiguous", "", reason: "Distinct ambiguity"),
                ExternalDocumentationReference(firstId, "available", "available", "https://docs.example.test/first.html")])
        let original = encodeDocIr(documentation)
        var checked = false
        for (artifact in rendererFor("html").render(decodeDocIr(original))) {
            if (!artifact.path.startsWith("html/symbols/") || !artifact.content.contains("<code>Box</code></h1>")) { continue }
            let html = artifact.content
            @Expect(html.split("Shared dependency index failure").size, 2)
            @Expect(html.split("Distinct ambiguity").size, 2)
            @Expect(html.split("id=\"external-reference-status\"").size, 2)
            @Expect(!html.contains("href=\"#external-reference-status\""))
            @Expect(html.contains("href=\"https://docs.example.test/first.html\""))
            @Expect(html.contains("public func first()"))
            @Expect(html.contains("public func second()"))
            checked = true
        }
        @Expect(checked)
        @Expect(encodeDocIr(documentation), original)
    }
}
