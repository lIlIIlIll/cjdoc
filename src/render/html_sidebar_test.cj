package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlSidebarNavigationTest {
    @TestCase
    func pageIdentityNeverUsesFragmentsOrSuffixMatching(): Unit {
        @Expect(sidebarPageIsCurrent("index.html", Some("index.html")))
        @Expect(!sidebarPageIsCurrent("index.html#packages", Some("index.html")))
        @Expect(!sidebarPageIsCurrent("index.html", Some("concepts/index.html")))
        @Expect(!sidebarPageIsCurrent("index.html", None))
        @Expect(!sidebarPageIsCurrent("symbols/owner.html", Some("symbols/member.html")))
    }

    @TestCase
    func currentSymbolRemainsVisibleAfterSidebarLimit(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-limit"
        let source = SourceRange("src/fixture.cj", SourcePosition(1, 1, 0),
            SourcePosition(1, 24, 23))
        let ids = ArrayList<String>()
        let declarations = ArrayList<SymbolDoc>()
        var selected: ?SymbolDoc = None
        for (index in 0..270) {
            let name = if (index == 269) { "zz_Last" } else { "Item${index}" }
            let id = "sidebar-${index}"
            let symbol = SymbolDoc(id, "class", name, "fixture.${name}",
                "fixture", moduleId, "public", source, "public class ${name}",
                SemanticInfo("partial", "ast"))
            ids.add(id)
            declarations.add(symbol)
            if (index == 269) { selected = Some(symbol) }
        }
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("sidebar-limit"), ConfigurationSnapshot(audience: "external"),
            modules: [ModuleDoc(moduleId, "sidebar-limit", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, symbolIds: ids.toArray())],
            declarations: declarations.toArray())
        let projection = RenderProjection(documentation)
        let out = RenderTextBuffer()
        appendSidebarActiveSymbols(out, projection, moduleId, "fixture",
            "../", "en", selected, Some(symbolPagePath(selected.getOrThrow())))
        let html = out.toString()

        @Expect(html.contains("class=\"sidebar-symbol is-current\""), true)
        @Expect(html.contains("aria-current=\"page\""), true)
        @Expect(html.contains("zz_Last"), true)
        let memberOut = RenderTextBuffer()
        appendSidebarActiveSymbols(memberOut, projection, moduleId, "fixture",
            "../", "en", selected, Some("symbols/member.html"))
        @Expect(!memberOut.toString().contains("aria-current=\"page\""))
        @Expect(memberOut.toString().contains("sidebar-symbol is-ancestor"))
    }

    @TestCase
    func nestedTypeAndMemberPagesHighlightOnlyTopLevelOwner(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-nested-owner"
        let packageName = "fixture"
        let path = "src/nested.cj"
        let source = SourceRange(path, SourcePosition(1, 1, 0),
            SourcePosition(6, 2, 90))
        let idPrefix =
            "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asidebar-nested-owner::fixture"
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
            let out = RenderTextBuffer()
            appendHtmlSidebar(out, documentation, projection, "../", "en",
                currentPackagePath: Some(packagePath), currentRoute: "api",
                currentSymbol: Some(current), currentPagePath: Some(currentPath))
            let html = out.toString()
            @Expect(html.contains("data-cjdoc-current-symbol=\"${outerId}\""), true)
            @Expect(html.contains("data-cjdoc-current-page=\"${currentPath}\""), true)
            @Expect(html.split("href=\"../${symbolPagePath(outer)}\"").size - 1, 1)
            @Expect(html.contains("class=\"sidebar-symbol is-ancestor\""), true)
            @Expect(!html.contains("aria-current=\"page\""))
            @Expect(!html.contains("href=\"../${currentPath}\""))
        }
    }

    @TestCase
    func overloadedTopLevelDeclarationsKeepDistinctVisibleLabels(): Unit {
        let moduleId = "cjdoc:module:v1:sidebar-overloads"
        let source = SourceRange("src/fixture.cj", SourcePosition(1, 1, 0),
            SourcePosition(1, 24, 23))
        let intType = TypeRef("primitive", "Int64", SemanticType("unavailable"))
        let stringType = TypeRef("primitive", "String", SemanticType("unavailable"))
        let numeric = SymbolDoc("makeBox-int", "function", "makeBox", "fixture.makeBox",
            "fixture", moduleId, "public", source, "public func makeBox(value: Int64): Unit",
            SemanticInfo("partial", "ast"), parameters: [ParameterDoc("value", intType)])
        let textual = SymbolDoc("makeBox-string", "function", "makeBox", "fixture.makeBox",
            "fixture", moduleId, "public", source, "public func makeBox(value: String): Unit",
            SemanticInfo("partial", "ast"), parameters: [ParameterDoc("value", stringType)])
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
            ProjectInfo("sidebar-overloads"), ConfigurationSnapshot(audience: "external"),
            modules: [ModuleDoc(moduleId, "sidebar-overloads", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId,
                symbolIds: ["makeBox-int", "makeBox-string"])],
            declarations: [numeric, textual])
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
        let documentation = DocumentationSet(GeneratorInfo("cjdoc", "test"),
            "complete", ProjectInfo("sidebar-extension"),
            ConfigurationSnapshot(audience: "external"),
            modules: [ModuleDoc(moduleId, "sidebar-extension", "root", "",
                packageNames: ["fixture"])],
            packages: [PackageDoc("fixture", moduleId, symbolIds: [
                "ext-pretty", "ext-length", "method-pretty", "method-length",
                "empty-first", "empty-second"])],
            declarations: [pretty, length, prettyMethod, lengthMethod,
                emptyFirst, emptySecond])
        let projection = RenderProjection(documentation)
        let labels = sidebarPackageLabels(projection, moduleId, "fixture")
        @Expect(labels["ext-pretty"], "Box<String> · pretty()")
        @Expect(labels["ext-length"], "Box<String> · length()")
        @Expect(labels["empty-first"], "Box<Int64>")
        @Expect(labels["empty-second"], "Box<Int64> · #2")
    }

}
