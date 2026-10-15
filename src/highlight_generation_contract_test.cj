package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HighlightGenerationContractTest {
    @TestCase
    func publicPolicyOverrideAndAudienceDoNotLeakDerivedData(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"highlight_contract\"\n" +
                "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
            File.writeTo(root.join("src/api.cj"), ("package highlight_contract\n" +
                "/** Visible.\n * ```python\n * value = True\n * ```\n */\npublic func visible(): Unit {}\n" +
                "/** Hidden.\n * ```python\n * secret = True\n * ```\n */\nprivate func hidden(): Unit {}\n").toArray())
            let documentation = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(languages: ["cangjie", "python"]))))
            var backendWarnings: Int64 = 0
            for (diagnostic in documentation.diagnostics where diagnostic.code == "CJDOC3120") { backendWarnings++ }
            @Expect(backendWarnings, 1)
            for (symbol in documentation.declarations) {
                if (symbol.name == "visible") {
                    let signature = symbol.signatureHighlight.getOrThrow()
                    @Expect(signature.state, "complete")

                    let comment = symbol.documentation.getOrThrow()
                    var codeBlocks: Int64 = 0
                    for (block in comment.markdown.children where block.kind == "code_block") {
                        codeBlocks++
                        @Expect(block.literal, "value = True\n")
                        @Expect(block.metadata.getOrThrow().codeHighlight.getOrThrow().reason, Some("backend-unavailable"))
                    }
                    @Expect(codeBlocks, 1)
                } else if (symbol.name == "hidden") {
                    @Expect(symbol.signatureHighlight.isNone())
                    let comment = symbol.documentation.getOrThrow()
                    for (node in comment.markdown.children where node.kind == "code_block") {
                        @Expect(node.metadata.getOrThrow().codeHighlight.isNone())
                    }
                }
            }
            let disabled = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT, highlight: Some(HighlightConfig(mode: "off"))))
            for (symbol in disabled.declarations) { @Expect(symbol.signatureHighlight.isNone()) }
            let strict = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(languages: ["cangjie", "python"], onError: "error"))))
            @Expect(strict.status, "partial")
            var backendErrors: Int64 = 0
            for (diagnostic in strict.diagnostics where diagnostic.code == "CJDOC4027") {
                @Expect(diagnostic.severity, "error")
                backendErrors++
            }
            @Expect(backendErrors, 1)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func filteredLanguageDoesNotPrepareOrReportBackendFailure(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"highlight_contract\"\n" +
                "version = \"1.0.0\"\noutput-type = \"static\"\n").toArray())
            File.writeTo(root.join("cjdoc.toml"), ("[i18n]\ndefault-language = \"en\"\n" +
                "languages = [\"en\"]\n").toArray())
            File.writeTo(root.join("src/api.cj"), ("package highlight_contract\n/** Visible.\n" +
                " * @description[lang=zh-CN]\n * ```python\n * filtered_language_secret = True\n * ```\n */\n" +
                "public func visible(): Unit {}\n").toArray())
            let document = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                highlight: Some(HighlightConfig(languages: ["cangjie", "python"]))))
            for (diagnostic in document.diagnostics) {
                @Expect(diagnostic.code != "CJDOC3120" && diagnostic.code != "CJDOC4027")
            }
            var retained: Int64 = 0
            for (symbol in document.declarations) {
                for (text in symbol.documentation.getOrThrow().localizedTexts where text.language == Some("zh-CN")) {
                    for (node in text.markdown.children where node.kind == "code_block") {
                        retained++
                        @Expect(node.literal.contains("filtered_language_secret"))
                        @Expect(node.metadata.getOrThrow().codeHighlight.isNone())
                    }
                }
            }
            @Expect(retained, 1)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }



    @TestCase
    func standaloneCodeMarkupEscapesAuthorInput(): Unit {
        let source = "\t中😀é <script>&amp;</code>\r\nnext\r\n"
        let block = api_model.MarkdownNode("code_block", literal: source)
        let html = api_render.renderStandaloneMarkdownHtml(block)

        @Expect(html.contains("&lt;script&gt;&amp;amp;&lt;/code&gt;"))
        @Expect(!html.contains("<script>"))
        @Expect(!html.contains("onclick="))
    }
}
