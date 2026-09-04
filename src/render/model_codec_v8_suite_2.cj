package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ModelCodecV8Suite2 {
    @TestCase
    func unavailableProviderCannotBackUsableDeclarationOrTypeSemantics(): Unit {
        let unavailableDeclaration = codecProviderDocument("provider", "version",
            providerState: "unavailable", declarationState: "unavailable")
        let encoded = encodeDocIr(unavailableDeclaration)
        @Expect(decodeDocIr(encoded).declarations[0].semantic.state, "unavailable")

        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", providerState: "unavailable",
                declarationState: "resolved")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecProviderDocument("provider", "version", canonicalSignature: Some("api(): Unit"),
                providerState: "unavailable", declarationState: "unavailable")))

        let resolvedType = TypeRef("semantic", "Known", SemanticType("resolved",
            canonical: Some("fixture.Known"), provider: Some("types")))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(
            resolvedType, canonicalTypes: true, typeProviderState: "unavailable")))

        // Ambiguous is intentionally not unavailable: it can retain a
        // non-authoritative spelling, but that spelling is never resolved.
        let ambiguousType = TypeRef("source", "Maybe", SemanticType("ambiguous",
            canonical: Some("fixture.Maybe"), provider: Some("types")))
        validateDocumentationSet(codecTypeDocument(ambiguousType, canonicalTypes: true,
            typeProviderState: "ambiguous"))
    }

    @TestCase
    func symbolRelationshipsRequireCapabilityExceptSourceFallback(): Unit {
        let typeRef = TypeRef("source", "Partial", SemanticType("partial", provider: Some("types")))
        let sourceFallback = SymbolRelationship("references", "missing", "unavailable")
        validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [sourceFallback]))

        let unavailableTarget = SymbolRelationship("references", "typed", "unavailable",
            targetSymbolId: Some(CODEC_TYPE_SYMBOL_ID))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [unavailableTarget])))

        let providerRelationship = SymbolRelationship("references", "candidate", "partial")
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [providerRelationship])))
        validateDocumentationSet(codecTypeDocument(typeRef,
            symbolRelationships: [providerRelationship], relationships: true))
    }

    @TestCase
    func recursiveDomainDepthIsExactAndCodecHasHeadroom(): Unit {
        let exactType = codecTypeDocument(codecNestedType(DOC_IR_MAX_TYPE_DEPTH))
        let typeJson = encodeDocIr(exactType)
        @Expect(decodeDocIr(typeJson).declarations.size, 1)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(codecNestedType(DOC_IR_MAX_TYPE_DEPTH + 1))))

        let exactMarkdown = codecMarkdownDocument(
            codecMarkdownAtDepth(DOC_IR_MAX_MARKDOWN_DEPTH))
        let markdownJson = encodeDocIr(exactMarkdown)
        @Expect(decodeDocIr(markdownJson).declarations.size, 1)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(codecMarkdownDocument(
            codecMarkdownAtDepth(DOC_IR_MAX_MARKDOWN_DEPTH + 1))))
    }

    @TestCase
    func sharedReferencesConsumeEncodedOccurrenceBudgets(): Unit {
        // Only 18 TypeRef objects are allocated, but binary sharing at 17
        // levels would serialize 262143 occurrences. Validation charges the
        // expansion that JSON will emit rather than unique object identity.
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecTypeDocument(codecSharedType(17))))

        // The same attack surface exists for MarkdownNode: 20 allocated nodes
        // (including document/paragraph) expand past the document-wide node and
        // edge limits and must fail before encoding.
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            codecMarkdownDocument(codecSharedMarkdown(17))))
    }

    @TestCase
    func encodedFieldAndOutputArtifactBudgetsAreClosed(): Unit {
        let oversizedField = String.fromUtf8(Array<Byte>(
            DOC_IR_MAX_JSON_STRING_BYTES + 1, repeat: b'x'))
        let singleField = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo(oversizedField), ConfigurationSnapshot(lintProfile: "off"))
        @Expect(!docIrFitsEncodedBudget(singleField, DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES))
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(singleField))

        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'y'))
        let diagnostics = ArrayList<Diagnostic>()
        for (_ in 0..24) {
            diagnostics.add(Diagnostic("warning", "CJDOC3999", chunk))
        }
        let aggregate = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("aggregate-budget"), ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        validateDocumentationSet(aggregate)
        @Expect(docIrFitsEncodedBudget(aggregate, DOC_IR_MAX_OUTPUT_ARTIFACT_BYTES))

        for (_ in 24..40) {
            diagnostics.add(Diagnostic("warning", "CJDOC3999", chunk))
        }
        let overDocumentBudget = DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial",
            ProjectInfo("aggregate-budget"), ConfigurationSnapshot(lintProfile: "off"),
            diagnostics: diagnostics.toArray())
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(overDocumentBudget))
    }

    @TestCase
    func frozenLegacySchemaIdsAndEmptyModuleProviderPolicy(): Unit {
        let frozenId = "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"
        @Expect(DOC_IR_V6_SCHEMA.contains(frozenId))
        @Expect(DOC_IR_V7_SCHEMA.contains(frozenId))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(V6_EMPTY_MODULE_PROVIDER_FIXTURE))
    }

    @TestCase
    func v6GlobalProviderMigrationPreflightsCartesianExpansion(): Unit {
        let migrated = decodeDocIr(codecV6ProviderMatrixJson(2, 1))
        @Expect(migrated.modules.size, 2)
        @Expect(migrated.providers.size, 2)
        @Expect(migrated.providers[0].moduleId != migrated.providers[1].moduleId)

        let error = @AssertThrows[IllegalArgumentException](
            decodeDocIr(codecV6ProviderMatrixJson(4096, 4096)))
        @Expect(error.message.contains("migration exceeds Doc IR occurrence/encoding budget"))
    }

    @TestCase
    func moduleSourcePrefixIsEmptyOrPortableRelativeAcrossDomainAndMigration(): Unit {
        validateDocumentationSet(codecModuleOnlyDocument(""))
        let encoded = encodeDocIr(codecModuleOnlyDocument("workspace/src"))
        @Expect(decodeDocIr(encoded).modules[0].sourcePrefix, "workspace/src")

        for (invalid in ["/absolute", "C:drive", "..", "../escape", "src/../escape",
            "src\\windows", "src//nested", "src/"]) {
            @ExpectThrows[IllegalArgumentException](ModuleDoc(
                "cjdoc:module:v1:invalid-prefix", "invalid-prefix", "root", invalid))
        }

        let invalidV8 = encoded.replace(
            "\"sourcePrefix\": \"workspace/src\"", "\"sourcePrefix\": \"../escape\"")
        @Expect(invalidV8 != encoded)
        let schemaError = @AssertThrows[IllegalArgumentException](decodeDocIr(invalidV8))
        @Expect(schemaError.message.contains("invalid Doc IR schema"))

        // Frozen v6 schema accepts this legacy spelling; migration must still
        // close it under the v8 typed domain before returning a document.
        @ExpectThrows[IllegalArgumentException](
            decodeDocIr(codecV6ProviderMatrixJson(1, 1, sourcePrefix: "../escape")))
    }

}
