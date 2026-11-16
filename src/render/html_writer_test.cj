package cjdoc.render

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlWriterSafetyTest {
    @TestCase
    func textAndAttributeValuesAreEscaped(): Unit {
        let writer = HtmlWriter()
        writer.open("p", attrs: [htmlClass("cj-x\" onclick=\"alert(1)"), htmlAttr("data-cjdoc-name", "<'&>")])
        writer.text("<script>alert('x')</script> & \"done\"")
        writer.close("p")
        @Expect(writer.toString(),
            "<p class=\"cj-x&quot; onclick=&quot;alert(1)\" data-cjdoc-name=\"&lt;&#39;&amp;&gt;\">" +
            "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;done&quot;</p>")
    }

    @TestCase
    func attributesKeepCallOrderAndFlagsHaveNoValue(): Unit {
        let writer = HtmlWriter()
        writer.void("input", attrs: [htmlAttr("type", "search"), htmlFlag("data-cjdoc-filter"),
            htmlAttr("aria-label", "Filter")])
        @Expect(writer.toString(), "<input type=\"search\" data-cjdoc-filter aria-label=\"Filter\">")
    }

    @TestCase
    func eventHandlerStyleAndMalformedAttributeNamesAreRejected(): Unit {
        for (name in ["onclick", "onload", "style", "srcdoc", "Class", "data_x", "", "1id", "x y"]) {
            let writer = HtmlWriter()
            @ExpectThrows[IllegalArgumentException](writer.open("div", attrs: [htmlAttr(name, "v")]))
        }
        let flagged = HtmlWriter()
        @ExpectThrows[IllegalArgumentException](flagged.void("br", attrs: [htmlFlag("onfocus")]))
    }

    @TestCase
    func urlAttributesRequireSafeUrl(): Unit {
        for (name in ["href", "src", "srcset", "action", "formaction"]) {
            let writer = HtmlWriter()
            @ExpectThrows[IllegalArgumentException](writer.open("a", attrs: [htmlAttr(name, "index.html")]))
        }
        let flagged = HtmlWriter()
        @ExpectThrows[IllegalArgumentException](flagged.open("a", attrs: [htmlFlag("href")]))
        let misplaced = HtmlWriter()
        @ExpectThrows[IllegalArgumentException](misplaced.open("a",
            attrs: [HtmlAttr.UrlValue("title", SafeUrl.siteRoute("index.html"))]))
        let writer = HtmlWriter()
        writer.textElement("a", "Home", attrs: [htmlHref(SafeUrl.siteRoute("../index.html#packages"))])
        @Expect(writer.toString(), "<a href=\"../index.html#packages\">Home</a>")
    }

    @TestCase
    func unsafeDestinationsCannotBecomeSafeUrls(): Unit {
        for (value in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "data:text/html,x", "vbscript:x",
            " https://example.test", "https://example.test/\nx"]) {
            @Expect(SafeUrl.external(value).isNone(), true)
            @Expect(SafeUrl.site(value).isNone(), true)
        }
        for (value in ["//example.test/x", "/etc/passwd", "a/../b.html", "../a/../b.html",
            "a\\b.html", "a.html#x y", "a.html#\"x", "a.html?q=<x>", "", "../", "a.html#",
            "a/..", "a/%2e%2e/b.html", "a/%2E./b.html", "a b.html"]) {
            @Expect(SafeUrl.site(value).isNone(), true)
        }
        @ExpectThrows[IllegalArgumentException](SafeUrl.siteRoute("javascript:alert(1)"))
        @ExpectThrows[IllegalArgumentException](SafeUrl.fragment("a b"))
        @ExpectThrows[IllegalArgumentException](SafeUrl.fragment(""))
    }

    @TestCase
    func generatedSiteRoutesAreAccepted(): Unit {
        for (value in ["index.html", "../../packages/package-a.html#symbol-x",
            "../index.html?tag=a%20b&moduleId=m&snapshotId=s", "assets/a.png",
            "concepts/v1..v2.html", "concepts/user%20guide.html", "./guide.html"]) {
            @Expect(SafeUrl.site(value).map({ url => url.value }), Some(value))
        }
        @Expect(SafeUrl.external("https://example.test/a?b#c").isSome(), true)
        @Expect(SafeUrl.fragment("doc-field-returns").value, "#doc-field-returns")
    }

    @TestCase
    func nestingMustBalance(): Unit {
        let mismatched = HtmlWriter()
        mismatched.open("div")
        mismatched.open("span")
        @ExpectThrows[IllegalStateException](mismatched.close("div"))
        let unclosed = HtmlWriter()
        unclosed.open("section")
        @ExpectThrows[IllegalStateException](unclosed.toString())
        let stray = HtmlWriter()
        @ExpectThrows[IllegalStateException](stray.close("p"))
        let voidOpen = HtmlWriter()
        @ExpectThrows[IllegalArgumentException](voidOpen.open("input"))
        let nonVoid = HtmlWriter()
        @ExpectThrows[IllegalArgumentException](nonVoid.void("div"))
    }

    @TestCase
    func dangerousElementsAndScriptBodiesAreRejected(): Unit {
        for (tag in ["style", "iframe", "object", "embed", "base", "form", "Div", "x-y", ""]) {
            let writer = HtmlWriter()
            @ExpectThrows[IllegalArgumentException](writer.open(tag))
        }
        let script = HtmlWriter()
        script.open("script", attrs: [htmlSrc(SafeUrl.siteRoute("search.js"))])
        @ExpectThrows[IllegalStateException](script.text("alert(1)"))
        @ExpectThrows[IllegalStateException](script.trusted(TrustedHtml.capture({ w => w.text("x") })))
        @ExpectThrows[IllegalStateException](script.open("span"))
        script.close("script")
        @Expect(script.toString(), "<script src=\"search.js\"></script>")
    }

    @TestCase
    func trustedFragmentsAreBalancedWriterOutput(): Unit {
        let fragment = TrustedHtml.capture({ w =>
            w.textElement("code", "a<b")
        })
        @Expect(fragment.value, "<code>a&lt;b</code>")
        @ExpectThrows[IllegalStateException](TrustedHtml.capture({ w => w.open("div") }))
        let writer = HtmlWriter()
        writer.element("p", []) { inner => inner.trusted(fragment) }
        @Expect(writer.toString(), "<p><code>a&lt;b</code></p>")
    }

    @TestCase
    func writerKeepsTheRendererByteBudget(): Unit {
        let writer = HtmlWriter(limit: 11)
        writer.text("<<")
        @ExpectThrows[RenderResourceLimitException](writer.text("<"))
    }
}
