package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlSidebarNavigationTest {
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
            "../", "en", selected)
        let html = out.toString()

        @Expect(html.contains("class=\"sidebar-symbol is-current\""), true)
        @Expect(html.contains("aria-current=\"page\""), true)
        @Expect(html.contains("zz_Last"), true)
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
