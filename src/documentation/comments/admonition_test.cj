protected package cjdoc.documentation.comments

import std.unittest.*
import std.unittest.testmacro.*

private func admonitionTextOccurrences(value: String, needle: String): Int64 {
    value.split(needle).size - 1
}

@Test
class AdmonitionParserTest {
    @TestCase
    func parsesExactPromptTagsWithBoundedContinuationAndPreservesLookalikes(): Unit {
        let comment = parseDocComment("/**\n" +
            " * Introduction.\n" +
            " * @note[id=tip] First line.\n" +
            " * Continuation line.\n" +
            " * @unknown remains ordinary body.\n" +
            " * Following body line.\n" +
            " *\n" +
            " * @warning[lang=en,id=guard] English warning.\n" +
            " * Warning continuation.\n" +
            " * @danger [square] remains literal prompt text.\n" +
            " * @Warning uppercase remains body.\n" +
            " * @noteish remains body.\n" +
            " * `@danger` remains inline code.\n" +
            " * > @danger remains a quote.\n" +
            " * - @danger remains a list item.\n" +
            " * ```text\n" +
            " * @danger remains fenced code.\n" +
            " * ```\n" +
            " */")
        @Expect(comment.admonitions.size, 3)
        @Expect(comment.admonitions[0].name, "note")
        @Expect(comment.admonitions[0].entryId, Some("tip"))
        @Expect(comment.admonitions[0].description, "First line.\nContinuation line.")
        @Expect(comment.admonitions[1].name, "warning")
        @Expect(comment.admonitions[1].entryId, Some("guard"))
        @Expect(comment.admonitions[1].description, "English warning.\nWarning continuation.")
        @Expect(comment.admonitions[2].name, "danger")
        @Expect(comment.admonitions[2].description, "[square] remains literal prompt text.")
        for (literal in ["@unknown remains ordinary body.", "Following body line.",
            "@Warning uppercase remains body.", "@noteish remains body.", "`@danger` remains inline code.",
            "> @danger remains a quote.", "- @danger remains a list item.",
            "@danger remains fenced code."]) {
            @Expect(comment.descriptionMarkdown.contains(literal), true)
            @Expect(admonitionTextOccurrences(comment.descriptionMarkdown, literal), 1)
        }
    }
}
