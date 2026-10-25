package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func overviewPage(text: String, targets!: Array<String> = [],
    language!: String = "en", bindings!: Array<DocumentationPageBinding> = []): DocumentationPage {
    DocumentationPage("overview", "docs/" + language + "/package.md", "concepts/deep/overview.html",
        "Catalogue", "package", text, MarkdownNode("document", children: [
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1), children: [MarkdownNode("text", literal: "Catalogue")]),
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)]),
            MarkdownNode("code_block", MarkdownNodeMetadata.forCodeBlock("indented", None<String>, 0, "", "", ""), literal: "import fixture.*")]),
        packageName: "fixture", language: Some(language), defaultLanguage: Some("en"),
        targetSymbolIds: targets, bindings: bindings)
}

private func overviewFixture(pages: Array<DocumentationPage>, duplicate!: Bool = false,
    audience!: String = "external"): DocumentationSet {
    let modules = ArrayList<ModuleDoc>()
    let packages = ArrayList<PackageDoc>()
    let files = ArrayList<FileDoc>()
    let symbols = ArrayList<SymbolDoc>()
    let providers = ArrayList<ProviderInfo>()
    for (name in if (duplicate) { ["one", "two"] } else { ["one"] }) {
        let moduleId = "cjdoc:module:v1:" + name
        let prefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3A" + name + "::fixture::"
        let path = if (name == "one") { "src/api.cj" } else { "deps/two/src/api.cj" }
        let source = SourceRange(path, SourcePosition(1, 1, 0), SourcePosition(1, 2, 1))
        providers.add(ProviderInfo("ast", "builtin", moduleId, "partial", SemanticCapabilities(false, false, false, false, false)))
        modules.add(ModuleDoc(moduleId, name, if (name == "one") { "root" } else { "pathDependency" },
            if (name == "one") { "" } else { "deps/two" }, packageNames: ["fixture"]))
        packages.add(PackageDoc("fixture", moduleId, sourceFiles: [path], symbolIds: [prefix + "entry", prefix + "secret"]))
        files.add(FileDoc(path, moduleId, "fixture"))
        symbols.add(SymbolDoc(prefix + "entry", "class", "Entry", "fixture.Entry", "fixture", moduleId,
            "public", source, "public class Entry", SemanticInfo("partial", "ast")))
        symbols.add(SymbolDoc(prefix + "secret", "class", "Secret", "fixture.Secret", "fixture", moduleId,
            "private", source, "private class Secret", SemanticInfo("partial", "ast")))
    }
    let value = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("package-overview"),
        ConfigurationSnapshot(audience: audience, lintProfile: "off"), modules: modules.toArray(), providers: providers.toArray(),
        packages: packages.toArray(), files: files.toArray(), declarations: symbols.toArray(), pages: pages)
    decodeDocIr(encodeDocIr(value))
}

private func overviewContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing overview artifact")
}

@Test
class HtmlPackageConceptsTest {
    @TestCase
    func selectedLanguageExcerptIsBoundedEscapedAndReturnsToExactPackage(): Unit {
        let long = String(Array<Rune>(300, repeat: r'中')) + "<script>"
        let pages = [overviewPage("English purpose <script>"), overviewPage(long, language: "zh-CN")]
        let value = overviewFixture(pages)
        let artifacts = renderDocumentationFormatsWithOptions(value, ["html", "markdown"], locale: "zh-CN", docVersion: Some("1.0.0"))
        let pkg = overviewContent(artifacts, "html/" + packagePagePath(value.packages[0].moduleId, "fixture"))
        @Expect(pkg.contains(String(Array<Rune>(240, repeat: r'中')) + "…"))
        @Expect(!pkg.contains("English purpose"))
        @Expect(!pkg.contains("import fixture.*"))
        @Expect(pkg.contains("href=\"../concepts/deep/overview.html\""))
        let guide = overviewContent(artifacts, "html/concepts/deep/overview.html")
        @Expect(guide.contains("href=\"../../" + packagePagePath(value.packages[0].moduleId, "fixture") + "#declarations\""))
        @Expect(guide.contains("import fixture.*"))
        let english = renderDocumentationFormatsWithOptions(value, ["html"], locale: "en")
        @Expect(overviewContent(english, "html/" + packagePagePath(value.packages[0].moduleId, "fixture")).contains("English purpose &lt;script&gt;"))
    }

    @TestCase
    func fallbackExcerptKeepsAuthoredLanguageOnAnotherLanguageSite(): Unit {
        let value = overviewFixture([overviewPage("English package purpose")])
        let artifacts = renderDocumentationFormatsWithOptions(value, ["html"], locale: "zh-CN")
        let pkg = overviewContent(artifacts, "html/" + packagePagePath(value.packages[0].moduleId, "fixture"))
        @Expect(pkg.contains("<html lang=\"zh-CN\""))
        @Expect(pkg.contains("<p lang=\"en\">English package purpose</p>"))
        @Expect(pkg.contains("data-translation-state=\"fallback\""))
    }

    @TestCase
    func sameNamedModulesRequireVisibleExplicitBinding(): Unit {
        let ambiguous = overviewFixture([overviewPage("Ambiguous purpose")], duplicate: true)
        let values = HtmlDocumentationRenderer().render(ambiguous)
        for (pkg in ambiguous.packages) {
            @Expect(!overviewContent(values, "html/" + packagePagePath(pkg.moduleId, pkg.name)).contains("class=\"package-overview\""))
        }
        let id = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Atwo::fixture::entry"
        let exact = overviewFixture([overviewPage("Module two purpose", targets: [id])], duplicate: true)
        let rendered = HtmlDocumentationRenderer().render(exact)
        @Expect(!overviewContent(rendered, "html/" + packagePagePath(exact.packages[0].moduleId, "fixture")).contains("Module two purpose"))
        @Expect(overviewContent(rendered, "html/" + packagePagePath(exact.packages[1].moduleId, "fixture")).contains("Module two purpose"))
    }

    @TestCase
    func hiddenAndMissingDependenciesCannotAdvertisePackageContent(): Unit {
        let hidden = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aone::fixture::secret"
        let cases = [overviewPage("Hidden purpose", targets: [hidden]),
            overviewPage("Missing purpose", bindings: [DocumentationPageBinding("absent.Type", "", "authored", "", 1)])]
        for (page in cases) {
            let value = overviewFixture([page])
            let artifacts = HtmlDocumentationRenderer().render(value)
            @Expect(!overviewContent(artifacts, "html/" + packagePagePath(value.packages[0].moduleId, "fixture")).contains("class=\"package-overview\""))
            @Expect(!overviewContent(artifacts, "html/concepts/deep/overview.html").contains("package-api-return"))
        }
        let all = overviewFixture([cases[0]], audience: "all")
        @Expect(overviewContent(HtmlDocumentationRenderer().render(all), "html/" + packagePagePath(all.packages[0].moduleId, "fixture")).contains("Hidden purpose"))
    }
    @TestCase
    func oldSyntheticSnapshotNeverBecomesAuthorTextByRouteOrWording(): Unit {
        let wording = "This page describes the conceptual role of the package."
        let old = DocumentationPage("old-package", "docs/packages/fixture.md", "concepts/packages/fixture.html",
            "fixture", "package", wording, MarkdownNode("document", children: [
                MarkdownNode("paragraph", children: [MarkdownNode("text", literal: wording)])]))
        let value = overviewFixture([old])
        let artifacts = HtmlDocumentationRenderer().render(value)
        @Expect(!overviewContent(artifacts, "html/" + packagePagePath(value.packages[0].moduleId, "fixture")).contains("class=\"package-overview\""))
        let authored = overviewFixture([overviewPage(wording)])
        @Expect(overviewContent(HtmlDocumentationRenderer().render(authored), "html/" + packagePagePath(authored.packages[0].moduleId, "fixture")).contains(wording))
        authored.appendDiagnostic(Diagnostic("warning", "CJDOC3026", "Captured page used a bounded fallback",
            source: Some(SourceRange("docs/en/package.md", SourcePosition(1, 1, 0), SourcePosition(1, 1, 0)))))
        @Expect(!overviewContent(HtmlDocumentationRenderer().render(authored), "html/" + packagePagePath(authored.packages[0].moduleId, "fixture")).contains("class=\"package-overview\""))
    }
    @TestCase
    func sharedSourcesKeepOnePackageEntryAndExactRouteReturns(): Unit {
        let first = overviewPage("Shared author content")
        let other = DocumentationPage("other", first.source, "concepts/other.html", "Other", "guide",
            first.text, first.markdown, packageName: "fixture", language: Some("en"), defaultLanguage: Some("en"))
        let value = overviewFixture([first, other])
        let rendered = HtmlDocumentationRenderer().render(value)
        let path = packagePagePath(value.packages[0].moduleId, "fixture")
        let pkg = overviewContent(rendered, "html/" + path)
        @Expect(pkg.contains("class=\"package-overview\""))
        @Expect(!pkg.contains("href=\"../concepts/other.html\""))
        @Expect(overviewContent(rendered, "html/concepts/deep/overview.html").contains("../../" + path + "#declarations"))
        @Expect(overviewContent(rendered, "html/concepts/other.html").contains("../" + path + "#declarations"))
    }
}

private func overviewSemanticLink(target: SymbolDoc, title: String): MarkdownNode {
    MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink(target.qualifiedName, "resolved",
        targetSymbolId: Some(target.id), semanticNavigation: Some(TypeNavigation("resolved", "exact",
            "local declaration", symbolKey: target.id, url: symbolPagePath(target)))),
        children: [MarkdownNode("text", literal: title)])
}

private func overviewSemanticPage(target: SymbolDoc, hidden: SymbolDoc): DocumentationPage {
    DocumentationPage("inline-links", "docs/links.md", "concepts/deep/links.html", "Links", "guide",
        "Controlled inline links", MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [
                overviewSemanticLink(target, "Visible target"),
                MarkdownNode("text", literal: " and "),
                MarkdownNode("semantic_link", MarkdownNodeMetadata.forSemanticLink("dependency.Entry", "unresolved",
                    semanticNavigation: Some(TypeNavigation("resolved", "manual", "explicit dependency documentation",
                        url: "./dependencies/category.html#entry"))),
                    children: [MarkdownNode("text", literal: "Dependency target")]),
                MarkdownNode("text", literal: " and "),
                overviewSemanticLink(hidden, "Hidden target")
            ])
        ]), packageName: "fixture", language: Some("en"), defaultLanguage: Some("en"))
}

@Test
class AgentConceptualSemanticLinksTest {
    @TestCase
    func inlineLinksUseTheActualAgentOutputDirectory(): Unit {
        let base = overviewFixture([])
        let target = base.declarations[0]
        let page = overviewSemanticPage(target, base.declarations[1])
        let documentation = overviewFixture([page])
        let context = DocumentationReadSnapshot(documentation)
        let markdown = context.renderPageMarkdown(page.id, pagePath: agentPageMarkdownPath(page)).getOrThrow()
        let link = markdown.split("[Visible target](", 2)
        @Expect(link.size, 2)
        if (link.size != 2) { return }
        let destination = link[1].split(" ", 2)[0]
        let parts = destination.split("#", 2)
        @Expect(parts[0].startsWith("../../"), true)
        var destinations: Int64 = 0
        for (artifact in HtmlDocumentationRenderer().render(documentation)
            where artifact.path == "html/" + parts[0].removePrefix("../../")) {
            destinations++
            @Expect(artifact.path, "html/" + symbolPagePath(target))
            if (parts.size == 2) {
                @Expect(artifact.content.contains("id=\"" + parts[1] + "\""), true)
            }
        }
        @Expect(destinations, 1)
        @Expect(markdown.contains("[Dependency target](../../dependencies/category.html#entry"), true)
        @Expect(!markdown.contains("../html/"), true)
    }

    @TestCase
    func visiblePageDoesNotLinkAHiddenLocalDeclaration(): Unit {
        let base = overviewFixture([])
        let hidden = base.declarations[1]
        let page = overviewSemanticPage(base.declarations[0], hidden)
        let documentation = overviewFixture([page])
        let markdown = DocumentationReadSnapshot(documentation).renderPageMarkdown(page.id,
            pagePath: agentPageMarkdownPath(page)).getOrThrow()
        @Expect(markdown.contains("[Hidden target]"), true)
        @Expect(!markdown.contains("[Hidden target]("), true)
        @Expect(!markdown.contains(symbolPagePath(hidden)), true)
    }
}
