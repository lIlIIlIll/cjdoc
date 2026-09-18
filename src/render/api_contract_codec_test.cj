package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let CODEC_TEST_MODULE = "cjdoc:module:v1:codec-test"

private func codecTestDeclaration(documentationFingerprint!: String = "a"): ApiContractDeclaration {
    ApiContractDeclaration("cjdoc:v2:codec-test", CODEC_TEST_MODULE, "fixture", "function", "api",
        "fixture.api", "public", "resolved", sourceApiSignature: ["public", "func", "api"],
        returnState: "resolved", returnType: Some("String"),
        documentationFingerprint: documentationFingerprint,
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}

private func codecTestSnapshot(declarations!: Array<ApiContractDeclaration> = [],
    exposures!: Array<ApiContractExposure> = []): ApiContractSnapshot {
    ApiContractSnapshot("codec-test", "external", "default", declarations: declarations,
        exposures: exposures)
}

@Test
class ApiContractCodecTest {
    @TestCase
    func hostileStringsRoundTripThroughRendererCodec(): Unit {
        let hostileName = "quote\\slash\ncontrol\t文字"
        let snapshot = codecTestSnapshot(
            declarations: [codecTestDeclaration()],
            exposures: [ApiContractExposure("exp", CODEC_TEST_MODULE, "fixture", hostileName,
                ["cjdoc:v2:codec-test\"target"], state: "resolved")])
        let encoded = encodeApiContractSnapshot(snapshot)
        let decoded = decodeApiContractSnapshot(encoded)
        @Expect(decoded.exposures.size, 1)
        @Expect(decoded.exposures[0].exposedName, hostileName)
        @Expect(decoded.exposures[0].targetIds[0], "cjdoc:v2:codec-test\"target")
        @Expect(decoded.declarations[0].returnType, Some("String"))
    }

    @TestCase
    func legacyExposureNamesMigrateToV2Fields(): Unit {
        let legacy = """
{"schemaVersion":"cjdoc.api-surface/1","project":"codec-test","audience":"external","declarations":[{"id":"decl","moduleId":"cjdoc:module:v1:codec-test","packageName":"fixture","ownerId":null,"kind":"function","name":"api","visibility":"public","sourceApiSignature":{"state":"available","tokens":["public","func"]}}],"exposures":[{"reExportId":"exp","moduleId":"cjdoc:module:v1:codec-test","packageName":"fixture","exposedName":"api","targetSymbolIds":["decl"]}]}
"""
        let decoded = decodeApiContractSnapshot(legacy)
        @Expect(decoded.exposures.size, 1)
        @Expect(decoded.exposures[0].id, "exp")
        @Expect(decoded.exposures[0].targetIds[0], "decl")
        @Expect(decoded.exposures[0].state, "unavailable")
        let invalidSignature = legacy.replace("\"available\"", "\"partial\"")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(invalidSignature))
    }

    @TestCase
    func strictCodecRejectsUnknownDuplicateAndDeepInputs(): Unit {
        let unknown = """
{"schemaVersion":"cjdoc.api-surface/2","project":"codec-test","audience":"external","cfgProfile":"default","collectionState":"resolved","declarations":[],"exposures":[],"extra":true}
"""
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(unknown))
        let duplicate = """
{"schemaVersion":"cjdoc.api-surface/2","schemaVersion":"cjdoc.api-surface/2","project":"codec-test","audience":"external","cfgProfile":"default","collectionState":"resolved","declarations":[],"exposures":[]}
"""
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(duplicate))
        let deep = StringBuilder()
        deep.append("{\"schemaVersion\":\"cjdoc.api-surface/2\",\"project\":\"codec-test\",\"audience\":\"external\",\"cfgProfile\":\"default\",\"collectionState\":\"resolved\",\"declarations\":")
        var depth: Int64 = 0
        while (depth < 40) { deep.append("["); depth++ }
        deep.append("null")
        depth = 0
        while (depth < 40) { deep.append("]"); depth++ }
        deep.append(",\"exposures\":[]}")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(deep.toString()))
    }
}