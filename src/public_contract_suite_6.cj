package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite6 {
    @TestCase
    func crossModuleProviderDiagnosticIsDetachedAtItsOriginModule(): Unit {
        let capture = CrossModuleDiagnosticCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
                providerFactories: [CrossModuleDiagnosticFactory(capture)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(capture.firstModuleSymbolId.isSome())
        @Expect(publicDiagnosticCount(documentation, "CJDOC2017"), 1)
        @Expect(publicDiagnosticCount(documentation, "CJDOC2999"), 1)
        var retainedDetached = false
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.message, "cross-module diagnostic identity")
                @Expect(diagnostic.symbolId.isNone())
                retainedDetached = true
            }
        }
        @Expect(retainedDetached)
        var resolvedProviders: Int64 = 0
        var partialProviders: Int64 = 0
        for (provider in documentation.providers) {
            if (provider.state == "resolved") {
                resolvedProviders++
            }
            if (provider.state == "partial") {
                partialProviders++
            }
        }
        @Expect(resolvedProviders, 1)
        @Expect(partialProviders, 1)
        @Expect(documentation.status, "partial")
    }

    @TestCase
    func diagnosticOrderingIsIndependentOfProviderInsertionOrder(): Unit {
        let capture = AlternatingDiagnosticCapture()
        let factory = AlternatingDiagnosticFactory(capture)
        let first = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let second = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(api_render.encodeDocIr(second), api_render.encodeDocIr(first))
        let ordered = ArrayList<String>()
        for (diagnostic in first.diagnostics) {
            if (diagnostic.code == "CJDOC2998") {
                ordered.add("${diagnostic.severity}:${diagnostic.message}")
            }
        }
        @Expect(ordered.size, 3)
        @Expect(ordered[0], "error:same")
        @Expect(ordered[1], "warning:alpha")
        @Expect(ordered[2], "warning:zeta")
    }

    @TestCase
    func recursiveTypeRelationshipOrderIsIndependentOfProviderInsertionOrder(): Unit {
        let capture = AlternatingTypeRelationshipCapture()
        let factory = AlternatingTypeRelationshipFactory(capture)
        let first = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let second = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(api_render.encodeDocIr(second), api_render.encodeDocIr(first))
        let ordered = ArrayList<api_model.TypeRef>()
        for (declaration in first.declarations) {
            for (relationship in declaration.typeRelationships) {
                if (relationship.kind == "ordering") {
                    ordered.add(relationship.target)
                }
            }
        }
        @Expect(ordered.size, 4)
        @Expect(ordered[0].kind, "semantic")
        @Expect(!ordered[0].nullable)
        @Expect(ordered[0].arguments[0].spelling, "A")
        @Expect(ordered[1].kind, "semantic")
        @Expect(!ordered[1].nullable)
        @Expect(ordered[1].arguments[0].spelling, "B")
        @Expect(ordered[2].kind, "semantic")
        @Expect(ordered[2].nullable)
        @Expect(ordered[2].arguments[0].spelling, "A")
        @Expect(ordered[3].kind, "source")
        @Expect(!ordered[3].nullable)
        @Expect(ordered[3].arguments[0].spelling, "A")
    }

    @TestCase
    func diagnosticTotalOrderIncludesFullRangeAndOptionalSymbolIdentity(): Unit {
        let documentation = DocumentationSet("diagnostic-order")
        let earlierEnd = SourceLocation("src/api.cj", 1, 1, 1, 2)
        let laterEnd = SourceLocation("src/api.cj", 1, 1, 1, 3)
        let laterEndLine = SourceLocation("src/api.cj", 1, 1, 2, 1)
        let laterStart = SourceLocation("src/api.cj", 1, 2, 1, 2)
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterEnd, symbolId: Some("b")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", symbolId: Some("b")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: earlierEnd, symbolId: Some("z")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same"))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", symbolId: Some("a")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterStart))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterEndLine))
        sortDocumentationDeterministically(documentation)
        @Expect(documentation.diagnostics[0].symbolId.isNone())
        @Expect(documentation.diagnostics[1].symbolId, Some("a"))
        @Expect(documentation.diagnostics[2].symbolId, Some("b"))
        @Expect(documentation.diagnostics[3].source.getOrThrow().endColumn, 2)
        @Expect(documentation.diagnostics[4].source.getOrThrow().endColumn, 3)
        @Expect(documentation.diagnostics[5].source.getOrThrow().endLine, 2)
        @Expect(documentation.diagnostics[6].source.getOrThrow().startColumn, 2)
    }

    @TestCase
    func capturedSourceOffsetsSurviveProviderSideFileMutation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "captured_source"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            File.writeTo(sourcePath,
                """
                package captured_source

                /** Captured source location. */
                public func stable(): Unit {}
                """
                    .toArray())
            let capture = SourceMutationCapture()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    providerFactories: [SourceMutationFactory(sourcePath.toString(), capture)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(capture.startOffset > 0)
            @Expect(capture.endOffset > capture.startOffset)
            @Expect(documentation.declarations.size, 1)
            @Expect(documentation.declarations[0].source.start.byteOffset, capture.startOffset)
            @Expect(documentation.declarations[0].source.end.byteOffset, capture.endOffset)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }


}
