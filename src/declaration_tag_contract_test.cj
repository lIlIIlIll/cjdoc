package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func repeatedTagId(byte: String, count: Int64): String {
    let builder = StringBuilder()
    var index: Int64 = 0
    while (index < count) {
        builder.append(byte)
        index++
    }
    builder.toString()
}

private func declarationTagTestGenerate(project: Path,
    cacheDirectory: ?String): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "standard",
        cacheDirectory: cacheDirectory, cacheFingerprint: Some("declaration-tag-contract-v1"),
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
}

private func declarationTagTestSymbol(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (symbol in documentation.declarations where symbol.name == name) { return symbol }
    throw IllegalStateException("declaration '${name}' not found")
}

private func declarationTagSubjects(comment: api_model.DocComment): Array<String> {
    let subjects = ArrayList<String>()
    for (tag in comment.tags where tag.name == "tag") { subjects.add(tag.subject) }
    subjects.toArray()
}

private func declarationTagDiagnosticCount(documentation: api_model.DocumentationSet,
    code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics where diagnostic.code == code) { count++ }
    count
}

@Test
class DeclarationTagContracts {
    @TestCase
    func publicTagIdsRequireCanonicalSharedMetadataAndDoNotRewriteRawTags(): Unit {
        let id64 = repeatedTagId("x", 64)
        let id65 = repeatedTagId("y", 65)
        let raw = "raw tag order"
        let tags = [
            api_model.DocTag("tag", "z", ""),
            api_model.DocTag("tag", "A", ""),
            api_model.DocTag("tag", "a", ""),
            api_model.DocTag("tag", id64, ""),
            api_model.DocTag("tag", "z", ""),
            api_model.DocTag("tag", "0-_", ""),
            api_model.DocTag("tag", "", ""),
            api_model.DocTag("tag", id65, ""),
            api_model.DocTag("tag", "流式", ""),
            api_model.DocTag("tag", "extra", "argument"),
            api_model.DocTag("tag", "directives", "", directives: "{invalid}"),
            api_model.DocTag("tag", "field", "", fieldId: "field-id"),
            api_model.DocTag("tag", "translated", "", translationState: "complete"),
            api_model.DocTag("tag", "localized", "", contentLanguage: Some("en")),
            api_model.DocTag("tag", "reference", "", referenceState: "resolved",
                targetSymbolId: Some("target")),
            api_model.DocTag("tag", "markdown", "",
                descriptionMarkdown: Some(api_model.MarkdownNode("document"))),
            api_model.DocTag("group", "not-a-tag", "")
        ]
        let comment = api_model.DocComment(raw, "", "", api_model.MarkdownNode("document"), tags: tags)

        @Expect(api_model.documentationTagIds(None), [])
        @Expect(api_model.documentationTagIds(Some(comment)), ["0-_", "A", "a", id64, "z"])
        @Expect(comment.rawText, raw)
        @Expect(declarationTagSubjects(comment), ["z", "A", "a", id64, "z", "0-_", "", id65,
            "流式", "extra", "directives", "field", "translated", "localized", "reference", "markdown"])
    }

    @TestCase
    func generatedTagsSurviveWorkerCacheAndLanguageViewsWithoutInheritance(): Unit {
        let id64 = repeatedTagId("x", 64)
        let id65 = repeatedTagId("y", 65)
        let commentText = "/**\n" +
            " * Shared API summary.\n" +
            " * @tag x\n" +
            " * @tag " + id64 + "\n" +
            " * @tag A\n" +
            " * @tag x\n" +
            " * @tag 0-_\n" +
            " * @tag " + id65 + "\n" +
            " * @tag 流式\n" +
            " * @tag extra extra\n" +
            " * @tag\n" +
            " * @tagged not-a-tag\n" +
            " * @tag[lang=en] qualified\n" +
            " * @tag[lang=bad--tag] malformed\n" +
            " * @param left Left value.\n" +
            " * @param right Right value.\n" +
            " * @return Combined value.\n" +
            " * @summary[lang=en] English summary.\n" +
            " * @param[lang=en] left Left translation.\n" +
            " * @return[lang=en] English result.\n" +
            " *\n" +
            " * ```text\n" +
            " * @tag fenced\n" +
            " * ```\n" +
            " * Inline `@tag inline` remains prose.\n" +
            " */"
        let extra = "/** @tag inherited */\npublic class TaggedBase {}\n" +
            "public class UntaggedChild <: TaggedBase {}\n"
        let project = i18nTestProject(commentText, extra: extra)
        let cache = project.join("cache")
        Directory.create(cache)
        try {
            let cold = declarationTagTestGenerate(project, Some(cache.toString()))
            let warm = declarationTagTestGenerate(project, Some(cache.toString()))
            for (documentation in [cold, warm]) {
                let add = declarationTagTestSymbol(documentation, "add")
                let comment = add.documentation.getOrThrow()
                @Expect(comment.rawText, commentText)
                @Expect(declarationTagSubjects(comment), ["x", id64, "A", "x", "0-_", id65,
                    "流式", "extra", ""])
                @Expect(api_model.documentationTagIds(Some(comment)), ["0-_", "A", "x", id64])
                @Expect(comment.defaultLanguage, Some("zh-CN"))

                var leftParameter = false
                var rightParameter = false
                var returned = false
                for (tag in comment.tags) {
                    if (tag.name == "param" && tag.subject == "left") {
                        @Expect(tag.description, "Left value.")
                        leftParameter = true
                    }
                    if (tag.name == "param" && tag.subject == "right") {
                        @Expect(tag.description, "Right value.")
                        rightParameter = true
                    }
                    if (tag.name == "return") {
                        @Expect(tag.description, "Combined value.")
                        returned = true
                    }
                }
                @Expect(leftParameter && rightParameter && returned)
                @Expect(declarationTagDiagnosticCount(documentation, "CJDOC3132"), 4)
                @Expect(declarationTagDiagnosticCount(documentation, "CJDOC3112"), 1)
                @Expect(declarationTagDiagnosticCount(documentation, "CJDOC3102"), 1)
                @Expect(declarationTagDiagnosticCount(documentation, "CJDOC3043"), 0)
                for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3132") {
                    @Expect(diagnostic.source.isSome(), true)
                    @Expect(diagnostic.symbolId, Some(add.id))
                }

                let english = api_render.projectDocumentationLanguage(documentation, "en")
                let englishComment = declarationTagTestSymbol(english, "add").documentation.getOrThrow()
                @Expect(api_model.documentationTagIds(Some(englishComment)), ["0-_", "A", "x", id64])
                for (text in englishComment.localizedTexts) { @Expect(text.kind != "tag", true) }
                var declarationFields: Int64 = 0
                for (entry in api_render.translationCoverageFor(documentation, "en").entries) {
                    @Expect(entry.kind != "tag", true)
                    if (entry.symbolId == Some(add.id)) { declarationFields++ }
                }
                // This signature contributes summary, two parameters and return;
                // the two classes contribute their own separate summary entries.
                @Expect(declarationFields, 4)

                let base = declarationTagTestSymbol(documentation, "TaggedBase")
                let child = declarationTagTestSymbol(documentation, "UntaggedChild")
                @Expect(api_model.documentationTagIds(base.documentation), ["inherited"])
                @Expect(api_model.documentationTagIds(child.documentation), [])
            }
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
}
