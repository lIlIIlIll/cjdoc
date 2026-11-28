protected package cjdoc.render.html

import cjdoc.render.foundation.RenderResourceLimitException
import cjdoc.render.routes.label
import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlWriterSafetyTest {
    @TestCase
    func compactLabelsKeepExactTextAcrossSoftWrapPoints(): Unit {
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

    @TestCase
    func writerClampsSkippedHeadingsInPagesAndSplicedFragments(): Unit {
        let w = HtmlWriter()
        w.doctype()
        w.open("html")
        w.open("body")
        w.textElement("h1", "T")
        w.textElement("h3", "Skipped")
        w.textElement("h4", "Nested")
        w.textElement("h3", "Peer")
        w.textElement("h2", "Back")
        w.textElement("h5", "Child")
        w.textElement("h6", "Deep")
        w.textElement("h6", "Deep peer")
        w.textElement("h2", "Next section")
        w.close("body")
        w.close("html")
        let page = w.toString()
        @Expect(page.contains("<h1>T</h1>"), true)
        @Expect(page.contains("<h2>Skipped</h2>"), true)
        @Expect(page.contains("<h3>Nested</h3>"), true)
        @Expect(page.contains("<h2>Peer</h2>"), true)
        @Expect(page.contains("<h2>Back</h2>"), true)
        @Expect(page.contains("<h3>Child</h3><h4>Deep</h4><h4>Deep peer</h4><h2>Next section</h2>"))

        let fragment = TrustedHtml.capture({ captured =>
            captured.textElement("h3", "Captured")
            captured.textElement("h3", "Peer")
            captured.textElement("h2", "Parent")
        })
        let spliced = HtmlWriter()
        spliced.doctype()
        spliced.open("html")
        spliced.open("body")
        spliced.textElement("h1", "T")
        spliced.trusted(fragment)
        spliced.close("body")
        spliced.close("html")
        let html = spliced.toString()
        @Expect(html.contains("<h2>Captured</h2>"), true)
        @Expect(html.contains("<h2>Peer</h2>"), true)
        @Expect(html.contains("<h2>Parent</h2>"), true)
        // A fragment writer is not a page and never rewrites by itself.
        @Expect(fragment.value.contains("<h3>Captured</h3>"), true)
    }
}
