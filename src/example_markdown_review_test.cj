package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func exampleReviewDocumentation(examples: String): api_model.DocumentationSet {
    let root = Directory.createTemp(getTempDirectory())
    try {
        Directory.create(root.join("src"))
        File.writeTo(root.join("cjpm.toml"),
            "[package]\nname = \"example_review\"\nversion = \"0.1.0\"\ncjc-version = \"1.1.0\"\noutput-type = \"static\"\n".toArray())
        File.writeTo(root.join("src/api.cj"), ("package example_review\n/**\n * Main docs.\n" +
            examples + "\n */\npublic func api(): Unit {}\npublic class SomeType {}\n").toArray())
        DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

private func exampleReviewSymbol(documentation: api_model.DocumentationSet): api_model.SymbolDoc {
    for (symbol in documentation.declarations) { if (symbol.name == "api") { return symbol } }
    throw IllegalArgumentException("missing example API")
}

private func exampleReviewSemanticNodes(node: api_model.MarkdownNode,
    nodes: ArrayList<api_model.MarkdownNode>): Unit {
    if (node.kind == "semantic_link") { nodes.add(node) }
    for (child in node.children) { exampleReviewSemanticNodes(child, nodes) }
}

@Test
class ExampleMarkdownReviewTest {
    @TestCase
    func retainedCodeAndImageUsePublishedAssetPath(): Unit {
        // Uses a committed fixture project: local-image resolution depends on the
        // project root, and a temporary root is canonicalized differently per
        // platform, which would make this case assert the environment, not the
        // documented behaviour.
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "example_assets", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        // Local asset embedding is a Linux-only capability in this repository, so the
        // published-path assertions only apply where it is enabled; the rendered code
        // block is asserted on every platform.
        if (!publicLocalAssetEmbeddingEnabled()) {
            @Expect(documentation.assets.size, 0)
            let hosted = api_render.HtmlDocumentationRenderer().render(documentation)
            let hostedHtml = renderedContent(hosted)
            @Expect(hostedHtml.contains("data-language=\"cangjie\""))
            @Expect(!hostedHtml.contains("alt=\"pixel\""))
            return
        }
        @Expect(documentation.assets.size, 1)
        @Expect(!publicHasDiagnostic(documentation, "CJDOC4026"))
        let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        var publishedPath = ""
        for (artifact in artifacts) { if (artifact.mediaType == "image/gif") { publishedPath = artifact.path } }
        @Assert(!publishedPath.isEmpty())
        let html = renderedContent(artifacts)
        @Expect(html.contains("src=\"../" + publishedPath.removePrefix("html/") + "\""))
        @Expect(html.contains("alt=\"pixel\""))
        @Expect(html.contains("data-language=\"cangjie\""))
    }

    @TestCase
    func discardedImageOnlyExamplesHaveNoAssetsOrAssetDiagnostics(): Unit {
        let documentation = exampleReviewDocumentation(
            " * @example Existing\n * ![pixel](pixel.gif) <script>unsafe</script>\n *\n * @example Missing\n * ![missing](missing.gif)")
        @Expect(documentation.assets.size, 0)
        @Expect(!publicHasDiagnostic(documentation, "CJDOC4026"))
        for (tag in exampleReviewSymbol(documentation).documentation.getOrThrow().tags) {
            if (tag.name == "example") { @Expect(tag.exampleMarkdown.isNone()) }
        }
        let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        for (artifact in artifacts) { @Expect(artifact.mediaType != "image/gif") }
        let html = renderedContent(artifacts)
        // The legacy path displayed literal Markdown, not an image element.
        @Expect(html.contains("![pixel](pixel.gif)"))
        @Expect(html.contains("![missing](missing.gif)"))
        @Expect(html.contains("&lt;script&gt;unsafe&lt;/script&gt;"))
        @Expect(!html.contains("<img "))
        @Expect(!html.contains("<script>unsafe</script>"))
        @Expect(!html.contains("sha256-"))
    }

    @TestCase
    func exampleHeadingsAndFragmentsAreScopedPerExample(): Unit {
        let body = "\n * ## Usage\n * [jump](#usage)\n *\n * ```cj\n * let n = 1\n * ```\n *";
        let documentation = exampleReviewDocumentation(" * @example First" + body + "\n * @example Second" + body)
        let artifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        var checkedPage = false
        for (artifact in artifacts) {
            if (!artifact.path.startsWith("html/symbols/") || !artifact.content.contains("example-list")) { continue }
            let html = artifact.content
            let ids = ArrayList<String>()
            for (part in html.split("id=\"")) {
                let id = part.split("\"", 2)[0]
                if (id.contains("--doc-usage")) { ids.add(id) }
            }
            @Assert(ids.size, 2)
            @Expect(ids[0] != ids[1])
            @Expect(html.contains("href=\"#" + ids[0] + "\">jump"))
            @Expect(html.contains("href=\"#" + ids[1] + "\">jump"))
            checkedPage = true
        }
        @Expect(checkedPage)
    }

    @TestCase
    func exampleSemanticLinksUseNormalResolutionAndDiagnostics(): Unit {
        let documentation = exampleReviewDocumentation(
            " * @example Links\n * {@link SomeType} and {@link MissingType}\n *\n * ```cj\n * let n = 1\n * ```")
        let nodes = ArrayList<api_model.MarkdownNode>()
        for (tag in exampleReviewSymbol(documentation).documentation.getOrThrow().tags) {
            if (let Some(tree) <- tag.exampleMarkdown) { exampleReviewSemanticNodes(tree, nodes) }
        }
        @Assert(nodes.size, 2)
        @Expect(nodes[0].metadata.getOrThrow().semanticState, Some("resolved"))
        @Expect(nodes[0].metadata.getOrThrow().semanticTargetSymbolId.isSome())
        @Expect(nodes[1].metadata.getOrThrow().semanticState, Some("unresolved"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2032"))
        let html = renderedContent(api_render.HtmlDocumentationRenderer().render(documentation))
        @Expect(html.contains(">SomeType</a>"))
        @Expect(html.contains("MissingType"))
    }

    @TestCase
    func excessiveExampleNestingFallsBackWithoutCollectingAssets(): Unit {
        let prefix = String.fromUtf8(Array<Byte>(60, repeat: b'>')) + " "
        let documentation = exampleReviewDocumentation(" * @example Deep\n * " + prefix +
            "![missing](missing.gif)\n * " + prefix + "\n * " + prefix +
            "```cj\n * " + prefix + "let n = 1\n * " + prefix + "```")
        @Expect(documentation.assets.size, 0)
        @Expect(!publicHasDiagnostic(documentation, "CJDOC4026"))
        let tag = exampleReviewSymbol(documentation).documentation.getOrThrow().tags[0]
        @Expect(tag.exampleMarkdown.isNone())
        @Expect(tag.description.contains("![missing](missing.gif)"))
    }

    @TestCase
    func projectionPreservesExecutionBytesAndExampleIdentity(): Unit {
        let examples = " * @example Bytes {must-pass}\n * ```cj\n * let n = 1\n * ```"
        let documentation = exampleReviewDocumentation(examples)
        let symbol = exampleReviewSymbol(documentation)
        let projected = symbol.documentation.getOrThrow().tags[0]
        @Expect(projected.description.toArray(), "```cj\nlet n = 1\n```".toArray())
        @Expect(projected.directives.toArray(), "{must-pass}".toArray())
        @Expect(api_render.exampleEvidenceKey(symbol.id, projected.subject), symbol.id + "\u{0}Bytes")
    }
}
