package cjdoc

import cjdoc.render as api_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class SourceMacroDocumentationTest {
    @TestCase
    func collectsMacroSignaturesAndBindsParameterReturnAndReferenceDocs(): Unit {
        let documentation = generateFixture("macro_sources", lintProfile: "standard")
        @Expect(documentation.status, "complete")
        @Expect(documentation.declarations.size, 2)
        @Expect(documentation.unsupportedDeclarations.size, 0)
        @Expect(documentation.macroInvocations.size, 0)
        @Expect(documentation.orphanDocComments.size, 0)
        @Expect(containsDiagnostic(documentation, "CJDOC1001"), false)
        @Expect(containsDiagnostic(documentation, "CJDOC3023"), false)
        var singleId = ""
        var pairId = ""
        for (symbol in documentation.declarations) {
            @Expect(symbol.kind, "macro")
            @Expect(symbol.visibility, "public")
            @Expect(symbol.headerSpelling.startsWith("public macro Echo("), true)
            @Expect(symbol.sourceApiSignature.state, "available")
            @Expect(symbol.returnType.getOrThrow().spelling, "Tokens")
            var returnFound = false
            for (tag in symbol.documentation.getOrThrow().tags where tag.name == "return") {
                returnFound = true
                @Expect(tag.description, "The unchanged tokens.")
            }
            @Expect(returnFound, true)
            for (parameter in symbol.parameters) {
                @Expect(parameter.typeRef.spelling, "Tokens")
                @Expect(parameter.documentation.isSome(), true)
            }
            if (symbol.parameters.size == 1) { singleId = symbol.id } else { pairId = symbol.id }
        }
        @Expect(singleId.isEmpty(), false)
        @Expect(pairId.isEmpty(), false)
        @Expect(singleId != pairId, true)
        for (symbol in documentation.declarations where symbol.parameters.size == 1) {
            var referenceFound = false
            for (reference in symbol.documentation.getOrThrow().tags where reference.name == "see") {
                referenceFound = true
                @Expect(reference.referenceState, "resolved")
                @Expect(reference.targetSymbolId, Some(pairId))
            }
            @Expect(referenceFound, true)
        }
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        let surface = api_render.apiContractSnapshotForDocumentation(documentation)
        @Expect(surface.declarations.size, 2)
        for (symbol in surface.declarations) {
            @Expect(symbol.kind, "macro")
            @Expect(symbol.parameters.size > 0, true)
        }
    }

    @TestCase
    func recoversNestedSourceInputsWithoutInventingExpandedMembers(): Unit {
        let documentation = generateFixture("macro_wrapped")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 7)
        @Expect(documentation.macroInvocations.size, 5)
        @Expect(documentation.unsupportedDeclarations.size, 1)
        @Expect(documentation.unsupportedDeclarations[0].name, "Opaque")
        @Expect(documentation.orphanDocComments.size, 0)
        let state = declarationNamed(documentation, "State")
        @Expect(state.kind, "enum")
        @Expect(state.visibility, "public")
        @Expect(state.source.start.line, 4)
        @Expect(state.headerSpelling, "@Outer\n@Derive[Equatable]\npublic enum State")
        @Expect(state.documentation.getOrThrow().summary,
            "A source enum inside nested macro wrappers.")
        let code = declarationNamed(documentation, "code")
        @Expect(code.source.start.line, 13)
        @Expect(code.source.start.column, 5)
        @Expect(code.ownerId, Some(state.id))
        @Expect(declarationNamed(documentation, "Busy").ownerId, Some(state.id))
        @Expect(declarationNamed(documentation, "Idle").visibility, "public")
        @Expect(declarationNamed(documentation, "size").visibility, "protected")
        @Expect(declarationNamed(documentation, "size").source.start.line, 20)
        @Expect(declarationNamed(documentation, "Hidden").visibility, "private")
        @Expect(containsDiagnostic(documentation, "CJDOC1011"), false)
        @Expect(containsDiagnostic(documentation, "CJDOC2002"), false)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func sourceCacheRetainsMacroKindsAndWrappedCommentRanges(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            for (fixture in ["macro_sources", "macro_wrapped"]) {
                let cache = temporary.join(fixture)
                Directory.create(cache)
                let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                    cacheFingerprint: Some("macro-documentation-v1"),
                    astPreflightExecutable: TEST_AST_PREFLIGHT)
                let cold = provider.collect(FIXTURES + fixture)
                @Expect(provider.cacheStats.writes, 1)
                let warm = provider.collect(FIXTURES + fixture)
                @Expect(provider.cacheStats.hits, 1)
                @Expect(provider.cacheStats.corruptEntries, 0)
                @Expect(warm.declarations.size, cold.declarations.size)
                for (index in 0..cold.declarations.size) {
                    let first = cold.declarations[index]
                    let second = warm.declarations[index]
                    @Expect(second.sourceKey, first.sourceKey)
                    @Expect(second.kind, first.kind)
                    @Expect(second.sourceSignature, first.sourceSignature)
                    @Expect(second.parameters.size, first.parameters.size)
                    @Expect(second.documentation.isSome(), first.documentation.isSome())
                    if (let Some(doc) <- first.documentation) {
                        @Expect(second.documentation.getOrThrow().raw, doc.raw)
                    }
                }
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func macroReadersShowCallableDetailsAndEscapeAuthorText(): Unit {
        let documentation = generateFixture("macro_sources")
        let htmlArtifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        let html = renderedHtmlContent(htmlArtifacts)
        @Expect(html.contains("id=\"macros\""), true)
        @Expect(html.contains("&lt;script&gt;"), true)
        @Expect(html.contains("<script>alert(1)</script>"), false)
        @Expect(html.contains("Echo(Tokens, Tokens)"), true)
        @Expect(html.contains("Source declaration tokens."), true)
        let markdown = renderedContent(api_render.MarkdownDocumentationRenderer().render(documentation))
        @Expect(markdown.contains("public macro Echo(input: Tokens): Tokens"), true)
        @Expect(markdown.contains("The unchanged tokens\\."), true)
        let wrong = SourceDeclaration("macro", "macro", "Echo", "fixture", "module", "public",
            SourceLocation("src/api.cj", 1, 1, 1, 1), "public macro Echo(input: Tokens): Tokens")
        wrong.parameters.add(SourceParameter("wrongName", "Tokens"))
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(wrong))
    }
}
