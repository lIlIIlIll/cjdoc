package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCodecV8Suite4 {
    @TestCase
    func providerIdentityCanonicalSignatureAndPortablePathAreClosed(): Unit {
        validateDocumentationSet(codecProviderDocument("provider", "version",
            canonicalSignature: Some("fixture.api(): Unit")))
        let exactIdentity = String.fromUtf8(Array<Byte>(
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES, repeat: b'p'))
        let exactIdentityRoundTrip = decodeDocIr(encodeDocIr(
            codecProviderDocument(exactIdentity, exactIdentity)))
        @Expect(exactIdentityRoundTrip.providers[0].name.size,
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES)
        @Expect(exactIdentityRoundTrip.providers[0].version.size,
            DOC_IR_MAX_PROVIDER_IDENTITY_BYTES)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument(" \t", "version")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", " \n")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument(String.fromUtf8(Array<Byte>(
                DOC_IR_MAX_PROVIDER_IDENTITY_BYTES + 1, repeat: b'p')), "version")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", String.fromUtf8(Array<Byte>(
                DOC_IR_MAX_PROVIDER_IDENTITY_BYTES + 1, repeat: b'v')))))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", canonicalSignature: Some("  \t"))))

        let providerJson = encodeDocIr(codecProviderDocument("provider", "version",
            canonicalSignature: Some("fixture.api(): Unit")))
        let blankSignature = providerJson.replace("fixture.api(): Unit", "   ")
        let signatureError = @AssertThrows[IllegalArgumentException](decodeDocIr(blankSignature))
        @Expect(signatureError.message.contains("invalid Doc IR schema"))
        let blankVersion = providerJson.replace("\"version\": \"version\"",
            "\"version\": \"   \"")
        let versionError = @AssertThrows[IllegalArgumentException](decodeDocIr(blankVersion))
        @Expect(versionError.message.contains("invalid Doc IR schema"))

        let invalidSegment = providerJson.replace("src/provider.cj", "src/../provider.cj")
        let pathError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidSegment))
        @Expect(pathError.message.contains("invalid Doc IR schema"))
        let emptySegment = providerJson.replace("src/provider.cj", "src//provider.cj")
        let emptySegmentError = @AssertThrows[IllegalArgumentException](decodeDocIr(emptySegment))
        @Expect(emptySegmentError.message.contains("invalid Doc IR schema"))
        let hiddenSegment = providerJson.replace("src/provider.cj", "src/.hidden/provider.cj")
        @Expect(decodeDocIr(hiddenSegment).files[0].path, "src/.hidden/provider.cj")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", path: "C:provider.cj")))
        let drivePrefix = providerJson.replace("src/provider.cj", "C:provider.cj")
        let drivePrefixError = @AssertThrows[IllegalArgumentException](decodeDocIr(drivePrefix))
        @Expect(drivePrefixError.message.contains("invalid Doc IR schema"))
        validateDocumentationSet(codecProviderDocument(
            "provider", "version", path: "1:provider.cj"))
        @Expect(decodeDocIr(providerJson.replace("src/provider.cj", "1:provider.cj"))
            .files[0].path, "1:provider.cj")

        // Frozen v7 accepts the historical loose shape declaratively, but the
        // v8 migration must still fail closed in the final domain validator.
        let legacyBlankProvider = V7_CODEC_FIXTURE.replace(
            "\"name\": \"ast\"", "\"name\": \"   \"")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(legacyBlankProvider))
    }

    @TestCase
    func schemaAssociatesMetadataWithMarkdownKind(): Unit {
        let heading = MarkdownNode("document", children: [MarkdownNode("heading",
            MarkdownNodeMetadata.forHeading(2), children: [MarkdownNode("text", literal: "topic")])])
        let encoded = encodeDocIr(codecMarkdownDocument(heading))
        let wrongMetadata = encoded.replace("\"level\": 2",
            "\"listKind\": \"bullet\", \"start\": 0, \"delimiter\": \"none\", \"tight\": true")
        @Expect(wrongMetadata != encoded)
        let error = @AssertThrows[IllegalArgumentException](decodeDocIr(wrongMetadata))
        @Expect(error.message.contains("invalid Doc IR schema"))
    }


}
