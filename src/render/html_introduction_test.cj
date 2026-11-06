package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.collection.*
import std.unittest.testmacro.*

private let INTRO_MODULE = "cjdoc:module:v1:introduction"

private func introductionId(kind: String): String {
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aintroduction::fixture::${kind}:Catalog#g0()"
}

private func introductionParagraph(text: String): MarkdownNode {
    MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)])
}

private func introductionText(kind: String, field: String, language: String,
    state!: String = "valid", multiple!: Bool = false): DocumentationText {
    let text = if (field == "description") { "Detailed introduction" } else { "Brief summary" }
    let paragraphs = if (multiple) {
        [introductionParagraph(text), introductionParagraph("Second summary paragraph")]
    } else { [introductionParagraph(text)] }
    DocumentationText(introductionId(kind) + ":doc:" + field + ":", field, "", Some(language),
        text, MarkdownNode("document", children: paragraphs), state: state)
}

private func introductionPage(kind: String, comment: DocComment, locale: String): String {
    let id = introductionId(kind)
    let source = SourceRange("src/catalog.cj", SourcePosition(1, 1, 0), SourcePosition(1, 20, 19))
    let header = if (kind == "extend") { "extend Catalog" } else { "public class Catalog" }
    let symbol = SymbolDoc(id, kind, "Catalog", "fixture.Catalog", "fixture", INTRO_MODULE,
        "public", source, header, SemanticInfo("partial", "ast"), documentation: Some(comment))
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("introduction"), ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", INTRO_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(INTRO_MODULE, "introduction", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", INTRO_MODULE, sourceFiles: ["src/catalog.cj"], symbolIds: [id])],
        files: [FileDoc("src/catalog.cj", INTRO_MODULE, "fixture")], declarations: [symbol])
    let selected = projectDocumentationLanguage(original, locale)
    for (artifact in HtmlDocumentationRenderer().render(selected)) {
        if (artifact.path.startsWith("html/symbols/") && artifact.content.contains("api-page-header")) {
            return artifact.content
        }
    }
    throw IllegalArgumentException("missing introduction page")
}

@Test
class HtmlIntroductionTest {
    @TestCase
    func localizedDescriptionWithoutSummaryHasOverviewForTypesAndExtensions(): Unit {
        for (kind in ["class", "extend"]) {
            for (locale in ["en", "zh-CN"]) {
                let comment = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some(locale),
                    localizedTexts: [introductionText(kind, "description", locale)])
                let html = introductionPage(kind, comment, locale)
                @Expect(html.contains("id=\"overview\" class=\"api-introduction\""))
                @Expect(html.contains("class=\"description\""))
                @Expect(html.contains("Detailed introduction"))
            }
        }
    }

    @TestCase
    func localizedSummaryParagraphsDoNotInventAnEmptyOverview(): Unit {
        for (kind in ["class", "extend"]) {
            for (locale in ["en", "zh-CN"]) {
                let comment = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some(locale),
                    localizedTexts: [introductionText(kind, "summary", locale, multiple: true)])
                let html = introductionPage(kind, comment, locale)
                @Expect(!html.contains("id=\"overview\""))
                @Expect(!html.contains("class=\"description\""))
                @Expect(html.contains("Brief summary"))
                @Expect(html.contains("Second summary paragraph"))
            }
        }
    }

    @TestCase
    func overviewFollowsSelectedDescriptionFallbackAndRejectsUnusableFields(): Unit {
        for (kind in ["class", "extend"]) {
            let fallback = DocComment("", "", "", MarkdownNode("document"),
                defaultLanguage: Some("zh-CN"), localizedTexts: [
                    introductionText(kind, "description", "zh-CN"),
                    introductionText(kind, "description", "en", state: "empty")])
            let html = introductionPage(kind, fallback, "en")
            @Expect(html.contains("id=\"overview\""))
            @Expect(html.contains("Detailed introduction"))
            @Expect(html.contains("data-translation-state=\"empty-fallback\""))
            for (state in ["empty", "invalid", "conflict"]) {
                let unusable = DocComment("", "", "", MarkdownNode("document"),
                    defaultLanguage: Some("en"), localizedTexts: [
                        introductionText(kind, "summary", "en", multiple: true),
                        introductionText(kind, "description", "en", state: state)])
                let missing = introductionPage(kind, unusable, "en")
                @Expect(!missing.contains("id=\"overview\""))
                @Expect(!missing.contains("class=\"description\""))
            }
        }
    }

    @TestCase
    func legacyOverviewStillExcludesTheLeadingSummaryParagraph(): Unit {
        let summary = introductionParagraph("Legacy summary")
        let description = introductionParagraph("Legacy description")
        for (kind in ["class", "extend"]) {
            let brief = DocComment("", "Legacy summary", "", MarkdownNode("document", children: [summary]))
            let full = DocComment("", "Legacy summary", "Legacy description",
                MarkdownNode("document", children: [summary, description]))
            @Expect(!introductionPage(kind, brief, "en").contains("id=\"overview\""))
            let html = introductionPage(kind, full, "en")
            @Expect(html.contains("id=\"overview\""))
            @Expect(html.contains("<div class=\"description\"><p>Legacy description</p>"))
            @Expect(html.split("Legacy summary").size, 2)
        }
    }
}

private func ownerContextTestSource(line: Int64): SourceRange {
    SourceRange("src/api.cj", SourcePosition(line, 1, line * 10),
        SourcePosition(line, 8, line * 10 + 7))
}

private func ownerContextTestComment(summary: String, description: String,
    tags!: Array<DocTag> = []): DocComment {
    DocComment("", summary, description, MarkdownNode("document", children: [
        introductionParagraph(summary),
        MarkdownNode("heading", children: [MarkdownNode("text", literal: "Owner guidance")]),
        introductionParagraph(description)
    ]), tags: tags)
}

private func ownerContextTestDocument(symbols: Array<SymbolDoc>): DocumentationSet {
    let moduleId = "cjdoc:module:v1:owner-context"
    let symbolIds = ArrayList<String>()
    for (symbol in symbols) { symbolIds.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("owner-context"), ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        modules: [ModuleDoc(moduleId, "owner-context", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            symbolIds: symbolIds.toArray())],
        files: [FileDoc("src/api.cj", moduleId, "fixture")],
        declarations: symbols)
}

private func ownerContextTestPage(symbols: Array<SymbolDoc>, current: SymbolDoc,
    locale!: String = "en"): String {
    let documentation = ownerContextTestDocument(symbols)
    let projection = RenderProjection(documentation)
    renderSymbolPage(documentation, projection, projection.visibleIndex, current,
        HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection), locale: locale)
}

private func expectOwnerContextUniqueIds(html: String): Unit {
    let ids = HashSet<String>()
    let attributes = html.split(" id=\"")
    for (position in 1..attributes.size) {
        let id = attributes[position].split("\"")[0]
        @Expect(ids.add(id))
    }
}

@Test
class HtmlOwnerDocumentationContextTest {
    @TestCase
    func memberContextIncludesOnlyOwnerSummaryIntroductionAndConstraints(): Unit {
        let owner = SymbolDoc("owner-context-box", "class", "Box", "fixture.Box", "fixture",
            "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(1),
            "public class Box", SemanticInfo("partial", "ast"),
            documentation: Some(ownerContextTestComment("Owner summary", "Owner introduction", tags: [
                DocTag("precondition", "", "Owner precondition", fieldId: "shared-field"),
                DocTag("example", "", "owner example payload"),
                DocTag("param", "capacity", "owner parameter payload"),
                DocTag("return", "", "owner return payload")
            ])))
        let current = SymbolDoc("owner-context-read", "function", "read", "fixture.Box.read",
            "fixture", "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(2),
            "public func read(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(owner.id), documentation: Some(ownerContextTestComment(
                "Member summary", "Member introduction", tags: [
                    DocTag("precondition", "", "Member precondition", fieldId: "shared-field")
                ])))
        let sibling = SymbolDoc("owner-context-sibling", "function", "close", "fixture.Box.close",
            "fixture", "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(3),
            "public func close(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(owner.id), documentation: Some(ownerContextTestComment(
                "Sibling summary", "sibling-only prose")))
        let html = ownerContextTestPage([owner, current, sibling], current)
        let memberField = documentationFieldAnchor("shared-field")
        @Expect(html.contains("class=\"owner-documentation-context\""))
        @Expect(html.contains("data-cjdoc-owner-context-source=\"${owner.id}\""))
        @Expect(html.split("data-cjdoc-owner-context-source=\"${owner.id}\"").size - 1, 1)
        @Expect(html.contains("href=\"../${symbolPagePath(owner)}\""))
        @Expect(html.contains("Owner summary"))
        @Expect(html.contains("Owner introduction"))
        @Expect(html.contains("Owner precondition"))
        @Expect(html.contains("Member precondition"))
        @Expect(!html.contains("owner example payload"))
        @Expect(!html.contains("owner parameter payload"))
        @Expect(!html.contains("owner return payload"))
        @Expect(!html.contains("sibling-only prose"))
        @Expect(html.contains("id=\"${memberField}\""))
        expectOwnerContextUniqueIds(html)
        @Expect(html.contains("id=\"${symbolAnchor(owner)}--doc-owner-guidance\""))
        let ownerPage = ownerContextTestPage([owner, current, sibling], owner)
        @Expect(!ownerPage.contains("class=\"owner-documentation-context\""))
    }

    @TestCase
    func nestedTypeOwnerChainIsOuterToInnerAndCycleSafe(): Unit {
        let outerId = "owner-context-outer"
        let innerId = "owner-context-inner"
        let leafId = "owner-context-leaf"
        let outer = SymbolDoc(outerId, "class", "Outer", "fixture.Outer", "fixture",
            "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(1),
            "public class Outer", SemanticInfo("partial", "ast"), ownerId: Some(innerId),
            documentation: Some(ownerContextTestComment("Outer declaration context", "Outer details",
                tags: [DocTag("precondition", "", "Outer constraint", fieldId: "shared-field")])))
        let inner = SymbolDoc(innerId, "class", "Inner", "fixture.Outer.Inner", "fixture",
            "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(2),
            "public class Inner", SemanticInfo("partial", "ast"), ownerId: Some(outerId),
            documentation: Some(ownerContextTestComment("Inner declaration context", "Inner details",
                tags: [DocTag("precondition", "", "Inner constraint", fieldId: "shared-field")])))
        let leaf = SymbolDoc(leafId, "class", "Leaf", "fixture.Outer.Inner.Leaf", "fixture",
            "cjdoc:module:v1:owner-context", "public", ownerContextTestSource(3),
            "public class Leaf", SemanticInfo("partial", "ast"), ownerId: Some(innerId))
        let index = HashMap<String, SymbolDoc>()
        index[outer.id] = outer
        index[inner.id] = inner
        index[leaf.id] = leaf
        let owners = visibleOwnerChain(index, leaf)
        let out = RenderTextBuffer()
        appendOwnerDocumentationContext(out, index, leaf, owners,
            HashMap<String, String>(), "../", "en")
        let html = out.toString()
        @Expect(html.split("data-cjdoc-owner-context-source=").size - 1, 2)
        @Expect(html.contains("href=\"../${symbolPagePath(outer)}\""))
        @Expect(html.contains("href=\"../${symbolPagePath(inner)}\""))
        @Expect(html.contains("Outer declaration context"))
        @Expect(html.contains("Inner declaration context"))
        @Expect(html.indexOf("Outer declaration context").getOrThrow() <
            html.indexOf("Inner declaration context").getOrThrow())
        expectOwnerContextUniqueIds(html)
    }

    @TestCase
    func extensionOwnerRetainsItsContractAndShowsOnlyVisibleResolvedTarget(): Unit {
        let moduleId = "cjdoc:module:v1:owner-context"
        let target = SymbolDoc("owner-context-visible-target", "class", "Target",
            "fixture.Target", "fixture", moduleId, "public", ownerContextTestSource(1),
            "public class Target", SemanticInfo("partial", "ast"),
            documentation: Some(ownerContextTestComment("Visible target summary",
                "Visible target type explanation", tags: [
                    DocTag("example", "", "target example payload")
                ])))
        let hiddenTarget = SymbolDoc("owner-context-hidden-target", "class", "HiddenTarget",
            "fixture.HiddenTarget", "fixture", moduleId, "private", ownerContextTestSource(2),
            "private class HiddenTarget", SemanticInfo("partial", "ast"),
            documentation: Some(ownerContextTestComment("Hidden target summary",
                "Hidden target secret")))
        let extensionHeader = "public extend fixture.Target where T <: Eq<T>"
        let extension = SymbolDoc("owner-context-extension", "extend", "Target", "fixture.Target",
            "fixture", moduleId, "public", ownerContextTestSource(3), extensionHeader,
            SemanticInfo("partial", "ast"), symbolRelationships: [
                SymbolRelationship("extensionTarget", "fixture.Target", "resolved",
                    targetSymbolId: Some(target.id))
            ], documentation: Some(ownerContextTestComment("Extension summary",
                "Extension introduction", tags: [
                    DocTag("precondition", "", "Extension constraint"),
                    DocTag("example", "", "extension example payload")
                ])))
        let extensionMember = SymbolDoc("owner-context-extension-member", "function", "extra",
            "fixture.Target.extra", "fixture", moduleId, "public", ownerContextTestSource(4),
            "public func extra(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(extension.id))
        let unresolvedExtension = SymbolDoc("owner-context-unresolved-extension", "extend",
            "Target", "fixture.Target", "fixture", moduleId, "public", ownerContextTestSource(5),
            "extend fixture.Target", SemanticInfo("partial", "ast"), symbolRelationships: [
                SymbolRelationship("extensionTarget", "fixture.Target", "partial",
                    targetSymbolId: Some(target.id))
            ])
        let unresolvedMember = SymbolDoc("owner-context-unresolved-member", "function", "extra",
            "fixture.Target.extra", "fixture", moduleId, "public", ownerContextTestSource(6),
            "public func extra(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(unresolvedExtension.id))
        let hiddenExtension = SymbolDoc("owner-context-hidden-extension", "extend",
            "HiddenTarget", "fixture.HiddenTarget", "fixture", moduleId, "public",
            ownerContextTestSource(7), "extend fixture.HiddenTarget", SemanticInfo("partial", "ast"),
            symbolRelationships: [
                SymbolRelationship("extensionTarget", "fixture.HiddenTarget", "resolved",
                    targetSymbolId: Some(hiddenTarget.id))
            ])
        let hiddenMember = SymbolDoc("owner-context-hidden-member", "function", "extra",
            "fixture.HiddenTarget.extra", "fixture", moduleId, "public", ownerContextTestSource(8),
            "public func extra(): Unit", SemanticInfo("partial", "ast"),
            ownerId: Some(hiddenExtension.id))
        let symbols = [target, hiddenTarget, extension, extensionMember,
            unresolvedExtension, unresolvedMember, hiddenExtension, hiddenMember]
        let resolvedHtml = ownerContextTestPage(symbols, extensionMember)
        @Expect(resolvedHtml.contains("Extension summary"))
        @Expect(resolvedHtml.contains("Extension introduction"))
        @Expect(resolvedHtml.contains("Extension constraint"))
        @Expect(resolvedHtml.contains("extend fixture.Target where T &lt;: Eq&lt;T&gt;"))
        @Expect(resolvedHtml.contains("Visible target type explanation"))
        @Expect(resolvedHtml.contains("href=\"../${symbolPagePath(target)}\""))
        @Expect(!resolvedHtml.contains("extension example payload"))
        @Expect(!resolvedHtml.contains("target example payload"))

        let unresolvedHtml = ownerContextTestPage(symbols, unresolvedMember)
        @Expect(!unresolvedHtml.contains("data-cjdoc-owner-context-source=\"${target.id}\""))
        @Expect(!unresolvedHtml.contains("Visible target type explanation"))
        let hiddenHtml = ownerContextTestPage(symbols, hiddenMember)
        @Expect(unresolvedHtml.contains("does not imply the member has no usage responsibilities."))
        @Expect(!hiddenHtml.contains("Hidden target summary"))
        @Expect(!hiddenHtml.contains("Hidden target secret"))
    }
}
