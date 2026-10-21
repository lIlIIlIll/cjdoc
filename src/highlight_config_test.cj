package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func highlightConfigFromText(text: String): HighlightConfig {
    let root = Directory.createTemp(getTempDirectory())
    try {
        File.writeTo(root.join("cjdoc.toml"), text.toArray())
        loadHighlightConfig(root.toString())
    } finally {
        let _ = removeIfExists(root, recursive: true)
    }
}

@Test
class HighlightConfigTest {
    @TestCase
    func absentFileUsesBuiltinDefaults(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let config = loadHighlightConfig(root.toString())
            @Expect(config.mode, "static")
            @Expect(config.languages.toArray(), ["cangjie"])
            @Expect(config.onError, "warn")
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func parsesOwnedSectionWithCommentsAndNormalizesAliases(): Unit {
        let config = highlightConfigFromText("[other]\nmode = invalid\n" +
            "[highlight] # presentation only\nmode = \"off\" # disabled\n" +
            "languages = [\" CJ \", \"py\", \"yml\", \"custom#grammar\",]\n" +
            "on-error = \"error\"\n[docs]\nindex = \"docs/index.md\"\n")
        @Expect(config.mode, "off")
        @Expect(config.onError, "error")
        @Expect(config.languages.toArray(), ["cangjie", "python", "yaml", "custom#grammar"])
    }

    @TestCase
    func languageSelectionNormalizesCandidatesWithoutAuthorizingOthers(): Unit {
        let defaults = HighlightConfig()
        @Expect(defaults.allowsLanguage(" CJ "))
        @Expect(!defaults.allowsLanguage("python"))
        @Expect(!defaults.allowsLanguage("text"))
        let selected = HighlightConfig(languages: ["CJ", "py"])
        @Expect(selected.allowsLanguage("cangjie"))
        @Expect(selected.allowsLanguage(" PYTHON "))
        @Expect(!selected.allowsLanguage("javascript"))
    }


    @TestCase
    func rejectsInvalidModesAndErrorPoliciesWithKey(): Unit {
        for (setting in ["mode = \"automatic\"", "mode = \"\"", "mode =",
            "on-error = \"ignore\"", "on-error = \"\"", "on-error ="]) {
            let error = @AssertThrows[IllegalArgumentException](
                highlightConfigFromText("[highlight]\n" + setting))
            let key = setting.split("=", 2)[0].trimAscii()
            @Expect(error.message.contains("[highlight]." + key), true)
        }
    }

    @TestCase
    func rejectsEmptyPlainAndDuplicateLanguages(): Unit {
        for (value in ["[]", "[\"\"]", "[\"text\"]", "[\"output\"]",
            "[\"cj\", \"cangjie\"]", "[\"PY\", \"python\"]", "[\"json\", \"json\"]"]) {
            let error = @AssertThrows[IllegalArgumentException](
                highlightConfigFromText("[highlight]\nlanguages = " + value))
            @Expect(error.message.contains("[highlight].languages"), true)
        }
    }

    @TestCase
    func rejectsMalformedLanguageArraysAndSettings(): Unit {
        for (setting in ["languages = python", "languages = [python]",
            "languages = [\"python\" \"json\"]", "languages = [\"python\",,]",
            "languages = [\"unfinished]", "unknown = 1", "mode = off\nmode = static", "broken"]) {
            @ExpectThrows[IllegalArgumentException](highlightConfigFromText("[highlight]\n" + setting))
        }
    }

    @TestCase
    func unknownLanguagesAreDataAndShellFamiliesStayDistinct(): Unit {
        let config = highlightConfigFromText("[highlight]\nlanguages = [\"future-language\", \"sh\", \"bash\", \"zsh\", \"fish\", \"powershell\"]")
        @Expect(config.languages.toArray(), ["future-language", "sh", "bash", "zsh", "fish", "powershell"])
        @Expect(config.mode, "static")
    }

    @TestCase
    func rejectsOversizedConfiguration(): Unit {
        let bytes = Array<UInt8>(HIGHLIGHT_CONFIG_MAX_BYTES + 1, repeat: b' ')
        @ExpectThrows[Exception](highlightConfigFromText(String.fromUtf8(bytes)))
    }
}

@When[os != "Windows"]
private func highlightTestHostPath(): String { "/opt/cjdoc tools/adapter.mjs" }

@When[os == "Windows"]
private func highlightTestHostPath(): String { "C:\\Tools\\cjdoc tools\\adapter.mjs" }

@Test
class HighlightHostCliTest {
    @TestCase
    func hostPathsRejectEmptyRelativeAndCommandStrings(): Unit {
        for (flag in ["--highlight-adapter", "--highlight-node"]) {
            for (value in ["", " ", "node", "./adapter.mjs", "../node", "~/node"]) {
                let error = @AssertThrows[IllegalArgumentException](parseNewCli(["generate", flag, value]))
                @Expect(error.message.contains(flag), true)
            }
            for (suffix in [";echo", "|cat", "&run", "$(run)", "`run`", "<in", ">out", "\n", "\"", "'"]) {
                let error = @AssertThrows[IllegalArgumentException](
                    parseNewCli(["generate", flag, highlightTestHostPath() + suffix]))
                @Expect(error.message.contains("shell metacharacters"), true)
            }
            @ExpectThrows[IllegalArgumentException](parseNewCli(["generate", flag]))
        }
    }

    @TestCase
    func validHostPathsRequirePairedAuthorization(): Unit {
        for (flag in ["--highlight-adapter", "--highlight-node"]) {
            let error = @AssertThrows[IllegalArgumentException](
                parseNewCli(["generate", flag, highlightTestHostPath()]))
            @Expect(error.message, "--highlight-adapter and --highlight-node must be supplied together")
            let wrongCommand = @AssertThrows[IllegalArgumentException](
                parseNewCli(["render", "--input", "docs.json", flag, highlightTestHostPath()]))
            @Expect(wrongCommand.message, "highlight host options are only valid for generate and check")
        }
        @Expect(parseNewCli(["generate"]).highlightAdapter.isNone(), true)
        @Expect(parseNewCli(["generate"]).highlightNode.isNone(), true)
        @Expect(parseNewCli(["generate", "--highlight-adapter", highlightTestHostPath(),
            "--highlight-node", highlightTestHostPath()]).highlightAdapter.isSome(), true)
    }
}
