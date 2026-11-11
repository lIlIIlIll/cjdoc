package cjdoc.render

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HtmlFontOptionsTest {
    @TestCase
    func familyListsAcceptNamesQuotedNamesAndGenericFamilies(): Unit {
        for (value in ["Inter", "\"Source Han Sans SC\", system-ui, sans-serif",
            "ui-monospace,JetBrains_Mono , monospace", "\"A B\""]) {
            @Expect(isValidHtmlFontFamilyList(value), true)
        }
    }

    @TestCase
    func familyListsRejectAnythingThatCouldLeaveTheDeclaration(): Unit {
        let tooLong = String(Array<Rune>(257, repeat: r'a'))
        for (value in ["", "x;}body{", "a/*b*/", "url(x)", "\"Inter", "Inter\"", "'Inter'", "a,,b",
            "a,", " ", "\" Inter\"", "Inter\\", "Inter\n", "\tInter", "<style>", tooLong]) {
            @Expect(isValidHtmlFontFamilyList(value), false)
        }
        @ExpectThrows[IllegalArgumentException](HtmlFontOptions(sans: Some("x;}body{")))
        @ExpectThrows[IllegalArgumentException](HtmlFontOptions(mono: Some("")))
    }

    @TestCase
    func overridesFollowTheBaseStylesheetAndReaderPreferencesStayLater(): Unit {
        let base = renderHtmlStylesheet(HtmlFontOptions())
        @Expect(base.contains("--cj-font-sans:\"Inter\""), false)
        let styled = renderHtmlStylesheet(HtmlFontOptions(sans: Some("\"Inter\", sans-serif"),
            mono: Some("Menlo")))
        @Expect(styled.startsWith(base), true)
        @Expect(styled[base.size..], ":root{--cj-font-sans:\"Inter\", sans-serif;}\n" +
            ":root{--cj-font-mono:Menlo;}\n")
        // The reader's font choice uses an attribute selector, which outranks the
        // publisher override regardless of order.
        @Expect(base.contains(":root[data-cj-font=\"serif\"] { --cj-font-sans: var(--cj-font-serif); }"),
            true)
    }
}
