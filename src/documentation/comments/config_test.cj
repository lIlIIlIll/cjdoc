protected package cjdoc.documentation.comments

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func commentConfigTestRoot(): Path {
    Directory.createTemp(getTempDirectory())
}

private func writeCommentConfig(root: Path, value: String): Unit {
    File.writeTo(root.join("cjdoc.toml"), value.toArray())
}

private func expectCommentSpecError(value: String): IllegalArgumentException {
    @AssertThrows[IllegalArgumentException](parseCommentSpec(value))
}

private let OWNER_FIELD = "[[comments.fields]]\nid = \"owner\"\ntitle = \"负责人\"\n" +
    "[comments.fields.titles]\nen = \"Owner\"\n"

@Test
class CommentConfigTest {
    @TestCase
    func absentFileHasNoPolicy(): Unit {
        let root = commentConfigTestRoot()
        try {
            @Expect(loadCommentSpec(root.toString()).isEmpty(), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func capturesFieldsTitlesAliasesAndRules(): Unit {
        let spec = parseCommentSpec(
            "[comments]\n" +
            "[comments.aliases]\n" +
            "maintainer = \"owner\"\n" +
            "team-2 = \"owner\"\n" +
            "rfc = \"see\"\n" +
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"负责人\"\nrepeatable = true\n" +
            "[comments.fields.titles]\nen = \"Owner\"\n" +
            "[[comments.rules]]\nrequire = \"owner\"\nwhen-present = \"summary\"\n" +
            "severity = \"warning\"\n")
        @Expect(spec.fields.size, 1)
        @Expect(spec.fields[0].id, "owner")
        @Expect(spec.fields[0].title, "负责人")
        @Expect(spec.fields[0].titleFor("en"), "Owner")
        @Expect(spec.fields[0].titleFor("zh-CN"), "负责人")
        @Expect(spec.fields[0].repeatable, true)
        @Expect(spec.resolve("maintainer"), "owner")
        @Expect(spec.resolve("team-2"), "owner")
        @Expect(spec.resolve("rfc"), "see")
        @Expect(spec.resolve("owner"), "owner")
        @Expect(spec.rules.size, 1)
        @Expect(spec.rules[0].required, "owner")
        @Expect(spec.rules[0].whenPresent, Some("summary"))
        @Expect(spec.rules[0].severity, "warning")
    }

    @TestCase
    func aliasMayPrecedeItsField(): Unit {
        let spec = parseCommentSpec("[comments.aliases]\nmaintainer = \"owner\"\n" + OWNER_FIELD)
        @Expect(spec.resolve("maintainer"), "owner")
    }

    @TestCase
    func repeatedFieldKeepsEveryEntry(): Unit {
        let spec = parseCommentSpec(
            "[[comments.fields]]\nid = \"reviewer\"\ntitle = \"Reviewer\"\nrepeatable = true\n")
        @Expect(spec.fields[0].repeatable, true)
    }

    @TestCase
    func rejectsUnknownTablesKeysAndShapes(): Unit {
        for (text in [
            "[comments.typo]\nkey = \"value\"\n",
            "[comments]\nkey = \"value\"\n",
            "[comments.fields]\nid = \"owner\"\n",
            "[comments.fields.titles]\nen = \"Owner\"\n",
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"Owner\"\nunknown = 1\n",
            "[[comments.fields]]\nid = \"owner\"\n",
            "[[comments.fields]]\ntitle = \"Owner\"\n",
            "[[comments.fields]]\nid = \"Owner\"\ntitle = \"Owner\"\n",
            "[[comments.fields]]\nid = \"1owner\"\ntitle = \"Owner\"\n",
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"\"\n",
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"Owner\"\nrepeatable = \"yes\"\n"])
        {
            let error = expectCommentSpecError(text)
            @Expect(error.message.contains("CJDOC3139"), true)
        }
    }

    @TestCase
    func rejectsTitleLanguageOutsideTheSupportedSet(): Unit {
        let error = expectCommentSpecError(
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"Owner\"\n" +
            "[comments.fields.titles]\nfr = \"Proprietaire\"\n")
        @Expect(error.message.contains("CJDOC3139"), true)
    }

    @TestCase
    func rejectsAliasesThatChainOrNameUnknownTargets(): Unit {
        let chained = expectCommentSpecError(
            "[comments.aliases]\nfirst = \"second\"\nsecond = \"see\"\n")
        @Expect(chained.message.contains("CJDOC3139"), true)
        let unknown = expectCommentSpecError("[comments.aliases]\nmaintainer = \"owner\"\n")
        @Expect(unknown.message.contains("CJDOC3139"), true)
    }

    @TestCase
    func rejectsAliasAndFieldNamesThatCollideWithBuiltins(): Unit {
        for (text in [
            "[comments.aliases]\nparam = \"see\"\n",
            "[comments.aliases]\nnote = \"see\"\n",
            "[[comments.fields]]\nid = \"summary\"\ntitle = \"Summary\"\n",
            "[[comments.fields]]\nid = \"note\"\ntitle = \"Note\"\n",
            OWNER_FIELD + "[comments.aliases]\nowner = \"see\"\n"])
        {
            let error = expectCommentSpecError(text)
            @Expect(error.message.contains("CJDOC3139"), true)
        }
    }

    @TestCase
    func rejectsDuplicateFieldsAndAliases(): Unit {
        let duplicateField = expectCommentSpecError(
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"Owner\"\n" +
            "[[comments.fields]]\nid = \"owner\"\ntitle = \"Owner again\"\n")
        @Expect(duplicateField.message.contains("CJDOC3139"), true)
        let duplicateAlias = expectCommentSpecError(
            "[comments.aliases]\nmaintainer = \"see\"\nmaintainer = \"see\"\n")
        @Expect(duplicateAlias.message.contains("CJDOC3139"), true)
    }

    @TestCase
    func rulesNameOnlyFormalTags(): Unit {
        let alias = expectCommentSpecError(
            "[comments.aliases]\nmaintainer = \"owner\"\n" + OWNER_FIELD +
            "[[comments.rules]]\nrequire = \"maintainer\"\n")
        @Expect(alias.message.contains("CJDOC3139"), true)
        let unknown = expectCommentSpecError("[[comments.rules]]\nrequire = \"nowhere\"\n")
        @Expect(unknown.message.contains("CJDOC3139"), true)
        let missing = expectCommentSpecError("[[comments.rules]]\nseverity = \"error\"\n")
        @Expect(missing.message.contains("CJDOC3139"), true)
        let severity = expectCommentSpecError(
            "[[comments.rules]]\nrequire = \"summary\"\nseverity = \"off\"\n")
        @Expect(severity.message.contains("CJDOC3139"), true)
        let identical = parseCommentSpec(
            "[[comments.rules]]\nrequire = \"summary\"\nwhen-present = \"summary\"\n")
        @Expect(identical.rules[0].whenPresent, Some("summary"))
    }

    @TestCase
    func acceptsBuiltinRuleEndpointsIncludingAdmonitions(): Unit {
        let spec = parseCommentSpec(
            "[[comments.rules]]\nrequire = \"param\"\nwhen-present = \"note\"\n")
        @Expect(spec.rules.size, 1)
    }

    @TestCase
    func moduleWithoutACommentTableIsEmpty(): Unit {
        let spec = parseCommentSpec("[i18n]\ndefault-language = \"en\"\n[[metadata.tags]]\n" +
            "id = \"stream\"\ntitle = \"Stream\"\n")
        @Expect(spec.isEmpty(), true)
    }

    @TestCase
    func aliasesResolveOnceAndNeverForwardChain(): Unit {
        let spec = parseCommentSpec("[comments.aliases]\nrfc = \"see\"\n")
        @Expect(spec.hasAlias("rfc"), true)
        @Expect(spec.hasAlias("see"), false)
        @Expect(spec.resolve("rfc"), "see")
    }
}
