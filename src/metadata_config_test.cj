package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func metadataConfigTestRoot(): Path {
    Directory.createTemp(getTempDirectory())
}

private func writeMetadataConfig(root: Path, value: String): Unit {
    File.writeTo(root.join("cjdoc.toml"), value.toArray())
}

private func expectMetadataConfigError(root: Path, value: String): IllegalArgumentException {
    writeMetadataConfig(root, value)
    let error = @AssertThrows[IllegalArgumentException](loadDocumentationMetadataConfig(root.toString()))
    @Expect(error.message.contains("CJDOC3133"), true)
    error
}

private func metadataGroupRecord(id: String, title!: String = "Group"): String {
    "[[metadata.groups]]\npackage = \"sample\"\nid = \"${id}\"\ntitle = \"${title}\"\n"
}

private func metadataTagRecord(id: String): String {
    "[[metadata.tags]]\nid = \"${id}\"\ntitle = \"Tag\"\n"
}

private func metadataRepeat(value: String, count: Int64): String {
    let result = StringBuilder()
    for (_ in 0..count) { result.append(value) }
    result.toString()
}

@Test
class MetadataConfigTest {
    @TestCase
    func missingFileReturnsEmptyRawConfig(): Unit {
        let root = metadataConfigTestRoot()
        try {
            let config = loadDocumentationMetadataConfig(root.toString())
            @Expect(config.groups.size, 0)
            @Expect(config.tags.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func parsesScopedRecordsEscapesQuotedCommentsAndSourceLines(): Unit {
        let root = metadataConfigTestRoot()
        try {
            writeMetadataConfig(root,
                "[metadata]\n\n" +
                "[[metadata.groups]]\n" +
                "package = \"declaration_groups\"\n" +
                "owner = 'declaration_groups.Application # exact'\n" +
                "id = \"20-query\"\n" +
                "title = \"Query \\u67E5\\u8BE2 \\U0001F600 #1\" # trailing comment\n" +
                "order = 999_999\n" +
                "[metadata.groups.titles]\n" +
                "en = \"Query # \\u0022name\\u0022 \\u005c path\"\n" +
                "zh-CN = '查询 # literal'\n\n" +
                "[[metadata.tags]]\n" +
                "id = 'streaming'\n" +
                "title = '流式'\n" +
                "[metadata.tags.titles]\n" +
                "en = \"Streaming\"\n")
            let config = loadDocumentationMetadataConfig(root.toString())
            @Expect(config.groups.size, 1)
            @Expect(config.tags.size, 1)
            let group = config.groups[0]
            @Expect(group.packageName, "declaration_groups")
            @Expect(group.owner, Some("declaration_groups.Application # exact"))
            @Expect(group.ownerId.isNone(), true)
            @Expect(group.id, "20-query")
            @Expect(group.title, "Query 查询 😀 #1")
            @Expect(group.order, Some(999999))
            @Expect(group.line, 3)
            @Expect(group.titles.size, 2)
            @Expect(group.titles[0].language, "en")
            @Expect(group.titles[0].title, "Query # \"name\" \\ path")
            @Expect(group.titles[1].language, "zh-CN")
            @Expect(group.titles[1].title, "查询 # literal")
            @Expect(config.tags[0].id, "streaming")
            @Expect(config.tags[0].title, "流式")
            @Expect(config.tags[0].titles.size, 1)
            @Expect(config.tags[0].titles[0].title, "Streaming")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func acceptsDuplicateScopeDefinitionsForBindingLayer(): Unit {
        let root = metadataConfigTestRoot()
        try {
            writeMetadataConfig(root, metadataGroupRecord("same") + metadataGroupRecord("same") + """
                [[metadata.tags]]
                id = "same"
                title = "Tag"
                [[metadata.tags]]
                id = "same"
                title = "Tag"
                """)
            let config = loadDocumentationMetadataConfig(root.toString())
            @Expect(config.groups.size, 2)
            @Expect(config.groups[0].line, 1)
            @Expect(config.groups[1].line, 5)
            @Expect(config.tags.size, 2)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func parsesOptionalOwnerIdAndPackageLevelGroup(): Unit {
        let root = metadataConfigTestRoot()
        try {
            writeMetadataConfig(root, """
                [[metadata.groups]]
                package = "sample"
                owner-id = "cjdoc:v2:sample::type"
                id = "group"
                title = "Package group"
                """)
            let config = loadDocumentationMetadataConfig(root.toString())
            @Expect(config.groups.size, 1)
            @Expect(config.groups[0].owner.isNone(), true)
            @Expect(config.groups[0].ownerId, Some("cjdoc:v2:sample::type"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func tagAndGroupIdsUseOneToSixtyFourAsciiIdentifierRule(): Unit {
        let root = metadataConfigTestRoot()
        try {
            let valid64 = metadataRepeat("a", 64)
            for (id in ["x", valid64]) {
                writeMetadataConfig(root, metadataGroupRecord(id))
                @Expect(loadDocumentationMetadataConfig(root.toString()).groups.size, 1)
                writeMetadataConfig(root, metadataTagRecord(id))
                @Expect(loadDocumentationMetadataConfig(root.toString()).tags.size, 1)
            }
            for (id in ["", metadataRepeat("a", 65), "é", "bad id"]) {
                let groupError = expectMetadataConfigError(root, metadataGroupRecord(id))
                @Expect(groupError.message.contains("id"), true)
                let tagError = expectMetadataConfigError(root, metadataTagRecord(id))
                @Expect(tagError.message.contains("id"), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func titleLimitCountsDecodedUtf8Bytes(): Unit {
        let root = metadataConfigTestRoot()
        try {
            let valid = metadataRepeat("é", 128)
            writeMetadataConfig(root, metadataGroupRecord("title", title: valid))
            @Expect(loadDocumentationMetadataConfig(root.toString()).groups[0].title.toArray().size, 256)
            let invalid = valid + "a"
            let error = expectMetadataConfigError(root, metadataGroupRecord("title", title: invalid))
            @Expect(error.message.contains("256 UTF-8 bytes"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectsInvalidTitleTextAfterTOMLDecoding(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for (value in ["", "   ", "\\n", "\\u0001", "\\u007f", "\\q"]) {
                let error = expectMetadataConfigError(root, metadataGroupRecord("title", title: value))
                @Expect(error.message.contains("CJDOC3133"), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func acceptsTomlIntegerFormsWithinOrderRange(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for ((value, expected) in [("0", 0), ("+0", 0), ("999_999", 999999), ("0xF423F", 999999)]) {
                writeMetadataConfig(root, metadataGroupRecord("order") + "order = ${value}\n")
                @Expect(loadDocumentationMetadataConfig(root.toString()).groups[0].order, Some(expected))
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectsWrongOrderTypesMalformedIntegersAndOutOfRangeValues(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for (value in ["\"20\"", "true", "1.0", "-1", "1000000", "01", "1__0", "0x"]) {
                expectMetadataConfigError(root, metadataGroupRecord("order") + "order = ${value}\n")
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectsUnsupportedMetadataTablesKeysAndInlineForms(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for (config in [
                "metadata = { groups = [] }\n",
                "metadata.groups = []\n",
                "metadata = \"\"\"not a table\"\"\"\n",
                "metadata.groups = '''invalid'''\n",
                "\"metadata\" = '''invalid'''\n",
                "[metadata]\n[metadata]\n",
                "[metadata]\nextra = true\n",
                "[metadata.groups]\n",
                "[[metadata.groups.extra]]\n",
                "[[metadata.groups]]\npackage = \"p\"\nid = \"g\"\ntitle = \"G\"\nunknown = 1\n",
                "[[metadata.tags]]\nid = \"t\"\ntitle = \"T\"\npackage = \"p\"\n",
                "[[metadata.groups]]\npackage = \"p\"\nid = \"g\"\ntitle = \"G\"\nowner = \"A\"\nowner-id = \"B\"\n",
                "[metadata.groups.titles]\nen = \"orphan\"\n",
                metadataGroupRecord("translated") + "[metadata.groups.titles]\nfr = \"French\"\n",
                metadataGroupRecord("g") + "[metadata.groups.titles]\nen = \"first\"\n[metadata.groups.titles]\n"]) {
                expectMetadataConfigError(root, config)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectsDuplicateKeysTitleLanguagesAndTitlesTables(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for (config in [
                metadataGroupRecord("g") + "id = \"g\"\n",
                metadataGroupRecord("g") + "[metadata.groups.titles]\nen = \"one\"\nen = \"two\"\n",
                metadataGroupRecord("g") + "[metadata.groups.titles]\nen = \"one\"\n[metadata.groups.titles]\n",
                "[[metadata.tags]]\nid = \"t\"\ntitle = \"T\"\ntitle = \"Again\"\n",
            ]) {
                expectMetadataConfigError(root, config)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectsMissingRequiredFieldsAndUnsupportedMultilineMetadata(): Unit {
        let root = metadataConfigTestRoot()
        try {
            for (config in [
                "[[metadata.groups]]\nid = \"g\"\ntitle = \"G\"\n",
                "[[metadata.groups]]\npackage = \"p\"\nid = \"g\"\n",
                "[[metadata.tags]]\nid = \"t\"\n",
                "[[metadata.groups]]\npackage = \"p\"\nid = \"g\"\ntitle = " +
                    "\"\"\"multiline\nvalue\n\"\"\"\n",
                "[[metadata.tags]]\nid = \"t\"\ntitle = '''\nmultiline\nvalue\n'''\n",
            ]) {
                let error = expectMetadataConfigError(root, config)
                if (config.contains("multiline")) { @Expect(error.message.contains("multiline"), true) }
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func ignoresMetadataLikeTextInsideQuotedAndMultilineUnrelatedValues(): Unit {
        let root = metadataConfigTestRoot()
        try {
            let config =
                "note = \"quoted # [[metadata.groups]] text\"\n" +
                "example = \"\"\"\n" +
                "[[metadata.groups]]\n" +
                "metadata = 'not syntax'\n" +
                "package = \"not-a-record\"\n" +
                "id = \"not-a-record\"\n" +
                "title = \"not-a-record\"\n" +
                "\"\"\"\n" +
                "literal = '''\n" +
                "[[metadata.tags]]\n" +
                "metadata.groups = \"not syntax\"\n" +
                "id = 'not-a-tag'\n" +
                "title = 'not-a-tag'\n" +
                "'''\n" +
                "nested = [\n" +
                "  [\"metadata\"],\n" +
                "]\n" +
                "[[metadata.groups]]\n" +
                "package = \"real\"\n" +
                "id = \"actual\"\n" +
                "title = \"Visible # title\" # comment is outside string\n"
            writeMetadataConfig(root, config)
            let loaded = loadDocumentationMetadataConfig(root.toString())
            @Expect(loaded.groups.size, 1)
            @Expect(loaded.groups[0].packageName, "real")
            @Expect(loaded.groups[0].id, "actual")
            @Expect(loaded.groups[0].title, "Visible # title")
            @Expect(loaded.tags.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func enforcesExactAndOversizeFileBounds(): Unit {
        let root = metadataConfigTestRoot()
        try {
            let record = metadataGroupRecord("bound")
            let exactPadding = DOCUMENTATION_METADATA_CONFIG_MAX_BYTES - record.size
            let exact = record + metadataRepeat(" ", exactPadding)
            writeMetadataConfig(root, exact)
            @Expect(loadDocumentationMetadataConfig(root.toString()).groups.size, 1)
            let tooLarge = metadataRepeat(" ", DOCUMENTATION_METADATA_CONFIG_MAX_BYTES + 1)
            let error = expectMetadataConfigError(root, tooLarge)
            @Expect(error.message.contains("65536 bytes"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
