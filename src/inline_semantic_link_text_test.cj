package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func semanticLinkTexts(tree: api_model.MarkdownNode): Array<String> {
    let result = ArrayList<String>()
    if (tree.kind == "text") { result.add(tree.literal) }
    for (child in tree.children) { result.add(all: semanticLinkTexts(child)) }
    result.toArray()
}

private func semanticLinkTargets(tree: api_model.MarkdownNode): Array<String> {
    let result = ArrayList<String>()
    if (tree.kind == "semantic_link") {
        result.add(tree.metadata.getOrThrow().semanticTarget.getOrThrow())
    }
    for (child in tree.children) { result.add(all: semanticLinkTargets(child)) }
    result.toArray()
}

// The same visible characters a reader sees: a semantic link renders its target
// once, so its duplicated text child is not counted twice.
private func semanticLinkRenderedText(tree: api_model.MarkdownNode): String {
    if (tree.kind == "semantic_link") { return tree.literal }
    var text = if (tree.kind == "text") { tree.literal } else { "" }
    for (child in tree.children) { text += semanticLinkRenderedText(child) }
    text
}

// The scanner separates where it searches from where it emits, so every author
// character survives regardless of how many unusable markers precede a valid one.
@Test
class InlineSemanticLinkAuthorTextTest {
    @TestCase
    func anEmptyTargetBeforeAValidLinkKeepsEveryPrefixCharacter(): Unit {
        let body = "Prefix {@link } middle {@link value} tail."
        let tree = parseStandaloneMarkdown(body)
        let targets = semanticLinkTargets(tree)
        @Assert(targets.size, 1)
        @Expect(targets[0], "value")
        @Expect(semanticLinkRenderedText(tree), "Prefix {@link } middle value tail.")
        @Expect(semanticLinkTexts(tree).contains("Prefix {@link } middle "))
        @Expect(semanticLinkTexts(tree).contains(" tail."))
    }

    @TestCase
    func unusableMarkersBeforeBetweenAndAfterValidLinksPreserveAllText(): Unit {
        for (invalid in ["{@link }", "{@link open", "{@link {nested}"]) {
            for ((body, visible, linkedCount) in [
                ("A ${invalid} B {@link value} C", "A ${invalid} B value C", 1),
                ("A {@link value} B ${invalid} C {@link value} D", "A value B ${invalid} C value D", 2),
                ("A {@link value} B ${invalid} C", "A value B ${invalid} C", 1)
            ]) {
                let tree = parseStandaloneMarkdown(body)
                @Expect(semanticLinkRenderedText(tree), visible)
                let targets = semanticLinkTargets(tree)
                @Expect(targets.size, linkedCount)
                for (target in targets) { @Expect(target, "value") }
            }
        }
    }

    @TestCase
    func validLinksStillResolveWhileAuthorPrefixesRemainInEveryRepresentation(): Unit {
        let root = i18nTestProject("/** Prefix {@link } middle {@link value} tail. */\n" +
            "public func value(): Int64 { 1 }")
        try {
            let documentation = i18nTestGenerate(root)
            var symbol: ?api_model.SymbolDoc = None
            for (declaration in documentation.declarations where declaration.name == "value") {
                symbol = Some(declaration)
            }
            let comment = symbol.getOrThrow().documentation.getOrThrow()
            @Expect(semanticLinkRenderedText(comment.markdown), "Prefix {@link } middle value tail.")
            let nodes = ArrayList<api_model.MarkdownNode>()
            for (child in comment.markdown.children) { appendSemanticLinks(child, nodes) }
            @Assert(nodes.size, 1)
            @Expect(nodes[0].metadata.getOrThrow().semanticState, Some("resolved"))
            @Expect(nodes[0].metadata.getOrThrow().semanticTargetSymbolId.isSome())
            let decoded = api_render.decodeDocIr(api_render.encodeDocIr(documentation))
            var decodedSymbol: ?api_model.SymbolDoc = None
            for (declaration in decoded.declarations where declaration.name == "value") {
                decodedSymbol = Some(declaration)
            }
            let decodedComment = decodedSymbol.getOrThrow().documentation.getOrThrow()
            @Expect(semanticLinkRenderedText(decodedComment.markdown),
                "Prefix {@link } middle value tail.")
            for (format in ["html", "markdown"]) {
                let artifacts = api_render.renderDocumentationFormatsWithOptions(decoded, [format],
                    locale: "en")
                var body = ""
                for (artifact in artifacts) { body += artifact.content }
                // Markdown output escapes literal braces; both forms keep the
                // author words, the valid link, and the trailing sentence.
                @Expect(body.contains("Prefix "))
                @Expect(body.contains(" middle "))
                @Expect(body.contains("value"))
                @Expect(body.contains(" tail."))
                if (format == "html") {
                    @Expect(body.contains("Prefix {@link } middle "))
                    @Expect(body.contains(">value</a>"))
                }
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}

private func appendSemanticLinks(tree: api_model.MarkdownNode,
    result: ArrayList<api_model.MarkdownNode>): Unit {
    if (tree.kind == "semantic_link") { result.add(tree) }
    for (child in tree.children) { appendSemanticLinks(child, result) }
}
