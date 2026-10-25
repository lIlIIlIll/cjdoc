package cjdoc

import cjdoc.provider as api_provider
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite1 {
    @TestCase
    func sourceDeclarationIdsAreSessionLocal(): Unit {
        let firstIssuer = api_provider.SourceDeclarationIssuer()
        let secondIssuer = api_provider.SourceDeclarationIssuer()
        let first = firstIssuer.issue("same-text")
        let sameSession = firstIssuer.issue("same-text")
        let otherSession = secondIssuer.issue("same-text")
        @Expect(first == sameSession)
        @Expect(first != otherSession)
        @Expect(first.serialize() == otherSession.serialize())
        @Expect(firstIssuer.owns(first))
        @Expect(!firstIssuer.owns(otherSession))
    }

    @TestCase
    func missingAstWorkerSkipsSourceExplicitly(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off"))
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(publicHasDiagnostic(documentation, "CJDOC1020"))
    }

    @TestCase
    func generatedDocIrRoundTripsStrictly(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "standard",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/16")
        @Expect(documentation.declarations.size, 25)
        @Expect(documentation.files.size, 1)
        @Expect(documentation.declarations[0].source.start.byteOffset > 0)

        let encoded = api_render.encodeDocIr(documentation)
        @Expect(!encoded.contains("/home/"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let unknown = encoded.replace("\"schemaVersion\":", "\"unknown\":true,\"schemaVersion\":")
        @ExpectThrows(api_render.decodeDocIr(unknown))
        for (version in 6..16) {
            let unsupported = encoded.replace("cjdoc.doc-ir/16", "cjdoc.doc-ir/${version}")
            @Expect(unsupported != encoded)
            @ExpectThrows(api_render.decodeDocIr(unsupported))
        }
        let duplicate = encoded.replace("\"schemaVersion\": \"cjdoc.doc-ir/16\",",
            "\"schemaVersion\": \"cjdoc.doc-ir/16\", \"schemaVersion\": \"cjdoc.doc-ir/16\",")
        @ExpectThrows(api_render.decodeDocIr(duplicate))

        let missingProviderModule = encoded.replace(
            "      \"moduleId\": \"cjdoc:module:v1:root\",\n      \"state\": \"partial\",",
            "      \"state\": \"partial\",")
        @Expect(missingProviderModule != encoded)
        @ExpectThrows(api_render.decodeDocIr(missingProviderModule))

        let unknownOwner = encoded.replace("      \"ownerId\": null,", "      \"ownerId\": \"cjdoc:missing\",")
        @Expect(unknownOwner != encoded)
        @ExpectThrows(api_render.decodeDocIr(unknownOwner))
    }

}
