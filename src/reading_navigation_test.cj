package cjdoc

import cjdoc.render as api_render
import std.unittest.*
import std.unittest.testmacro.*

@Test
class ReadingNavigationTest {
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
