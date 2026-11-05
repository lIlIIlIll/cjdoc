package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ReadingNavigationTest {
    @TestCase
    func missingMembersFallBackToKnownOwnerWithoutGuessingOverloads(): Unit {
        let currentIndex = VersionSymbolIndex()
        currentIndex.add("owner", "symbols/owner.html")
        currentIndex.add("overload-one", "symbols/one.html", owner: Some("owner"))
        currentIndex.add("overload-two", "symbols/two.html", owner: Some("owner"))
        let oldIndex = VersionSymbolIndex()
        oldIndex.add("owner", "symbols/old-owner.html")
        oldIndex.add("overload-one", "symbols/old-one.html", owner: Some("owner"))
        let current = VersionSite(VersionComposeSpec("new", "unused"), currentIndex)
        let old = VersionSite(VersionComposeSpec("old", "unused"), oldIndex)
        let missing = versionTargetRoute(current, "symbols/two.html", old)
        @Expect(missing.href, "symbols/old-owner.html")
        @Expect(match (missing.state) { case VersionNavigationState.MissingSymbol => true; case _ => false })
        let present = versionTargetRoute(current, "symbols/one.html", old)
        @Expect(present.href, "symbols/old-one.html")
        @Expect(match (present.state) { case VersionNavigationState.Exact => true; case _ => false })
        let absent = VersionSite(VersionComposeSpec("absent", "unused"), VersionSymbolIndex())
        let unavailable = versionTargetRoute(current, "symbols/two.html", absent)
        @Expect(unavailable.href, "index.html")
        @Expect(match (unavailable.state) { case VersionNavigationState.MissingSymbol => true; case _ => false })
        let selector = versionSelector(current, "new/symbols/owner.html", "symbols/owner.html",
            ArrayList<VersionSite>([current, old]), chinese: true)
        @Expect(selector.contains("data-cjdoc-version-routes="))
        @Expect(selector.contains("data-cjdoc-version-state=\"exact\""))
        @Expect(selector.contains("data-cjdoc-version-messages="))
        @Expect(selector.contains(versionSymbolAnchor("overload-one")))
        @Expect(selector.contains(versionSymbolAnchor("overload-two")))
        @Expect(selector.contains("../../old/symbols/old-one.html"))
        @Expect(selector.contains("此版本没有该符号"))
        @Expect(!selector.contains("data-cjdoc-version-missing"))
    }

    @TestCase
    func versionLanguageTargetsClassifyLanguageSectionPageAndInlineContextFallbacks(): Unit {
        let current = VersionSite(VersionComposeSpec("new", "unused"), VersionSymbolIndex())
        let targetIndex = VersionSymbolIndex()
        targetIndex.add("member", "symbols/old-member.html")
        let target = VersionSite(VersionComposeSpec("old", "unused"), targetIndex)
        target.defaultLanguage = "zh-CN"
        let page = VersionLogicalIdentity("en", pageId: Some("conceptual:guide"))
        let defaultPage = page.withLanguage("zh-CN")
        target.logicalRoutes[defaultPage.key()] = "html/zh-CN/concepts/guide.html"
        let languageFallback = versionLanguageTarget(current, page, target)
        @Expect(languageFallback.href, "html/zh-CN/concepts/guide.html")
        @Expect(match (languageFallback.state) { case VersionNavigationState.MissingLanguage => true; case _ => false })
        let symbol = VersionLogicalIdentity("en", symbolId: Some("member"))
        let defaultSymbol = symbol.withLanguage("zh-CN")
        target.logicalRoutes[defaultSymbol.key()] = "html/zh-CN/symbols/member.html"
        let symbolLanguageFallback = versionLanguageTarget(current, symbol, target)
        @Expect(symbolLanguageFallback.href, "html/zh-CN/symbols/member.html")
        @Expect(match (symbolLanguageFallback.state) { case VersionNavigationState.MissingLanguage => true; case _ => false })
        let _ = target.logicalRoutes.remove(defaultSymbol.key())

        let section = VersionLogicalIdentity("en", pageId: Some("conceptual:guide"),
            sectionId: Some("detail:section:id"))
        let defaultSection = section.withLanguage("zh-CN")
        target.logicalRoutes[defaultSection.key()] = "html/zh-CN/concepts/guide.html#details"
        let sectionLanguageFallback = versionLanguageTarget(current, section, target)
        @Expect(sectionLanguageFallback.href, "html/zh-CN/concepts/guide.html#details")
        @Expect(match (sectionLanguageFallback.state) { case VersionNavigationState.MissingLanguage => true; case _ => false })
        let _ = target.logicalRoutes.remove(defaultSection.key())
        let missingSection = versionLanguageTarget(current, section, target)
        @Expect(missingSection.href, "html/zh-CN/concepts/guide.html")
        @Expect(match (missingSection.state) { case VersionNavigationState.MissingSection => true; case _ => false })

        let inline = VersionLogicalIdentity("en", pageId: Some("context:owner"),
            symbolId: Some("member"))
        current.parentsByIdentity[inline.key()] = VersionLogicalIdentity("en", symbolId: Some("member"))
        target.logicalRoutes[VersionLogicalIdentity("en", symbolId: Some("member")).key()] =
            "html/en/symbols/old-member.html"
        let inlineFallback = versionLanguageTarget(current, inline, target)
        @Expect(inlineFallback.href, "html/en/symbols/old-member.html")
        @Expect(match (inlineFallback.state) { case VersionNavigationState.MissingSection => true; case _ => false })

        let missingPage = VersionLogicalIdentity("en", pageId: Some("conceptual:removed"))
        let pageFallback = versionLanguageTarget(current, missingPage, target)
        @Expect(pageFallback.href, "index.html")
        @Expect(match (pageFallback.state) { case VersionNavigationState.MissingPage => true; case _ => false })
        let ordinaryPage = versionTargetRoute(current, "validation.html", target)
        @Expect(ordinaryPage.href, "index.html")
        @Expect(match (ordinaryPage.state) { case VersionNavigationState.MissingPage => true; case _ => false })
    }

    @TestCase
    func manifestRouteIdentityPreservesOpaqueDelimiterCharacters(): Unit {
        let manifest = """
{"schemaVersion":"cjdoc.site-manifest/1","defaultLanguage":"en","routes":[
 {"language":"en","pageId":"page:section:prefix","symbolId":"symbol:section:opaque",
  "sectionId":"field:section:param","ownerSymbolId":"owner:symbol:opaque",
  "href":"html/en/opaque.html#field-anchor"}]}
"""
        let htmlPath = "html/en/opaque.html"
        let routesPath = "site-manifest.json"
        let files = ArrayList<VersionSourceFile>([
            VersionSourceFile(htmlPath, "text/html", "<a id=\"field-anchor\"></a>".toArray()),
            VersionSourceFile(routesPath, "application/json", manifest.toArray())])
        let paths = HashSet<String>()
        let _ = paths.add(htmlPath)
        let _ = paths.add(routesPath)
        let site = VersionSite(VersionComposeSpec("opaque", "unused"), VersionSymbolIndex())
        loadVersionLanguageRoutes(site, files, paths)
        let identity = VersionLogicalIdentity("en", pageId: Some("page:section:prefix"),
            symbolId: Some("symbol:section:opaque"), sectionId: Some("field:section:param"))
        @Expect(site.logicalRoutes[identity.key()], htmlPath + "#field-anchor")
        @Expect(site.logicalIdentityByHref[htmlPath + "#field-anchor"].sectionId,
            Some("field:section:param"))
        @Expect(site.logicalIdentityByHref[htmlPath + "#field-anchor"].pageId,
            Some("page:section:prefix"))
        @Expect(site.logicalIdentityByHref[htmlPath + "#field-anchor"].symbolId,
            Some("symbol:section:opaque"))
        @Expect(site.parentsByIdentity[identity.key()].symbolId, Some("owner:symbol:opaque"))
        @Expect(match (versionLanguageTarget(site, identity, site).state) {
            case VersionNavigationState.Exact => true; case _ => false
        })
        let distinct = VersionLogicalIdentity("en", pageId: Some("page"),
            symbolId: Some("section:prefix:symbol:section:opaque"),
            sectionId: Some("field:section:param"))
        @Expect(identity.key() != distinct.key(), true)
    }

    @TestCase
    func bareUrlEndsBeforeChineseProseButExplicitUnicodeUrlsRemain(): Unit {
        let bare = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "打开 http://localhost:8000。然后阅读文档。"))
        @Expect(bare.contains("href=\"http://localhost:8000\""))
        @Expect(bare.contains("</a>。然后阅读文档。"))
        let explicit = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "[原文](https://example.test/路径，原样) <https://example.test/路径，原样>"))
        @Expect(explicit.contains("href=\"https://example.test/路径，原样\""))
        @Expect(!explicit.contains("href=\"https://example.test/路径\""))
    }

    @TestCase
    func guidePreviewLinkPreservesItsAddressAndFollowingProse(): Unit {
        let html = api_render.renderStandaloneMarkdownHtml(parseStandaloneMarkdown(
            "访问 [本地预览 / Local preview](http://127.0.0.1:8080)。修改注释或指南后，serve 会重新生成。"))
        @Expect(html.contains("href=\"http://127.0.0.1:8080\""))
        @Expect(html.contains("本地预览 / Local preview</a>。修改注释或指南后，serve 会重新生成。"))
        @Expect(!html.contains("8080](http"))
    }
}
