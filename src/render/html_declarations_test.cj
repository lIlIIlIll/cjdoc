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

private func rowDocumentation(symbols: Array<SymbolDoc>, audience!: String = "external",
    metadata!: DocumentationMetadata = DocumentationMetadata()): DocumentationSet {
    let ids = ArrayList<String>()
    for (symbol in symbols) { ids.add(symbol.id) }
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("package-rows"),
        ConfigurationSnapshot(audience: audience, lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", ROW_MODULE, "partial",
            SemanticCapabilities(false, false, false, true, false))],
        modules: [ModuleDoc(ROW_MODULE, "package-rows", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", ROW_MODULE, sourceFiles: ["src/api.cj"], symbolIds: ids.toArray())],
        files: [FileDoc("src/api.cj", ROW_MODULE, "fixture")], declarations: symbols,
        metadata: metadata)

}

private func packageRowsHtml(documentation: DocumentationSet, locale: String): String {
    for (artifact in renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)) {
        if (artifact.path.startsWith("html/packages/") && artifact.path.endsWith("/index.html")) {
            return artifact.content
        }
    }
    throw IllegalArgumentException("missing package page")
}

// Both the multi-category (umbrella H2) and single-category (the group heading
// itself) shapes expose the same #declarations anchor, so the historical deep
// link keeps resolving whichever shape a package projects.
private func declarationRowsHtml(html: String): String {
    let marker = html.indexOf("id=\"declarations\"").getOrThrow()
    html[marker..html.indexOf("</main>").getOrThrow()]
}

@Test
class HtmlPackageDeclarationTest {
    @TestCase
    func reverseUsagesDescribePositionsWithoutChangingTargetsOrMultiplicity(): Unit {
        let target = rowSymbol("class:Entry#g0()", "Entry", "class", "public class Entry")
        let reference = TypeRef("named", "Entry", SemanticType("resolved",
            canonical: Some("fixture.Entry"), provider: Some("ast")))
        let symbols = ArrayList<SymbolDoc>([target])
        let kinds = ["parameter", "field", "return", "superType", "extensionTarget",
            "genericConstraint", "provider<&>"]
        for (kind in kinds) {
            let base = rowSymbol("function:${kind}#g0()", kind, "function", "")
            symbols.add(SymbolDoc(base.id, base.kind, base.name, base.qualifiedName,
                base.packageName, base.moduleId, base.visibility, base.source, "", base.semantic,
                typeRelationships: [TypeRelationship(kind, reference), TypeRelationship(kind, reference)]))
        }
        let documentation = rowDocumentation(symbols.toArray())
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        let links = HtmlTypeLinkIndex(documentation, projection)
        @Expect(links.reverseUsages(target.id).size, kinds.size)
        for (locale in ["en", "zh-CN"]) {
            let out = HtmlWriter()
            appendReverseTypeUsages(out, links, target, "../", locale)
            let html = out.toString()
            @Expect(html.split("class=\"cj-usages__item\"").size - 1, kinds.size)
            @Expect(!html.contains("provider<&>"))
            @Expect(html.contains("provider&lt;&amp;&gt;"))
            for (usage in links.reverseUsages(target.id)) {
                @Expect(html.contains("../" + projection.symbolFileHref(usage.source.id)))
            }
        }
    }

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
        // The route index buckets by the same visible declarations the page lists.
        let projection = RenderProjection(documentation, buildApiRoutes: true)
        for (locale in ["en", "zh-CN"]) {
            let html = declarationRowsHtml(packageRowsHtml(documentation, locale))
            // Generated list boundaries carry display-only soft breaks; the
            // reader text is unchanged once the void elements are removed.
            let plain = html.replace("<wbr>", "")
            @Expect(plain.contains("<code>Entry&lt;T&gt;</code>"))
            @Expect(plain.contains("<code>Map&lt;K, V&gt;</code>"))
            @Expect(plain.contains("<code>Unknown</code>"))
            @Expect(!plain.contains("NotInModel"))
            @Expect(plain.contains("<code>Entry&lt;String&gt;</code>"))
            @Expect(!plain.contains("Entry&lt;String&gt;&lt;T&gt;"))
            // Rows link to the canonical declaration routes and never inline the
            // captured source header; the kind is the section heading, not a
            // repeated badge column on every row.
            for (symbol in documentation.declarations) {
                @Expect(html.contains("href=\"../../" + projection.symbolFileHref(symbol.id) + "\""))
            }
            @Expect(!html.contains("where K &lt;: Hashable"))
            @Expect(!html.contains("class=\"cj-kind\""))
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
        // Package rows are a compact table: the signature stays on the declaration page.
        @Expect(!html.contains("cj-signature"))
        @Expect(html.contains("class=\"cj-decl-table__link\""))
        @Expect(!html.contains("cj-signature-inline"))
        @Expect(html.split("class=\"cj-decl-table__row\"").size - 1, 2)
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
                DocComment("raw", "private summary must not leak", "", MarkdownNode("document"),
                    tags: [DocTag("group", "private-group", ""),
                        DocTag("tag", "private-tag", "")])))
        let symbols = [publicType, function, special, hidden]
        let hiddenMetadata = DocumentationMetadata(
            groups: [DocumentationGroupDefinition(ROW_MODULE, "fixture", "private-group",
                "private-group-title")],
            tags: [DocumentationTagDefinition(ROW_MODULE, "private-tag", "private-tag-title")])
        let external = declarationRowsHtml(packageRowsHtml(
            rowDocumentation(symbols, metadata: hiddenMetadata), "zh-CN"))
        @Expect(external.contains("类（1）"))
        @Expect(external.contains("函数（1）"))
        @Expect(external.contains("宏（1）"))
        // Each visible kind heading states the kind once; the rows do not
        // repeat it in a third column.
        @Expect(external.contains(">类（1）</h3>"))
        @Expect(external.contains(">函数（1）</h3>"))
        @Expect(!external.contains("class=\"cj-kind\""))
        @Expect(htmlKindLabel("macro", "zh-CN"), "宏")
        @Expect(external.contains("Quoted"))
        @Expect(!external.contains("Hidden"))
        @Expect(!external.contains("private summary must not leak"))
        @Expect(!external.contains("private-group-title"))
        @Expect(!external.contains("private-tag-title"))
        @Expect(!external.contains("private-tag"))
        let all = declarationRowsHtml(packageRowsHtml(
            rowDocumentation(symbols, audience: "all", metadata: hiddenMetadata), "zh-CN"))
        @Expect(all.contains("private summary must not leak"))
        @Expect(all.contains("private-group-title"))
        @Expect(all.contains("private-tag-title"))
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
        // Rows show the navigation label, which keeps the parameter list of a
        // function distinguishable; the escaped source name is still escaped.
        @Expect(html.contains("<code>&lt;&gt;&amp;&quot;&#39;()</code>"), true)
        @Expect(html.contains("中文摘要 &lt;&gt;&amp;&quot;&#39; English summary &amp; details"))
        @Expect(!html.contains("<code><>&"))
        // Overloads stay distinct rows even though the table drops signatures.
        @Expect(html.split("data-member-name=\"read\"").size - 1, 2)
        @Expect(html.contains("<td class=\"cj-decl-table__summary\"></td>"))
        @Expect(!html.contains("class=\"cj-badges\""))
    }

    @TestCase
    func classificationBadgesEscapeTitlesAndUseCapturedScopeLinks(): Unit {
        let base = rowSymbol("function:classified#g0()", "classified", "function",
            "public func classified(): Unit")
        let classified = SymbolDoc(base.id, base.kind, base.name, base.qualifiedName,
            base.packageName, base.moduleId, base.visibility, base.source, base.headerSpelling,
            base.semantic, documentation: Some(DocComment("raw", "summary", "",
                MarkdownNode("document"), tags: [
                    DocTag("group", "unsafe", "inline title"),
                    DocTag("tag", "stream", "")
                ])))
        let unusedSentinel = "secret-unused-definition-93"
        let metadata = DocumentationMetadata(
            groups: [
                DocumentationGroupDefinition(ROW_MODULE, "fixture", "unsafe",
                    "<img src=x onerror=alert(1)>"),
                DocumentationGroupDefinition(ROW_MODULE, "fixture", "unused",
                    unusedSentinel)
            ],
            tags: [
                DocumentationTagDefinition(ROW_MODULE, "stream", "<svg onload=alert(1)>"),
                DocumentationTagDefinition(ROW_MODULE, "unused-tag", unusedSentinel)
            ])
        let html = declarationRowsHtml(packageRowsHtml(
            rowDocumentation([classified], metadata: metadata), "en"))
        @Expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        @Expect(html.contains("&lt;svg onload=alert(1)&gt;"))
        @Expect(!html.contains("<img src=x onerror=alert(1)>"))
        @Expect(!html.contains("<svg onload=alert(1)>"))
        @Expect(!html.contains(unusedSentinel))
        let primary = html.indexOf("<a class=\"cj-decl-table__link\"").getOrThrow()
        let badges = html.indexOf("<div class=\"cj-badges\">").getOrThrow()
        @Expect(primary < badges)
        @Expect(html[primary..badges].contains("</a>"))
        @Expect(html.contains("data-cjdoc-tag-id=\"stream\""))
        @Expect(html.contains("href=\"../../index.html?tag=stream&amp;moduleId=cjdoc%3Amodule%3Av1%3Apackage-rows&amp;snapshotId="))
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
            @Expect(html.contains("<span class=\"cj-anchor-alias\" id=\"functions\" aria-hidden=\"true\"></span>"))
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

    // The kind is stated once: a visible kind heading suppresses the row badge,
    // while an author group whose kind heading is merged (one visible kind) must
    // still tell the reader the kind on each row.
    @TestCase
    func kindBadgeAppearsOnlyWhenNoHeadingStatesIt(): Unit {
        let singleKind = rowSymbol("function:alpha#g0()", "alpha", "function",
            "public func alpha(): Unit")
        let single = packageRowsHtml(rowDocumentation([singleKind]), "en")
        @Expect(single.contains(">Functions (1)</h2>"))
        @Expect(!single.contains("cj-decl-table__kind"))

        let groupedBase = rowSymbol("function:grouped#g0()", "grouped", "function",
            "public func grouped(): Unit")
        let grouped = SymbolDoc(groupedBase.id, groupedBase.kind, groupedBase.name,
            groupedBase.qualifiedName, groupedBase.packageName, groupedBase.moduleId,
            groupedBase.visibility, groupedBase.source, groupedBase.headerSpelling,
            groupedBase.semantic, documentation: Some(DocComment("raw", "summary", "",
                MarkdownNode("document"), tags: [DocTag("group", "core", "")])))
        let groupedDocumentation = rowDocumentation([grouped], metadata: DocumentationMetadata(
            groups: [DocumentationGroupDefinition(ROW_MODULE, "fixture", "core", "Core")]))
        let groupedHtml = packageRowsHtml(groupedDocumentation, "en")
        // One visible kind under the author group: no second heading, so the row
        // carries the kind badge.
        @Expect(groupedHtml.contains("data-group-total=\"1\""))
        @Expect(!groupedHtml.contains(">Functions (1)</h3>"))
        @Expect(groupedHtml.contains("<span class=\"cj-kind cj-decl-table__kind\" " +
            "data-kind=\"function\">function</span>"))
    }

    // The declaration row itself is the outline target: it owns the stable
    // symbol anchor, carries the entry role, and keeps the compact label text
    // intact across display-only soft-break points.
    @TestCase
    func declarationRowsOwnStableAnchorsAndKeepCompactLabelText(): Unit {
        let symbol = rowSymbol("function:parse#g0(String)", "parse", "function",
            "public func parse(text: String): Unit")
        let html = declarationRowsHtml(packageRowsHtml(rowDocumentation([symbol]), "en"))
        let anchor = symbolAnchor(symbol)
        @Expect(html.contains("<tr class=\"cj-decl-table__row\" data-cjdoc-member " +
            "data-member-symbol-id=\"" + symbol.id + "\""), true)
        @Expect(html.contains("id=\"" + anchor + "\" data-cjdoc-toc-role=\"entry\""), true)
        @Expect(html.split("id=\"" + anchor + "\"").size, 2)
        // The primary link is still the declaration destination.
        @Expect(html.contains("<a class=\"cj-decl-table__link\" "), true)
        let out = HtmlWriter()
        appendSoftWrappedLabel(out, "parse(text: String, separator!: String = \",\")")
        let wrapped = out.toString()
        // Soft breaks land only after the generated list opener and separators;
        // removing them restores the exact label.
        @Expect(wrapped.contains("parse(<wbr>text: String, <wbr>separator!: String"), true)
        @Expect(wrapped.replace("<wbr>", ""),
            "parse(text: String, separator!: String = &quot;,&quot;)")
        let empty = HtmlWriter()
        appendSoftWrappedLabel(empty, "isEmpty()")
        @Expect(empty.toString(), "isEmpty()")
        // A default expression's own parentheses are not display boundaries.
        let nested = HtmlWriter()
        appendSoftWrappedLabel(nested, "policy(value: Option<(Int64, String)>)")
        @Expect(nested.toString(), "policy(<wbr>value: Option&lt;(Int64, String)&gt;)")
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
            @Expect(html.contains("class=\"cj-empty\""))
        }
    }
}