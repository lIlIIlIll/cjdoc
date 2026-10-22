package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let NAV_RENDER_MODULE = "cjdoc:module:v1:navigation-render"
private let NAV_RENDER_TOKEN = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Anavigation-render::fixture::class:Token#g0()"
private let NAV_RENDER_ACCEPT = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Anavigation-render::fixture::function:accept#g0(String,Token)"
private let NAV_RENDER_RAW = "public func accept(label!: String = \"Token\", item!: Token): Token"

private func navigationRenderTokens(values: Array<String>): Array<String> {
    let result = ArrayList<String>()
    for (value in values) {
        let kind = match (value) {
            case "public" => "PUBLIC"
            case "func" => "FUNC"
            case "\"Token\"" => "STRING_LITERAL"
            case _ => "IDENTIFIER"
        }
        result.add("${kind}:${value.size}:${value}")
    }
    result.toArray()
}

private func navigationRenderDocument(typeRef: TypeRef, raw!: String = NAV_RENDER_RAW,
    values!: Array<String> = ["public", "func", "accept", "(", "label", "!", ":", "String", "=", "\"Token\"", ",",
        "item", "!", ":", "Token", ")", ":", "Token"], tags!: Array<DocTag> = [],
    tokenVisibility!: String = "public", markdown!: ?MarkdownNode = None): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, raw.size + 1, raw.size))
    let token = SymbolDoc(NAV_RENDER_TOKEN, "class", "Token", "fixture.Token", "fixture", NAV_RENDER_MODULE,
        tokenVisibility, source, tokenVisibility + " class Token", SemanticInfo("partial", "ast"))
    let comment = DocComment("Navigation documentation", "", "", markdown.getOrDefault({ => MarkdownNode("document") }), tags: tags)
    let accept = SymbolDoc(NAV_RENDER_ACCEPT, "function", "accept", "fixture.accept", "fixture", NAV_RENDER_MODULE,
        "public", source, raw, SemanticInfo("partial", "ast"),
        parameters: [ParameterDoc("label", TypeRef("named", "String", SemanticType("unavailable"))), ParameterDoc("item", typeRef)],
        returnType: Some(typeRef), documentation: Some(comment),
        sourceApiSignature: SourceApiSignature("available", tokens: navigationRenderTokens(values)))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("navigation-render"),
        ConfigurationSnapshot(lintProfile: "off"),
        providers: [
            ProviderInfo("ast", "builtin", NAV_RENDER_MODULE, "partial", SemanticCapabilities(true, false, false, true, false)),
            ProviderInfo("source", "test", NAV_RENDER_MODULE, "partial", SemanticCapabilities(true, false, false, true, false)),
            ProviderInfo("compiler", "test", NAV_RENDER_MODULE, "partial", SemanticCapabilities(true, false, false, true, false))],
        modules: [ModuleDoc(NAV_RENDER_MODULE, "navigation-render", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", NAV_RENDER_MODULE, sourceFiles: ["src/api.cj"], symbolIds: [NAV_RENDER_TOKEN, NAV_RENDER_ACCEPT])],
        files: [FileDoc("src/api.cj", NAV_RENDER_MODULE, "fixture")], declarations: [token, accept])
}

private func navigationRenderType(url: String): TypeRef {
    TypeRef("named", "Token", SemanticType("unavailable"), navigation: Some(TypeNavigation("resolved", "manual",
        "Explicit documentation reference", url: url)))
}

private func navigationRenderSignature(html: String): String {
    let blocks = html.split("class=\"signature-block\"", 2)
    @Assert(blocks.size == 2)
    let code = blocks[1].split("<code", 2)
    @Assert(code.size == 2)
    let body = code[1].split(">", 2)
    @Assert(body.size == 2)
    body[1].split("</code>", 2)[0]
}

private func navigationRenderPage(artifacts: Array<RenderArtifact>, prefix: String): RenderArtifact {
    for (artifact in artifacts where artifact.path.startsWith(prefix) && artifact.content.contains("signature-block")) {
        let signature = navigationRenderSignature(artifact.content)
        if (navigationRenderText(signature).startsWith("public func accept")) { return artifact }
    }
    throw IllegalArgumentException("missing public navigation signature page")
}

private func navigationRenderMarkdown(artifacts: Array<RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts where artifact.path.startsWith("markdown/") && artifact.path.endsWith(".md")) { out.append(artifact.content) }
    out.toString()
}

private func navigationRenderText(html: String): String {
    let out = StringBuilder()
    let parts = html.split("<")
    out.append(parts[0])
    for (index in 1..parts.size) {
        if (let Some(end) <- parts[index].indexOf(">")) { out.append(parts[index][end + 1..]) }
    }
    out.toString().replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"")
        .replace("&#39;", "'").replace("&amp;", "&")
}

@Test
class DependencyNavigationRenderTest {
    @TestCase
    func nonTargetNullNavigationCannotBorrowUntrustedCanonicalFallback(): Unit {
        for (kind in ["primitive", "optional", "tuple", "function", "typeParameter"]) {
            for (provider in ["ast", "source", "compiler"]) {
                let reference = TypeRef(kind, "Token", SemanticType("resolved",
                    canonical: Some("fixture.Token"), provider: Some(provider)))
                let document = decodeDocIr(encodeDocIr(navigationRenderDocument(reference)))
                let stored = document.declarations[1].returnType.getOrThrow()
                @Expect(stored.semantic.state, "resolved")
                @Expect(stored.navigation.isNone(), true)
                let links = HtmlTypeLinkIndex(document, RenderProjection(document))
                let allowed = provider == "compiler" && kind != "typeParameter"
                @Expect(links.targetUrl(stored).isSome(), allowed)
                if (!allowed) {
                    let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
                    let signature = navigationRenderSignature(html)
                    @Expect(!signature.contains("class=\"type-link\""))
                    let markdown = navigationRenderMarkdown(renderDocumentationFormatsWithOptions(
                        document, ["markdown"], locale: "en"))
                    @Expect(!markdown.contains("[`Token`]("))
                }
            }
            let explicitUrl = "https://docs.example.test/Token.html#type"
            let explicit = TypeRef(kind, "Token", SemanticType("unavailable"),
                navigation: Some(TypeNavigation("resolved", "manual", "Explicit host decision", url: explicitUrl)))
            let explicitDocument = decodeDocIr(encodeDocIr(navigationRenderDocument(explicit)))
            let storedExplicit = explicitDocument.declarations[1].returnType.getOrThrow()
            @Expect(storedExplicit.semantic.state, "unavailable")
            @Expect(storedExplicit.navigation.getOrThrow().reason, explicit.navigation.getOrThrow().reason)
            @Expect(HtmlTypeLinkIndex(explicitDocument, RenderProjection(explicitDocument))
                .targetUrl(storedExplicit), Some(explicitUrl))
            @Expect(navigationRenderPage(HtmlDocumentationRenderer().render(explicitDocument), "html/symbols/")
                .content.contains("href=\"" + explicitUrl + "\""))
            let markdown = navigationRenderMarkdown(renderDocumentationFormatsWithOptions(
                explicitDocument, ["markdown"], locale: "en"))
            let tokenDestinations = markdown.split("[`Token`](")
            @Assert(tokenDestinations.size > 1)
            for (index in 1..tokenDestinations.size) {
                let target = tokenDestinations[index]
                @Expect(target.startsWith(explicitUrl + ")") ||
                    target.startsWith(explicitUrl + " \"") || target.startsWith(explicitUrl + " '") ||
                    target.startsWith(explicitUrl + " ("))
            }
        }
    }

    @TestCase
    func preboundWebAndPortableUrlsWorkInHtmlAndMarkdown(): Unit {
        for (url in ["https://docs.example.test/api/Token.html#type", "http://docs.example.test/Token.html",
            "dependencies/library/Token.html#type", "./dependencies/library/Token.html#type",
            "dependencies/library/Token.html#%E7%B1%BB"]) {
            let document = navigationRenderDocument(navigationRenderType(url))
            let before = encodeDocIr(document)
            let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
            let expected = if (url.startsWith("http")) { url } else { "../" + url.removePrefix("./") }
            @Expect(html.contains("href=\"" + expected + "\""))
            @Expect(!html.contains("href=\"../http"))
            let signature = navigationRenderSignature(html)
            @Expect(navigationRenderText(signature), NAV_RENDER_RAW)
            @Expect(!signature.contains("&quot;<a"))
            let markdown = navigationRenderMarkdown(renderDocumentationFormatsWithOptions(document, ["markdown"], locale: "en"))
            let destination = if (url.startsWith("http")) { url } else {
                "../../html/" + url.removePrefix("./")
            }
            @Expect(markdown.contains("[`Token`](" + destination + " \"manual: Explicit documentation reference\")"))
            @Expect(markdown.contains("```cangjie\n" + NAV_RENDER_RAW + "\n```"))
            @Expect(!markdown.contains("(../https://"))
            @Expect(encodeDocIr(document), before)
            @Expect(document.declarations[1].parameters[1].typeRef.semantic.state, "unavailable")
        }
    }

    @TestCase
    func bodySemanticLinksConsumeFrozenNavigationWithRelativeFragments(): Unit {
        for (fragment in ["L18", "%E7%B1%BB"]) {
            let url = "./dependencies/category.html#" + fragment
            let node = MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink("external.Token.member", "unresolved",
                semanticNavigation: Some(TypeNavigation("resolved", "manual", "explicit documentation", url: url))),
                children: [MarkdownNode("text", literal: "member")])
            let document = navigationRenderDocument(TypeRef("named", "Token", SemanticType("unavailable")),
                markdown: Some(MarkdownNode("document", children: [MarkdownNode("paragraph", children: [node])])))
            let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
            @Expect(html.contains("href=\"../dependencies/category.html#" + fragment + "\" data-doc-match=\"manual\" title=\"manual: explicit documentation\">member</a>"))
            let markdown = navigationRenderMarkdown(renderDocumentationFormatsWithOptions(document, ["markdown"], locale: "en"))
            @Expect(markdown.contains("[member](../../html/dependencies/category.html#" + fragment + " \"manual: explicit documentation\")"))
            @Expect(node.metadata.getOrThrow().semanticState, Some("unresolved"))
            @Expect(node.metadata.getOrThrow().semanticExternalUrl.isNone())
        }
    }

    @TestCase
    func nonresolvedNavigationPreventsCanonicalGuessAndEscapesReason(): Unit {
        let typeRef = TypeRef("named", "Token", SemanticType("resolved", canonical: Some("fixture.Token"), provider: Some("ast")),
            navigation: Some(TypeNavigation("ambiguous", "none", "Conflicting <script> indexes")))
        let document = navigationRenderDocument(typeRef)
        let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
        let signature = html.split("class=\"signature-block\"", 2)[1].split("</pre>", 2)[0]
        @Expect(!signature.contains("signature-type-link"))
        @Expect(signature.contains("Conflicting &lt;script&gt; indexes"))
        @Expect(!signature.contains("<script> indexes"))
        let markdown = navigationRenderMarkdown(MarkdownDocumentationRenderer().render(document))
        @Expect(!markdown.contains("[`Token`]("))
        @Expect(typeRef.semantic.state, "resolved")
    }

    @TestCase
    func optionalTupleFunctionAndNestedGenericChildrenLinkWithoutChangingSource(): Unit {
        let token = navigationRenderType("https://docs.example.test/Token.html")
        let optional = TypeRef("optional", "?Token", SemanticType("unavailable"), nullable: true, arguments: [token])
        let box = TypeRef("generic", "Box<Token>", SemanticType("unavailable"), arguments: [token],
            navigation: Some(TypeNavigation("resolved", "manual", "Explicit box documentation", url: "dependencies/Box.html")))
        let function = TypeRef("function", "(Token) -> Box<Token>", SemanticType("unavailable"), arguments: [token, box])
        let tuple = TypeRef("tuple", "(?Token, (Token) -> Box<Token>)", SemanticType("unavailable"), arguments: [optional, function])
        let raw = "public func accept<T>(label!: String = \"Token\", item!: (? /* Token */ Token, (Token) -> Box<Token>)): (?Token, (Token) -> Box<Token>)"
        let values = ["public", "func", "accept", "<", "T", ">", "(", "label", "!", ":", "String", "=", "\"Token\"", ",", "item", "!", ":",
            "(", "?", "Token", ",", "(", "Token", ")", "->", "Box", "<", "Token", ">", ")", ")", ":",
            "(", "?", "Token", ",", "(", "Token", ")", "->", "Box", "<", "Token", ">", ")"]
        let document = navigationRenderDocument(tuple, raw: raw, values: values)
        let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
        let signature = navigationRenderSignature(html)
        @Expect(navigationRenderText(signature), raw)
        @Expect(signature.split("href=\"https://docs.example.test/Token.html\"").size - 1, 6)
        @Expect(signature.split("href=\"../dependencies/Box.html\"").size - 1, 2)
        @Expect(!signature.contains("<a class=\"type-link signature-type-link\" href=\"https://docs.example.test/Token.html\">T</a>"))
        let markdown = navigationRenderMarkdown(MarkdownDocumentationRenderer().render(document))
        @Expect(markdown.contains("?[`Token`](https://docs.example.test/Token.html \"manual: Explicit documentation reference\")"))
        @Expect(markdown.contains("[`Box`](../../html/dependencies/Box.html \"manual: Explicit box documentation\")"))
    }

    @TestCase
    func tagSubjectsConsumeIndependentNavigationWithoutSemanticPromotion(): Unit {
        let navigation = TypeNavigation("resolved", "manual", "Explicit documentation", url: "https://docs.example.test/Failure.html")
        let tags = [DocTag("see", "Token", "", referenceState: "unavailable", navigation: Some(navigation)),
            DocTag("throws", "Failure", "Failure explanation", referenceState: "unavailable", navigation: Some(navigation))]
        let document = navigationRenderDocument(navigationRenderType("dependencies/Token.html"), tags: tags)
        let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
        @Expect(html.contains("href=\"https://docs.example.test/Failure.html\" data-doc-match=\"manual\" title=\"manual: Explicit documentation\"><code>Failure</code></a>"))
        @Expect(html.contains("href=\"https://docs.example.test/Failure.html\" data-doc-match=\"manual\" title=\"manual: Explicit documentation\"><code>Token</code></a>"))
        let markdown = navigationRenderMarkdown(MarkdownDocumentationRenderer().render(document))
        @Expect(markdown.contains("[`Failure`](https://docs.example.test/Failure.html \"manual: Explicit documentation\")"))
        @Expect(markdown.contains("[`Token`](https://docs.example.test/Failure.html \"manual: Explicit documentation\")"))
        @Expect(document.declarations[1].documentation.getOrThrow().tags[0].referenceState, "unavailable")
    }

    @TestCase
    func parenthesizedZeroArgumentFunctionsAndShiftCloseTokensRetainLinks(): Unit {
        let token = navigationRenderType("https://docs.example.test/Token.html")
        let wrapped = TypeRef("named", "(Token)", SemanticType("unavailable"), navigation: token.navigation)
        let callback = TypeRef("function", "(() -> (Token))", SemanticType("unavailable"), arguments: [wrapped])
        let inner = TypeRef("generic", "Box<Token>", SemanticType("unavailable"), arguments: [token],
            navigation: Some(TypeNavigation("resolved", "manual", "Explicit box documentation", url: "dependencies/Box.html")))
        let outer = TypeRef("generic", "Box<Box<Token>>", SemanticType("unavailable"), arguments: [inner], navigation: inner.navigation)
        let tuple = TypeRef("tuple", "((() -> (Token)), Box<Box<Token>>)", SemanticType("unavailable"), arguments: [callback, outer])
        let raw = "public func accept(label!: String = \"Token\", item!: ((() -> (Token)), Box<Box<Token>>)): ((() -> (Token)), Box<Box<Token>>)"
        let values = ["public", "func", "accept", "(", "label", "!", ":", "String", "=", "\"Token\"", ",", "item", "!", ":",
            "(", "(", "(", ")", "->", "(", "Token", ")", ")", ",", "Box", "<", "Box", "<", "Token", ">>", ")", ")", ":",
            "(", "(", "(", ")", "->", "(", "Token", ")", ")", ",", "Box", "<", "Box", "<", "Token", ">>", ")"]
        let document = navigationRenderDocument(tuple, raw: raw, values: values)
        let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
        let signature = navigationRenderSignature(html)
        @Expect(navigationRenderText(signature), raw)
        @Expect(signature.split("href=\"https://docs.example.test/Token.html\"").size - 1, 4)
        @Expect(signature.split("href=\"../dependencies/Box.html\"").size - 1, 4)
    }


    @TestCase
    func localPreboundRoutesUseMarkdownPagesWithoutSemanticResolution(): Unit {
        let initial = navigationRenderDocument(TypeRef("named", "Token", SemanticType("unavailable")))
        var route = ""
        for (artifact in HtmlDocumentationRenderer().render(initial) where artifact.path.startsWith("html/symbols/symbol-") &&
            artifact.content.contains("signature-block")) {
            let signature = navigationRenderSignature(artifact.content)
            if (navigationRenderText(signature) == "public class Token") { route = artifact.path.removePrefix("html/") }
        }
        @Assert(!route.isEmpty())
        let typeRef = TypeRef("named", "Token", SemanticType("unavailable"), navigation: Some(TypeNavigation("resolved", "exact",
            "Local source declaration", symbolKey: NAV_RENDER_TOKEN, url: route)))
        let document = navigationRenderDocument(typeRef)
        let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
        @Expect(html.contains("href=\"../" + route + "\""))
        let direct = navigationRenderMarkdown(MarkdownDocumentationRenderer().render(document))
        let site = navigationRenderMarkdown(renderDocumentationFormatsWithOptions(document, ["markdown"], locale: "en"))
        let markdownRoute = route[..route.size - 5] + ".md"
        @Expect(direct.contains("](../" + markdownRoute + "#symbol-"))
        @Expect(site.contains("](../" + markdownRoute + "#symbol-"))
        @Expect(typeRef.semantic.state, "unavailable")
        let filtered = navigationRenderDocument(typeRef, tokenVisibility: "private")
        let filteredHtml = navigationRenderPage(HtmlDocumentationRenderer().render(filtered), "html/symbols/").content
        let filteredSignature = filteredHtml.split("class=\"signature-block\"", 2)[1].split("</pre>", 2)[0]
        @Expect(!filteredSignature.contains("signature-type-link"))
        @Expect(!navigationRenderMarkdown(MarkdownDocumentationRenderer().render(filtered)).contains("[`Token`]("))
    }


    @TestCase
    func unsafeNavigationNeverProducesClickableDestinations(): Unit {
        for (url in ["javascript:alert(1)", "//example.test/Token.html", "../Token.html", "file:///Token.html",
            "https://docs.example.test/Token.html\" onclick=\"alert(1)", "dependencies/%2e%2e/Token.html"]) {
            try {
                let document = navigationRenderDocument(navigationRenderType(url))
                let html = navigationRenderPage(HtmlDocumentationRenderer().render(document), "html/symbols/").content
                let signature = html.split("class=\"signature-block\"", 2)[1].split("</pre>", 2)[0]
                @Expect(!signature.contains("signature-type-link"))
                @Expect(!signature.contains("onclick="))
                let markdown = navigationRenderMarkdown(MarkdownDocumentationRenderer().render(document))
                @Expect(!markdown.contains("[`Token`]("))
            } catch (_: IllegalArgumentException) {
                // Strict imported-IR validation may reject the unsafe fact before rendering.
            }
        }
    }
}
