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
        let (missingHref, missing) = versionTargetRoute(current, "symbols/two.html", old)
        @Expect(missingHref, "symbols/old-owner.html")
        @Expect(missing, true)
        let (presentHref, presentMissing) = versionTargetRoute(current, "symbols/one.html", old)
        @Expect(presentHref, "symbols/old-one.html")
        @Expect(presentMissing, false)
        let absent = VersionSite(VersionComposeSpec("absent", "unused"), VersionSymbolIndex())
        let (absentHref, absentMissing) = versionTargetRoute(current, "symbols/two.html", absent)
        @Expect(absentHref, "index.html")
        @Expect(absentMissing, true)
        let selector = versionSelector(current, "new/symbols/owner.html", "symbols/owner.html",
            ArrayList<VersionSite>([current, old]), chinese: true)
        @Expect(selector.contains("data-cjdoc-version-routes="))
        @Expect(selector.contains(versionSymbolAnchor("overload-one")))
        @Expect(selector.contains(versionSymbolAnchor("overload-two")))
        @Expect(selector.contains("../../old/symbols/old-one.html"))
        @Expect(selector.contains("此版本没有该符号"))
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
}
