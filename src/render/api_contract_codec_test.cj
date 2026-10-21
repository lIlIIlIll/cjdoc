package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let CODEC_TEST_MODULE = "cjdoc:module:v1:codec-test"
private func codecTestDeclaration(documentationFingerprint!: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"): ApiContractDeclaration {
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
    func rejectsInvalidFingerprintValues(): Unit {
        let encoded = encodeApiContractSnapshot(codecTestSnapshot(
            declarations: [codecTestDeclaration()]))
        let empty = encoded.replace(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(empty))
        let nonHex = encoded.replace(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(nonHex))
    }
    @TestCase
    func rejectsLegacyApiSurfaceVersions(): Unit {
        let v1 = "{\"schemaVersion\":\"cjdoc.api-surface/1\"}"
        let v2 = "{\"schemaVersion\":\"cjdoc.api-surface/2\"}"
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(v1))
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(v2))
    }

    @TestCase
    func strictCodecRejectsUnknownDuplicateAndDeepInputs(): Unit {
        let unknown = """
{"schemaVersion":"cjdoc.api-surface/3","project":"codec-test","audience":"external","cfgProfile":"default","collectionState":"resolved","declarations":[],"exposures":[],"extra":true}
"""
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(unknown))
        let duplicate = """
{"schemaVersion":"cjdoc.api-surface/3","schemaVersion":"cjdoc.api-surface/3","project":"codec-test","audience":"external","cfgProfile":"default","collectionState":"resolved","declarations":[],"exposures":[]}
"""
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(duplicate))
        let invalidAudience = unknown.replace("external", "team").replace(",\"extra\":true", "")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(invalidAudience))

        let deep = StringBuilder()
        deep.append("{\"schemaVersion\":\"cjdoc.api-surface/3\",\"project\":\"codec-test\",\"audience\":\"external\",\"cfgProfile\":\"default\",\"collectionState\":\"resolved\",\"declarations\":")
        var depth: Int64 = 0
        while (depth < 40) { deep.append("["); depth++ }
        deep.append("null")
        depth = 0
        while (depth < 40) { deep.append("]"); depth++ }
        deep.append(",\"exposures\":[]}")
        @ExpectThrows[IllegalArgumentException](decodeApiContractSnapshot(deep.toString()))
    }
}
