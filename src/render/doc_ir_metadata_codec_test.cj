package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let DOC_IR_METADATA_TEST_MODULE = "cjdoc:module:v1:metadata-transport"
private let DOC_IR_METADATA_TEST_OWNER =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ametadata-transport::fixture::class:Catalog#g0()"
private let DOC_IR_METADATA_TEST_VISIBLE =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ametadata-transport::fixture::Catalog::function:visible#g0()"
private let DOC_IR_METADATA_TEST_HIDDEN =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ametadata-transport::fixture::Catalog::function:hidden#g0()"
private let DOC_IR_METADATA_TEST_SECOND_MODULE = "cjdoc:module:v1:metadata-transport-second"
private let DOC_IR_METADATA_TEST_SECOND_OWNER =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Ametadata-transport-second::fixture::class:CatalogTwo#g0()"

private func metadataCodecDocumentWithSecondScope(metadata: DocumentationMetadata): DocumentationSet {
    let base = metadataCodecDocument(DocumentationMetadata())
    let secondOwner = SymbolDoc(DOC_IR_METADATA_TEST_SECOND_OWNER, "class", "CatalogTwo",
        "fixture.CatalogTwo", "fixture", DOC_IR_METADATA_TEST_SECOND_MODULE, "private",
        SourceRange("other/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 20, 19)),
        "private class CatalogTwo", SemanticInfo("partial", "ast"))
    let providers = ArrayList<ProviderInfo>(base.providers.toArray())
    providers.add(ProviderInfo("ast", "builtin", DOC_IR_METADATA_TEST_SECOND_MODULE, "partial",
        SemanticCapabilities(false, false, false, false, false)))
    let modules = ArrayList<ModuleDoc>(base.modules.toArray())
    modules.add(ModuleDoc(DOC_IR_METADATA_TEST_SECOND_MODULE, "metadata-transport-second", "root", "",
        packageNames: ["fixture"]))
    let packages = ArrayList<PackageDoc>(base.packages.toArray())
    packages.add(PackageDoc("fixture", DOC_IR_METADATA_TEST_SECOND_MODULE,
        sourceFiles: ["other/api.cj"], symbolIds: [secondOwner.id]))
    let files = ArrayList<FileDoc>(base.files.toArray())
    files.add(FileDoc("other/api.cj", DOC_IR_METADATA_TEST_SECOND_MODULE, "fixture"))
    let declarations = ArrayList<SymbolDoc>(base.declarations.toArray())
    declarations.add(secondOwner)
    DocumentationSet(base.generator, base.status, base.project, base.configuration,
        providers: providers.toArray(), modules: modules.toArray(), packages: packages.toArray(),
        files: files.toArray(), declarations: declarations.toArray(), metadata: metadata)
}

private func metadataCodecRange(line: Int64): SourceRange {
    let startByte = (line - 1) * 30
    SourceRange("src/api.cj", SourcePosition(line, 1, startByte), SourcePosition(line, 20, startByte + 19))
}

private func metadataCodecComment(groupId: String, tagId: String): DocComment {
    DocComment("", "", "", MarkdownNode("document"), tags: [
        DocTag("group", groupId, ""), DocTag("tag", tagId, "")
    ])
}

private func metadataCodecDocument(metadata: DocumentationMetadata): DocumentationSet {
    let owner = SymbolDoc(DOC_IR_METADATA_TEST_OWNER, "class", "Catalog", "fixture.Catalog", "fixture",
        DOC_IR_METADATA_TEST_MODULE, "public", metadataCodecRange(1), "public class Catalog",
        SemanticInfo("partial", "ast"))
    let visible = SymbolDoc(DOC_IR_METADATA_TEST_VISIBLE, "function", "visible", "fixture.Catalog.visible",
        "fixture", DOC_IR_METADATA_TEST_MODULE, "public", metadataCodecRange(2),
        "public func visible(): Unit", SemanticInfo("partial", "ast"), ownerId: Some(owner.id),
        documentation: Some(metadataCodecComment("20-query", "stream")))
    let hidden = SymbolDoc(DOC_IR_METADATA_TEST_HIDDEN, "function", "hidden", "fixture.Catalog.hidden",
        "fixture", DOC_IR_METADATA_TEST_MODULE, "private", metadataCodecRange(3),
        "private func hidden(): Unit", SemanticInfo("partial", "ast"), ownerId: Some(owner.id),
        documentation: Some(metadataCodecComment("private-group", "secret")))
    let declarations: Array<SymbolDoc> = [owner, visible, hidden]
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "partial", ProjectInfo("metadata-codec"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", DOC_IR_METADATA_TEST_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(DOC_IR_METADATA_TEST_MODULE, "metadata-transport", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", DOC_IR_METADATA_TEST_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: [owner.id, visible.id, hidden.id])],
        files: [FileDoc("src/api.cj", DOC_IR_METADATA_TEST_MODULE, "fixture")],
        declarations: declarations, metadata: metadata)
}

private func metadataCodecFixture(): DocumentationSet {
    let owner = Some(DOC_IR_METADATA_TEST_OWNER)
    let english = DocumentationTitle("en", "Query")
    let chinese = DocumentationTitle("zh-CN", "查询")
    metadataCodecDocument(DocumentationMetadata(
        groups: [
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "unused-group", "Unused",
                ownerId: owner),
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "private-group", "Private",
                ownerId: owner),
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "20-query", "Query",
                ownerId: owner, titles: [chinese, english], order: Some(20))
        ],
        tags: [
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "unused-tag", "Unused"),
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "secret", "Secret"),
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "stream", "Stream")
        ]))
}

private func metadataJsonObject(documentation: DocumentationSet): JsonObject {
    JsonNode.parse(encodeDocIr(documentation)).asObject()
}

@Test
class DocIrMetadataCodecTest {
    @TestCase
    func metadataRoundTripsWithCanonicalUtf8Ordering(): Unit {
        let documentation = metadataCodecFixture()
        let encoded = encodeDocIr(documentation)
        let decoded = decodeDocIr(encoded)
        @Expect(decoded.schemaVersion, "cjdoc.doc-ir/18")
        @Expect(encodeDocIr(decoded), encoded)
        @Expect(decoded.metadata.groups[0].id, "20-query")
        @Expect(decoded.metadata.groups[1].id, "private-group")
        @Expect(decoded.metadata.groups[2].id, "unused-group")
        @Expect(decoded.metadata.groups[0].titles[0].language, "en")
        @Expect(decoded.metadata.groups[0].titles[1].language, "zh-CN")
        @Expect(decoded.metadata.tags[0].id, "secret")
        @Expect(decoded.metadata.tags[1].id, "stream")
        @Expect(decoded.metadata.tags[2].id, "unused-tag")
    }

    @TestCase
    func rootMetadataIsRequiredNonNullAndStrict(): Unit {
        let encoded = encodeDocIr(metadataCodecFixture())
        let missing = metadataJsonObject(metadataCodecFixture())
        let _ = missing.remove("metadata")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(missing.toJson()))

        let nullMetadata = metadataJsonObject(metadataCodecFixture())
        nullMetadata.put("metadata", JsonNode.nullValue)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(nullMetadata.toJson()))

        let unknownMetadata = metadataJsonObject(metadataCodecFixture())
        unknownMetadata.get("metadata").getOrThrow().asObject().put("unexpected", JsonNode.boolean(true))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(unknownMetadata.toJson()))

        let oldVersion = encoded.replace("cjdoc.doc-ir/18", "cjdoc.doc-ir/17")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(oldVersion))
    }
    @TestCase
    func nullableGroupFieldsAcceptExplicitNullAndDefinitionLimitsAreEnforced(): Unit {
        let explicitNulls = metadataJsonObject(metadataCodecFixture())
        let nullGroup = explicitNulls.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray().get(0).getOrThrow().asObject()
        nullGroup.put("ownerId", JsonNode.nullValue)
        nullGroup.put("order", JsonNode.nullValue)
        let decodedNulls = decodeDocIr(explicitNulls.toJson())
        @Expect(decodedNulls.metadata.groups[0].ownerId.isNone(), true)
        @Expect(decodedNulls.metadata.groups[0].order.isNone(), true)

        let longTitle = metadataJsonObject(metadataCodecFixture())
        let longTitleGroups = longTitle.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        longTitleGroups.get(0).getOrThrow().asObject().put("title",
            JsonNode.string(String.fromUtf8(Array<Byte>(257, repeat: b'x'))))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(longTitle.toJson()))

        let highOrder = metadataJsonObject(metadataCodecFixture())
        let highOrderGroups = highOrder.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        highOrderGroups.get(0).getOrThrow().asObject().put("order", JsonNode.int64(1000000))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(highOrder.toJson()))

        let excessive = metadataJsonObject(metadataCodecFixture())
        let metadata = excessive.get("metadata").getOrThrow().asObject()
        let sourceGroup = metadata.get("groups").getOrThrow().asArray().get(0).getOrThrow()
        let tooManyGroups = JsonNode.array()
        for (_ in 0..2049) { tooManyGroups.add(sourceGroup) }
        metadata.put("groups", tooManyGroups)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(excessive.toJson()))
    }

    @TestCase
    func definitionFieldsRejectMissingNullMalformedAndUnknownValues(): Unit {
        let missingOwner = metadataJsonObject(metadataCodecFixture())
        let groups = missingOwner.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        let firstGroup = groups.get(0).getOrThrow().asObject()
        let _ = firstGroup.remove("ownerId")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(missingOwner.toJson()))

        let nullTitle = metadataJsonObject(metadataCodecFixture())
        let nullGroups = nullTitle.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        nullGroups.get(0).getOrThrow().asObject().put("title", JsonNode.nullValue)
        @ExpectThrows[IllegalArgumentException](decodeDocIr(nullTitle.toJson()))

        let unknownGroupField = metadataJsonObject(metadataCodecFixture())
        let unknownGroups = unknownGroupField.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        unknownGroups.get(0).getOrThrow().asObject().put("extra", JsonNode.string("rejected"))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(unknownGroupField.toJson()))

        let invalidId = metadataJsonObject(metadataCodecFixture())
        let invalidGroups = invalidId.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        invalidGroups.get(0).getOrThrow().asObject().put("id", JsonNode.string("invalid id"))
        @ExpectThrows[IllegalArgumentException](decodeDocIr(invalidId.toJson()))

        let missingOrder = metadataJsonObject(metadataCodecFixture())
        let orderGroups = missingOrder.get("metadata").getOrThrow().asObject()
            .get("groups").getOrThrow().asArray()
        let _ = orderGroups.get(0).getOrThrow().asObject().remove("order")
        @ExpectThrows[IllegalArgumentException](decodeDocIr(missingOrder.toJson()))
    }

    @TestCase
    func metadataDefinitionsRequireUniqueScopesAndRealReferences(): Unit {
        let owner = Some(DOC_IR_METADATA_TEST_OWNER)
        let duplicateGroups = DocumentationMetadata(groups: [
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "duplicate", "One",
                ownerId: owner),
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "duplicate", "Two",
                ownerId: owner)
        ])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(duplicateGroups)))

        let duplicateTags = DocumentationMetadata(tags: [
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "same", "One"),
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "same", "Two")
        ])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(duplicateTags)))

        let scopedDefinitions = DocumentationMetadata(groups: [
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "shared",
                "Package-level scope"),
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_MODULE, "fixture", "shared",
                "Owner scope", ownerId: owner),
            DocumentationGroupDefinition(DOC_IR_METADATA_TEST_SECOND_MODULE, "fixture", "shared",
                "Second module scope", ownerId: Some(DOC_IR_METADATA_TEST_SECOND_OWNER))
        ], tags: [
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_MODULE, "shared-tag", "Root tag"),
            DocumentationTagDefinition(DOC_IR_METADATA_TEST_SECOND_MODULE, "shared-tag", "Second tag")
        ])
        validateDocumentationSet(metadataCodecDocumentWithSecondScope(scopedDefinitions))

        let publication = projectPublicationDocumentation(
            metadataCodecDocumentWithSecondScope(scopedDefinitions))
        @Expect(publication.metadata.groups.isEmpty(), true)
        @Expect(publication.metadata.tags.isEmpty(), true)

        let unknownModule = DocumentationMetadata(tags: [DocumentationTagDefinition(
            "cjdoc:module:v1:unknown", "tag", "Tag")])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(unknownModule)))

        let unknownPackage = DocumentationMetadata(groups: [DocumentationGroupDefinition(
            DOC_IR_METADATA_TEST_MODULE, "missing", "group", "Group")])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(unknownPackage)))

        let unknownOwner = DocumentationMetadata(groups: [DocumentationGroupDefinition(
            DOC_IR_METADATA_TEST_MODULE, "fixture", "group", "Group",
            ownerId: Some("cjdoc:v2:unknown::fixture::class:Missing"))])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(unknownOwner)))

        let nonContainerOwner = DocumentationMetadata(groups: [DocumentationGroupDefinition(
            DOC_IR_METADATA_TEST_MODULE, "fixture", "group", "Group",
            ownerId: Some(DOC_IR_METADATA_TEST_VISIBLE))])
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(
            metadataCodecDocument(nonContainerOwner)))
    }

    @TestCase
    func visibleDeclarationUsePrunesHiddenAndUnusedDefinitions(): Unit {
        let documentation = metadataCodecFixture()
        let visible = ArrayList<SymbolDoc>()
        for (item in documentation.declarations where item.id != DOC_IR_METADATA_TEST_HIDDEN) {
            visible.add(item)
        }
        let captured = documentationMetadataForDeclarations(documentation.metadata, visible.toArray())
        @Expect(captured.groups.size, 1)
        @Expect(captured.groups[0].id, "20-query")
        @Expect(captured.tags.size, 1)
        @Expect(captured.tags[0].id, "stream")

        let published = projectPublicationDocumentation(documentation)
        @Expect(published.declarations.size, 2)
        @Expect(published.metadata.groups.size, 1)
        @Expect(published.metadata.groups[0].id, "20-query")
        @Expect(published.metadata.tags.size, 1)
        @Expect(published.metadata.tags[0].id, "stream")
    }

    @TestCase
    func metadataIsChargedToTheExistingEncoderBudget(): Unit {
        let emptyMetadata = metadataCodecDocument(DocumentationMetadata())
        let populated = metadataCodecFixture()
        let emptyCapacity = validateDocIrEncodingBudget(emptyMetadata, DOC_IR_MAX_JSON_DOCUMENT_BYTES)
        let populatedCapacity = validateDocIrEncodingBudget(populated, DOC_IR_MAX_JSON_DOCUMENT_BYTES)
        @Expect(populatedCapacity > emptyCapacity)
        @ExpectThrows[IllegalArgumentException](validateDocumentationSet(populated,
            maxDocumentBytes: emptyCapacity))
    }

}
