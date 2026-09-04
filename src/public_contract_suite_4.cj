package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite4 {
    @TestCase
    func providerIdentityIsReadOnceAndHostileExceptionsStayInModuleFallback(): Unit {
        let stableCapture = HostileProviderCapture()
        let stableFactory = HostileProviderFactory("valid", stableCapture)
        let stableRequest = GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
            providerFactories: [stableFactory], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
        @Expect(stableCapture.nameReads, 0)
        @Expect(stableCapture.versionReads, 0)
        let stable = DocumentationEngine().generate(stableRequest)
        @Expect(stableCapture.nameReads, 1)
        @Expect(stableCapture.versionReads, 1)
        @Expect(stableCapture.opened, 2)
        @Expect(stableCapture.analyzed, 2)
        @Expect(stableCapture.closed, 2)
        @Expect(!publicHasDiagnostic(stable, "CJDOC2001"))

        for (mode in ["name-throws", "version-throws", "blank-name", "blank-version", "huge-name", "huge-version",
            "open-throws", "analyze-throws", "close-throws"]) {
            let capture = HostileProviderCapture()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                    providerFactories: [HostileProviderFactory(mode, capture)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(capture.nameReads, 1)
            @Expect(capture.versionReads, 1)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(documentation.providers[0].state, "unavailable")
            @Expect(documentation.declarations.size, 25)
            if (mode == "name-throws" || mode == "version-throws" || mode == "blank-name" || mode == "blank-version" ||
                mode == "huge-name" || mode == "huge-version") {
                @Expect(capture.opened, 0)
                @Expect(capture.analyzed, 0)
                @Expect(capture.closed, 0)
            } else if (mode == "open-throws") {
                @Expect(capture.opened, 1)
                @Expect(capture.analyzed, 0)
                @Expect(capture.closed, 0)
            } else {
                @Expect(capture.opened, 1)
                @Expect(capture.analyzed, 1)
                @Expect(capture.closed, 1)
            }
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC2001") {
                    @Expect(diagnostic.message.size < 512)
                    @Expect(!diagnostic.message.contains("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
                }
            }
        }
    }

    @TestCase
    func generationRequestNormalizesCfgValuesAtConstruction(): Unit {
        let request = GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic",
            cfgValues: [
                CfgValue("target", "x86_64"),
                CfgValue("os", "linux"),
                CfgValue("target", "x86_64")
            ]
        )
        @Expect(request.cfgValues.size, 2)
        @Expect(request.cfgValues[0].name, "os")
        @Expect(request.cfgValues[0].value, "linux")
        @Expect(request.cfgValues[1].name, "target")
        @Expect(request.cfgValues[1].value, "x86_64")
        @ExpectThrows[IllegalArgumentException](GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", cfgValues: [
                CfgValue("os", "linux"), CfgValue("os", "windows")
            ]))
    }

    @TestCase
    func remappedLintWarningsDoNotMarkSourceStatusPartial(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "lint", lintProfile: "standard",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3001"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3008"))
        @Expect(documentation.status, "complete")
    }

    @TestCase
    func finalSemanticStatesDriveProviderAndDocumentStatus(): Unit {
        let partial = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("partial")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(partial.providers[0].state, "partial")
        @Expect(partial.status, "complete")
        for (declaration in partial.declarations) {
            @Expect(declaration.semantic.state, "partial")
        }
        let partialEncoded = api_render.encodeDocIr(partial)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(partialEncoded)), partialEncoded)

        let unavailable = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("unavailable")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(unavailable.providers[0].state, "unavailable")
        @Expect(unavailable.status, "partial")
        for (declaration in unavailable.declarations) {
            @Expect(declaration.semantic.state, "unavailable")
        }
        let unavailableEncoded = api_render.encodeDocIr(unavailable)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(unavailableEncoded)), unavailableEncoded)

        let ambiguous = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("ambiguous")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(ambiguous.providers[0].state, "ambiguous")
        @Expect(ambiguous.status, "partial")
        for (declaration in ambiguous.declarations) {
            @Expect(declaration.semantic.state, "ambiguous")
        }
        let ambiguousEncoded = api_render.encodeDocIr(ambiguous)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(ambiguousEncoded)), ambiguousEncoded)
    }

    @TestCase
    func implicitNestedTypeProviderIsNormalizedToCurrentFactory(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [ImplicitTypeProviderFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        var sawNestedType = false
        for (declaration in documentation.declarations) {
            if (let Some(typeRef) <- declaration.returnType) {
                if (typeRef.arguments.isEmpty()) {
                    continue
                }
                @Expect(typeRef.semantic.provider, Some("implicit-type-provider-test"))
                @Expect(typeRef.arguments[0].semantic.provider,
                    Some("implicit-type-provider-test"))
                sawNestedType = true
            }
        }
        @Expect(sawNestedType)
    }


}
