package cjdoc

import std.unittest.*
import std.unittest.testmacro.*

@Test
class LocalExternalDocPathTests {
    @TestCase
    func acceptsExplicitDocsetRoot(): Unit {
        @Expect(safeLocalExternalBaseUrl("./dependencies/support-v1"))
        @Expect(safeLocalExternalHref("./dependencies/support-v1", "symbols/Token.html"),
            Some("./dependencies/support-v1/symbols/Token.html"))
    }

    @TestCase
    func rejectsAlternativeNamespacesAndTraversal(): Unit {
        for (value in ["", ".", "..", "../support", "/support", "//host/support",
            "https://host/support", "file:///support", "./../support", "./a/../support",
            "./a//b", "./a/./b", "./a/%2e%2e", "./a\\b", "./a?b", "./a#b", "./a b"]) {
            @Expect(!safeLocalExternalBaseUrl(value))
        }
    }

    @TestCase
    func localIndexCannotOverrideBaseOrInjectAnchor(): Unit {
        for (value in ["", "../Token.html", "/Token.html", "//host/Token.html",
            "https://host/Token.html", "javascript:alert(1)", "symbols/%2e%2e/Token.html",
            "symbols/Token.html?query", "symbols/Token.html#member-1", "symbols/Token.html#",
            "symbols/Token.html#a#b", "symbols/Token.html#a/b", "symbols/Token.html#a%2fb",
            "symbols/Token.html#<b>", "symbols/Token.html\n"]) {
            @Expect(safeLocalExternalHref("./dependencies/support-v1", value).isNone())
        }
    }
}
