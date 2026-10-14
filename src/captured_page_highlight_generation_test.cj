package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func capturedPageHighlightBlocks(node: api_model.MarkdownNode,
    blocks: ArrayList<api_model.MarkdownNode>): Unit {
    if (node.kind == "code_block") { blocks.add(node) }
    for (child in node.children) { capturedPageHighlightBlocks(child, blocks) }
}

private func expectCapturedPageHighlightPolicy(setting: String, expectedState: String): Unit {
    let code = "let 名称 = #\"raw <script>\"#\n"
    let fence = "~~~cj\n" + code + "~~~\n"
    let project = i18nTestProject("/** API summary.\n *\n * " + fence.replace("\n", "\n * ") + "\n */")
    try {
        Directory.create(project.join("docs"))
        File.writeTo(project.join("docs/guide.md"), ("# Guide\n\n" + fence).toArray())
        File.writeTo(project.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"zh-CN\"\n" +
            "languages = [\"zh-CN\", \"en\"]\n" + setting +
            "\n[[docs.pages]]\nid = \"guide\"\nsource = \"docs/guide.md\"\n" +
            "route = \"concepts/highlight.html\"\n").toArray())
        let generated = i18nTestGenerate(project)
        // The public capture entry also works without a source asset collector.
        let recaptured = captureDocumentationPages(generated, GenerationRequest(project.toString()))
        for (documentation in [generated, recaptured]) {
            var guides: Int64 = 0
            for (page in documentation.pages where page.id == "guide") {
                let blocks = ArrayList<api_model.MarkdownNode>()
                capturedPageHighlightBlocks(page.markdown, blocks)
                @Expect(blocks.size, 1)
                @Expect(blocks[0].literal, code)
                let highlight = blocks[0].metadata.getOrThrow().codeHighlight
                if (expectedState == "absent") { @Expect(highlight.isNone()) } else {
                    let prepared = highlight.getOrThrow()
                    @Expect(prepared.state, expectedState)
                    @Expect(prepared.matchesSource(code))
                    if (expectedState == "plain") {
                        @Expect(prepared.reason, Some("disabled"))
                        @Expect(prepared.spans.size, 0)
                    } else { @Expect(!prepared.spans.isEmpty()) }
                }
                guides++
            }
            @Expect(guides, 1)
        }
        let encoded = api_render.encodeDocIr(generated)
        let _ = removeIfExists(project, recursive: true)
        let imported = api_render.decodeDocIr(encoded)
        @Expect(api_render.encodeDocIr(imported), encoded)
        var html = ""
        for (artifact in api_render.renderDocumentationFormatsWithOptions(imported, ["html"], locale: "zh-CN")) {
            if (artifact.path == "html/concepts/highlight.html") { html = artifact.content }
        }
        @Expect(!html.isEmpty())
        @Expect(html.contains("&lt;script&gt;"))
        @Expect(!html.contains("<script>"))
        @Expect(html.contains("<span class=\"code-"), expectedState == "complete")
    } finally { let _ = removeIfExists(project, recursive: true) }
}

@When[os == "Linux"]
@Test
class CapturedPageHighlightGenerationTest {
    @TestCase
    func defaultPolicyHighlightsCapturedCangjie(): Unit {
        expectCapturedPageHighlightPolicy("", "complete")
    }

    @TestCase
    func disabledPolicyLeavesCapturedMetadataAbsent(): Unit {
        expectCapturedPageHighlightPolicy("[highlight]\nmode = \"off\"\n", "absent")
    }

    @TestCase
    func excludedLanguagePreservesDisabledMetadata(): Unit {
        expectCapturedPageHighlightPolicy("[highlight]\nlanguages = [\"python\"]\n", "plain")
    }

    @TestCase
    func selectedAliasRetainsCapturedHighlighting(): Unit {
        expectCapturedPageHighlightPolicy("[highlight]\nmode = \"static\"\nlanguages = [\"CJ\"]\n", "complete")
    }
}
