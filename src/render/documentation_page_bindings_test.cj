package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private let PAGE_BINDING_MODULE = "cjdoc:module:v1:page-binding"
private let PAGE_BINDING_PREFIX = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apage-binding::fixture::"
private let PAGE_BINDING_RUN = PAGE_BINDING_PREFIX + "function:run#g0()"
private let PAGE_BINDING_BOX = PAGE_BINDING_PREFIX + "class:Box#g0()"
private let PAGE_BINDING_MEMBER = PAGE_BINDING_PREFIX + "Box::function:member#g0()"
private let PAGE_BINDING_HIDDEN = PAGE_BINDING_PREFIX + "function:hidden#g0()"

private func pageBinding(target: String, state: String, id!: ?String = None,
    selector!: String = "example"): DocumentationPageBinding {
    DocumentationPageBinding(target, selector, "authored", "v1", 7,
        state: state, targetSymbolId: id)
}

private func pageBindingDocumentation(hiddenOnly!: Bool = false, fallbackOnly!: Bool = false): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let semantic = SemanticInfo("partial", "ast")
    let run = SymbolDoc(PAGE_BINDING_RUN, "function", "run", "fixture.run", "fixture", PAGE_BINDING_MODULE,
        "public", source, "public func run(): Unit", semantic)
    let box = SymbolDoc(PAGE_BINDING_BOX, "class", "Box", "fixture.Box", "fixture", PAGE_BINDING_MODULE,
        "public", source, "public class Box", semantic)
    let member = SymbolDoc(PAGE_BINDING_MEMBER, "function", "member", "fixture.Box.member", "fixture",
        PAGE_BINDING_MODULE, "public", source, "public func member(): Unit", semantic, ownerId: Some(PAGE_BINDING_BOX))
    let hidden = SymbolDoc(PAGE_BINDING_HIDDEN, "function", "hidden", "fixture.hidden", "fixture", PAGE_BINDING_MODULE,
        "private", source, "private func hidden(): Unit", semantic)
    let targets = if (hiddenOnly) { [PAGE_BINDING_HIDDEN] } else { [PAGE_BINDING_RUN, PAGE_BINDING_BOX, PAGE_BINDING_MEMBER] }
    let bindings = if (hiddenOnly) { [pageBinding("HiddenBindingSecret", "resolved", id: Some(PAGE_BINDING_HIDDEN), selector: "HiddenSelectorSecret")] }
        else { [pageBinding("fixture.run", "resolved", id: Some(PAGE_BINDING_RUN)),
            pageBinding("fixture.Box", "resolved", id: Some(PAGE_BINDING_BOX)),
            pageBinding("fixture.Box.member", "resolved", id: Some(PAGE_BINDING_MEMBER)),
            pageBinding("MissingTarget", "unresolved"), pageBinding("UncertainTarget", "ambiguous"),
            pageBinding("HiddenBindingSecret", "unavailable", selector: "HiddenSelectorSecret"),
            pageBinding("ConflictingTarget", "conflict")] }
    let tree = MarkdownNode("document", children: [MarkdownNode("paragraph", children: [MarkdownNode("text", literal: "Guide body")])])
    let english = DocumentationPage("guide", "docs/en/start.md", "concepts/guides/deep/start.html", "Guide", "guide", "Guide body", tree,
        language: Some("en"), defaultLanguage: Some("zh-CN"), bindings: bindings, targetSymbolIds: targets)
    let chinese = DocumentationPage("guide", "docs/zh/start.md", "concepts/zh.html", "Guide", "guide", "Guide body", tree,
        language: Some("zh-CN"), defaultLanguage: Some("zh-CN"), bindings: bindings, targetSymbolIds: targets)
    let empty = DocumentationPage("empty", "docs/empty.md", "concepts/empty.html", "Empty", "guide", "Guide body", tree)
    let original = DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("page-binding"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"), providers: [ProviderInfo("ast", "builtin",
            PAGE_BINDING_MODULE, "partial", SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(PAGE_BINDING_MODULE, "page-binding", "root", "", packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", PAGE_BINDING_MODULE, sourceFiles: ["src/api.cj"], symbolIds: [PAGE_BINDING_RUN, PAGE_BINDING_BOX, PAGE_BINDING_MEMBER, PAGE_BINDING_HIDDEN])],
        files: [FileDoc("src/api.cj", PAGE_BINDING_MODULE, "fixture")], declarations: [run, box, member, hidden],
        languageOptions: Some(DocumentationLanguageOptions("zh-CN", languages: ["en", "zh-CN"])),
        pages: if (fallbackOnly) { [chinese, empty] } else { [english, chinese, empty] })
    decodeDocIr(encodeDocIr(original))
}

private func pageBindingContent(values: Array<RenderArtifact>, path: String): String {
    for (value in values where value.path == path) { return value.content }
    throw IllegalArgumentException("missing page binding artifact")
}

private func verifyPageBindingTarget(values: Array<RenderArtifact>, root: String, guide: String,
    prefix: String, symbol: SymbolDoc): Unit {
    let anchor = symbolAnchor(symbol)
    var destination = ""
    for (value in values where value.path.startsWith(root) && value.content.contains("<a id=\"" + anchor + "\"></a>")) {
        @Expect(destination.isEmpty())
        destination = value.path.removePrefix(root)
    }
    @Expect(!destination.isEmpty())
    @Expect(guide.contains("](" + prefix + destination + "#" + anchor + ")"))
}

@Test
class DocumentationPageBindingsTest {
    @TestCase
    func sourceFreeMarkdownKeepsAllAssociationStatesAndRealApiTargets(): Unit {
        let documentation = pageBindingDocumentation()
        let encoded = encodeDocIr(documentation)
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")
        let guide = pageBindingContent(values, "markdown/concepts/guides/deep/start.md")
        for (state in ["Linked", "Target not found", "Ambiguous target", "Not available in this audience", "Conflicting markers"]) { @Expect(guide.contains(state)) }
        for (index in 0..3) { verifyPageBindingTarget(values, "markdown/", guide, "../../../", documentation.declarations[index]) }
        @Expect(!guide.contains("HiddenBindingSecret"))
        @Expect(!guide.contains("HiddenSelectorSecret"))
        @Expect(!pageBindingContent(values, "markdown/concepts/empty.md").contains("API associations"))
        @Expect(encodeDocIr(documentation), encoded)
    }

    @TestCase
    func allLanguagesAndDefaultFallbackKeepLinksInsideActualReadingRoots(): Unit {
        let documentation = pageBindingDocumentation()
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], allLanguages: true)
        for ((language, route, prefix, state) in [("en", "concepts/guides/deep/start.md", "../../../", "Linked"),
            ("zh-CN", "concepts/zh.md", "../", "已关联")]) {
            let root = "markdown/" + language + "/"
            let guide = pageBindingContent(values, root + route)
            @Expect(guide.contains(state))
            for (index in 0..3) { verifyPageBindingTarget(values, root, guide, prefix, documentation.declarations[index]) }
        }
        let fallback = pageBindingDocumentation(fallbackOnly: true)
        let selected = renderDocumentationFormatsWithOptions(fallback, ["markdown"], locale: "en")
        let guide = pageBindingContent(selected, "markdown/concepts/zh.md")
        @Expect(guide.contains("Linked"))
        @Expect(guide.contains("Content language: zh-CN"))
        verifyPageBindingTarget(selected, "markdown/", guide, "../", fallback.declarations[0])
    }

    @TestCase
    func invisibleImportedTargetsStayHiddenThroughEveryMarkdownEntrypoint(): Unit {
        let documentation = pageBindingDocumentation(hiddenOnly: true)
        let encoded = encodeDocIr(documentation)
        let values = renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: "en")
        let guide = pageBindingContent(values, "markdown/concepts/guides/deep/start.md")
        @Expect(guide.contains("Not available in this audience"))
        @Expect(!guide.contains("HiddenBindingSecret"))
        @Expect(!guide.contains("HiddenSelectorSecret"))
        @Expect(!guide.contains("fixture.hidden"))
        let direct = MarkdownDocumentationRenderer().render(documentation)
        let directGuide = pageBindingContent(direct, "markdown/concepts/guides/deep/start.md")
        @Expect(directGuide.contains("Not available in this audience"))
        @Expect(!directGuide.contains("HiddenBindingSecret"))
        @Expect(!directGuide.contains("HiddenSelectorSecret"))
        @Expect(!directGuide.contains("fixture.hidden"))
        @Expect(encodeDocIr(documentation), encoded)
    }
}
