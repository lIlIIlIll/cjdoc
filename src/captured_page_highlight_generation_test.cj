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

    @TestCase
    func sourceFreeBindingsKeepRealBodyPositionsWithoutPromotingExamples(): Unit {
        let project = i18nTestProject("/** Addition. */", extra: "private func hidden(): Unit {}\n")
        let marker = "<!-- cjdoc-bind target=\"language_fixture.add\" version=\"fixture-v1\" -->"
        try {
            Directory.create(project.join("docs"))
            File.writeTo(project.join("docs/guide.md"), ("# Guide\n\n" +
                "Ordinary cjdoc-inline-binding-0 text.\n\n" +
                "~~~text\n" + marker + "\n~~~\n\n" +
                "> " + marker + "\n\n" +
                "    " + marker + "\n\n" +
                "Before real binding.\n" + marker + "\nAfter real binding.\n\n" +
                "<!-- cjdoc-bind target=\"language_fixture.hidden\" provenance=\"private/source.cj\" -->\n\n" +
                "After hidden binding.\n\n" +
                "| A | B |\n| - | - |\n| one | two |\n" +
                "<!-- cjdoc-bind target=\"TableTarget\" -->\n| three | four |\n").toArray())
            File.writeTo(project.join("cjdoc.toml"), ("[[docs.pages]]\nid = \"guide\"\n" +
                "source = \"docs/guide.md\"\nroute = \"concepts/bindings.html\"\n").toArray())
            let generated = i18nTestGenerate(project)
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(generated))
            let _ = removeIfExists(project, recursive: true)
            let values = api_render.renderDocumentationFormatsWithOptions(imported, ["html"], locale: "en")
            var guide = ""
            var home = ""
            for (artifact in values) {
                if (artifact.path == "html/concepts/bindings.html") { guide = artifact.content }
                if (artifact.path == "html/index.html") { home = artifact.content }
            }
            @Expect(home.contains("href=\"concepts/bindings.html\""))
            @Expect(guide.split("class=\"inline-binding\"").size, 4)
            let chipAt = guide.indexOf("class=\"inline-binding\"").getOrThrow()
            @Expect(guide.indexOf("Before real binding.").getOrThrow() < chipAt)
            @Expect(chipAt < guide.indexOf("After real binding.").getOrThrow())
            let indexAt = guide.indexOf("id=\"conceptual-bindings-heading\"").getOrThrow()
            @Expect(guide.indexOf("After hidden binding.").getOrThrow() < indexAt)
            let associations = guide[indexAt..]
            @Expect(associations.contains("fixture-v1"))
            @Expect(associations.split("symbols/symbol-").size, 2)
            @Expect(associations.contains("Not available in this audience"))
            @Expect(!guide.contains("language_fixture.hidden"))
            @Expect(!guide.contains("private/source.cj"))
            @Expect(guide.contains("Ordinary cjdoc-inline-binding-0 text."))
            @Expect(guide.contains("<blockquote><pre>&lt;!-- cjdoc-bind target="))
            @Expect(!guide.contains("<p><div class=\"inline-binding\""))
            @Expect(guide.split("<table>").size, 2)
            let tableStart = guide.indexOf("<table>").getOrThrow()
            let tableEnd = guide.indexOf("</table>", tableStart).getOrThrow()
            let table = guide[tableStart..tableEnd]
            @Expect(table.contains("one"))
            @Expect(table.contains("three"))
            @Expect(table.contains("class=\"inline-binding\""))
            @Expect(table.contains("TableTarget"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }


    @TestCase
    func sourceFreeOpaqueConsumersMatchUnmodifiedStandaloneMarkdown(): Unit {
        let marker = "<!-- cjdoc-bind target=\"language_fixture.add\" -->"
        let bodies = [
            ("html", "<div>\n" + marker + "\n</div>\n"),
            ("comment", "<!-- outer\n" + marker + "\n-->\n"),
            ("fence", "~~~text\n" + marker + "\n~~~\n"),
            ("indent", "    " + marker + "\n"),
            ("quote", "> " + marker + "\n"),
            ("escaped", "\\" + marker + "\n"),
            ("code", "Inline `prefix\n    " + marker + "\nsuffix` end.\n")
        ]
        let project = i18nTestProject("/** Addition. */")
        try {
            Directory.create(project.join("docs"))
            var config = "[highlight]\nmode = \"off\"\n"
            for ((id, body) in bodies) {
                File.writeTo(project.join("docs/" + id + ".md"), body.replace("\n", "\r\n").toArray())
                config += "\n[[docs.pages]]\nid = \"" + id + "\"\nsource = \"docs/" + id + ".md\"\n" +
                    "route = \"concepts/" + id + ".html\"\ntitle = \"" + id + "\"\n"
            }
            File.writeTo(project.join("cjdoc.toml"), config.toArray())
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(i18nTestGenerate(project)))
            let _ = removeIfExists(project, recursive: true)
            let actual = api_render.renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
            for ((id, body) in bodies) {
                let original = parseStandaloneMarkdown(body.replace("\n", "\r\n"), highlightMode: "off")
                let oracle = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
                    api_model.ProjectInfo("oracle"), api_model.ConfigurationSnapshot(lintProfile: "off"),
                    pages: [api_model.DocumentationPage(id, "docs/" + id + ".md", "concepts/" + id + ".html",
                        id, "guide", body, original)])
                let expected = api_render.renderDocumentationFormatsWithOptions(oracle, ["markdown"], locale: "en")
                var html = ""
                var markdown = ""
                var expectedMarkdown = ""
                for (artifact in actual) {
                    if (artifact.path == "html/concepts/" + id + ".html") { html = artifact.content }
                    if (artifact.path == "markdown/concepts/" + id + ".md") { markdown = artifact.content }
                }
                for (artifact in expected) {
                    if (artifact.path == "markdown/concepts/" + id + ".md") { expectedMarkdown = artifact.content }
                }
                @Expect(html.contains(api_render.renderStandaloneMarkdownHtml(original)))
                @Expect(markdown, expectedMarkdown)
                @Expect(!html.contains("class=\"inline-binding\""))
                @Expect(!html.contains("class=\"conceptual-bindings\""))
                var captured = false
                for (page in imported.pages where page.id == id) {
                    @Expect(page.bindings.isEmpty())
                    @Expect(page.targetSymbolIds.isEmpty())
                    captured = true
                }
                @Expect(captured)
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func capturedDirectivesPreserveOriginalParagraphAndReferenceBoundaries(): Unit {
        let marker = "<!-- cjdoc-bind target=\"language_fixture.add\" -->"
        let bodies = [
            ("inline", "Inline `prefix\n" + marker + "\nsuffix` end.\n"),
            ("reference", "[example][ref]\n\n[ref]: https://example.test/ \"before\n" + marker + "\nafter\"\n"),
            ("lazy", "> Quoted paragraph\n" + marker + "\nafter quote\n")
        ]
        let project = i18nTestProject("/** Addition. */")
        try {
            Directory.create(project.join("docs"))
            var config = "[highlight]\nmode = \"off\"\n"
            for ((id, body) in bodies) {
                File.writeTo(project.join("docs/" + id + ".md"), body.toArray())
                config += "\n[[docs.pages]]\nid = \"" + id + "\"\nsource = \"docs/" + id + ".md\"\n" +
                    "route = \"concepts/" + id + ".html\"\n"
            }
            File.writeTo(project.join("cjdoc.toml"), config.toArray())
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(i18nTestGenerate(project)))
            let _ = removeIfExists(project, recursive: true)
            let actual = api_render.renderDocumentationFormatsWithOptions(imported, ["html", "markdown"], locale: "en")
            for ((id, body) in bodies) {
                let original = parseStandaloneMarkdown(body, highlightMode: "off")
                var captured: ?api_model.DocumentationPage = None
                for (page in imported.pages where page.id == id) { captured = Some(page) }
                let page = captured.getOrThrow()
                @Expect(page.bindings.size, if (id == "lazy") { 0 } else { 1 })
                var html = ""
                var markdown = ""
                for (artifact in actual) {
                    if (artifact.path == "html/concepts/" + id + ".html") { html = artifact.content }
                    if (artifact.path == "markdown/concepts/" + id + ".md") { markdown = artifact.content }
                }
                @Expect(html.split("class=\"inline-binding\"").size, if (id == "lazy") { 1 } else { 2 })
                @Expect(html.contains("class=\"conceptual-bindings\""), id != "lazy")
                if (id == "inline") {
                    @Expect(html.contains("Inline `prefix"))
                    @Expect(html.contains("suffix` end."))
                    @Expect(!html.contains("<code>prefix"))
                    @Expect(markdown.contains("prefix"))
                    @Expect(markdown.contains("suffix"))
                } else if (id == "reference") {
                    @Expect(html.contains("[example][ref]"))
                    @Expect(html.contains("[ref]: <a href=\"https://example.test/\""))
                    @Expect(html.contains(">https://example.test/</a>"))
                    @Expect(!html.contains(">example</a>"))
                    @Expect(markdown.contains("before"))
                    @Expect(markdown.contains("after"))
                } else {
                    @Expect(html.contains(api_render.renderStandaloneMarkdownHtml(original)))
                    let oracle = api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
                        api_model.ProjectInfo("oracle"), api_model.ConfigurationSnapshot(lintProfile: "off"),
                        pages: [api_model.DocumentationPage(id, "docs/" + id + ".md", "concepts/" + id + ".html",
                            id, "guide", body, original)])
                    var expectedMarkdown = ""
                    for (artifact in api_render.renderDocumentationFormatsWithOptions(oracle, ["markdown"], locale: "en")) {
                        if (artifact.path == "markdown/concepts/" + id + ".md") { expectedMarkdown = artifact.content }
                    }
                    @Expect(markdown, expectedMarkdown)
                    @Expect(page.targetSymbolIds.isEmpty())
                }
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

}
