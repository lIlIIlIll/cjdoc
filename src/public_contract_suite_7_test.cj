package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite7 {
    @TestCase
    func structuralMarkdownLeavesUseEmptyLiteral(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "markdown_leaf"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package markdown_leaf

                /**
                 * Summary.
                 *
                 * ---
                 */
                public func leaf(): Unit {}
                """
                    .toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(documentation.declarations.size, 1)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(markdownLiteral(comment.markdown, "thematic_break"), Some(""))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func duplicateSymbolsAreDeterministicallyPrunedAndPackageIdsRebuilt(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "duplicate", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        @Expect(publicHasDiagnostic(documentation, "CJDOC2006"))
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.packages.size, 1)
        @Expect(documentation.packages[0].symbolIds.size, 1)
        @Expect(documentation.packages[0].symbolIds[0], documentation.declarations[0].id)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func enumNonExhaustiveFlowsThroughProviderAndPublicProjection(): Unit {
        let capture = EnumFactCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "types", lintProfile: "off",
                providerFactories: [EnumFactFactory(capture)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(capture.sawEnum)
        @Expect(!capture.leakedToNonEnum)
        var sawPublicEnum = false
        for (declaration in documentation.declarations) {
            if (declaration.kind == "enum") {
                @Expect(declaration.enumNonExhaustive, Some(false))
                sawPublicEnum = true
            } else {
                @Expect(declaration.enumNonExhaustive.isNone())
            }
        }
        @Expect(sawPublicEnum)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func providerSourceViewPreservesParameterDefaultExpressions(): Unit {
        let capture = DefaultExpressionCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "frontend_regressions", lintProfile: "off",
                providerFactories: [DefaultExpressionFactory(capture)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(capture.sawDeclaration)
        @Expect(capture.required, None<String>)
        @Expect(capture.count, Some("40 + 2"))
        @Expect(capture.label, Some("\"cjdoc\""))
    }

    @TestCase
    func providerAnnotationsOverlaySourceFactsWithProvenance(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [AnnotationFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var checked = false
        for (declaration in documentation.declarations) {
            if (declaration.name != "oldParse") {
                continue
            }
            var hasSource = false
            var hasProvider = false
            for (annotation in declaration.annotations) {
                if (annotation.provenance == "source" && annotation.spelling.startsWith("@Deprecated")) {
                    hasSource = true
                }
                if (annotation.provenance == "provider" && annotation.spelling == "@ProviderMeta" &&
                    annotation.provider == Some("annotation-test")) {
                    hasProvider = true
                }
            }
            @Expect(hasSource)
            @Expect(hasProvider)
            checked = true
        }
        @Expect(checked)
    }

}
