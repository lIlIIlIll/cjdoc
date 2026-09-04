package cjdoc

import cjdoc.model as api_model
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite1 {
    @TestCase
    func extractsSupportedLanguageStructures(): Unit {
        let documentation = generateFixture("basic")
        @Expect(documentation.declarations.size, 25)
        let kinds = HashSet<String>()
        for (declaration in documentation.declarations) { kinds.add(declaration.kind) }
        for (expected in ["class", "struct", "interface", "enum", "extend", "function",
            "property", "constructor", "typeAlias", "enumCase", "variable"]) {
            @Expect(kinds.contains(expected), true)
        }
        @Expect(declarationNamed(documentation, "解析").qualifiedName, "basic.解析")
        @Expect(declarationNamed(documentation, "identity").genericParameters.size, 1)
    }

    @TestCase
    func overloadsHaveStableDistinctSymbolIds(): Unit {
        let documentation = generateFixture("basic")
        let overloadIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse") { overloadIds.add(declaration.id) }
            @Expect(!declaration.id.contains("src/"), true)
            @Expect(!declaration.id.contains(":1:"), true)
        }
        @Expect(overloadIds.size, 2)
        @Expect(overloadIds[0] != overloadIds[1], true)
        @Expect(overloadIds[0].contains("Array<UInt8>") || overloadIds[1].contains("Array<UInt8>"), true)
        @Expect(overloadIds[0].contains("String") || overloadIds[1].contains("String"), true)
    }

    @TestCase
    func filePrivateTopLevelDeclarationsHaveInjectiveSymbolIds(): Unit {
        let documentation = generateFixture("private_file_scope")
        let helperIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "sameHelper") { helperIds.add(declaration.id) }
        }
        @Expect(helperIds.size, 2)
        @Expect(helperIds[0] != helperIds[1], true)
        @Expect(helperIds[0].contains("::file:src/"), true)
        @Expect(helperIds[1].contains("::file:src/"), true)
    }

    @TestCase
    func parsesStructuredCommentsAndMarkdownAst(): Unit {
        let documentation = generateFixture("basic")
        var selected: ?api_model.SymbolDoc = None
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse" && declaration.parameters.size == 1 &&
                declaration.parameters[0].typeRef.spelling == "String") { selected = Some(declaration) }
        }
        let declaration = selected.getOrThrow()
        let comment = declaration.documentation.getOrThrow()
        @Expect(comment.summary, "从文本解析值。")
        @Expect(comment.markdown.kind, "document")
        @Expect(comment.markdown.children.size >= 3, true)
        @Expect(comment.markdown.children[0].kind, "paragraph")
        var tagNames = HashSet<String>()
        for (tag in comment.tags) { tagNames.add(tag.name) }
        for (name in ["param", "return", "throws", "see", "since"]) {
            @Expect(tagNames.contains(name), true)
        }
    }

    @TestCase
    func keepsStructuredTagsInsideGfmFencesAndParsesSpacedSeeTargets(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            * ~~~~text
            * @param notATag preserved
            * ~~~
            * ~~~~
            * ````text
            * @throws NotAType preserved
            * ```
            * ````
            * @see sample.target(String, Bool) related overload
            * @see sample.transform<(String) -> Bool>(Int64) arrow target
            */
            """)
        @Expect(comment.params.size, 0)
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.descriptionMarkdown.contains("@param notATag preserved"), true)
        @Expect(comment.descriptionMarkdown.contains("@throws NotAType preserved"), true)
        @Expect(comment.see.size, 2)
        @Expect(comment.see[0].subject, "sample.target(String, Bool)")
        @Expect(comment.see[0].description, "related overload")
        @Expect(comment.see[1].subject, "sample.transform<(String) -> Bool>(Int64)")
        @Expect(comment.see[1].description, "arrow target")
    }

    @TestCase
    func parsesExamplesAsStructuredMultilineTags(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            * @example Basic addition
            *
            * ```cj
            * let result = add(1, 2)
            * @param insideCode remains code
            *
            * ```
            *
            * Explain the input above.
            *
            * @example Invalid input
            *
            * ~~~cj
            * add(-1, 2)
            * ~~~
            * @param left left value
            * @return sum
            */
            """)
        @Expect(comment.summaryMarkdown, "Summary.")
        @Expect(comment.descriptionMarkdown, "")
        @Expect(comment.examples.size, 2)
        @Expect(comment.examples[0].subject, "Basic addition")
        @Expect(comment.examples[0].description.contains("@param insideCode remains code"), true)
        @Expect(comment.examples[0].description.contains("\n\n"), true)
        @Expect(comment.examples[0].description.contains("Explain the input above."), true)
        @Expect(comment.examples[1].subject, "Invalid input")
        @Expect(comment.examples[1].description.contains("add(-1, 2)"), true)
        @Expect(comment.params.size, 1)
        @Expect(comment.params[0].subject, "left")
        @Expect(comment.returns.isSome(), true)
        @Expect(comment.returns.getOrThrow().description, "sum")
    }

    @TestCase
    func trimsManyLeadingDocCommentLinesWithoutChangingMarkdown(): Unit {
        let raw = StringBuilder("/**\n")
        var index: Int64 = 0
        while (index < 20000) {
            raw.append(" *\n")
            index++
        }
        raw.append(" * Summary.\n */")
        let comment = parseDocComment(raw.toString())
        @Expect(comment.summaryMarkdown, "Summary.")
        @Expect(comment.descriptionMarkdown, "")
    }

    @TestCase
    func treatsFourSpaceMarkdownAsCodeAndAllowsOnlyThreeSpaceFences(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            *     @param indented not a tag
            *     ``` not a fence
            *     @throws Indented also not a tag
            *    ```text
            * @param fenced still not a tag
            *     ``` four-space closing does not close
            * @return still fenced
            *    ```
            * @see sample.target real tag
            */
            """)
        @Expect(comment.params.size, 0)
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.returns.isNone(), true)
        @Expect(comment.see.size, 1)
        @Expect(comment.see[0].subject, "sample.target")
        @Expect(comment.descriptionMarkdown.contains("@param indented not a tag"), true)
        @Expect(comment.descriptionMarkdown.contains("@return still fenced"), true)
    }

    @TestCase
    func derivesStructuredTagsAndSummaryFromGfmBlockStructure(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            * - list item
            *   ```cj
            *   @param nested hidden in list-item fence
            *
            *   @throws Nested hidden after a blank code line
            *   ```
            *
            * ```bad`info
            * @param visible parsed from the paragraph because the info string is invalid
            * ```
            * @see hidden.inside.unclosed.fence
            */
            """)
        @Expect(comment.summaryMarkdown, "Summary.")
        @Expect(comment.params.size, 1)
        @Expect(comment.params[0].subject, "visible")
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.see.size, 0)
        @Expect(comment.descriptionMarkdown.contains("@param nested hidden"), true)
        @Expect(comment.descriptionMarkdown.contains("@throws Nested hidden"), true)
        @Expect(comment.descriptionMarkdown.contains("@see hidden.inside.unclosed.fence"), true)
        @Expect(comment.descriptionMarkdown.contains("```bad`info"), true)
    }

    @TestCase
    func selectsFirstParagraphAsSummaryAndRetainsOtherBlocksAsDescription(): Unit {
        let comment = parseDocComment("""
            /**
            * # API heading
            *
            * Paragraph summary.
            *
            * - Additional detail
            */
            """)
        @Expect(comment.summaryMarkdown, "Paragraph summary.")
        @Expect(comment.descriptionMarkdown.contains("# API heading"), true)
        @Expect(comment.descriptionMarkdown.contains("- Additional detail"), true)

        let blocksOnly = parseDocComment("""
            /**
            * # Heading only
            *
            * - Detail only
            */
            """)
        @Expect(blocksOnly.summaryMarkdown, "")
        @Expect(blocksOnly.descriptionMarkdown.contains("# Heading only"), true)
    }


}
