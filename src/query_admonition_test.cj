package cjdoc

import cjdoc.model.*
import cjdoc.model as api_model
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let QUERY_ADMONITION_MODULE = "cjdoc:module:v1:query-admonition"
private let QUERY_ADMONITION_SYMBOL =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aquery-admonition::fixture::function:refresh#g0()"
private let QUERY_ADMONITION_AST_ONLY_SYMBOL =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aquery-admonition::fixture::function:signal#g0()"
private func queryAdmonitionBlock(level: String, text: String): MarkdownNode {
    MarkdownNode("admonition", MarkdownNodeMetadata.forAdmonition(level), children: [
        MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)])
    ])
}

private func queryAdmonitionWrapper(level: String, text: String): MarkdownNode {
    MarkdownNode("document", children: [queryAdmonitionBlock(level, text)])
}

private func queryAdmonitionDocumentation(): api_model.DocumentationSet {
    let warningBody = "Recheck the captured data. AdmonitionSearchSentinel."
    let warningMarkdown = queryAdmonitionWrapper("warning", warningBody)
    let warning = api_model.DocTag("warning", "", warningBody, contentLanguage: Some("en"),
        translationState: "unpaired", descriptionMarkdown: Some(warningMarkdown))
    let warningText = DocumentationText("", "warning", "", Some("en"), warningBody,
        warningMarkdown, state: "unpaired")
    let tags = [warning, api_model.DocTag("throws", "IOException", "Keep ordinary contract tags separate.")]
    let comment = api_model.DocComment("", "", "", MarkdownNode("document", children: [
        queryAdmonitionBlock("note", "CombinedSearchBody remains searchable.")
    ]), tags: tags, localizedTexts: [warningText], localizationScope: "admonitions")
    let astOnlyComment = api_model.DocComment("", "", "", MarkdownNode("document", children: [
        queryAdmonitionBlock("warning", "ASTOnlySearchBody remains searchable.")
    ]), localizationScope: "admonitions")
    let source = SourceRange("src/refresh.cj", SourcePosition(1, 1, 0), SourcePosition(20, 1, 19))
    let symbol = api_model.SymbolDoc(QUERY_ADMONITION_SYMBOL, "function", "refresh", "fixture.refresh",
        "fixture", QUERY_ADMONITION_MODULE, "public", source, "public func refresh(): Unit",
        api_model.SemanticInfo("partial", "ast"), documentation: Some(comment))
    let astOnly = api_model.SymbolDoc(QUERY_ADMONITION_AST_ONLY_SYMBOL, "function", "signal", "fixture.signal",
        "fixture", QUERY_ADMONITION_MODULE, "public", source, "public func signal(): Unit",
        api_model.SemanticInfo("partial", "ast"), documentation: Some(astOnlyComment))
    api_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("query-admonition"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [api_model.ProviderInfo("ast", "builtin", QUERY_ADMONITION_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(QUERY_ADMONITION_MODULE, "query-admonition", "root", "",
            packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", QUERY_ADMONITION_MODULE,
            sourceFiles: ["src/refresh.cj"], symbolIds: [
                QUERY_ADMONITION_SYMBOL, QUERY_ADMONITION_AST_ONLY_SYMBOL
            ])],
        files: [api_model.FileDoc("src/refresh.cj", QUERY_ADMONITION_MODULE, "fixture")],
        declarations: [symbol, astOnly])
}

private func queryAdmonitionResult(session: DocumentationQuerySession,
    request: String): JsonObject {
    JsonNode.parse(session.execute(request)).asObject()
}

@Test
class DocumentationQueryAdmonitionTest {
    @TestCase
    func descriptionChapterFiltersCapturedTagsAndKeepsAstOnlyAlertsAvailable(): Unit {
        let query = DocumentationQuerySession(queryAdmonitionDocumentation())
        let response = queryAdmonitionResult(query,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${QUERY_ADMONITION_SYMBOL}\"," +
            "\"sections\":[\"description\"],\"language\":\"en\",\"maxBytes\":65536}")
        @Expect(response.get("status").getOrThrow().asString(), "ok")
        let item = response.get("result").getOrThrow().asObject().get("items").getOrThrow()
            .asArray()[0].asObject()
        let sections = item.get("sections").getOrThrow().asArray()
        var description: ?JsonObject = None
        for (index in 0..sections.size()) {
            let section = sections[index].asObject()
            if (section.get("name").getOrThrow().asString() == "description") {
                @Expect(section.get("state").getOrThrow().asString(), "available")
                description = Some(section.get("value").getOrThrow().asObject())
            }
        }
        let value = description.getOrThrow()
        let markdown = value.get("markdown").getOrThrow().asObject()
        let markdownChildren = markdown.get("children").getOrThrow().asArray()
        @Expect(markdownChildren.size(), 1)
        @Expect(markdownChildren[0].asObject().get("kind").getOrThrow().asString(), "admonition")
        @Expect(markdownChildren[0].asObject().get("metadata").getOrThrow().asObject()
            .get("level").getOrThrow().asString(), "note")

        let tags = value.get("documentationTags").getOrThrow().asArray()
        @Expect(tags.size(), 1)
        @Expect(tags[0].asObject().get("name").getOrThrow().asString(), "warning")
        @Expect(tags[0].asObject().get("description").getOrThrow().asString(),
            "Recheck the captured data. AdmonitionSearchSentinel.")
        let tagMarkdown = tags[0].asObject().get("descriptionMarkdown").getOrThrow().asObject()
        let tagAlert = tagMarkdown.get("children").getOrThrow().asArray()[0].asObject()
        @Expect(tagAlert.get("kind").getOrThrow().asString(), "admonition")
        @Expect(tagAlert.get("metadata").getOrThrow().asObject().get("level").getOrThrow().asString(),
            "warning")
        let tagParagraph = tagAlert.get("children").getOrThrow().asArray()[0].asObject()
        @Expect(tagParagraph.get("children").getOrThrow().asArray()[0].asObject()
            .get("literal").getOrThrow().asString(), "Recheck the captured data. AdmonitionSearchSentinel.")
        let localized = value.get("localizedTexts").getOrThrow().asArray()
        @Expect(localized.size(), 1)
        @Expect(localized[0].asObject().get("kind").getOrThrow().asString(), "warning")
        let astOnlyResponse = queryAdmonitionResult(query,
            "{\"operation\":\"get_symbol\",\"symbolId\":\"${QUERY_ADMONITION_AST_ONLY_SYMBOL}\"," +
            "\"sections\":[\"description\"],\"language\":\"en\",\"maxBytes\":65536}")
        let astOnlyItem = astOnlyResponse.get("result").getOrThrow().asObject()
            .get("items").getOrThrow().asArray()[0].asObject()
        var astOnlyAvailable = false
        for (index in 0..astOnlyItem.get("sections").getOrThrow().asArray().size()) {
            let section = astOnlyItem.get("sections").getOrThrow().asArray()[index].asObject()
            if (section.get("name").getOrThrow().asString() != "description") { continue }
            @Expect(section.get("state").getOrThrow().asString(), "available")
            let value = section.get("value").getOrThrow().asObject()
            let astMarkdown = value.get("markdown").getOrThrow().asObject()
            let astAlert = astMarkdown.get("children").getOrThrow().asArray()[0].asObject()
            @Expect(astAlert.get("kind").getOrThrow().asString(), "admonition")
            @Expect(astAlert.get("metadata").getOrThrow().asObject().get("level").getOrThrow().asString(),
                "warning")
            let astParagraph = astAlert.get("children").getOrThrow().asArray()[0].asObject()
            @Expect(astParagraph.get("children").getOrThrow().asArray()[0].asObject()
                .get("literal").getOrThrow().asString(), "ASTOnlySearchBody remains searchable.")
            @Expect(value.get("documentationTags").getOrThrow().asArray().size(), 0)
            @Expect(value.get("localizedTexts").getOrThrow().asArray().size(), 0)
            astOnlyAvailable = true
        }
        @Expect(astOnlyAvailable, true)

    }

    @TestCase
    func fullIrSearchFindsAlertTextFromBothAstAndSelectedTagExactlyOnce(): Unit {
        let query = DocumentationQuerySession(queryAdmonitionDocumentation())
        let tagHit = queryAdmonitionResult(query,
            "{\"operation\":\"search\",\"query\":\"AdmonitionSearchSentinel\"," +
            "\"profile\":\"full-ir\",\"language\":\"en\",\"limit\":10}")
        @Expect(tagHit.get("status").getOrThrow().asString(), "ok")
        let tagItems = tagHit.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
        @Expect(tagItems.size(), 1)
        let tagIdentity = tagItems[0].asObject().get("identity").getOrThrow().asObject()
        @Expect(tagIdentity.get("symbolId").getOrThrow().asString(), QUERY_ADMONITION_SYMBOL)

        let astHit = queryAdmonitionResult(query,
            "{\"operation\":\"search\",\"query\":\"ASTOnlySearchBody\"," +
            "\"profile\":\"full-ir\",\"language\":\"en\",\"limit\":10}")
        @Expect(astHit.get("status").getOrThrow().asString(), "ok")
        let astItems = astHit.get("result").getOrThrow().asObject().get("items").getOrThrow().asArray()
        @Expect(astItems.size(), 1)
        let astIdentity = astItems[0].asObject().get("identity").getOrThrow().asObject()
        @Expect(astIdentity.get("symbolId").getOrThrow().asString(), QUERY_ADMONITION_AST_ONLY_SYMBOL)
    }
}
