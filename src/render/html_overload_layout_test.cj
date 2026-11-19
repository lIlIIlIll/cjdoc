package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func overloadLayoutDocumentation(): DocumentationSet {
    let moduleId = "cjdoc:module:v1:overload-layout"
    let ownerId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::class:Catalog#g0()"
    let intId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:add#g0(Int64,Int64)"
    let stringId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:add#g0(String)"
    let arrayId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aoverload-layout::fixture::Catalog::function:addAll#g0(Array)"
    let source = SourceRange("src/catalog.cj", SourcePosition(1, 1, 0),
        SourcePosition(1, 42, 41))
    let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
    let stringType = TypeRef("primitive", "String", SemanticType("unavailable"))
    let arrayType = TypeRef("generic", "Array<String>", SemanticType("unavailable"),
        arguments: [stringType])
    let owner = SymbolDoc(ownerId, "class", "Catalog", "fixture.Catalog", "fixture",
        moduleId, "public", source, "public class Catalog", SemanticInfo("partial", "ast"))
    let intAdd = SymbolDoc(intId, "function", "add", "fixture.Catalog.add", "fixture",
        moduleId, "public", source, "public func add(value: Int64, radix!: Int64 = 10): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [
            ParameterDoc("value", intType, documentation: Some("Integer input")),
            ParameterDoc("radix", intType, documentation: Some("Only base ten is supported"),
                defaultExpression: Some("10"))
        ], documentation: Some(DocComment("raw", "Append an integer", "",
            MarkdownNode("document"), tags: [
                DocTag("throws", "IllegalArgumentException", "radix must equal 10"),
                DocTag("postcondition", "", "new entry matches value.toString()")
            ])))
    let stringAdd = SymbolDoc(stringId, "function", "add", "fixture.Catalog.add", "fixture",
        moduleId, "public", source, "public func add(value!: String = \"<b>\"): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [ParameterDoc("value", stringType, documentation: Some("Text input"),
            defaultExpression: Some("\"<b>\""))],
        documentation: Some(DocComment("raw", "Append a string", "",
            MarkdownNode("document"))))
    let addAll = SymbolDoc(arrayId, "function", "addAll", "fixture.Catalog.addAll", "fixture",
        moduleId, "public", source, "public func addAll(entries: Array<String>): Unit",
        SemanticInfo("partial", "ast"), ownerId: Some(ownerId),
        parameters: [ParameterDoc("entries", arrayType)],
        documentation: Some(DocComment("raw", "Append multiple strings", "",
            MarkdownNode("document"))))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("overload-layout"), ConfigurationSnapshot(lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "overload-layout", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId,
            sourceFiles: ["src/catalog.cj"],
            symbolIds: [ownerId, intId, stringId, arrayId])],
        files: [FileDoc("src/catalog.cj", moduleId, "fixture")],
        declarations: [owner, intAdd, stringAdd, addAll])
}

private func overloadLayoutContent(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalArgumentException("missing overload layout artifact")
}

// Route allocation sees the same visible declaration set the HTML renderer does.
private func routeAllocationProjection(declarations: Array<SymbolDoc>):
    (RenderProjection, HashMap<String, String>) {
    let ids = ArrayList<String>()
    for (symbol in declarations) { ids.add(symbol.id) }
    let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("route-allocation"), ConfigurationSnapshot(audience: "external",
            lintProfile: "off"),
        modules: [ModuleDoc("cjdoc:module:v1:route-allocation", "route-allocation", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", "cjdoc:module:v1:route-allocation",
            sourceFiles: ["src/api.cj"], symbolIds: ids.toArray())],
        files: [FileDoc("src/api.cj", "cjdoc:module:v1:route-allocation", "fixture")],
        declarations: declarations)
    let projection = RenderProjection(documentation, buildApiRoutes: true)
    let paths = HashMap<String, String>()
    for (symbol in declarations where projection.visibleIndex.contains(symbol.id)) {
        paths[symbol.id] = projection.symbolFileHref(symbol.id)
    }
    (projection, paths)
}

@Test
class HtmlOverloadContractLayoutTest {
    @TestCase
    func overloadBoundaryDoesNotAbsorbOtherMemberNames(): Unit {
        let documentation = overloadLayoutDocumentation()
        let owner = documentation.declarations[0]
        let addAll = documentation.declarations[3]
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        let ownerPath = projection.symbolFileHref(owner.id)
        var html = ""
        for (artifact in artifacts) {
            if (artifact.path == "html/${ownerPath}") { html = artifact.content }
        }
        @Expect(!html.isEmpty(), true)
        // One role="group" wrapper per overload family, never one per member.
        @Expect(html.split("data-cjdoc-overload-group").size, 2)
        @Expect(html.contains("data-overload-total=\"2\""), true)
        @Expect(html.contains("aria-labelledby=\"overloads-"), true)
        @Expect(html.split("data-member-name=\"add\"").size, 3)
        // Distinct signatures, not just the shared "add" name, must appear
        // in the page outline for readers choosing between overloads.
        @Expect(html.contains("data-cjdoc-toc-label=\"add(Int64"), true)
        @Expect(html.contains("data-cjdoc-toc-label=\"add(String"), true)

        // A member is a native <details> whose summary is the signature line.
        @Expect(html.contains("</div>\n<div class=\"cj-member-row\"><details class=\"cj-member\"" +
            " id=\"${symbolAnchor(addAll)}\""), true)
        @Expect(html.contains("data-member-name=\"addAll\""), true)
        @Expect(html.contains("id=\"${symbolAnchor(addAll)}-summary\""), true)
        @Expect(html.contains("aria-labelledby=\"${symbolAnchor(addAll)}-actions-group-label " +
            "${symbolAnchor(addAll)}-summary\""), true)
        @Expect(html.contains("aria-controls=\"${symbolAnchor(addAll)}-actions\""), true)
        @Expect(html.contains("class=\"cj-signature-inline cj-member__signature\""), true)
        @Expect(html.contains("class=\"cj-params__declaration\""), true)
        @Expect(html.contains("Int64</code></span> " +
            "<span class=\"cj-params__default\">= <code>10</code></span>"), true)
        @Expect(html.contains("String</code></span> " +
            "<span class=\"cj-params__default\">= <code>&quot;&lt;b&gt;&quot;</code></span>"), true)
        @Expect(html.contains("Only base ten is supported"), true)
        @Expect(html.contains("id=\"${docBlockAnchor(addAll, "parameters")}\""), true)
        @Expect(html.contains("<dl class=\"cj-throws\""), true)
        @Expect(html.contains("class=\"cj-throws__row\""), true)
        @Expect(html.contains("radix must equal 10"), true)
        // A member detail heading follows its real structural parent. This
        // page has no custom group, so the chain is kind H2 -> overload H3 ->
        // detail H4: the contract inside an overload family is one level below
        // the overload title instead of tying with it.
        @Expect(html.contains(">Postcondition</h4>"), true)
        @Expect(html.contains(">Postcondition</h3>"), false)
        @Expect(html.contains("new entry matches value.toString()"), true)
        @Expect(!html.contains(">Behavior contracts</h3>"), true)
        @Expect(!html.contains(">Behavior contracts</h4>"), true)
    }

    @TestCase
    func memberScriptsKeepTheDataHookContract(): Unit {
        // The controller implementation is free to change, but the hooks the
        // server markup exposes are a contract and must keep being consumed.
        for (hook in ["data-cjdoc-overload-group", "data-cjdoc-member-actions",
            "data-cjdoc-member-filter", "data-cjdoc-member-origin",
            "data-cjdoc-members-expand", "data-cjdoc-members-collapse",
            "data-cjdoc-copy-link", "data-cjdoc-copy-status"]) {
            @Expect(HTML_SEARCH_SCRIPT.contains(hook), true)
        }
    }

    @TestCase
    func memberRowsKeepStableAnchorsAndActionChains(): Unit {
        let documentation = overloadLayoutDocumentation()
        let owner = documentation.declarations[0]
        let intAdd = documentation.declarations[1]
        let artifacts = HtmlDocumentationRenderer().render(documentation)
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        let ownerPath = projection.symbolFileHref(owner.id)
        let intAddPath = projection.symbolFileHref(intAdd.id)
        var html = ""
        for (artifact in artifacts) {
            if (artifact.path == "html/${ownerPath}") { html = artifact.content }
        }
        let anchor = symbolAnchor(intAdd)
        @Expect(html.contains("role=\"group\""), true)
        @Expect(html.contains("data-cjdoc-member-actions"), true)
        @Expect(html.contains("data-cjdoc-member-actions-toggle"), true)
        // The inline member copy resolves to that overload's own canonical page,
        // relative to the owning type page, not to the type page itself.
        @Expect(html.contains("data-cjdoc-copy-link=\"" +
            pageRootPrefix(ownerPath) + intAddPath + "\""), true)
        // The old readable slug stays a real redirect alias for this overload.
        let alias = symbolReadablePagePath(intAdd)
        @Expect(overloadLayoutContent(artifacts, "html/" + alias).contains(
            "data-cjdoc-route=\"symbol-alias\""), true)
        @Expect(overloadLayoutContent(artifacts, "html/" + alias).contains(
            pageRootPrefix(alias) + intAddPath), true)
        @Expect(html.contains("id=\"${anchor}-actions-copy-label\""), true)
        @Expect(html.contains("id=\"${anchor}-actions-standalone-label\""), true)
        @Expect(html.contains("data-cjdoc-copy-status"), true)
        // Legacy vocabulary must not come back.
        for (legacy in ["class=\"member-row\"", "class=\"declaration-summary member-detail\"",
            "class=\"declaration-signature\"", "class=\"parameter-declaration\"",
            "class=\"type-link\"", "class=\"signature-block\"", "class=\"member-detail-actions\"",
            "class=\"member-browser-toolbar\"", "class=\"parameter-row\""]) {
            @Expect(html.contains(legacy), false)
        }
    }

    // Route allocation is an identity problem: same-name declarations that are
    // not overloads must not share a body, hidden declarations get no route, and
    // input order never moves a declaration. Cross-kind name twins, an overload
    // family and a filtered member in one fixture cover that boundary.
    @TestCase
    func routeAllocationSeparatesKindsOverloadsAndHiddenMembers(): Unit {
        let moduleId = "cjdoc:module:v1:route-allocation"
        let prefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroute-allocation::fixture::"
        let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
        let semantic = SemanticInfo("partial", "ast")
        let typeTwin = SymbolDoc(prefix + "class:makeBox#g0()", "class", "makeBox",
            "fixture.makeBox", "fixture", moduleId, "public", source,
            "public class makeBox", semantic)
        let functionTwin = SymbolDoc(prefix + "function:makeBox#g0()", "function", "makeBox",
            "fixture.makeBox", "fixture", moduleId, "public", source,
            "public func makeBox(): Unit", semantic)
        let intAdd = SymbolDoc(prefix + "function:add#g0(Int64)", "function", "add",
            "fixture.add", "fixture", moduleId, "public", source,
            "public func add(value: Int64): Unit", semantic,
            parameters: [ParameterDoc("value", TypeRef("primitive", "Int64",
                SemanticType("unavailable")))])
        let stringAdd = SymbolDoc(prefix + "function:add#g0(String)", "function", "add",
            "fixture.add", "fixture", moduleId, "public", source,
            "public func add(value: String): Unit", semantic,
            parameters: [ParameterDoc("value", TypeRef("primitive", "String",
                SemanticType("unavailable")))])
        let hidden = SymbolDoc(prefix + "function:secret#g0()", "function", "secret",
            "fixture.secret", "fixture", moduleId, "private", source,
            "private func secret(): Unit", semantic)

        let ordered = [typeTwin, functionTwin, intAdd, stringAdd, hidden]
        let reversed = [hidden, stringAdd, intAdd, functionTwin, typeTwin]
        let (projection, paths) = routeAllocationProjection(ordered.toArray())
        let (_, reversedPaths) = routeAllocationProjection(reversed.toArray())
        @Expect(paths.size, 4)
        // Swapping the input order cannot move any declaration's address.
        let forward = ArrayList<String>()
        let backward = ArrayList<String>()
        for (symbol in ordered) {
            if (let Some(path) <- paths.get(symbol.id)) { forward.add(symbol.id + "|" + path) }
            if (let Some(path) <- reversedPaths.get(symbol.id)) { backward.add(symbol.id + "|" + path) }
        }
        @Expect(forward.size, 4)
        @Expect(backward.toArray(), forward.toArray())

        // Cross-kind name twins are distinct identities, not overloads: neither
        // may occupy the bare `makeBox/` URL the other could claim.
        let typePath = paths[typeTwin.id]
        let functionPath = paths[functionTwin.id]
        @Expect(typePath != functionPath, true)
        @Expect(typePath != "fixture/makeBox/index.html", true)
        @Expect(functionPath != "fixture/makeBox/index.html", true)

        // Overloads share one signature-choice page and get distinct bodies.
        let intPath = paths[intAdd.id]
        let stringPath = paths[stringAdd.id]
        @Expect(intPath != stringPath, true)
        @Expect(intPath.startsWith("fixture/add/~"), true)
        @Expect(stringPath.startsWith("fixture/add/~"), true)
        var choiceFile = ""
        var choiceSymbols = 0
        for (choice in projection.apiRoutes.getOrThrow().selectionPages where
            choice.file == "fixture/add/index.html") {
            choiceFile = choice.file
            choiceSymbols = choice.symbols.size
        }
        @Expect(choiceFile, "fixture/add/index.html")
        @Expect(choiceSymbols, 2)
        // The choice page is its own page identity, not a fabricated SymbolId.
        for (symbol in ordered where projection.visibleIndex.contains(symbol.id)) {
            @Expect(projection.symbolFileHref(symbol.id) != "fixture/add/index.html", true)
        }

        // A filtered declaration is outside the audience: it owns no body.
        @Expect(projection.visibleIndex.contains(hidden.id), false)
        @Expect(projection.apiRoutes.getOrThrow().filePath(hidden.id).isNone(), true)
        // Every published body is a real directory index below the document root.
        for ((_, path) in paths) {
            @Expect(path.endsWith("/index.html"), true)
            @Expect(!path.startsWith("symbols/"), true)
            @Expect(!path.contains(".."), true)
        }
    }
}
