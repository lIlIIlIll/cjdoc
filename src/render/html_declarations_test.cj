package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let ROW_MODULE = "cjdoc:module:v1:package-rows"

private func rowSymbol(key: String, name: String, kind: String, header: String,
    generics!: Array<String> = []): SymbolDoc {
    SymbolDoc("cjdoc:v2:cjdoc%3Amodule%3Av1%3Apackage-rows::fixture::${key}",
        kind, name, "fixture." + name, "fixture", ROW_MODULE, "public",
        SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 2, 1)),
        header, SemanticInfo("partial", "ast"), genericParameters: generics)
}

private func rowDocumentation(symbols: Array<SymbolDoc>, audience!: String = "external"): DocumentationSet {
    let ids = ArrayList<String>()
    for (symbol in symbols) { ids.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("package-rows"),
        ConfigurationSnapshot(audience: audience, lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", ROW_MODULE, "partial",
            SemanticCapabilities(false, false, false, true, false))],
        modules: [ModuleDoc(ROW_MODULE, "package-rows", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", ROW_MODULE, sourceFiles: ["src/api.cj"], symbolIds: ids.toArray())],
        files: [FileDoc("src/api.cj", ROW_MODULE, "fixture")], declarations: symbols)
}

private func packageRowsHtml(documentation: DocumentationSet, locale: String): String {
    for (artifact in renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)) {
        if (artifact.path.startsWith("html/packages/")) { return artifact.content }
    }
    throw IllegalArgumentException("missing package page")
}

// Both the multi-category (umbrella H2) and single-category (the group heading
// itself) shapes expose the same #declarations anchor, so the historical deep
// link keeps resolving whichever shape a package projects.
private func declarationRowsHtml(html: String): String {
    let marker = html.indexOf("id=\"declarations\"").getOrThrow()
    let sectionStart = html[0..marker].lastIndexOf("<section").getOrThrow()
    html[sectionStart..html.indexOf("</main>").getOrThrow()]
}

@Test
class HtmlPackageDeclarationTest {
    @TestCase
    func genericIdentityComesFromModelAndDoesNotRewriteSourceOrRoutes(): Unit {
        let documentation = rowDocumentation([
            rowSymbol("class:Entry#g1()", "Entry", "class", "public class Entry<T>", generics: ["T"]),
            rowSymbol("class:Map#g2()", "Map", "class",
                "public class Map<K,V> where K <: Hashable<K>", generics: ["K", "V"]),
            rowSymbol("class:Unknown#g0()", "Unknown", "class", "public class Unknown<NotInModel>"),
            rowSymbol("extend:Entry<String>#g1()", "Entry < String >", "extend",
                "extend<T> Entry<String> where T <: Comparable<T>", generics: ["T"])
        ])
        let original = encodeDocIr(documentation)
        for (locale in ["en", "zh-CN"]) {
            let html = declarationRowsHtml(packageRowsHtml(documentation, locale))
            @Expect(html.contains("<code>Entry&lt;T&gt;</code>"))
            @Expect(html.contains("<code>Map&lt;K, V&gt;</code>"))
            @Expect(html.contains("<code>Unknown</code>"))
            @Expect(!html.contains("<code>Unknown&lt;NotInModel&gt;</code>"))
            @Expect(html.contains("public class Unknown&lt;NotInModel&gt;"))
            @Expect(html.contains("public class Map&lt;K,V&gt; where K &lt;: Hashable&lt;K&gt;"))
            @Expect(html.contains("<code>Entry&lt;String&gt;</code>"))
            @Expect(!html.contains("Entry&lt;String&gt;&lt;T&gt;"))
            @Expect(!html.contains("class=\"declaration-kind\""))
            @Expect(html.contains(if (locale == "en") { "Classes (3)" } else { "类（3）" }))
        }
        @Expect(encodeDocIr(documentation), original)
    }

    @TestCase
    func packageSignaturesPreserveHighlightAndResolvedLinksWithoutNestedAnchors(): Unit {
        let target = rowSymbol("class:Entry#g0()", "Entry", "class", "public class Entry")
        let base = rowSymbol("function:accept#g0(String,Entry)", "accept", "function", "")
        let typeRef = TypeRef("named", "Entry", SemanticType("resolved",
            canonical: Some("fixture.Entry"), provider: Some("ast")))
        let raw = "public func accept(label!: String = \"Entry\", item!: Entry): Entry"
        let tokens = ["PUBLIC:6:public", "FUNC:4:func", "IDENTIFIER:6:accept", "LPAREN:1:(",
            "IDENTIFIER:5:label", "NOT:1:!", "COLON:1::", "IDENTIFIER:6:String", "ASSIGN:1:=",
            "STRING_LITERAL:7:\"Entry\"", "COMMA:1:,", "IDENTIFIER:4:item", "NOT:1:!", "COLON:1::",
            "IDENTIFIER:5:Entry", "RPAREN:1:)", "COLON:1::", "IDENTIFIER:5:Entry"]
        let function = SymbolDoc(base.id, base.kind, base.name, base.qualifiedName,
            base.packageName, base.moduleId, base.visibility, base.source, raw, base.semantic,
            parameters: [ParameterDoc("label", TypeRef("named", "String", SemanticType("unavailable"))),
                ParameterDoc("item", typeRef)], returnType: Some(typeRef),
            sourceApiSignature: SourceApiSignature("available", tokens: tokens),
            signatureHighlight: Some(CodeHighlight("cangjie", contractFingerprint(raw), raw.size,
                "fixture", "1", "complete", None, [CodeSpan(0, 6, "keyword"),
                    CodeSpan(raw.indexOf("\"Entry\"").getOrThrow(),
                        raw.indexOf("\"Entry\"").getOrThrow() + 7, "string")])))
        let html = declarationRowsHtml(packageRowsHtml(rowDocumentation([target, function]), "en"))
        @Expect(html.split("class=\"type-link signature-type-link\"").size, 3)
        @Expect(html.contains("<span class=\"code-keyword\">public</span>"))
        @Expect(html.contains("<span class=\"code-string\">&quot;Entry&quot;</span>"))
        @Expect(!html.contains("&quot;<a"))
    }


    @TestCase
    func projectedCountsAndAmbiguousKindsDoNotLeakPrivateDeclarations(): Unit {
        let publicType = rowSymbol("class:Shared#g0()", "Shared", "class", "public class Shared")
        let function = rowSymbol("function:Shared#g0()", "Shared", "function", "public func Shared(): Unit")
        let special = rowSymbol("macro:Quoted#g0()", "Quoted", "macro", "")
        let hidden = SymbolDoc("cjdoc:v2:cjdoc%3Amodule%3Av1%3Apackage-rows::fixture::class:Hidden#g0()",
            "class", "Hidden", "fixture.Hidden", "fixture", ROW_MODULE, "private", publicType.source,
            "private class Hidden", SemanticInfo("partial", "ast"), documentation: Some(
                DocComment("raw", "private summary must not leak", "", MarkdownNode("document"))))
        let symbols = [publicType, function, special, hidden]
        let external = declarationRowsHtml(packageRowsHtml(rowDocumentation(symbols), "zh-CN"))
        @Expect(external.contains("类（1）"))
        @Expect(external.contains("函数（1）"))
        @Expect(external.contains("其他声明（1）"))
        @Expect(external.contains("class=\"declaration-kind\">类</span>"))
        @Expect(external.contains("class=\"declaration-kind\">函数</span>"))
        @Expect(external.contains("class=\"declaration-kind\">macro</span>"))
        @Expect(!external.contains("Hidden"))
        @Expect(!external.contains("private summary must not leak"))
        let all = declarationRowsHtml(packageRowsHtml(rowDocumentation(symbols, audience: "all"), "zh-CN"))
        @Expect(all.contains("类（2）"))
        @Expect(all.contains("private summary must not leak"))
    }

    @TestCase
    func overloadsAndEscapedTextRemainCompleteWithoutInventedEmptyContent(): Unit {
        let unusual = "<>&\"'"
        let summary = "中文摘要 " + unusual + " English summary & details"
        let base = rowSymbol("function:escaped#g0()", unusual, "function", "")
        let escaped = SymbolDoc(base.id, base.kind, base.name, base.qualifiedName,
            base.packageName, base.moduleId, base.visibility, base.source, "public func " + unusual + "(): Unit",
            base.semantic, documentation: Some(DocComment("raw", summary, "", MarkdownNode("document"))))
        let documentation = rowDocumentation([
            escaped,
            rowSymbol("function:read#g0(Int64)", "read", "function", "public func read(value: Int64 = 42): Unit"),
            rowSymbol("function:read#g0(String)", "read", "function", "public func read(value: String = \"<>&\"): Unit"),
            rowSymbol("class:Empty#g0()", "Empty", "class", "")
        ])
        let html = declarationRowsHtml(packageRowsHtml(documentation, "en"))
        @Expect(html.contains("<code>&lt;&gt;&amp;&quot;&#39;</code>"))
        @Expect(html.contains("中文摘要 &lt;&gt;&amp;&quot;&#39; English summary &amp; details"))
        @Expect(!html.contains("<code><>&"))
        @Expect(html.contains("public func read(value: Int64 = 42): Unit"))
        @Expect(html.contains("public func read(value: String = &quot;&lt;&gt;&amp;&quot;): Unit"))
        @Expect(!html.contains("<p class=\"declaration-description\"></p>"))
        @Expect(!html.contains("<code class=\"declaration-signature\"></code>"))
    }

    // Issue #112: the anchor must resolve for the far more common single-category
    // package too, without a heading that duplicates the section it introduces.
    @TestCase
    func singleCategoryPackageKeepsTheDeclarationsAnchorWithoutDuplicateHeading(): Unit {
        let onlyFunctions = rowDocumentation([
            rowSymbol("function:alpha#g0()", "alpha", "function", "public func alpha(): Unit"),
            rowSymbol("function:beta#g0()", "beta", "function", "public func beta(): Unit")
        ])
        let cases = [("en", "Functions", " (2)"), ("zh-CN", "函数", "（2）")]
        for (index in 0..cases.size) {
            let locale = cases[index][0]
            let heading = cases[index][1]
            let count = cases[index][2]
            let html = packageRowsHtml(onlyFunctions, locale)
            @Expect(html.split("id=\"declarations\"").size, 2)
            @Expect(html.contains("<h2 id=\"declarations\" data-cjdoc-toc-role=\"group\">" + heading + count + "</h2>"))
            @Expect(!html.contains("<h2 id=\"functions\""))
            @Expect(!html.contains("<h2 id=\"declarations\">" + if (locale == "en") { "Declarations" } else { "声明" }))
        }
    }

    // A single category is the section: no umbrella heading, no second heading
    // for the same content, and no empty pseudo-section in the TOC.
    @TestCase
    func multipleCategoriesNestUnderOneUmbrellaHeadingAndPruneEmptyGroups(): Unit {
        let documentation = rowDocumentation([
            rowSymbol("class:Entry#g0()", "Entry", "class", "public class Entry"),
            rowSymbol("function:run#g0()", "run", "function", "public func run(): Unit")
        ])
        let html = packageRowsHtml(documentation, "en")
        @Expect(html.split("<h2 id=\"declarations\"").size, 2)
        @Expect(html.contains("<h3 id=\"classes\" data-cjdoc-toc-role=\"group\">Classes (1)</h3>"))
        @Expect(html.contains("<h3 id=\"functions\" data-cjdoc-toc-role=\"group\">Functions (1)</h3>"))
        // No heading is emitted for a category the projection did not produce.
        @Expect(!html.contains("id=\"structs\""))
        @Expect(!html.contains("id=\"enums\""))
        @Expect(!html.contains("(0)"))
        @Expect(!html.contains("（0）"))
    }

    // An audience that sees no declarations still gets a labelled, TOC-visible
    // section instead of a bare paragraph with no anchor. The page exists because
    // the package has re-exports, which is what makes an empty projection
    // renderable at all (html_routing.cj keeps exactly those packages).
    @TestCase
    func emptyProjectionKeepsALabelledDeclarationsSection(): Unit {
        let reExport = ReExportDoc(
            "cjdoc:reexport:v1:1111111111111111111111111111111111111111111111111111111111111111",
            "single", "fixture", "unavailable", SourceRange("src/api.cj",
                SourcePosition(1, 1, 0), SourcePosition(1, 2, 1)))
        let documentation = rowDocumentation([])
        let packages = ArrayList<PackageDoc>()
        for (pkg in documentation.packages) {
            packages.add(PackageDoc(pkg.name, pkg.moduleId,
                sourceFiles: pkg.sourceFiles.toArray(), symbolIds: pkg.symbolIds.toArray(),
                reExports: [reExport]))
        }
        let document = DocumentationSet(documentation.generator, documentation.status,
            documentation.project, documentation.configuration,
            providers: documentation.providers.toArray(), modules: documentation.modules.toArray(),
            packages: packages.toArray(), files: documentation.files.toArray(),
            declarations: documentation.declarations.toArray())
        let cases = [("en", "Declarations"), ("zh-CN", "声明")]
        for (index in 0..cases.size) {
            let locale = cases[index][0]
            let heading = cases[index][1]
            let html = packageRowsHtml(document, locale)
            @Expect(html.contains("<h2 id=\"declarations\" data-cjdoc-toc-role=\"group\">" + heading + "</h2>"))
            @Expect(html.contains("class=\"empty-state\""))
        }
    }
}