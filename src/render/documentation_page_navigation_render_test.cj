package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let FROZEN_PAGE_MODULE = "cjdoc:module:v1:frozen-page"
private let FROZEN_PAGE_PREFIX = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Afrozen-page::fixture::"
private let FROZEN_PAGE_RUN = FROZEN_PAGE_PREFIX + "function:run#g0()"
private let FROZEN_PAGE_OVERLOAD = FROZEN_PAGE_PREFIX + "function:run#g0(String)"
private let FROZEN_PAGE_HIDDEN = FROZEN_PAGE_PREFIX + "function:hidden#g0()"
private let FROZEN_PAGE_ROUTE = "concepts/guides/deep/start.html"
private let FROZEN_PAGE_CODE = "let original  =  \"external.run\" // copied spelling"
private let FROZEN_PAGE_HEADER = "public func run( /* exact source */ ): Unit"

private func frozenPageBinding(target: String, navigation: ?TypeNavigation,
    state!: String = "unresolved", id!: ?String = None, selector!: String = "original  selector"): DocumentationPageBinding {
    DocumentationPageBinding(target, selector, "authored", "2.7.0", 7,
        state: state, targetSymbolId: id, navigation: navigation)
}

private func frozenPageNavigation(url: String, reason!: String = "Pinned guide documentation"): TypeNavigation {
    TypeNavigation("resolved", "manual", reason, documentSetId: "external-docs", indexIdentity: "published-index",
        symbolKey: "external.run#function#g0()", url: url, apiIdentity: "library-api-2.7", language: "en")
}

private func frozenPageDocument(bindings: Array<DocumentationPageBinding>): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 80, 79))
    let semantic = SemanticInfo("partial", "ast")
    let run = SymbolDoc(FROZEN_PAGE_RUN, "function", "run", "fixture.run", "fixture", FROZEN_PAGE_MODULE,
        "public", source, FROZEN_PAGE_HEADER, semantic)
    let overload = SymbolDoc(FROZEN_PAGE_OVERLOAD, "function", "run", "fixture.run", "fixture", FROZEN_PAGE_MODULE,
        "public", source, "public func run(value!: String = \"raw value\"): Unit", semantic,
        parameters: [ParameterDoc("value", TypeRef("named", "String", SemanticType("unavailable")), defaultExpression: Some("\"raw value\""))])
    let hidden = SymbolDoc(FROZEN_PAGE_HIDDEN, "function", "hidden", "fixture.hidden", "fixture", FROZEN_PAGE_MODULE,
        "private", source, "private func hidden(): Unit", semantic)
    let targets = ArrayList<String>()
    for (binding in bindings) {
        if (let Some(id) <- binding.targetSymbolId) { if (!targets.contains(id)) { targets.add(id) } }
    }
    let guide = DocumentationPage("guide", "docs/en/start.md", FROZEN_PAGE_ROUTE, "Frozen guide", "guide", "Guide body",
        MarkdownNode("document", children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Guide body")]),
            MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("fenced", Some("`"), 3, "cangjie", "cangjie", ""), literal: FROZEN_PAGE_CODE)]),
        language: Some("en"), defaultLanguage: Some("en"), bindings: bindings, targetSymbolIds: targets.toArray())
    let external = DocumentationPage("external", "docs/en/external.md", "dependencies/external.html", "External API", "guide", "External body",
        MarkdownNode("document", children: [MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
            children: [MarkdownNode("text", literal: "External API")])]), language: Some("en"), defaultLanguage: Some("en"))
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("frozen-page"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", FROZEN_PAGE_MODULE, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(FROZEN_PAGE_MODULE, "frozen-page", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", FROZEN_PAGE_MODULE, sourceFiles: ["src/api.cj"], symbolIds: [FROZEN_PAGE_RUN, FROZEN_PAGE_OVERLOAD, FROZEN_PAGE_HIDDEN])],
        files: [FileDoc("src/api.cj", FROZEN_PAGE_MODULE, "fixture")], declarations: [run, overload, hidden], pages: [guide, external])
    decodeDocIr(encodeDocIr(original))
}

private func frozenPageContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing frozen page artifact")
}

private func frozenPageSearchBinding(artifacts: Array<RenderArtifact>, index!: Int64 = 0): JsonObject {
    let root = JsonNode.parse(frozenPageContent(artifacts, "html/search-index.json")).asObject()
    let entries = root.get("entries").getOrThrow().asArray()
    for (position in 0..entries.size()) {
        let object = entries.get(position).getOrThrow().asObject()
        if (object.get("id").getOrThrow().asString() == "cjdoc:concept:guide") {
            return object.get("bindings").getOrThrow().asArray().get(index).getOrThrow().asObject()
        }
    }
    throw IllegalArgumentException("missing frozen page search binding")
}

@Test
class DocumentationPageNavigationRenderTest {
    @TestCase
    func frozenExternalLinksRebaseFromNestedPagesAndKeepLocalBindingState(): Unit {
        for (url in ["https://docs.example.test/api/run.html#run", "http://docs.example.test/run.html",
            "https://docs.example.test:8443/%E4%B8%AD%E6%96%87.html#%E7%B1%BB",
            "./dependencies/external.html#symbol:name",
            "https://docs.example.test/api.md?plain=1#L3", "./dependencies/external.html?plain=1#symbol:name",
            "./dependencies/external.html#standalone--doc-external-api"]) {
            let navigation = frozenPageNavigation(url)
            let document = frozenPageDocument([frozenPageBinding("external.run", Some(navigation))])
            let encoded = encodeDocIr(document)
            let artifacts = renderDocumentationFormatsWithOptions(document, ["html", "markdown"], locale: "en")
            let html = frozenPageContent(artifacts, "html/" + FROZEN_PAGE_ROUTE)
            let markdown = frozenPageContent(artifacts, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
            let relative = !url.startsWith("http")
            let htmlHref = if (relative) { "../../../" + url.removePrefix("./") } else { url }
            let markdownHref = if (relative) { "../../../../html/" + url.removePrefix("./") } else { url }
            @Expect(html.contains("href=\"" + htmlHref + "\""))
            @Expect(html.contains("data-state=\"unresolved\""))
            @Expect(html.contains("data-doc-match=\"manual\""))
            @Expect(html.contains("title=\"Declared API version: 2.7.0; manual: Pinned guide documentation; API identity: library-api-2.7\""))
            @Expect(!html.contains("../https://"))
            @Expect(html.contains("let original  =  &quot;external.run&quot; // copied spelling"))
            @Expect(markdown.contains("[`external.run`](" + markdownHref + " \"Declared API version: 2.7.0; manual: Pinned guide documentation; API identity: library-api-2.7\")"))
            @Expect(markdown.contains("```cangjie\n" + FROZEN_PAGE_CODE + "\n```"))
            if (relative) { @Expect(frozenPageContent(artifacts, "html/dependencies/external.html").contains("id=\"standalone--doc-external-api\"")) }
            let search = frozenPageSearchBinding(artifacts)
            @Expect(search.get("state").getOrThrow().asString(), "unresolved")
            @Expect(search.get("href").getOrThrow().asString(), url.removePrefix("./"))
            let persisted = search.get("navigation").getOrThrow().asObject()
            @Expect(persisted.get("url").getOrThrow().asString(), url)
            @Expect(persisted.get("matchLevel").getOrThrow().asString(), "manual")
            @Expect(document.pages[0].bindings[0].state, "unresolved")
            @Expect(document.generator.toolchain.isEmpty())
            @Expect(encodeDocIr(document), encoded)
            let direct = MarkdownDocumentationRenderer().render(document)
            let directGuide = frozenPageContent(direct, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
            @Expect(directGuide, markdown)
        }
    }

    @TestCase
    func onlyLegacyOrMatchingFrozenLocalTargetsUseLocalArtifacts(): Unit {
        let legacy = frozenPageDocument([frozenPageBinding("fixture.run", None, state: "resolved", id: Some(FROZEN_PAGE_RUN))])
        let baseline = renderDocumentationFormatsWithOptions(legacy, ["html", "markdown", "symbol-index"], locale: "en")
        let inventory = JsonNode.parse(frozenPageContent(baseline, "symbol-index/symbol-index.json")).asObject()
        let entries = inventory.get("entries").getOrThrow().asArray()
        var actual = ""
        for (position in 0..entries.size()) {
            let object = entries.get(position).getOrThrow().asObject()
            if (object.get("id").getOrThrow().asString() == FROZEN_PAGE_RUN) { actual = object.get("href").getOrThrow().asString() }
        }
        @Assert(!actual.isEmpty())
        @Expect(!frozenPageContent(baseline, actual).isEmpty())
        let matching = TypeNavigation("resolved", "exact", "Exact local source", symbolKey: FROZEN_PAGE_RUN, url: actual.removePrefix("html/"))
        for (document in [legacy, frozenPageDocument([frozenPageBinding("fixture.run", Some(matching), state: "resolved", id: Some(FROZEN_PAGE_RUN))])]) {
            let artifacts = renderDocumentationFormatsWithOptions(document, ["html", "markdown"], locale: "en")
            let html = frozenPageContent(artifacts, "html/" + FROZEN_PAGE_ROUTE)
            @Expect(html.contains("href=\"../../../" + actual.removePrefix("html/") + "\""))
            let markdown = frozenPageContent(artifacts, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
            var matchingTarget = false
            for (artifact in artifacts where artifact.path.startsWith("markdown/") && artifact.path.endsWith(".md")) {
                if (!artifact.content.contains("public func run")) { continue }
                let marker = artifact.content.split("<a id=\"", 2)
                if (marker.size != 2) { continue }
                let anchor = marker[1].split("\"", 2)[0]
                if (markdown.contains("](../../../" + artifact.path.removePrefix("markdown/") + "#" + anchor)) { matchingTarget = true }
            }
            @Expect(matchingTarget)
            @Expect(frozenPageSearchBinding(artifacts).get("href").getOrThrow().asString(), actual.removePrefix("html/"))
        }
        let external = frozenPageDocument([frozenPageBinding("fixture.run", Some(frozenPageNavigation("https://docs.example.test/correct-version.html")),
            state: "resolved", id: Some(FROZEN_PAGE_RUN))])
        let externalArtifacts = renderDocumentationFormatsWithOptions(external, ["html", "markdown"], locale: "en")
        let externalHtml = frozenPageContent(externalArtifacts, "html/" + FROZEN_PAGE_ROUTE)
        @Expect(externalHtml.contains("href=\"https://docs.example.test/correct-version.html\""))
        let externalMarkdown = frozenPageContent(externalArtifacts, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
        @Expect(externalMarkdown.contains("](https://docs.example.test/correct-version.html "))
        @Expect(frozenPageSearchBinding(externalArtifacts).get("href").getOrThrow().asString(), "https://docs.example.test/correct-version.html")
        let unresolved = frozenPageDocument([frozenPageBinding("fixture.run", Some(TypeNavigation("unresolved", "none", "Wrong dependency version")),
            state: "resolved", id: Some(FROZEN_PAGE_RUN))])
        let unresolvedArtifacts = renderDocumentationFormatsWithOptions(unresolved, ["html", "markdown"], locale: "en")
        let unresolvedHtml = frozenPageContent(unresolvedArtifacts, "html/" + FROZEN_PAGE_ROUTE)
        let chip = unresolvedHtml.split("class=\"conceptual-bindings\"", 2)[1].split("</section>", 2)[0]
        @Expect(!chip.contains("href="))
        @Expect(chip.contains("Wrong dependency version"))
        let unresolvedMarkdown = frozenPageContent(unresolvedArtifacts, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
        @Expect(!unresolvedMarkdown.contains("[`fixture.run`]("))
        @Expect(frozenPageSearchBinding(unresolvedArtifacts).get("href").getOrThrow().isNull)
        @Expect(unresolved.pages[0].bindings[0].state, "resolved")
    }

    @TestCase
    func filteredUnavailableAndAmbiguousBindingsNeverAcquireExternalFallbacks(): Unit {
        let secret = frozenPageNavigation("https://docs.example.test/SecretNavigation.html", reason: "SecretNavigationReason")
        @ExpectThrows[IllegalArgumentException](frozenPageBinding("UnavailableSecret", Some(secret), state: "unavailable"))
        let bindings = [frozenPageBinding("SecretTarget", Some(secret), state: "resolved", id: Some(FROZEN_PAGE_HIDDEN), selector: "SecretSelector"),
            frozenPageBinding("UnavailableSecret", None, state: "unavailable", selector: "UnavailableSelector"),
            frozenPageBinding("ConflictingTarget", Some(secret), state: "conflict"),
            frozenPageBinding("AmbiguousTarget", Some(secret), state: "ambiguous"),
            frozenPageBinding("UncertainDocumentation", Some(TypeNavigation("ambiguous", "none", "Conflicting documentation identities")))]
        let document = frozenPageDocument(bindings)
        let artifacts = renderDocumentationFormatsWithOptions(document, ["html", "markdown"], locale: "en")
        let html = frozenPageContent(artifacts, "html/" + FROZEN_PAGE_ROUTE)
        let markdown = frozenPageContent(artifacts, "markdown/" + FROZEN_PAGE_ROUTE.removeSuffix(".html") + ".md")
        let search = frozenPageContent(artifacts, "html/search-index.json")
        for (content in [html, markdown, search]) {
            @Expect(!content.contains("SecretTarget"))
            @Expect(!content.contains("SecretSelector"))
            @Expect(!content.contains("UnavailableSecret"))
            @Expect(!content.contains("UnavailableSelector"))
        }
        @Expect(!html.contains("href=\"https://docs.example.test/SecretNavigation.html\""))
        @Expect(!markdown.contains("](https://docs.example.test/SecretNavigation.html"))
        for (content in [html, markdown]) {
            @Expect(content.contains("Conflicting markers"))
            @Expect(content.contains("Ambiguous target"))
            @Expect(content.contains("Ambiguous documentation target"))
        }
        @Expect(frozenPageSearchBinding(artifacts).get("href").getOrThrow().isNull)
        @Expect(frozenPageSearchBinding(artifacts).get("state").getOrThrow().asString(), "conflict")
        @Expect(frozenPageSearchBinding(artifacts, index: 1).get("href").getOrThrow().isNull)
        @Expect(frozenPageSearchBinding(artifacts, index: 1).get("state").getOrThrow().asString(), "ambiguous")
        @Expect(frozenPageSearchBinding(artifacts, index: 2).get("href").getOrThrow().isNull)
        @Expect(frozenPageSearchBinding(artifacts, index: 2).get("state").getOrThrow().asString(), "unresolved")
    }

    @TestCase
    func unsafeFrozenPageUrlsAreRejectedBeforeTheyCanBecomeLinks(): Unit {
        for (url in ["javascript:alert(1)", "//example.test/run", "../run.html", "file:///private/run.html",
            "https://docs.example.test/run.html\" onclick=\"alert(1)",
            "https://docs.example.test/type.html#%ZZ", "https://docs.example.test:99999/type.html",
            "https://docs.example.test/type.html#%0Ainjected", "https://docs.example.test/%2e%2e/type.html",
            "https://docs.example.test/type.html#%2f", "https://user@docs.example.test/type.html",
            "https://docs.example.test:0/type.html", "https://docs.example.test:/type.html",
            "https://docs.example.test/%E4%B8/type.html", "./dependencies/type.html#%ZZ",
            "./unsafe:path.html#symbol", "https://docs.example.test/api.md?plain=1&plain=2#L3",
            "https://docs.example.test/api.md?plain=%0A#L3", "./dependencies/external.html?=1#symbol",
            "./dependencies/external.html?plain=1?extra=2#symbol", "./dependencies/external.html?plain=1;extra=2#symbol"]) {
            @ExpectThrows[IllegalArgumentException](frozenPageDocument([frozenPageBinding("external.run", Some(frozenPageNavigation(url)))]))
        }
    }

    @TestCase
    func symbolInventoryPublishesExactSourceHeadersForEveryVisibleOverload(): Unit {
        let document = frozenPageDocument([])
        let inventory = JsonNode.parse(SymbolIndexDocumentationRenderer().render(document)[0].content).asObject()
        @Expect(inventory.get("schemaVersion").getOrThrow().asString(), "cjdoc.symbol-index/2")
        var checked: Int64 = 0
        let entries = inventory.get("entries").getOrThrow().asArray()
        for (position in 0..entries.size()) {
            let object = entries.get(position).getOrThrow().asObject()
            for (symbol in document.declarations where symbol.id == object.get("id").getOrThrow().asString()) {
                @Expect(object.get("sourceHeader").getOrThrow().asString(), symbol.headerSpelling)
                checked++
            }
        }
        @Expect(checked, 2)
    }
}
