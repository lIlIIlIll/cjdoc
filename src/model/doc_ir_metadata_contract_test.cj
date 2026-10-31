package cjdoc.model

import std.unittest.*
import std.collection.*
import std.unittest.testmacro.*

private func titleAtUtf8Boundary(characterCount: Int64, suffix: String): String {
    let suffixBytes = suffix.toArray()
    let bytes = Array<Byte>(characterCount * 3 + suffixBytes.size, repeat: 0x00u8)
    var characterIndex: Int64 = 0
    while (characterIndex < characterCount) {
        let byteIndex = characterIndex * 3
        bytes[byteIndex] = 0xE7u8
        bytes[byteIndex + 1] = 0x95u8
        bytes[byteIndex + 2] = 0x8Cu8
        characterIndex += 1
    }
    var suffixIndex: Int64 = 0
    while (suffixIndex < suffixBytes.size) {
        bytes[characterCount * 3 + suffixIndex] = suffixBytes[suffixIndex]
        suffixIndex += 1
    }
    String.fromUtf8(bytes)
}

@Test
class DocumentationMetadataContractTest {
    @TestCase
    func identifiersRejectEmptyNonAsciiAndOverlongValues(): Unit {
        for (id in ["", String.fromUtf8(Array<Byte>(65, repeat: b'a')), "中文", "two words"]) {
            @ExpectThrows[IllegalArgumentException](
                DocumentationGroupDefinition("module", "package", id, "Group"))
            @ExpectThrows[IllegalArgumentException](
                DocumentationTagDefinition("module", id, "Tag"))
        }
    }

    @TestCase
    func titlesRejectUtf8OverflowRatherThanCountingRunes(): Unit {
        let overLimit = titleAtUtf8Boundary(85, "xy")
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", overLimit))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "group", overLimit))
        @ExpectThrows[IllegalArgumentException](DocumentationTagDefinition("module", "tag", overLimit))
    }

    @TestCase
    func titlesAcceptTheExactUtf8ByteBoundary(): Unit {
        let limit = titleAtUtf8Boundary(85, "x")
        @Expect(limit.size, 256)
        @Expect(DocumentationTitle("en", limit).title, limit)
        @Expect(DocumentationGroupDefinition("module", "package", "group", limit).title, limit)
        @Expect(DocumentationTagDefinition("module", "tag", limit).title, limit)
    }

    @TestCase
    func titlesRejectBlankControlsAndMultipleLines(): Unit {
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", ""))
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", "   "))
        let nonBreakingSpace: Array<Byte> = [0xC2u8, 0xA0u8]
        @ExpectThrows[IllegalArgumentException](
            DocumentationTitle("en", String.fromUtf8(nonBreakingSpace)))
        let c0Control: Array<Byte> = [b'x', 0x01u8, b'y']
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", String.fromUtf8(c0Control)))
        let delControl: Array<Byte> = [b'x', 0x7Fu8, b'y']
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", String.fromUtf8(delControl)))
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", "first\nsecond"))
        let lineSeparator: Array<Byte> = [b'x', 0xE2u8, 0x80u8, 0xA8u8, b'y']
        @ExpectThrows[IllegalArgumentException](
            DocumentationTitle("en", String.fromUtf8(lineSeparator)))
        let nextLine: Array<Byte> = [b'x', 0xC2u8, 0x85u8, b'y']
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("en", String.fromUtf8(nextLine)))
    }

    @TestCase
    func translatedTitlesRejectUnknownAndDuplicateLanguages(): Unit {
        let english = DocumentationTitle("en", "Query")
        @ExpectThrows[IllegalArgumentException](DocumentationTitle("fr", "Recherche"))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "query", "Query",
                titles: [english, DocumentationTitle("en", "Another query")]))
        @ExpectThrows[IllegalArgumentException](
            DocumentationTagDefinition("module", "query", "Query",
                titles: [english, DocumentationTitle("en", "Another query")]))
        let chinese = DocumentationTitle("zh-CN", "查询")
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "query", "Query",
                titles: [english, chinese, DocumentationTitle("en", "Third title")]))
        @ExpectThrows[IllegalArgumentException](
            DocumentationTagDefinition("module", "query", "Query",
                titles: [english, chinese, DocumentationTitle("en", "Third title")]))
    }

    @TestCase
    func groupOrderAndScopeValuesRejectInvalidInputs(): Unit {
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "negative", "Negative", order: Some(-1)))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "large", "Large", order: Some(1000000)))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("", "package", "group", "Group"))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "", "group", "Group"))
        @ExpectThrows[IllegalArgumentException](
            DocumentationGroupDefinition("module", "package", "group", "Group", ownerId: Some("")))
        @ExpectThrows[IllegalArgumentException](DocumentationTagDefinition("", "tag", "Tag"))
        @Expect(DocumentationGroupDefinition("module", "package", "first", "First",
            order: Some(0)).order, Some(0))
        @Expect(DocumentationGroupDefinition("module", "package", "last", "Last",
            order: Some(999999)).order, Some(999999))
    }

    @TestCase
    func metadataCollectionsAndOrderingAreBoundedAndDeterministic(): Unit {
        let group = DocumentationGroupDefinition("module", "package", "group", "Group")
        let tag = DocumentationTagDefinition("module", "tag", "Tag")
        let atLimit = DocumentationMetadata(
            groups: Array<DocumentationGroupDefinition>(2048, repeat: group),
            tags: Array<DocumentationTagDefinition>(2048, repeat: tag))
        @Expect(atLimit.groups.size, 2048)
        @Expect(atLimit.tags.size, 2048)

        let ordered = DocumentationMetadata(
            groups: [
                DocumentationGroupDefinition("z-module", "package", "z", "Z"),
                DocumentationGroupDefinition("a-module", "package", "b", "B"),
                DocumentationGroupDefinition("a-module", "package", "a", "A")
            ],
            tags: [
                DocumentationTagDefinition("module", "stream", "Stream"),
                DocumentationTagDefinition("module", "alpha", "Alpha")
            ])
        @Expect(ordered.groups[0].id, "a")
        @Expect(ordered.groups[1].id, "b")
        @Expect(ordered.groups[2].moduleId, "z-module")
        @Expect(ordered.tags[0].id, "alpha")
        let translated = DocumentationTagDefinition("module", "localized", "Base",
            titles: [DocumentationTitle("zh-CN", "中文"), DocumentationTitle("en", "English")])
        @Expect(translated.titles[0].language, "en")
        @Expect(translated.titles[1].language, "zh-CN")
    }

    @TestCase
    func callerMutationsCannotChangeCapturedMetadata(): Unit {
        let english = DocumentationTitle("en", "Original")
        let replacement = DocumentationTitle("zh-CN", "替换")
        var inputTitles: Array<DocumentationTitle> = [english]
        let group = DocumentationGroupDefinition("module", "package", "group", "Group",
            titles: inputTitles)
        inputTitles[0] = replacement
        @Expect(group.titles[0].title, "Original")
        var tagTitles: Array<DocumentationTitle> = [english]
        let tag = DocumentationTagDefinition("module", "tag", "Tag", titles: tagTitles)
        tagTitles[0] = replacement
        var inputGroups: Array<DocumentationGroupDefinition> = [group]
        var inputTags: Array<DocumentationTagDefinition> = [tag]
        let metadata = DocumentationMetadata(groups: inputGroups, tags: inputTags)
        inputGroups[0] = DocumentationGroupDefinition("module", "package", "replacement", "Replacement")
        inputTags[0] = DocumentationTagDefinition("module", "replacement", "Replacement")
        @Expect(metadata.groups[0].id, "group")
        @Expect(metadata.tags[0].id, "tag")
        @Expect(metadata.tags[0].titles[0].language, "en")
    }

    @TestCase
    func metadataRejectsOversizedDefinitionCategories(): Unit {
        let group = DocumentationGroupDefinition("module", "package", "group", "Group")
        let tag = DocumentationTagDefinition("module", "tag", "Tag")
        @ExpectThrows[IllegalArgumentException](
            DocumentationMetadata(groups: Array<DocumentationGroupDefinition>(2049, repeat: group)))
        @ExpectThrows[IllegalArgumentException](
            DocumentationMetadata(tags: Array<DocumentationTagDefinition>(2049, repeat: tag)))
    }
}
