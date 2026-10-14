package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let SUBJECT_REFERENCE_MODULE = "cjdoc:module:v1:subject-reference"
private let SUBJECT_REFERENCE_ID = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asubject-reference::fixture::function:api#g0()"
private let SUBJECT_REFERENCE_FIELD = SUBJECT_REFERENCE_ID + ":doc:see:" + SUBJECT_REFERENCE_ID

private func subjectReferenceDocumentation(language: ?String, defaultLanguage: ?String,
    localized!: Bool = true): DocumentationSet {
    let tree = MarkdownNode("document")
    let text = DocumentationText(SUBJECT_REFERENCE_FIELD, "see", "fixture.api", language,
        "", tree, state: "empty", referenceState: "resolved", targetSymbolId: Some(SUBJECT_REFERENCE_ID))
    let comment = DocComment("@see fixture.api", "", "", tree,
        defaultLanguage: defaultLanguage, localizedTexts: if (localized) { [text] } else { [] },
        tags: if (localized) { [] } else { [DocTag("see", "fixture.api", "", referenceState: "resolved",
            targetSymbolId: Some(SUBJECT_REFERENCE_ID))] })
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let symbol = SymbolDoc(SUBJECT_REFERENCE_ID, "function", "api", "fixture.api", "fixture",
        SUBJECT_REFERENCE_MODULE, "public", source, "public func api(): Unit", SemanticInfo("partial", "ast"),
        documentation: Some(comment))
    let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("subject-reference"),
        ConfigurationSnapshot(lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            SUBJECT_REFERENCE_MODULE, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(SUBJECT_REFERENCE_MODULE, "subject-reference", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", SUBJECT_REFERENCE_MODULE, sourceFiles: ["src/api.cj"], symbolIds: [SUBJECT_REFERENCE_ID])],
        files: [FileDoc("src/api.cj", SUBJECT_REFERENCE_MODULE, "fixture")], declarations: [symbol])
    decodeDocIr(encodeDocIr(documentation))
}

private func subjectReferenceHtmlPage(artifacts: Array<RenderArtifact>): RenderArtifact {
    for (artifact in artifacts where artifact.path.startsWith("html/symbols/") &&
        artifact.content.contains("<h3>See also</h3>")) { return artifact }
    throw IllegalArgumentException("missing subject-only HTML reference")
}

private func subjectReferenceMarkdown(artifacts: Array<RenderArtifact>): String {
    for (artifact in artifacts where artifact.path.startsWith("markdown/") &&
        artifact.content.contains("#### See also")) { return artifact.content }
    throw IllegalArgumentException("missing subject-only Markdown reference")
}

private func verifySubjectReferenceProvenance(documentation: DocumentationSet, state: String,
    provenance: String): Unit {
    let authorIr = encodeDocIr(documentation)
    let selected = projectDocumentationLanguage(documentation, "en")
    let selectedIr = encodeDocIr(selected)
    var selectedReference = false
    for (tag in selected.declarations[0].documentation.getOrThrow().tags where tag.name == "see") {
        @Expect(tag.description.isEmpty())
        @Expect(tag.translationState, state)
        @Expect(tag.referenceState, "resolved")
        @Expect(tag.targetSymbolId, Some(SUBJECT_REFERENCE_ID))
        selectedReference = true
    }
    @Expect(selectedReference)
    let site = renderDocumentationFormatsWithOptions(selected, ["html", "markdown"], locale: "en")
    for (values in [site, HtmlDocumentationRenderer().render(selected)]) {
        let page = subjectReferenceHtmlPage(values)
        let row = page.content.split("<h3>See also</h3>", 2)[1].split("</ul>", 2)[0]
        @Expect(row.contains("href=\"../" + page.path.removePrefix("html/") + "\""))
        @Expect(row.contains("<code>fixture.api</code>"))
        if (!state.isEmpty()) {
            @Expect(row.contains("data-translation-state=\"" + state + "\""))
            @Expect(row.contains(provenance))
            @Expect(row.contains("id=\"doc-field-" + contractFingerprint(SUBJECT_REFERENCE_FIELD) + "\""))
        } else {
            @Expect(!row.contains("content-language"))
            @Expect(!row.contains("doc-field-"))
        }
    }
    for (values in [site, MarkdownDocumentationRenderer().render(selected)]) {
        let section = subjectReferenceMarkdown(values).split("#### See also", 2)[1]
        @Expect(section.contains("- `fixture.api`"))
        if (!state.isEmpty()) { @Expect(section.contains(provenance.replace("-", "\\-"))) }
        else { @Expect(!section.contains(" — ")) }
    }
    @Expect(encodeDocIr(selected), selectedIr)
    @Expect(encodeDocIr(documentation), authorIr)
}

@Test
class SubjectOnlyReferenceProvenanceTest {
    @TestCase
    func subjectOnlyDefaultReferenceKeepsFallbackProvenanceAndResolvedLink(): Unit {
        verifySubjectReferenceProvenance(subjectReferenceDocumentation(Some("zh-CN"), Some("zh-CN")),
            "empty-fallback", "Empty translation; original text: zh-CN")
    }

    @TestCase
    func subjectOnlyExactAndUnknownReferencesKeepTheirOwnProvenance(): Unit {
        verifySubjectReferenceProvenance(subjectReferenceDocumentation(Some("en"), Some("zh-CN")),
            "empty", "Translation is empty")
        verifySubjectReferenceProvenance(subjectReferenceDocumentation(None, None), "unknown", "unknown language")
    }

    @TestCase
    func unlocalizedSubjectOnlyReferenceKeepsExistingOutputWithoutInventedProvenance(): Unit {
        verifySubjectReferenceProvenance(subjectReferenceDocumentation(None, None, localized: false), "", "")
    }
}
