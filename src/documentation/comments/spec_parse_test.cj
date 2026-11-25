protected package cjdoc.documentation.comments

import cjdoc.source.SourceLocation
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let OWNER_SPEC = parseCommentSpec(
    "[comments.aliases]\nmaintainer = \"owner\"\nmain = \"owner\"\n" +
    "[[comments.fields]]\nid = \"owner\"\ntitle = \"负责人\"\n" +
    "[comments.fields.titles]\nen = \"Owner\"\n" +
    "[[comments.fields]]\nid = \"reviewer\"\ntitle = \"Reviewer\"\nrepeatable = true\n" +
    "[[comments.fields]]\nid = \"team-2\"\ntitle = \"Team\"\n")

private func commentSource(line: Int64): SourceLocation {
    SourceLocation("src/lib.cj", line, 1, line, 1)
}

private func fieldValuesOf(comment: DocComment, fieldId: String): ArrayList<String> {
    let values = ArrayList<String>()
    for (entry in comment.fieldValues) {
        if (entry.fieldId == fieldId) { values.add(entry.value) }
    }
    values
}

@Test
class CommentSpecParseTest {
    @TestCase
    func aliasRewritesOnlyTheAuthoredHead(): Unit {
        let comment = parseDocCommentAt("/**\n * Summary.\n * @maintainer Platform Team\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        let occurrences = comment.occurrences
        @Expect(occurrences.size, 1)
        @Expect(occurrences[0].name, "owner")
        @Expect(occurrences[0].authored, "maintainer")
        @Expect(occurrences[0].payload, true)
        @Expect(fieldValuesOf(comment, "owner")[0], "Platform Team")
    }

    @TestCase
    func aliasToBuiltinFollowsTheBuiltinRule(): Unit {
        let spec = parseCommentSpec("[comments.aliases]\nrfc = \"see\"\n")
        let comment = parseDocCommentAt(
            "/**\n * Summary.\n * @rfc StreamReader\n * @see OtherReader\n */",
            Some(commentSource(1)), spec: Some(spec))
        // Two authored @see entries after alias resolution are both references.
        @Expect(comment.see.size, 2)
        @Expect(comment.occurrences.size, 2)
        @Expect(comment.occurrences[0].name, "see")
        @Expect(comment.occurrences[0].authored, "rfc")
    }

    @TestCase
    func fieldValuesKeepInteriorSpellingAndAreNotProse(): Unit {
        let comment = parseDocCommentAt(
            "/**\n * Summary paragraph.\n * @owner 平台  Team-2\n *\n * Body paragraph.\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(fieldValuesOf(comment, "owner")[0], "平台  Team-2")
        @Expect(comment.descriptionMarkdown.contains("@owner"), false)
        @Expect(comment.descriptionMarkdown.contains("Body paragraph."), true)
    }

    @TestCase
    func fieldNamesUseCompleteLexicalHeads(): Unit {
        // `@team-2x` is not the declared `team-2`, so the line stays prose.
        let comment = parseDocCommentAt("/**\n * Summary.\n * @team-2x value\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(comment.fieldValues.isEmpty(), true)
        @Expect((comment.summaryMarkdown + comment.descriptionMarkdown).contains("@team-2x value"), true)
        let exact = parseDocCommentAt("/**\n * Summary.\n * @team-2 value\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(fieldValuesOf(exact, "team-2")[0], "value")
    }

    @TestCase
    func emptyAndMultiLineValuesAreStructuralErrors(): Unit {
        let empty = parseDocCommentAt("/**\n * Summary.\n * @owner\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(empty.problems.size, 1)
        @Expect(empty.problems[0].code, "CJDOC3140")
        @Expect(empty.fieldValues.isEmpty(), true)
        // A paragraph separator (U+2028) is a line boundary, not field text.
        let separator: Array<Byte> = [0xE2u8, 0x80u8, 0xA8u8]
        let separated = parseDocCommentAt(
            "/**\n * Summary.\n * @owner first" + String.fromUtf8(separator) + "second\n */",
            Some(commentSource(3)), spec: Some(OWNER_SPEC))
        @Expect(separated.problems.size, 1)
        @Expect(separated.problems[0].code, "CJDOC3140")
        @Expect(separated.fieldValues.isEmpty(), true)
    }

    @TestCase
    func attributesAreRejectedOnCustomFields(): Unit {
        let comment = parseDocCommentAt("/**\n * Summary.\n * @owner[lang=en] platform\n */",
            Some(commentSource(2)), spec: Some(OWNER_SPEC))
        @Expect(comment.problems.size, 1)
        @Expect(comment.problems[0].code, "CJDOC3140")
        @Expect(comment.problems[0].message.contains("attribute"), true)
        @Expect(comment.problems[0].source.isSome(), true)
    }

    @TestCase
    func repeatedSingleValueFieldInvalidatesTheWholeField(): Unit {
        let comment = parseDocCommentAt(
            "/**\n * Summary.\n * @owner platform\n * @maintainer platform\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(comment.problems.size, 1)
        @Expect(comment.problems[0].code, "CJDOC3141")
        @Expect(comment.fieldValues.isEmpty(), true)
    }

    @TestCase
    func repeatableFieldKeepsEveryValidEntry(): Unit {
        let comment = parseDocCommentAt(
            "/**\n * Summary.\n * @reviewer alice\n * @reviewer bob\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        let values = fieldValuesOf(comment, "reviewer")
        @Expect(values.size, 2)
        @Expect(values[0], "alice")
        @Expect(values[1], "bob")
    }

    @TestCase
    func fencedAndQuotedSpellingsStayProse(): Unit {
        let comment = parseDocCommentAt(
            "/**\n * Summary.\n *\n * ```cangjie\n * @owner platform\n * ```\n *\n" +
            " * > @owner quoted\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(comment.fieldValues.isEmpty(), true)
        @Expect(comment.occurrences.isEmpty(), true)
    }

    @TestCase
    func documentedProjectLeavesUnrelatedTagsAlone(): Unit {
        let comment = parseDocCommentAt(
            "/**\n * Summary.\n * @group 10-query 查询\n * @param count 数量。\n */",
            Some(commentSource(1)), spec: Some(OWNER_SPEC))
        @Expect(comment.params.size, 1)
        @Expect(comment.contracts.size, 1)
        @Expect(comment.params[0].description, "数量。")
    }

    @TestCase
    func emptyPolicyKeepsTheHistoricalPath(): Unit {
        let raw = "/**\n * Summary.\n * @param count 数量。\n */"
        let withSpec = parseDocCommentAt(raw, Some(commentSource(1)),
            spec: Some(CommentSpec()))
        let without = parseDocCommentAt(raw, Some(commentSource(1)))
        @Expect(withSpec.params.size, without.params.size)
        @Expect(withSpec.summaryMarkdown, without.summaryMarkdown)
    }
}
