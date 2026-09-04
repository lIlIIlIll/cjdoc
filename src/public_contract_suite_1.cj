package cjdoc

import cjdoc.provider as api_provider
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
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
    func generatedDocIrRoundTripsStrictly(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "standard",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/8")
        @Expect(documentation.declarations.size, 25)
        @Expect(documentation.files.size, 1)
        @Expect(documentation.declarations[0].source.start.byteOffset > 0)

        let encoded = api_render.encodeDocIr(documentation)
        @Expect(!encoded.contains("/home/"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let unknown = encoded.replace("\"schemaVersion\":", "\"unknown\":true,\"schemaVersion\":")
        @ExpectThrows(api_render.decodeDocIr(unknown))
        let duplicate = encoded.replace("\"schemaVersion\": \"cjdoc.doc-ir/8\",",
            "\"schemaVersion\": \"cjdoc.doc-ir/8\", \"schemaVersion\": \"cjdoc.doc-ir/8\",")
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

    @TestCase
    func strictV6InputMigratesOnlyWithUniquePackageModuleMapping(): Unit {
        let path = Path("tests/fixtures/golden-v6/basic.docs.json")
        let legacy = String.fromUtf8(File.readFrom(path))
        let migrated = api_render.decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, "cjdoc.doc-ir/8")
        @Expect(migrated.providers.size, 1)
        @Expect(migrated.providers[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].id.startsWith(
            "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::"))
        @Expect(migrated.packages[0].symbolIds[0], migrated.declarations[0].id)
        var migratedAnnotation = false
        var migratedReference = false
        for (declaration in migrated.declarations) {
            if (let Some(ownerId) <- declaration.ownerId) {
                @Expect(ownerId.startsWith("cjdoc:v2:"))
            }
            for (relationship in declaration.symbolRelationships) {
                if (let Some(targetId) <- relationship.targetSymbolId) {
                    @Expect(targetId.startsWith("cjdoc:v2:"))
                    migratedReference = true
                }
            }
            if (let Some(documentation) <- declaration.documentation) {
                for (tag in documentation.tags) {
                    if (let Some(targetId) <- tag.targetSymbolId) {
                        @Expect(targetId.startsWith("cjdoc:v2:"))
                        migratedReference = true
                    }
                }
            }
            for (annotation in declaration.annotations) {
                @Expect(annotation.provenance, "source")
                @Expect(annotation.provider.isNone())
                migratedAnnotation = true
            }
        }
        @Expect(migratedAnnotation)
        @Expect(migratedReference)

        let ambiguous = legacy.replace("  \"modules\": [\n    {",
            "  \"modules\": [\n" + "    {\"id\":\"cjdoc:module:v1:other\",\"name\":\"other\"," +
                "\"role\":\"workspace\",\"sourcePrefix\":\"other\"," +
                "\"packageNames\":[\"basic\"],\"dependencyIds\":[]},\n    {")
        @Expect(ambiguous != legacy)
        @ExpectThrows(api_render.decodeDocIr(ambiguous))
    }


}
