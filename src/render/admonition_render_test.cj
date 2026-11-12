package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let ADMONITION_RENDER_MODULE = "cjdoc:module:v1:admonition-render"
private let ADMONITION_RENDER_OWNER =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aadmonition-render::fixture::class:Cache#g0()"
private let ADMONITION_RENDER_MEMBER =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aadmonition-render::fixture::Cache::function:commit#g0()"
private let ADMONITION_RENDER_SOURCE = SourceRange("src/cache.cj",
    SourcePosition(1, 1, 0), SourcePosition(24, 1, 23))

private func admonitionParagraph(text: String): MarkdownNode {
    MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)])
}

private func admonitionBlock(level: String, text: String): MarkdownNode {
    MarkdownNode("admonition", MarkdownNodeMetadata.forAdmonition(level),
        children: [admonitionParagraph(text)])
}

private func admonitionWrapper(level: String, text: String): MarkdownNode {
    MarkdownNode("document", children: [admonitionBlock(level, text)])
}

private func admonitionTestTag(level: String, text: String, language: String):
    (DocTag, DocumentationText) {
    let markdown = admonitionWrapper(level, text)
    let tag = DocTag(level, "", text, contentLanguage: Some(language),
        translationState: "unpaired", descriptionMarkdown: Some(markdown))
    let localized = DocumentationText("", level, "", Some(language), text, markdown,
        state: "unpaired")
    (tag, localized)
}

private func admonitionTestComments(): (DocComment, DocComment) {
    let ownerComment = DocComment("", "Cache container.", "",
        MarkdownNode("document", children: [
            admonitionParagraph("Cache container."),
            admonitionBlock("note", "A cache entry is a hint, not a source of truth.")
        ]), localizationScope: "admonitions")
    let (warningTag, warningText) = admonitionTestTag("warning",
        "Revalidate the source before committing. AdmonitionSearchSentinel. Keep the captured revision.", "en")
    let (dangerTag, dangerText) = admonitionTestTag("danger",
        "Never publish a partial captured result.", "en")
    let memberComment = DocComment("", "Applies one cache update.", "",
        MarkdownNode("document", children: [admonitionParagraph("Applies one cache update.")]),
        tags: [warningTag, dangerTag], localizedTexts: [warningText, dangerText],
        localizationScope: "admonitions")
    (ownerComment, memberComment)
}

private func admonitionTestDocumentation(ownerComment: DocComment,
    memberComment: DocComment): DocumentationSet {
    let owner = SymbolDoc(ADMONITION_RENDER_OWNER, "class", "Cache", "fixture.Cache",
        "fixture", ADMONITION_RENDER_MODULE, "public", ADMONITION_RENDER_SOURCE,
        "public class Cache", SemanticInfo("partial", "ast"),
        documentation: Some(ownerComment))
    let member = SymbolDoc(ADMONITION_RENDER_MEMBER, "function", "commit",
        "fixture.Cache.commit", "fixture", ADMONITION_RENDER_MODULE, "public",
        ADMONITION_RENDER_SOURCE, "public func commit(): Unit", SemanticInfo("partial", "ast"),
        ownerId: Some(ADMONITION_RENDER_OWNER), documentation: Some(memberComment))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("admonition-render"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", ADMONITION_RENDER_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(ADMONITION_RENDER_MODULE, "admonition-render", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", ADMONITION_RENDER_MODULE,
            sourceFiles: ["src/cache.cj"], symbolIds: [ADMONITION_RENDER_OWNER, ADMONITION_RENDER_MEMBER])],
        files: [FileDoc("src/cache.cj", ADMONITION_RENDER_MODULE, "fixture")],
        declarations: [owner, member])
}

private func admonitionMemberSummary(html: String, memberId: String): String {
    let marker = "data-member-symbol-id=\"${memberId}\""
    let start = html.indexOf(marker).getOrThrow()
    let summaryParts = html[start..].split("<summary", 2)
    if (summaryParts.size < 2) {
        throw IllegalArgumentException("missing admonition member summary")
    }
    let summary = summaryParts[1].split("</summary>", 2)
    if (summary.size < 2) {
        throw IllegalArgumentException("unterminated admonition member summary")
    }
    summary[0]
}

private func admonitionArtifact(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts) { if (artifact.path == path) { return artifact.content } }
    throw IllegalArgumentException("missing admonition test artifact")
}

private func admonitionProjectionEntry(projection: DocumentationSearchProjection,
    canonicalId: String): SearchProjectedEntry {
    for (entry in projection.entries) {
        if (entry.canonicalId == canonicalId) { return entry }
    }
    throw IllegalArgumentException("missing admonition search entry")
}

private func admonitionLongBody(): String {
    let out = StringBuilder()
    var count: Int64 = 0
    while (count < 2048) { out.append("x"); count++ }
    out.append(" BoundedAdmonitionTailSentinel")
    out.toString()
}

@Test
class AdmonitionRenderTest {
    @TestCase
    func capturedBlocksRenderAsLocalizedStaticAsidesAndEscapeAuthorHtml(): Unit {
        let malicious = admonitionBlock("danger", "Untrusted <img src=x onerror=alert(1)> text.")
        let html = renderStandaloneMarkdownHtml(MarkdownNode("document", children: [malicious]),
            locale: "zh-CN")
        @Expect(html.contains("<aside class=\"cj-admonition cj-admonition--danger\" " +
            "data-admonition-level=\"danger\" aria-label=\"危险\">"), true)
        @Expect(html.contains("<span class=\"cj-admonition__icon\" aria-hidden=\"true\">"), true)
        @Expect(html.contains("<span class=\"cj-admonition__title\">危险</span>"), true)
        @Expect(html.contains("<div class=\"cj-admonition__body cj-prose\">"), true)
        @Expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"), true)
        @Expect(html.contains("<img src=x"), false)
        @Expect(html.contains("role=\"alert\""), false)
        @Expect(html.contains("aria-live"), false)
    }

    @TestCase
    func independentTagsRenderAfterIntroductionAndKeepCollapsedRiskVisible(): Unit {
        let (ownerComment, memberComment) = admonitionTestComments()
        let documentation = admonitionTestDocumentation(ownerComment, memberComment)
        let artifacts = renderDocumentationFormatsWithOptions(documentation, ["html", "markdown"],
            locale: "en")
        let ownerHtml = admonitionArtifact(artifacts, "html/" + symbolPagePath(documentation.declarations[0]))
        @Expect(ownerHtml.contains("data-admonition-level=\"note\" aria-label=\"Note\""), true)
        let summary = admonitionMemberSummary(ownerHtml, ADMONITION_RENDER_MEMBER)
        @Expect(summary.contains("<span class=\"cj-risks\">"), true)
        @Expect(summary.contains("cj-risk cj-risk--danger"), true)
        @Expect(summary.contains("cj-risk cj-risk--warning"), true)
        @Expect(summary.contains("data-admonition-level=\"danger\""), true)
        @Expect(summary.contains("data-admonition-level=\"warning\""), true)
        @Expect(summary.contains(" Danger</span>"), true)
        @Expect(summary.contains(" Warning</span>"), true)
        @Expect(summary.indexOf("Danger").getOrThrow() <
            summary.indexOf("Warning").getOrThrow(), true)
        @Expect(ownerHtml.contains("role=\"alert\""), false)

        let snapshot = DocumentationReadSnapshot(documentation, locale: Some("zh-CN"))
        let markdown = snapshot.renderDeclarationMarkdown(ADMONITION_RENDER_MEMBER).getOrThrow()
        // Markdown escapes punctuation; these checks pin authored prose and ordering, not escape spelling.
        @Expect(markdown.contains("> [!WARNING]"), true)
        @Expect(markdown.contains("Revalidate the source before committing"), true)
        @Expect(markdown.contains("Keep the captured revision"), true)
        @Expect(markdown.contains("> [!CAUTION]"), true)
        @Expect(markdown.contains("Never publish a partial captured result"), true)
        @Expect(markdown.contains("[!DANGER]"), false)
        @Expect(markdown.contains("原文：en"), true)
        @Expect(markdown.split("AdmonitionSearchSentinel").size, 2)
        @Expect(markdown.indexOf("> [!WARNING]").getOrThrow() <
            markdown.indexOf("Revalidate the source before committing").getOrThrow(), true)
        @Expect(markdown.indexOf("Keep the captured revision").getOrThrow() <
            markdown.indexOf("> [!CAUTION]").getOrThrow(), true)
        @Expect(markdown.indexOf("> [!CAUTION]").getOrThrow() <
            markdown.indexOf("Never publish a partial captured result").getOrThrow(), true)

        let search = JsonNode.parse(admonitionArtifact(artifacts, "html/search-index.json")).asObject()
        let entries = search.get("entries").getOrThrow().asArray()
        var matched = false
        for (index in 0..entries.size()) {
            let entry = entries[index].asObject()
            if (entry.get("canonicalId").getOrThrow().asString() != ADMONITION_RENDER_MEMBER) { continue }
            matched = true
            let body = entry.get("body").getOrThrow().asString()
            @Expect(body.split("AdmonitionSearchSentinel").size, 2)
            @Expect(entry.get("bodyTruncated").getOrThrow().asBool(), false)
        }
        @Expect(matched, true)
        let coverage = search.get("coverage").getOrThrow().asObject()
        @Expect(coverage.get("bodyComplete").getOrThrow().asBool(), true)
    }

    @TestCase
    func fullAndBoundedSearchRetainAdmonitionBodyCompleteness(): Unit {
        let longAlert = admonitionBlock("warning", admonitionLongBody())
        let longComment = DocComment("", "", "", MarkdownNode("document", children: [longAlert]),
            localizationScope: "admonitions")
        let emptyComment = DocComment("", "", "", MarkdownNode("document"),
            localizationScope: "admonitions")
        let documentation = admonitionTestDocumentation(emptyComment, longComment)
        let snapshot = DocumentationReadSnapshot(documentation, locale: Some("en"))
        let complete = buildDocumentationSearchProjection(snapshot, "full-ir")
        let completeEntry = admonitionProjectionEntry(complete, ADMONITION_RENDER_MEMBER)
        @Expect(completeEntry.body.contains("BoundedAdmonitionTailSentinel"), true)
        @Expect(completeEntry.body.split("BoundedAdmonitionTailSentinel").size, 2)
        @Expect(completeEntry.bodyTruncated, false)
        @Expect(complete.bodyComplete, true)

        let bounded = buildDocumentationSearchProjection(snapshot, searchStaticProfileName())
        let boundedEntry = admonitionProjectionEntry(bounded, ADMONITION_RENDER_MEMBER)
        @Expect(boundedEntry.body.size, 2000)
        @Expect(boundedEntry.body.contains("BoundedAdmonitionTailSentinel"), false)
        @Expect(boundedEntry.bodyTruncated, true)
        @Expect(bounded.bodyComplete, false)
        @Expect(bounded.truncatedCount, 1)
    }
}
