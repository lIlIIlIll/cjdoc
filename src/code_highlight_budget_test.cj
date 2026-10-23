package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func budgetTestMarkdown(body: String, context: MarkdownGenerationContext): api_model.MarkdownNode {
    let source = api_model.SourceRange("src/budget.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 1, 0))
    publicMarkdown(body, LocalAssetCollector(ArrayList<SourceFileOrigin>()), "src/budget.cj",
        source, "budget-symbol", context)
}

@Test
class CodeHighlightBudgetTest {
    @TestCase
    func exhaustedBudgetRetainsWholeBlocksAndReportsOnce(): Unit {
        let context = MarkdownGenerationContext(highlightBytes: 11000)
        let code = "let 名称 = 1\n"
        let body = "~~~cj\n" + code + "~~~\n\n~~~cj\n" + code + "~~~\n\n~~~cj\n" + code + "~~~\n"
        let tree = budgetTestMarkdown(body, context)
        @Assert(tree.children.size, 3)
        @Expect(tree.children[0].metadata.getOrThrow().codeHighlight.isSome())
        for (index in 0..3) {
            let block = tree.children[index]
            @Expect(block.literal, code)
            if (index > 0) { @Expect(block.metadata.getOrThrow().codeHighlight.isNone()) }
        }
        @Expect(context.highlight("let later = 2", "cj").isNone())
        @Assert(context.diagnostics().size, 1)
        @Expect(context.diagnostics()[0].code, "CJDOC3028")
        @Expect(context.diagnostics()[0].severity, "warning")
        @Expect(context.diagnostics().size, 1)
        let html = api_render.renderStandaloneMarkdownHtml(tree)
        @Expect(html.contains("let 名称 = 1\n"))
        @Expect(html.contains("名称"))
    }

    @TestCase
    func identicalInputsRetainIdenticalPrefix(): Unit {
        let code = "~~~cj\nlet x = 1\n~~~\n\n~~~cj\nlet y = 2\n~~~\n"
        let firstContext = MarkdownGenerationContext(highlightBytes: 11000)
        let secondContext = MarkdownGenerationContext(highlightBytes: 11000)
        let first = budgetTestMarkdown(code, firstContext)
        let second = budgetTestMarkdown(code, secondContext)
        @Assert(first.children.size, second.children.size)
        for (index in 0..first.children.size) {
            let left = first.children[index]
            let right = second.children[index]
            @Expect(left.literal, right.literal)
            @Expect(left.metadata.getOrThrow().codeHighlight.isSome(),
                right.metadata.getOrThrow().codeHighlight.isSome())
        }
        @Expect(api_render.renderStandaloneMarkdownHtml(first), api_render.renderStandaloneMarkdownHtml(second))
        @Expect(firstContext.diagnostics()[0].message, secondContext.diagnostics()[0].message)
    }

    @TestCase
    func examplesCommentsAndSignaturesShareOneAllowance(): Unit {
        let context = MarkdownGenerationContext(highlightBytes: 11000)
        let body = "~~~cj\nlet x = 1\n~~~\n"
        let comment = DocComment("original raw comment", body, "")
        comment.examples.add(DocTag("example", "example", body))
        let symbol = SymbolDoc("function", "sample", "fixture", "module", "public",
            SourceLocation("src/budget.cj", 1, 1, 1, 1), "public func sample(): Unit")
        symbol.id = "budget-symbol"
        symbol.qualifiedName = "fixture.sample"
        symbol.documentation = Some(comment)
        let declaration = publicSymbol(symbol, PublicSourceMapper(), HashMap<String, String>(),
            LocalAssetCollector(ArrayList<SourceFileOrigin>()), context, HashSet<String>())
        let projected = declaration.documentation.getOrThrow()
        let example = projected.tags[0]
        @Expect(example.description, body)
        @Expect(example.exampleMarkdown.getOrThrow().children[0].literal, "let x = 1\n")
        @Expect(example.exampleMarkdown.getOrThrow().children[0].metadata.getOrThrow().codeHighlight.isSome())
        @Expect(projected.markdown.children[0].metadata.getOrThrow().codeHighlight.isNone())
        @Expect(projected.markdown.children[0].literal, "let x = 1\n")
        @Expect(projected.rawText, comment.raw)
        @Expect(projected.summary, body)
        @Expect(declaration.headerSpelling, symbol.sourceSignature)
        @Expect(declaration.signatureHighlight.isNone())
        @Expect(context.diagnostics().size, 1)
    }

    @TestCase
    func totalSpanAndPreparationLimitsRejectWholeMetadata(): Unit {
        let budget = HighlightGenerationBudget()
        let tooMany = String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_TOTAL_SPANS + 1, repeat: b'('))
        @Expect(budget.prepare(tooMany, "cj").isNone())
        @Expect(budget.prepare("let x = 1", "cj").isNone())
        @Expect(budget.diagnostics().size, 1)
        let inputBudget = HighlightGenerationBudget()
        let chunk = String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_BLOCK_BYTES, repeat: b'a'))
        for (_ in 0..(MAX_HIGHLIGHT_TOTAL_PREPARED_BYTES / chunk.size)) {
            @Expect(inputBudget.prepare(chunk, "cj").isSome())
        }
        @Expect(inputBudget.prepare("x", "cj").isNone())
        @Expect(inputBudget.diagnostics().size, 1)
    }

    @TestCase
    func perBlockLimitsRemainUnchangedWithoutDroppingCode(): Unit {
        @Expect(MAX_HIGHLIGHT_BLOCK_BYTES, 262144)
        @Expect(MAX_HIGHLIGHT_SPANS_PER_BLOCK, 65536)
        for (source in [String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_BLOCK_BYTES + 1, repeat: b'a')),
            String.fromUtf8(Array<Byte>(MAX_HIGHLIGHT_SPANS_PER_BLOCK + 1, repeat: b'('))]) {
            let context = MarkdownGenerationContext()
            let tree = budgetTestMarkdown("~~~cj\n" + source + "\n~~~\n", context)
            let block = tree.children[0]
            @Expect(block.literal, source + "\n")
            let value = block.metadata.getOrThrow().codeHighlight.getOrThrow()
            @Expect(value.state, "plain")
            @Expect(value.reason, Some("resource-limit"))
            @Expect(value.spans.size, 0)
            @Expect(context.diagnostics().size, 0)
        }
    }

    @TestCase
    func nearCodecLimitDropsHighlightingRatherThanDeclarations(): Unit {
        let input = DocumentationSet("near-codec-limit")
        let signature = String.fromUtf8(Array<Byte>(100, repeat: b'('))
        for (index in 0..150) {
            let symbol = SymbolDoc("function", "sample", "fixture", "module", "public",
                SourceLocation("src/budget.cj", 1, 1, 1, 1), signature)
            symbol.id = "budget-symbol-${index}"
            symbol.qualifiedName = "fixture.sample${index}"
            input.symbols.add(symbol)
        }
        let chunk = String.fromUtf8(Array<Byte>(1024 * 1024, repeat: b'x'))
        for (_ in 0..31) { input.diagnostics.add(Diagnostic("warning", "CJDOC3999", chunk)) }
        let result = publicDocumentation(input, GenerationRequest("unused", lintProfile: "off", maxDocIrMiB: 32))
        @Assert(result.declarations.size, 150)
        for (symbol in result.declarations) {
            @Expect(symbol.headerSpelling, signature)
            @Expect(symbol.signatureHighlight.isNone())
        }
        @Expect(api_render.docIrFitsEncodedBudget(result, api_model.DOC_IR_MAX_JSON_DOCUMENT_BYTES))
        var budgetWarnings: Int64 = 0
        for (diagnostic in result.diagnostics) {
            @Expect(diagnostic.code != "CJDOC3027")
            if (diagnostic.code == "CJDOC3028") { budgetWarnings++ }
        }
        @Expect(budgetWarnings, 1)
    }
}
