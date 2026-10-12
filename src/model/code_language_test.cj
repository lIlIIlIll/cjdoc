package cjdoc.model

import std.unittest.*
import std.unittest.testmacro.*

@Test
class CodeLanguageTest {
    @TestCase
    func aliasesAreExplicitAndLocaleIndependent(): Unit {
        @Expect(normalizeCodeLanguage("CJ"), "cangjie")
        @Expect(normalizeCodeLanguage(" Cangjie\t"), "cangjie")
        @Expect(normalizeCodeLanguage("PY"), "python")
        @Expect(normalizeCodeLanguage("yml"), "yaml")
        for (language in ["bash", "sh", "zsh", "fish", "powershell", "toml", "json"]) {
            @Expect(normalizeCodeLanguage(language), language)
        }
        @Expect(normalizeCodeLanguage("zh-CN"), "zh-cn")
        @Expect(normalizeCodeLanguage("仓颉"), "仓颉")
    }

    @TestCase
    func plaintextIsExplicitAndInfoStringsAreNotParsed(): Unit {
        for (language in ["", "text", "PLAINTEXT", "plain", "output", "console",
            "nohighlight", "no-highlight"]) {
            @Expect(normalizeCodeLanguage(language), "")
        }
        @Expect(normalizeCodeLanguage("cangjie {run}"), "cangjie {run}")
        @Expect(normalizeCodeLanguage("cj\" onclick=\"bad"), "cj\" onclick=\"bad")
    }
}
