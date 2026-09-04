package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_algorithms.*

@Test
class ModelCodecV8Suite1 {
    @TestCase
    func sha256MatchesPublishedVectors(): Unit {
        @Expect(docIrSha256Bytes([]),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        @Expect(docIrSha256Bytes("abc".toArray()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @TestCase
    func v7MigrationRekeysAssetsAndAddsV8Fields(): Unit {
        let migrated = decodeDocIr(V7_CODEC_FIXTURE)
        let assetId = "sha256-1e85ec81b9800b4c443d39caca0d0926089a3ac201120db1ceb45b93789480b8"
        @Expect(migrated.schemaVersion, DOC_IR_SCHEMA_VERSION)
        @Expect(migrated.assets[0].id, assetId)
        let comment = migrated.declarations[0].documentation.getOrThrow()
        @Expect(comment.markdown.children[0].children[0].literal, assetId)
        @Expect(comment.markdown.children[0].metadata.isNone())
        @Expect(migrated.declarations[0].enumNonExhaustive.isNone())
        let encoded = encodeDocIr(migrated)
        @Expect(encoded.contains("\"schemaVersion\": \"cjdoc.doc-ir/8\""))
        @Expect(encoded.contains("\"metadata\": null"))
        @Expect(encoded.contains("\"enumNonExhaustive\": null"))
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        let dangling = encoded.replace("\"macroSymbolId\": null",
            "\"macroSymbolId\": \"cjdoc:v2:missing\"")
        @Expect(dangling != encoded)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(dangling))
    }

    @TestCase
    func denseDagIsLinearAndCyclesStillFail(): Unit {
        // Complete DAG: 64 vertices and 64*63/2 = 2016 edges. The old path-recursive
        // validator expands roughly 2^62 paths from vertex zero; tri-color visits each edge once.
        let dense = codecDenseDag(64)
        validateDocumentationSet(dense)
        @Expect(dense.modules.size, 64)

        let capabilities = SemanticCapabilities(false, false, false, false, false)
        let firstId = "cjdoc:module:v1:cycle-a"
        let secondId = "cjdoc:module:v1:cycle-b"
        let cyclic = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("cycle"), ConfigurationSnapshot(lintProfile: "off"), providers: [
                ProviderInfo("ast", "builtin", firstId, "partial", capabilities),
                ProviderInfo("ast", "builtin", secondId, "partial", capabilities)
            ], modules: [
                ModuleDoc(firstId, "a", "root", "", dependencyIds: [secondId]),
                ModuleDoc(secondId, "b", "workspace", "", dependencyIds: [firstId])
            ])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(cyclic))
    }

    @TestCase
    func strictJsonStringLimitCoversSixteenMiBAssetEncoding(): Unit {
        // Base64 for a 16 MiB asset is 22,369,624 bytes; exercise the exact 24 MiB parser limit.
        let payload = String.fromUtf8(Array<Byte>(24 * 1024 * 1024, repeat: b'a'))
        let decoded = decodeDocIr(codecEmptyJson(payload))
        @Expect(decoded.project.name.size, 24 * 1024 * 1024)
    }

    @TestCase
    func strictJsonStringLimitRejectsOneByteOverBoundary(): Unit {
        let payload = String.fromUtf8(Array<Byte>(24 * 1024 * 1024 + 1, repeat: b'a'))
        @ExpectThrows(decodeDocIr(codecEmptyJson(payload)))
    }

    @TestCase
    func schemaStringLengthCountsUnicodeScalars(): Unit {
        let schema = JsonSchema.parse("{\"type\":\"string\",\"minLength\":2,\"maxLength\":2}")
        @Expect(schema.validate(JsonStringValue("éa")).isEmpty())
        @Expect(!schema.validate(JsonStringValue("é")).isEmpty())
        @Expect(!schema.validate(JsonStringValue("éab")).isEmpty())
    }

    @TestCase
    func largeDefaultHeapCodeBlockShapeRoundTripsAndOverBudgetShapeRejects(): Unit {
        let codeBlock = MarkdownNode("code_block",
            MarkdownNodeMetadata.forCodeBlock("indented", None<String>, 0, "", "", ""),
            literal: "code")
        let children = ArrayList<MarkdownNode>()
        // Each block contributes both a Markdown and metadata object. This
        // stays close to the 32 MiB conservative encoding census while leaving
        // room for the fixed document envelope.
        for (_ in 0..23000) { children.add(codeBlock) }
        let encoded = encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: children.toArray())))
        @Expect(encoded.size < DOC_IR_MAX_JSON_DOCUMENT_BYTES)

        let decoded = decodeDocIr(encoded)
        @Expect(decoded.declarations[0].documentation.getOrThrow()
            .markdown.children.size, 23000)

        for (_ in 23000..24000) { children.add(codeBlock) }
        @ExpectThrows[IllegalArgumentException](encodeDocIr(codecMarkdownDocument(
            MarkdownNode("document", children: children.toArray()))))
    }

    @TestCase
    func semanticTypeCorrelationIsClosedInDomainAndSchema(): Unit {
        let unavailable = TypeRef("source", "Unknown", SemanticType("unavailable"))
        let unavailableJson = encodeDocIr(codecTypeDocument(unavailable))
        @Expect(decodeDocIr(unavailableJson).declarations.size, 1)

        let resolved = TypeRef("semantic", "Known", SemanticType("resolved",
            canonical: Some("fixture.Known"), provider: Some("types")))
        let resolvedJson = encodeDocIr(codecTypeDocument(resolved, canonicalTypes: true))
        @Expect(decodeDocIr(resolvedJson).declarations.size, 1)

        let missingProvider = TypeRef("source", "Partial", SemanticType("partial"))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(missingProvider)))
        let unavailableProvider = TypeRef("source", "Unknown", SemanticType("unavailable",
            provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(unavailableProvider)))
        let unavailableCanonical = TypeRef("source", "Unknown", SemanticType("unavailable",
            canonical: Some("fixture.Unknown"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(unavailableCanonical, canonicalTypes: true)))
        let emptyCanonical = TypeRef("semantic", "Known", SemanticType("partial",
            canonical: Some(""), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(emptyCanonical, canonicalTypes: true)))
        let blankCanonical = TypeRef("semantic", "Known", SemanticType("partial",
            canonical: Some(" \t"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(blankCanonical, canonicalTypes: true)))

        let emptyCanonicalJson = resolvedJson.replace(
            "\"canonical\": \"fixture.Known\"", "\"canonical\": \"\"")
        @Expect(emptyCanonicalJson != resolvedJson)
        let canonicalError = @AssertThrows[IllegalArgumentException](decodeDocIr(emptyCanonicalJson))
        @Expect(canonicalError.message.contains("invalid Doc IR schema"))
        let blankCanonicalJson = resolvedJson.replace(
            "\"canonical\": \"fixture.Known\"", "\"canonical\": \"   \"")
        @Expect(blankCanonicalJson != resolvedJson)
        let blankCanonicalError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(blankCanonicalJson))
        @Expect(blankCanonicalError.message.contains("invalid Doc IR schema"))

        let partial = TypeRef("source", "Partial", SemanticType("partial", provider: Some("types")))
        let partialJson = encodeDocIr(codecTypeDocument(partial))
        let missingProviderJson = partialJson.replace(
            "\"provider\": \"types\"", "\"provider\": null")
        @Expect(missingProviderJson != partialJson)
        let providerError = @AssertThrows[IllegalArgumentException](decodeDocIr(missingProviderJson))
        @Expect(providerError.message.contains("invalid Doc IR schema"))

        let unavailableCanonicalJson = unavailableJson.replace(
            "\"canonical\": null", "\"canonical\": \"fixture.Unknown\"")
        @Expect(unavailableCanonicalJson != unavailableJson)
        let unavailableError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(unavailableCanonicalJson))
        @Expect(unavailableError.message.contains("invalid Doc IR schema"))
        let unavailableProviderJson = unavailableJson.replace(
            "\"provider\": null", "\"provider\": \"types\"")
        @Expect(unavailableProviderJson != unavailableJson)
        let unavailableProviderError = @AssertThrows[IllegalArgumentException](
            decodeDocIr(unavailableProviderJson))
        @Expect(unavailableProviderError.message.contains("invalid Doc IR schema"))
    }

}
