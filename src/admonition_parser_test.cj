package cjdoc

import cjdoc.source.cache.{
    SourceCacheWriter, SourceCacheReader, cacheAddDocComment, cacheReadDocComment,
    validateCachedDocComment}
import cjdoc.documentation.comments.parseDocComment
import cjdoc.source.SourceLocation
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func admonitionTextOccurrences(value: String, needle: String): Int64 {
    value.split(needle).size - 1
}

@Test
class AdmonitionParserTest {
    @TestCase
    func invalidPromptHeadersRemainBodyAndProducePreciseDiagnostics(): Unit {
        let project = i18nTestProject("/**\n" +
            " * Intro.\n" +
            " * @note[id=bad,lang=en] reversed attributes.\n" +
            " * Preserve this continuation.\n" +
            " * @warning[id=Bad] invalid identifier.\n" +
            " * @danger[id=empty]\n" +
            " * @note[lang=en,id=valid] Valid prompt.\n" +
            " */")
        try {
            let documentation = i18nTestGenerate(project)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(comment.description.contains("@note[id=bad,lang=en] reversed attributes."), true)
            @Expect(admonitionTextOccurrences(comment.description, "@note[id=bad,lang=en]"), 1)
            @Expect(admonitionTextOccurrences(comment.description, "Preserve this continuation."), 1)
            @Expect(admonitionTextOccurrences(comment.description,
                "@warning[id=Bad] invalid identifier."), 1)
            @Expect(comment.description.contains("Preserve this continuation."), true)
            @Expect(comment.localizedTexts.size >= 2, true)
            var validPrompt = false
            for (text in comment.localizedTexts where text.entryId == Some("valid")) {
                validPrompt = text.kind == "note" && text.language == Some("en")
            }
            @Expect(validPrompt, true)
            var invalidSyntaxCount: Int64 = 0
            var invalidIdCount: Int64 = 0
            var emptyPromptCount: Int64 = 0
            let codes = HashSet<String>()
            for (diagnostic in documentation.diagnostics) {
                codes.add(diagnostic.code)
                if (diagnostic.code == "CJDOC3115") { invalidSyntaxCount++ }
                if (diagnostic.code == "CJDOC3116") { invalidIdCount++ }
                if (diagnostic.code == "CJDOC3117") { emptyPromptCount++ }
                if (diagnostic.code == "CJDOC3115") {
                    let source = diagnostic.source.getOrThrow()
                    @Expect(source.path, "src/api.cj")
                    @Expect(source.start.line, 4)
                    @Expect(source.start.column, 4)
                    @Expect(source.end.line, 4)
                    @Expect(source.end.column, 46)
                    @Expect(diagnostic.symbolId.isSome(), true)
                } else if (diagnostic.code == "CJDOC3116") {
                    let source = diagnostic.source.getOrThrow()
                    @Expect(source.path, "src/api.cj")
                    @Expect(source.start.line, 6)
                    @Expect(source.start.column, 4)
                    @Expect(source.end.line, 6)
                    @Expect(source.end.column, 40)
                    @Expect(diagnostic.symbolId.isSome(), true)
                } else if (diagnostic.code == "CJDOC3117") {
                    let source = diagnostic.source.getOrThrow()
                    @Expect(source.path, "src/api.cj")
                    @Expect(source.start.line, 7)
                    @Expect(source.start.column, 4)
                    @Expect(source.end.line, 7)
                    @Expect(source.end.column, 21)
                    @Expect(diagnostic.symbolId.isSome(), true)
                }
            }
            @Expect(invalidSyntaxCount, 1)
            @Expect(invalidIdCount, 1)
            @Expect(emptyPromptCount, 1)
            @Expect(codes.contains("CJDOC3115"), true)
            @Expect(codes.contains("CJDOC3116"), true)
            @Expect(codes.contains("CJDOC3117"), true)
            @Expect(codes.contains("CJDOC3118"), false)
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
    @TestCase
    func sourceParseCacheRoundTripsPromptIdentityAndSourceFields(): Unit {
        let parsed = parseDocComment("/**\n * @warning[id=cached] Preserved text.\n */")
        validateCachedDocComment(Some(parsed))
        parsed.admonitions[0].source = Some(SourceLocation("src/cache.cj", 2, 4, 3, 6))
        let writer = SourceCacheWriter()
        cacheAddDocComment(writer, Some(parsed))
        let bytes = writer.result().getOrThrow()
        let decoded = cacheReadDocComment(SourceCacheReader(bytes)).getOrThrow()
        @Expect(decoded.localizationScope, "all")
        @Expect(decoded.admonitions.size, 1)
        @Expect(decoded.admonitions[0].name, "warning")
        @Expect(decoded.admonitions[0].entryId, Some("cached"))
        @Expect(decoded.admonitions[0].description, "Preserved text.")
        @Expect(decoded.admonitions[0].source.isSome(), true)
        @Expect(decoded.admonitions[0].source.getOrThrow().path, "src/cache.cj")
        @Expect(decoded.admonitions[0].source.getOrThrow().startLine, 2)
        @Expect(decoded.admonitions[0].source.getOrThrow().endColumn, 6)
    }
}
