package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let CONCEPTUAL_HEADER_MANIFEST =
    "[package]\nname = \"docs_header_probe\"\nversion = \"1.0.0\"\ncjc-version = \"1.2.0\"\noutput-type = \"static\"\n"

private func conceptualHeaderProject(configuration: String): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"))
    Directory.create(root.join("docs"))
    File.writeTo(root.join("cjpm.toml"), CONCEPTUAL_HEADER_MANIFEST.toArray())
    File.writeTo(root.join("src/api.cj"),
        "package docs_header_probe\n/** Value. */\npublic func value(): Int64 { 1 }\n".toArray())
    File.writeTo(root.join("docs/guide.md"), "# Guide\n\nThis page explains the API.\n".toArray())
    File.writeTo(root.join("cjdoc.toml"), configuration.toArray())
    root
}

private func conceptualHeaderGenerate(project: Path): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(project.toString(), lintProfile: "off",
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
}

private func conceptualGuide(documentation: api_model.DocumentationSet): api_model.DocumentationPage {
    for (page in documentation.pages where page.kind == "guide" && page.source == "docs/guide.md") {
        return page
    }
    throw IllegalArgumentException("registered guide was not captured")
}

// One assertion set for both spellings: a header comment may not change what the
// reader registers, and the captured page must keep its route and body.
private func expectEquivalentGuide(configuration: String): Unit {
    let project = conceptualHeaderProject(configuration)
    try {
        let documentation = conceptualHeaderGenerate(project)
        let guide = conceptualGuide(documentation)
        @Expect(guide.route, "concepts/guide.html")
        @Expect(guide.text.contains("This page explains the API."))
        @Expect(documentation.pages.size > 1)
    } finally {
        let _ = removeIfExists(project, recursive: true)
    }
}

@Test
class ConceptualConfigContractTest {
    @TestCase
    func headerTrailingCommentsRegisterTheSameGuideAsThePlainHeader(): Unit {
        let plain = "[[docs.pages]]\nsource = \"docs/guide.md\"\nroute = \"concepts/guide\"\n"
        expectEquivalentGuide(plain)
        for suffix in [" # Guide registration", "\t# Guide registration", "   ", " # 中文说明"] {
            expectEquivalentGuide("[[docs.pages]]" + suffix + "\n" +
                "source = \"docs/guide.md\"\nroute = \"concepts/guide\"\n")
        }
    }

    @TestCase
    func quotedHashesAndPseudoHeadersInsideMultilineValuesStayValues(): Unit {
        let configuration = "[fixture-note]\n" +
            "text = \"\"\"\n[[docs.pages]]\nsource = \"docs/missing.md\"\n\"\"\"\n\n" +
            "[[docs.pages]] # real registration\n" +
            "source = \"docs/guide.md\"\nroute = \"concepts/guide\"\n" +
            "title = \"Guide # not a comment\"\n"
        let project = conceptualHeaderProject(configuration)
        try {
            let documentation = conceptualHeaderGenerate(project)
            let guide = conceptualGuide(documentation)
            @Expect(guide.title, "Guide # not a comment")
            @Expect(guide.route, "concepts/guide.html")
            for (page in documentation.pages) {
                @Expect(page.source != "docs/missing.md", true)
            }
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }

    @TestCase
    func malformedOrIncompletePageConfigurationKeepsAnActionableError(): Unit {
        for configuration in [
            "[[docs.pages]] # missing body\n",
            "[[docs.pages]]\nroute = \"concepts/guide\"\n",
            "[[docs.pages]]\nsource = \"docs/guide.md\"\nroute = \"../escape\"\n",
            "[[docs.pages]]\nsource = \"docs/guide.md\"\ntitle = \"\"\" multiline\n"
        ] {
            let project = conceptualHeaderProject(configuration)
            try {
                @ExpectThrows[IllegalArgumentException](conceptualHeaderGenerate(project))
            } finally {
                let _ = removeIfExists(project, recursive: true)
            }
        }
    }

    @TestCase
    func projectWithoutPageConfigurationIsNotReportedAsABrokenConfig(): Unit {
        let project = conceptualHeaderProject("")
        try {
            let documentation = conceptualHeaderGenerate(project)
            @Expect(documentation.pages.isEmpty())
        } finally {
            let _ = removeIfExists(project, recursive: true)
        }
    }
}
