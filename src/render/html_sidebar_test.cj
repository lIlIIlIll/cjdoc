package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func sidebarFixtureDocumentation(moduleId: String, packageName: String,
    declarations: Array<SymbolDoc>): DocumentationSet {
    let ids = ArrayList<String>()
    for (symbol in declarations) { ids.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("sidebar-fixture"), ConfigurationSnapshot(audience: "external"),
        modules: [ModuleDoc(moduleId, "sidebar-fixture", "root", "",
            packageNames: [packageName])],
        packages: [PackageDoc(packageName, moduleId, symbolIds: ids.toArray())],
        declarations: declarations)
}

private func sidebarFixtureSource(): SourceRange {
    SourceRange("src/fixture.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
}

private func renderSidebarHtml(projection: RenderProjection, currentPackagePath: ?String,
    currentSymbol: ?SymbolDoc, currentPagePath: ?String): String {
    let w = HtmlWriter()
    appendHtmlSidebar(w, projection, "../", "en",
        currentPackagePath: currentPackagePath, currentRoute: "api",
        currentSymbol: currentSymbol, currentPagePath: currentPagePath)
    w.toString()
}

@Test
class HtmlSidebarNavigationTest {
    @TestCase
    func pageIdentityNeverUsesFragmentsOrSuffixMatching(): Unit {
        @Expect(sidebarPageIsCurrent("index.html", Some("index.html")))
        @Expect(!sidebarPageIsCurrent("index.html#packages", Some("index.html")))
        @Expect(!sidebarPageIsCurrent("index.html", Some("concepts/index.html")))
        @Expect(!sidebarPageIsCurrent("index.html", None))
        @Expect(!sidebarPageIsCurrent("symbols/owner.html", Some("symbols/member.html")))
        @Expect(!sidebarPageIsCurrent("packages/a.html?x=1", Some("packages/a.html?x=1")))
    }

    @TestCase
    func currentPackageBranchKeepsEveryDeclarationReachable(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-limit"
        let declarations = ArrayList<SymbolDoc>()
        var selected: ?SymbolDoc = None
        for (index in 0..270) {
            let name = if (index == 269) { "zz_Last" } else { "Item${index}" }
            let symbol = SymbolDoc("sidebar-${index}", "class", name, "fixture.${name}",
                "fixture", moduleId, "public", sidebarFixtureSource(),
                "public class ${name}", SemanticInfo("partial", "ast"))
            declarations.add(symbol)
            if (index == 269) { selected = Some(symbol) }
        }
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture",
            declarations.toArray())
        let projection = RenderProjection(documentation)
        let packagePath = packagePagePath(moduleId, "fixture")
        let html = renderSidebarHtml(projection, Some(packagePath),
            selected, Some(symbolPagePath(selected.getOrThrow())))

        // The whole current-package branch is server rendered; the tree is usable
        // without scripts and the active declaration survives the bounded window.
        @Expect(html.contains("data-cjdoc-tree-item=\"package\""))
        @Expect(html.contains("data-cjdoc-current-symbol=\"sidebar-269\""))
        @Expect(html.contains("data-cjdoc-current-page=\"${symbolPagePath(selected.getOrThrow())}\""))
        @Expect(html.contains("zz_Last"))
        @Expect(html.contains("aria-current=\"page\""))
        @Expect(html.contains("cj-tree__link--ancestor"))
        @Expect(html.contains("data-cjdoc-sidebar-more"))
        @Expect(html.contains("#declarations"))
        let memberOut = renderSidebarHtml(projection, Some(packagePath),
            selected, Some("symbols/member.html"))
        @Expect(!memberOut.contains("aria-current=\"page\""))
        @Expect(memberOut.contains("cj-tree__link--ancestor"))
    }

    @TestCase
    func nestedTypeAndMemberPagesHighlightOnlyTopLevelOwner(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-nested-owner"
        let packageName = "fixture"
        let path = "src/nested.cj"
        let source = SourceRange(path, SourcePosition(1, 1, 0), SourcePosition(6, 2, 90))
        let idPrefix = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asidebar-nested-owner::fixture"
        let outerId = idPrefix + "::class:Outer#g0()"
        let innerId = idPrefix + "::Outer::class:Inner#g0()"
        let memberId = idPrefix + "::Outer::Inner::function:render#g0()"
        let semantic = SemanticInfo("partial", "syntax")
        let outer = SymbolDoc(outerId, "class", "Outer", "fixture.Outer",
            packageName, moduleId, "public", source, "public class Outer", semantic)
        let inner = SymbolDoc(innerId, "class", "Inner", "fixture.Outer.Inner",
            packageName, moduleId, "public", source, "public class Inner", semantic,
            ownerId: Some(outerId))
        let unit = TypeRef("primitive", "Unit",
            SemanticType("partial", provider: Some("syntax")))
        let member = SymbolDoc(memberId, "function", "render",
            "fixture.Outer.Inner.render", packageName, moduleId, "public", source,
            "public func render(): Unit", semantic, ownerId: Some(innerId),
            returnType: Some(unit))
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"),
            "complete", ProjectInfo("nested-sidebar"),
            ConfigurationSnapshot(audience: "external"),
            providers: [ProviderInfo("syntax", "1", moduleId, "partial",
                SemanticCapabilities(true, true, true, false, false))],
            modules: [ModuleDoc(moduleId, "nested-sidebar", "root", "",
                packageNames: [packageName])],
            packages: [PackageDoc(packageName, moduleId,
                sourceFiles: [path], symbolIds: [outerId, innerId, memberId])],
            files: [FileDoc(path, moduleId, packageName,
                provenance: SourceProvenance.unavailable("no_project_repository"))],
            declarations: [outer, inner, member])
        validateDocumentationSet(documentation)
        let projection = RenderProjection(documentation)
        let packagePath = packagePagePath(moduleId, packageName)
        for (current in [inner, member]) {
            let currentPath = symbolPagePath(current)
            let html = renderSidebarHtml(projection, Some(packagePath),
                Some(current), Some(currentPath))
            @Expect(html.contains("data-cjdoc-current-symbol=\"${outerId}\""))
            @Expect(html.contains("data-cjdoc-current-page=\"${currentPath}\""))
            // The context owner stays a single, reachable ancestor link.
            @Expect(html.split("href=\"../${symbolPagePath(outer)}\"").size - 1, 1)
            @Expect(html.contains("cj-tree__link--ancestor"))
            @Expect(!html.contains("aria-current=\"page\""))
            @Expect(!html.contains("href=\"../${currentPath}\""))
            // Nested declarations stay reachable as fragment links on the owner page.
            @Expect(html.contains("../${symbolPagePath(outer)}#${symbolAnchor(inner)}"))
        }
    }

    @TestCase
    func memberLinksCarryFragmentsAndNeverClaimPageIdentity(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-members"
        let source = sidebarFixtureSource()
        let owner = SymbolDoc("type-owner", "class", "Owner", "fixture.Owner",
            "fixture", moduleId, "public", source, "public class Owner",
            SemanticInfo("partial", "ast"))
        let run = SymbolDoc("member-run", "function", "run", "fixture.Owner.run",
            "fixture", moduleId, "public", source, "public func run(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some("type-owner"))
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture",
            [owner, run])
        let projection = RenderProjection(documentation)
        let packagePath = packagePagePath(moduleId, "fixture")
        let html = renderSidebarHtml(projection, Some(packagePath),
            Some(owner), Some(symbolPagePath(owner)))

        @Expect(html.contains("data-cjdoc-tree-item=\"member\""))
        @Expect(html.contains("cj-tree__children"))
        // The member's own anchor is the fragment; the type link owns the page.
        @Expect(html.contains("href=\"../${symbolPagePath(owner)}#${symbolAnchor(run)}\""))
        // Attribute order is fixed by the writer: class, data hook, aria state, href.
        @Expect(html.contains("<a class=\"cj-tree__link\" data-cjdoc-nav-link " +
            "aria-current=\"page\" href=\"../${symbolPagePath(owner)}\">"))
        @Expect(html.contains("data-kind=\"function\""))
    }

    @TestCase
    func overloadedTopLevelDeclarationsKeepDistinctVisibleLabels(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-overloads"
        let source = sidebarFixtureSource()
        let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
        let stringType = TypeRef("primitive", "String", SemanticType("unavailable"))
        let numeric = SymbolDoc("makeBox-int", "function", "makeBox", "fixture.makeBox",
            "fixture", moduleId, "public", source, "public func makeBox(value: Int64): Unit",
            SemanticInfo("partial", "ast"), parameters: [ParameterDoc("value", intType)])
        let textual = SymbolDoc("makeBox-string", "function", "makeBox", "fixture.makeBox",
            "fixture", moduleId, "public", source, "public func makeBox(value: String): Unit",
            SemanticInfo("partial", "ast"), parameters: [ParameterDoc("value", stringType)])
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture",
            [numeric, textual])
        let projection = RenderProjection(documentation)
        let labels = sidebarPackageLabels(projection, moduleId, "fixture")
        @Expect(labels["makeBox-int"], "makeBox(Int64)")
        @Expect(labels["makeBox-string"], "makeBox(String)")
    }

    @TestCase
    func duplicateExtensionTargetsHaveDistinctReadableLinks(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-extension"
        let source = SourceRange("src/fixture.cj", SourcePosition(2, 1, 16),
            SourcePosition(2, 36, 51))
        let pretty = SymbolDoc("ext-pretty", "extend", "Box<String>",
            "fixture.Box<String>", "fixture", moduleId, "public", source,
            "extend Box<String>", SemanticInfo("partial", "ast"))
        let length = SymbolDoc("ext-length", "extend", "Box<String>",
            "fixture.Box<String>", "fixture", moduleId, "public", source,
            "extend Box<String>", SemanticInfo("partial", "ast"))
        let prettyMethod = SymbolDoc("method-pretty", "function", "pretty",
            "fixture.Box.pretty", "fixture", moduleId, "public", source,
            "public func pretty(): String", SemanticInfo("partial", "ast"),
            ownerId: Some("ext-pretty"))
        let lengthMethod = SymbolDoc("method-length", "function", "length",
            "fixture.Box.length", "fixture", moduleId, "public", source,
            "public func length(): Int64", SemanticInfo("partial", "ast"),
            ownerId: Some("ext-length"))
        let emptyFirst = SymbolDoc("empty-first", "extend", "Box<Int64>",
            "fixture.Box<Int64>", "fixture", moduleId, "public", source,
            "extend Box<Int64>", SemanticInfo("partial", "ast"))
        let emptySecond = SymbolDoc("empty-second", "extend", "Box<Int64>",
            "fixture.Box<Int64>", "fixture", moduleId, "public", source,
            "extend Box<Int64>", SemanticInfo("partial", "ast"))
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture",
            [pretty, length, prettyMethod, lengthMethod, emptyFirst, emptySecond])
        let projection = RenderProjection(documentation)
        let labels = sidebarPackageLabels(projection, moduleId, "fixture")
        @Expect(labels["ext-pretty"], "Box<String> · pretty()")
        @Expect(labels["ext-length"], "Box<String> · length()")
        @Expect(labels["empty-first"], "Box<Int64>")
        @Expect(labels["empty-second"], "Box<Int64> · #2")
    }
}

@Test
class HtmlSidebarIndexTest {
    @TestCase
    func publishesVersionTwoNavigationWithSortedKeysAndResolvableTargets(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-index"
        let source = sidebarFixtureSource()
        let owner = SymbolDoc("type-b", "class", "Box", "fixture.Box",
            "fixture", moduleId, "public", source, "public class Box",
            SemanticInfo("partial", "ast"))
        let second = SymbolDoc("type-a", "class", "Axis", "fixture.Axis",
            "fixture", moduleId, "public", source, "public class Axis",
            SemanticInfo("partial", "ast"))
        let run = SymbolDoc("member-b", "function", "run", "fixture.Box.run",
            "fixture", moduleId, "public", source, "public func run(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some("type-b"))
        let stop = SymbolDoc("member-a", "function", "stop", "fixture.Box.stop",
            "fixture", moduleId, "public", source, "public func stop(): Unit",
            SemanticInfo("partial", "ast"), ownerId: Some("type-b"))
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture",
            [owner, second, run, stop])
        let projection = RenderProjection(documentation)
        let script = renderSidebarIndexScript(projection, "en")
        let packagePath = packagePagePath(moduleId, "fixture")

        @Expect(script.startsWith("globalThis.__CJDOC_SIDEBAR_INDEX__={\"version\":2,"))
        @Expect(script.endsWith("}};\n"))
        @Expect(script.contains("\"packages\":[{\"id\":\"${packagePath}\""))
        @Expect(script.contains("\"href\":\"${packagePath}\""))
        @Expect(script.contains("\"types\":{\"type-a\":{\"label\":\"Axis\""))
        @Expect(script.contains("\"kind\":\"class\""))
        @Expect(script.contains("\"href\":\"${symbolPagePath(second)}\""))
        // The members array keeps reader display order; the JSON object keys are
        // sorted separately and asserted below.
        @Expect(script.contains("\"members\":[\"member-b\",\"member-a\"]"))
        @Expect(script.contains("\"members\":{\"member-a\":{\"label\":\"stop()\""))
        @Expect(script.contains("\"anchor\":\"${symbolAnchor(stop)}\""))
        // Object keys are byte ordered so the shared payload stays deterministic.
        let firstType = script.indexOf("\"type-a\":")
        let lastType = script.indexOf("\"type-b\":")
        @Expect(firstType.isSome() && lastType.isSome())
        @Expect(firstType.getOrThrow() < lastType.getOrThrow())
        let firstMember = script.indexOf("\"member-a\":{\"label\"")
        let lastMember = script.indexOf("\"member-b\":{\"label\"")
        @Expect(firstMember.isSome() && lastMember.isSome())
        @Expect(firstMember.getOrThrow() < lastMember.getOrThrow())
        // Hrefs stay root-relative; the browser adds the per-page prefix.
        @Expect(!script.contains("\"href\":\"../"))
    }

    @TestCase
    func navigationPayloadEscapesAuthorTextAsJsonStrings(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-index-plain"
        let owner = SymbolDoc("type-escape", "class", "Box\"quoted\"", "fixture.Box",
            "fixture", moduleId, "public", sidebarFixtureSource(),
            "public class Box", SemanticInfo("partial", "ast"))
        let documentation = sidebarFixtureDocumentation(moduleId, "fixture", [owner])
        let script = renderSidebarIndexScript(RenderProjection(documentation), "en")
        // The payload is an external JSON literal: quotes are escaped, never raw.
        @Expect(script.contains("\"label\":\"Box\\\"quoted\\\"\""))
        @Expect(!script.contains("Box\"quoted\""))
    }
}
