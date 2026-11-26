protected package cjdoc.render.agent

import cjdoc.render.foundation.{RenderArtifact, RenderArtifactCollector}
import cjdoc.render.routes.selectedDocumentationPages
import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let LLMS_MODULE = "cjdoc:module:v1:llms-navigation"
private let LLMS_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Allms-navigation::routesample::function:value#g0()"

private func llmsPage(id: String, route: String, title: String, kind: String): DocumentationPage {
    DocumentationPage(id, "docs/" + id + ".md", route, title, kind, title,
        MarkdownNode("document", children: [
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(1),
                children: [MarkdownNode("text", literal: title)]),
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Body.")])
        ]))
}

private func llmsDocumentation(pages: Array<DocumentationPage>): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let value = SymbolDoc(LLMS_SYMBOL, "function", "value", "routesample.value", "routesample",
        LLMS_MODULE, "public", source, "public func value(): Int64 { 1 }",
        SemanticInfo("partial", "ast"))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("routesample"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", LLMS_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(LLMS_MODULE, "routesample", "root", "", packageNames: ["routesample"])],
        packages: [PackageDoc("routesample", LLMS_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: [LLMS_SYMBOL])],
        files: [FileDoc("src/api.cj", LLMS_MODULE, "routesample")],
        declarations: [value], pages: pages)
}

private func llmsRouteFixture(): DocumentationSet {
    llmsDocumentation([
        llmsPage("project", "concepts/index.html", "Route space", "project"),
        llmsPage("module", "concepts/modules/routesample.html", "routesample module", "module"),
        llmsPage("package", "concepts/packages/routesample.html", "Package routesample", "package"),
        llmsPage("guide", "concepts/guides/my-guide.html", "My guide", "guide"),
        llmsPage("other", "concepts/other.html", "Other guide", "guide")
    ])
}

private func llmsArtifact(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalStateException("missing agent artifact " + path)
}

private func llmsText(documentation: DocumentationSet): String {
    llmsArtifact(renderAgentReadableArtifacts(documentation, includeValidation: true),
        "html/llms.txt")
}

/** Walk the real continuation chain and return every enumerated route. */
private func navigationRoutes(artifacts: Array<RenderArtifact>): Array<String> {
    let routes = ArrayList<String>()
    var name = "html/navigation-index.json"
    let visited = HashSet<String>()
    while (visited.add(name)) {
        let text = llmsArtifact(artifacts, name)
        let pagesAt = match (text.indexOf("\"pages\":[")) {
            case Some(value) => value + "\"pages\":[".size
            case None => throw IllegalStateException("navigation part has no pages")
        }
        // `pages` is the final field, so its close is the document's last `]}`.
        let pagesEnd = match (text.lastIndexOf("]}")) {
            case Some(value) => value
            case None => throw IllegalStateException("navigation pages are unterminated")
        }
        var rest = text[pagesAt..pagesEnd]
        while (let Some(position) <- rest.indexOf("\"href\":\"")) {
            let tail = rest[(position + "\"href\":\"".size)..]
            let end = match (tail.indexOf("\"")) {
                case Some(value) => value
                case None => break
            }
            routes.add(tail[..end])
            rest = tail[end..]
        }
        if (let Some(position) <- text.indexOf("\"next\":\"")) {
            let tail = text[(position + "\"next\":\"".size)..]
            let end = match (tail.indexOf("\"")) {
                case Some(value) => value
                case None => throw IllegalStateException("navigation continuation is unterminated")
            }
            name = "html/" + tail[..end]
        } else {
            break
        }
    }
    routes.toArray()
}

/** Extract document-root links from the selected-directory sections of llms.txt. */
private func llmsLinkedRoutes(llms: String): Array<String> {
    let routes = ArrayList<String>()
    for (line in llms.split("\n") where line.startsWith("- [")) {
        let open = match (line.indexOf("](<")) {
            case Some(value) => value
            case None => continue
        }
        let tail = line[(open + "](<".size)..]
        let end = match (tail.indexOf(">)")) {
            case Some(value) => value
            case None => continue
        }
        let href = tail[..end]
        if (!href.endsWith(".json")) { routes.add(href) }
    }
    routes.toArray()
}

private func llmsSection(llms: String, heading: String, next: String): String {
    let start = match (llms.indexOf(heading)) {
        case Some(value) => value
        case None => throw IllegalStateException("llms.txt lacks section " + heading)
    }
    let end = match (llms.indexOf(next, start)) {
        case Some(value) => value
        case None => llms.size
    }
    llms[start..end]
}

@Test
class AgentNavigationLlmsTest {
    @TestCase
    func capturedConceptKindsFillTheirOwnGroupsAndApiPackagesStaySeparate(): Unit {
        let documentation = llmsRouteFixture()
        let llms = llmsText(documentation)
        let concepts = llmsSection(llms, "## Concepts and guides", "## API packages")
        for ((heading, link) in [
            ("### Project overview", "concepts/index.html"),
            ("### Modules", "concepts/modules/routesample.html"),
            ("### Package overviews", "concepts/packages/routesample.html"),
            ("### Guides", "concepts/guides/my-guide.html"),
            ("### Guides", "concepts/other.html")
        ]) {
            @Expect(concepts.contains(heading))
            @Expect(concepts.contains("](<" + link + ">"))
        }
        // The conceptual package overview stays in concepts; only the generated
        // API package appears in the API packages section.
        let packages = llmsSection(llms, "## API packages",
            "Use symbol-index.json to resolve")
        @Expect(packages.contains("](<packages/routesample/index.html>)"))
        @Expect(!packages.contains("concepts/"))
        @Expect(!packages.contains("Package routesample"))
        // Every listed route is enumerated by the navigation index, and the
        // concept group links exactly the selected captured pages.
        let artifacts = renderAgentReadableArtifacts(documentation, includeValidation: true)
        let navigation = navigationRoutes(artifacts)
        let listed = llmsLinkedRoutes(llms)
        for (href in listed) {
            if (href == "index.html") { continue }
            @Expect(navigation.contains(href))
        }
        var conceptLinks: Int64 = 0
        for (href in listed where href.startsWith("concepts/")) { conceptLinks++ }
        @Expect(conceptLinks, 5)
    }

    @TestCase
    func truncatedConceptListStillOffersTheBoundedContinuation(): Unit {
        let pages = ArrayList<DocumentationPage>()
        // A valid document can exceed the byte budget well before its page limit.
        let longTitle = StringBuilder()
        for (_ in 0..512) { longTitle.append("Long title ") }
        let titleSuffix = longTitle.toString()
        let moduleCount: Int64 = 32
        for (index in 0..moduleCount) {
            pages.add(llmsPage("module-${index}", "concepts/modules/m-${index}.html",
                "Module ${index}: ${titleSuffix}", "module"))
        }
        pages.add(llmsPage("guide", "concepts/guides/guide.html", "Guide", "guide"))
        let llms = llmsText(llmsDocumentation(pages.toArray()))
        @Expect(llms.contains("## Concepts and guides"))
        @Expect(llms.contains("### Guides"))
        @Expect(llms.contains("](<concepts/guides/guide.html>)"))
        @Expect(llms.contains("### Modules"))
        var listedModules: Int64 = 0
        for (href in llmsLinkedRoutes(llms) where href.startsWith("concepts/modules/")) {
            listedModules++
        }
        @Expect(listedModules > 0 && listedModules < moduleCount)
        @Expect(llms.contains("Additional conceptual pages are listed in navigation-index.json"))
        @Expect(llms.contains("Follow navigation-index.json and its actual continuation files"))
        // Truncation of concepts does not hide the generated API packages.
        @Expect(llms.contains("## API packages"))
    }

    @TestCase
    func navigationContinuationAndLlmsAgreeOnEveryListedRoute(): Unit {
        let documentation = llmsRouteFixture()
        let context = DocumentationReadSnapshot(documentation)
        let pages = agentNavigationPages(context,
            selectedDocumentationPages(documentation, "en"), true)
        let artifacts = RenderArtifactCollector()
        // A deliberately small part budget proves the continuation chain is
        // real rather than one page that happens to fit.
        appendAgentNavigationArtifacts(artifacts, context, pages, None,
            includeValidation: true, limit: 2048)
        let rendered = artifacts.toArray()
        var parts: Int64 = 0
        for (artifact in rendered where artifact.path.startsWith("html/navigation-index")) {
            parts++
        }
        @Expect(parts > 1)
        let navigation = navigationRoutes(rendered)
        @Expect(navigation.contains("concepts/guides/my-guide.html"))
        let llms = renderAgentLlms(context, pages, None, false)
        @Expect(llms.contains("Follow navigation-index.json and its actual continuation files"))
        for (href in llmsLinkedRoutes(llms) where href.startsWith("concepts/")) {
            @Expect(navigation.contains(href))
        }
    }
}
