package cjdoc.render

import cjdoc.render.html.{HtmlTypeLinkIndex, RenderProjection, renderSymbolPage}
import cjdoc.render.publication.indexSymbols
import cjdoc.render.routes.pageRootPrefix
import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let ROUTE_TEST_MODULE = "cjdoc:module:v1:api-route-layout"

private func routeTestSource(offset: Int64): SourceRange {
    SourceRange("src/api.cj", SourcePosition(offset + 1, 1, offset * 16),
        SourcePosition(offset + 1, 2, offset * 16 + 1))
}

private func routeTestSymbol(kind: String, name: String, owner!: ?String = None,
    parameters!: Array<ParameterDoc> = [], relationships!: Array<SymbolRelationship> = [],
    offset!: Int64 = 0): SymbolDoc {
    SymbolDoc("route:${kind}:${name}:${offset}", kind, name, "fixture." + name, "fixture",
        ROUTE_TEST_MODULE, "public", routeTestSource(offset),
        "public ${kind} ${name}", SemanticInfo("partial", "ast"), ownerId: owner,
        parameters: parameters, symbolRelationships: relationships)
}

private func routeTestDocumentation(declarations: Array<SymbolDoc>): DocumentationSet {
    let ids = ArrayList<String>()
    for (symbol in declarations) { ids.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("api-route-layout"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        modules: [ModuleDoc(ROUTE_TEST_MODULE, "api-route-layout", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", ROUTE_TEST_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: ids.toArray())],
        files: [FileDoc("src/api.cj", ROUTE_TEST_MODULE, "fixture")],
        declarations: declarations)
}

private func routePaths(documentation: DocumentationSet): HashMap<String, String> {
    let projection = RenderProjection(documentation, buildApiRoutes: true)
    let result = HashMap<String, String>()
    for (symbol in documentation.declarations) {
        if (let Some(path) <- projection.apiRoutes.getOrThrow().filePath(symbol.id)) {
            result[symbol.id] = path
        }
    }
    result
}

// A type, one of its members, and a same-named extension family. The extension
// target is a real resolved relationship, as the producer publishes it.
private func routeTestCounter(withExtension: Bool, withExtraExtension: Bool,
    withOverload: Bool): Array<SymbolDoc> {
    let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
    let extensions = ArrayList<SymbolDoc>()
    let backward = ArrayList<SymbolRelationship>()
    if (withExtension) {
        let first = routeTestSymbol("extend", "Counter", offset: 4)
        extensions.add(first)
        backward.add(SymbolRelationship("extendedBy", "Counter", "resolved",
            targetSymbolId: Some(first.id)))
        if (withExtraExtension) {
            let second = routeTestSymbol("extend", "Counter", offset: 6)
            extensions.add(second)
            backward.add(SymbolRelationship("extendedBy", "Counter", "resolved",
                targetSymbolId: Some(second.id)))
        }
    }
    // The produced IR carries both directions; the type page finds its
    // extension members through `extendedBy` on the type itself.
    let counter = SymbolDoc("route:class:Counter:0", "class", "Counter", "fixture.Counter",
        "fixture", ROUTE_TEST_MODULE, "public", routeTestSource(0), "public class Counter",
        SemanticInfo("partial", "ast"), symbolRelationships: backward.toArray())
    let result = ArrayList<SymbolDoc>([counter,
        routeTestSymbol("function", "get", owner: Some(counter.id), offset: 1)])
    result.add(routeTestSymbol("function", "set",
        parameters: [ParameterDoc("value", intType)], offset: 2))
    if (withOverload) {
        result.add(routeTestSymbol("function", "set", parameters: [
            ParameterDoc("value", intType), ParameterDoc("radix", intType)], offset: 3))
    }
    for (extension in extensions) {
        let forward = SymbolRelationship("extensionTarget", "Counter", "resolved",
            targetSymbolId: Some(counter.id))
        let rebuilt = SymbolDoc(extension.id, extension.kind, extension.name,
            extension.qualifiedName, extension.packageName, extension.moduleId,
            extension.visibility, extension.source, extension.headerSpelling,
            extension.semantic, symbolRelationships: [forward])
        result.add(rebuilt)
        result.add(routeTestSymbol("function",
            if (rebuilt.id.endsWith(":4")) { "increment" } else { "decrement" },
            owner: Some(rebuilt.id), offset: if (rebuilt.id.endsWith(":4")) { 5 } else { 7 }))
    }
    result.toArray()
}

private func headingLevels(html: String): Array<Int64> {
    let levels = ArrayList<Int64>()
    var index = 0
    while (index + 2 < html.size) {
        if (html[index] == b'<' && html[index + 1] == b'h' && html[index + 2] >= b'1' &&
            html[index + 2] <= b'6') {
            let next = if (index + 3 < html.size) { html[index + 3] } else { b'>' }
            if (next == b'>' || next == b' ') {
                levels.add(Int64(html[index + 2] - b'0'))
            }
        }
        index++
    }
    levels.toArray()
}

// Exactly one h1 per page and never a level more than one below its predecessor.
private func expectNoHeadingSkip(html: String): Unit {
    let levels = headingLevels(html)
    @Expect(levels[0], 1)
    var previous: Int64 = 0
    var h1Count: Int64 = 0
    for (level in levels) {
        @Expect(level <= previous + 1, true)
        if (level == 1) { h1Count++ }
        previous = level
    }
    @Expect(h1Count, 1)
}

@Test
class ApiRouteLayoutTest {
    // The frozen acceptance case: adding only an extension must not move any
    // previously published page, including the type page and its members.
    @TestCase
    func addingAnExtensionPreservesEveryExistingRoute(): Unit {
        let before = routePaths(routeTestDocumentation(routeTestCounter(false, false, false)))
        let after = routePaths(routeTestDocumentation(routeTestCounter(true, true, false)))
        @Expect(before.size > 0, true)
        for ((id, path) in before) {
            @Expect(after.get(id), Some(path))
        }
        @Expect(after.size, before.size + 4)
    }

    @TestCase
    func typePageStaysCanonicalAndExtensionsOwnPredictableDirectories(): Unit {
        let documentation = routeTestDocumentation(routeTestCounter(true, true, false))
        let paths = routePaths(documentation)
        let counter = documentation.declarations[0]
        @Expect(paths[counter.id], "fixture/Counter/index.html")
        let extension = documentation.declarations[3]
        let second = documentation.declarations[5]
        @Expect(paths[extension.id], "fixture/Counter/extensions/index.html")
        @Expect(paths[second.id], "fixture/Counter/extensions/2/index.html")
        for ((_, path) in paths) {
            @Expect(path.contains("~"), false)
        }
        // Members of an extension belong to the target type, so renumbering an
        // extension block never moves a member page.
        let increment = documentation.declarations[4]
        @Expect(paths[increment.id], "fixture/Counter/increment/signature-no-args/index.html")
    }

    @TestCase
    func typePageStillListsExtensionMembersAndLinksTheirPages(): Unit {
        let documentation = routeTestDocumentation(routeTestCounter(true, false, false))
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        let counter = documentation.declarations[0]
        let extensionMember = documentation.declarations[4]
        let html = renderSymbolPage(documentation, projection, indexSymbols(documentation),
            counter, HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
        @Expect(html.contains("data-member-name=\"increment\""), true)
        @Expect(html.contains("data-member-origin=\"extension\""), true)
        let expected = pageRootPrefix(projection.symbolFileHref(counter.id)) +
            projection.symbolFileHref(extensionMember.id)
        @Expect(html.contains("href=\"" + expected + "\""), true)
    }

    // Overloads use readable ordinal directories rather than opaque digests.
    @TestCase
    func overloadSignaturesUseReadableStableDirectories(): Unit {
        let single = routeTestDocumentation(routeTestCounter(false, false, false))
        let overloaded = routeTestDocumentation(routeTestCounter(false, false, true))
        // A lone declaration keeps its bare member route.
        @Expect(routePaths(single)[single.declarations[2].id], "fixture/set/index.html")
        let overloadedPaths = routePaths(overloaded)
        let setInt = overloaded.declarations[2]
        let setOverload = overloaded.declarations[3]
        @Expect(overloadedPaths[setInt.id], "fixture/set/signature-1/index.html")
        @Expect(overloadedPaths[setOverload.id], "fixture/set/signature-2/index.html")
        // Reversed input order and an added extension both leave them in place.
        let symbols = routeTestCounter(false, false, true)
        let reversed = routePaths(routeTestDocumentation(
            [symbols[3], symbols[2], symbols[0], symbols[1]]))
        let extended = routePaths(routeTestDocumentation(routeTestCounter(true, false, true)))
        for ((id, path) in overloadedPaths) {
            @Expect(reversed.get(id), Some(path))
            @Expect(extended.get(id), Some(path))
        }
    }
}

@Test
class SymbolPageHeadingTiersTest {
    private func standaloneFunctionPage(comment: DocComment): String {
        let symbol = SymbolDoc("heading:function:greet", "function", "greet", "fixture.greet",
            "fixture", ROUTE_TEST_MODULE, "public", routeTestSource(0),
            "public func greet(): Unit", SemanticInfo("partial", "ast"),
            documentation: Some(comment))
        let documentation = routeTestDocumentation([symbol])
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        renderSymbolPage(documentation, projection, indexSymbols(documentation), symbol,
            HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
    }

    @TestCase
    func standalonePagesNeverSkipTheFirstSectionLevel(): Unit {
        // `## Details` is authored Markdown; `@return` and `@see` add structured
        // sections that previously started at h3 directly below the page h1.
        let tree = MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Greets.")]),
            MarkdownNode("heading", MarkdownNodeMetadata.forHeading(2),
                children: [MarkdownNode("text", literal: "Details")])
        ])
        let comment = DocComment("raw", "Greets.", "", tree, tags: [
            DocTag("return", "", "Nothing"),
            DocTag("see", "fixture.other", "")
        ])
        let html = standaloneFunctionPage(comment)
        expectNoHeadingSkip(html)
        @Expect(headingLevels(html).size > 2, true)
    }

    @TestCase
    func classAndMemberPagesShareTheSameSectionSemantics(): Unit {
        let documentation = routeTestDocumentation(routeTestCounter(true, false, false))
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        for (symbol in documentation.declarations) {
            let html = renderSymbolPage(documentation, projection, indexSymbols(documentation),
                symbol, HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
            expectNoHeadingSkip(html)
        }
    }

    private func headingRankOf(html: String, marker: String): Int64 {
        // The nearest enclosing heading start, so a rank is read from the
        // markup that owns the text instead of from the page-wide sequence.
        let at = html.indexOf(marker).getOrThrow()
        var index = at
        while (index > 0) {
            if (html[index] == b'<' && index + 3 < html.size && html[index + 1] == b'h' &&
                html[index + 2] >= b'1' && html[index + 2] <= b'6' &&
                (html[index + 3] == b'>' || html[index + 3] == b' ')) {
                return Int64(html[index + 2] - b'0')
            }
            index--
        }
        throw IllegalArgumentException("no heading owns '" + marker + "'")
    }

    private func occurrencesOf(html: String, marker: String): Int64 {
        html.split(marker).size - 1
    }

    private func headingClassComment(): DocComment {
        DocComment("raw", "A box.", "", MarkdownNode("document", children: [
            MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "A box.")])]),
            tags: [DocTag("example", "Class usage",
                "Create an empty box.\n\n```cangjie\nlet box = Box()\n```")])
    }

    // A class with and without members, so the class's own sections can be read
    // against the member browser that precedes them.
    private func classExamplesPage(withMember: Bool): String {
        let owner = SymbolDoc("heading:class:Box", "class", "Box", "fixture.Box", "fixture",
            ROUTE_TEST_MODULE, "public", routeTestSource(0), "public class Box",
            SemanticInfo("partial", "ast"), documentation: Some(headingClassComment()))
        let declarations = ArrayList<SymbolDoc>([owner])
        if (withMember) {
            declarations.add(SymbolDoc("heading:class:Box:run", "function", "run",
                "fixture.Box.run", "fixture", ROUTE_TEST_MODULE, "public", routeTestSource(1),
                "public func run(repeat: Int64): Unit", SemanticInfo("partial", "ast"),
                ownerId: Some(owner.id),
                parameters: [ParameterDoc("repeat", TypeRef("primitive", "Int64",
                    SemanticType("unavailable")))],
                documentation: Some(DocComment("raw", "Runs.", "", MarkdownNode("document"),
                    tags: [DocTag("param", "repeat", "how many times"),
                        DocTag("example", "Member usage",
                            "Run the box twice.\n\n```cangjie\nBox().run(2)\n```")]))))
        }
        let documentation = routeTestDocumentation(declarations.toArray())
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        renderSymbolPage(documentation, projection, indexSymbols(documentation), owner,
            HashMap<String, String>(), HtmlTypeLinkIndex(documentation, projection))
    }

    @TestCase
    func classExamplesStayASiblingOfTheMemberSections(): Unit {
        // Without members the class's own sections follow its title directly:
        // Examples is h2 and each example title is h3.
        let bare = classExamplesPage(false)
        expectNoHeadingSkip(bare)
        @Expect(occurrencesOf(bare, "<h2>Examples</h2>"), 1)
        @Expect(occurrencesOf(bare, "<h3>Examples</h3>"), 0)
        @Expect(headingRankOf(bare, ">Class usage<"), 3)

        // With a member present the class's Examples section keeps the rank of
        // the member kind heading ("Functions" -> h2). Emitting the class-level
        // section one rank lower made the writer clamp it under the member
        // section even though it belongs to the class: the reported failure.
        let populated = classExamplesPage(true)
        expectNoHeadingSkip(populated)
        @Expect(populated.contains("data-cjdoc-member-browser"), true)
        let memberKindRank = headingRankOf(populated, "id=\"functions\"")
        @Expect(memberKindRank, 2)
        @Expect(occurrencesOf(populated, "<h2>Examples</h2>"), 1)
        @Expect(occurrencesOf(populated, "<h3>Examples</h3>"), 1)
        @Expect(headingRankOf(populated, ">Class usage<"), memberKindRank + 1)
        // The populated member body stays one rank below its semantic parent:
        // its Parameters and Examples are h3 under the h2 kind heading, and its
        // example title is h4 under that Examples heading.
        @Expect(headingRankOf(populated, ">Parameters<"), memberKindRank + 1)
        @Expect(headingRankOf(populated, ">Member usage<"), memberKindRank + 2)
        // The member's nested sections precede the class's own section, so the
        // two Examples headings are distinguishable by owner, not just rank.
        @Expect(populated.indexOf("<h3>Examples</h3>").getOrThrow() <
            populated.indexOf("<h2>Examples</h2>").getOrThrow(), true)
        // Both owners keep their own example content: the rank change moves a
        // heading and never merges or drops a nested example.
        @Expect(occurrencesOf(populated, "Run the box twice."), 1)
        @Expect(occurrencesOf(populated, "Create an empty box."), 1)
    }
}
