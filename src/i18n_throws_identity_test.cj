package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func localizedThrowsHtml(documentation: api_model.DocumentationSet, locale: String): String {
    for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["html"], locale: locale)) {
        if (artifact.path.startsWith("html/symbols/") && artifact.content.contains("<dl class=\"throws-list\"")) { return artifact.content }
    }
    throw IllegalArgumentException("missing symbol HTML artifact")
}

private func localizedThrowsCount(documentation: api_model.DocumentationSet, locale: String): Int64 {
    let selected = api_render.projectDocumentationLanguage(documentation, locale)
    var count: Int64 = 0
    for (tag in selected.declarations[0].documentation.getOrThrow().tags) {
        if (tag.name == "throws") { count++ }
    }
    count
}

@Test
class I18nThrowsIdentityTest {
    @TestCase
    func explicitThrowsIdSelectsOneLanguageAndSurvivesStrictRoundTrip(): Unit {
        let project = i18nTestProject("""
            /**
             * 中文摘要。
             * @summary[lang=en] English summary.
             * @throws[id=index-range] IllegalArgumentException `index` 越界。
             * @throws[lang=en,id=index-range] IllegalArgumentException `index` is out of range.
             */
            """)
        try {
            let generated = i18nTestGenerate(project)
            @Expect(!publicHasDiagnostic(generated, "CJDOC3107"))
            @Expect(!publicHasDiagnostic(generated, "CJDOC3114"))
            let author = generated.declarations[0].documentation.getOrThrow()
            var authored: Int64 = 0
            let expectedId = generated.declarations[0].id + ":doc:throws:author-index-range"
            for (text in author.localizedTexts where text.kind == "throws") {
                @Expect(text.state, "valid")
                @Expect(text.fieldId, expectedId)
                authored++
            }
            @Expect(authored, 2)
            let encoded = api_render.encodeDocIr(generated)
            let imported = api_render.decodeDocIr(encoded)
            @Expect(api_render.encodeDocIr(imported), encoded)
            for ((locale, wanted, other, wantedMarkdown, otherMarkdown) in [
                ("zh-CN", "越界。", "is out of range.", "越界。", "is out of range\\."),
                ("en", "is out of range.", "越界。", "is out of range\\.", "越界。")
            ]) {
                @Expect(localizedThrowsCount(imported, locale), 1)
                let html = localizedThrowsHtml(imported, locale)
                @Expect(html.split("class=\"throws-row\"").size, 2)
                @Expect(html.contains(wanted))
                @Expect(!html.contains(other))
                @Expect(!html.contains("原文：en"))
                @Expect(!html.contains("Original text: zh-CN"))
                let md = renderedContent(api_render.renderDocumentationFormatsWithOptions(imported,
                    ["markdown"], locale: locale))
                @Expect(md.contains(wantedMarkdown))
                @Expect(!md.contains(otherMarkdown))
            }
            @Expect(api_render.translationCoverageFor(imported, "zh-CN").unpaired, 0)
            @Expect(api_render.translationCoverageFor(imported, "en").unpaired, 0)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func foreignOnlyThrowsKeepsOneVisibleContractAndAccurateCoverage(): Unit {
        let project = i18nTestProject("""
            /** 中文摘要。
             * @throws[lang=en,id=index-range] IllegalArgumentException Index is out of range.
             */
            """)
        try {
            let generated = i18nTestGenerate(project)
            let imported = api_render.decodeDocIr(api_render.encodeDocIr(generated))
            @Expect(localizedThrowsCount(imported, "zh-CN"), 1)
            @Expect(localizedThrowsCount(imported, "en"), 1)
            let chinese = localizedThrowsHtml(imported, "zh-CN")
            @Expect(chinese.split("class=\"throws-row\"").size, 2)
            @Expect(chinese.contains("Index is out of range."))
            @Expect(chinese.contains("暂无当前语言翻译，原文：en"))
            let english = localizedThrowsHtml(imported, "en")
            @Expect(!english.contains("暂无当前语言翻译"))
            let projected = api_render.projectDocumentationLanguage(imported, "zh-CN")
            var observed = false
            for (tag in projected.declarations[0].documentation.getOrThrow().tags where tag.name == "throws") {
                @Expect(tag.translationState, "fallback")
                @Expect(tag.contentLanguage, Some("en"))
                observed = true
            }
            @Expect(observed)
            let coverage = api_render.translationCoverageFor(imported, "zh-CN")
            var sawFallback = false
            for (entry in coverage.entries where entry.kind == "throws") {
                @Expect(entry.state, "fallback")
                sawFallback = true
            }
            @Expect(sawFallback)
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func twoConditionsOfOneExceptionStayDistinct(): Unit {
        let project = i18nTestProject("""
            /** 中文摘要。
             * @throws[id=negative] IllegalArgumentException 负索引。
             * @throws[id=overflow] IllegalArgumentException 索引过大。
             * @throws[lang=en,id=overflow] IllegalArgumentException Index too large.
             * @throws[lang=en,id=negative] IllegalArgumentException Negative index.
             */
            """)
        try {
            let generated = i18nTestGenerate(project)
            @Expect(!publicHasDiagnostic(generated, "CJDOC3114"))
            for (locale in ["en", "zh-CN"]) {
                @Expect(localizedThrowsCount(generated, locale), 2)
                @Expect(localizedThrowsHtml(generated, locale).split("class=\"throws-row\"").size, 3)
            }
            let en = localizedThrowsHtml(generated, "en")
            @Expect(en.contains("Index too large."))
            @Expect(en.contains("Negative index."))
            @Expect(!en.contains("负索引。"))
            @Expect(!en.contains("索引过大。"))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func reusedOrConflictingIdFailsWithoutHidingAuthoredConditions(): Unit {
        for (body in [
            "@throws[id=shared] IllegalArgumentException First.\n * @throws[id=shared] IllegalArgumentException Second.",
            "@throws[id=shared] IllegalArgumentException 中文。\n * @throws[lang=en,id=shared] IllegalStateException English."
        ]) {
            let project = i18nTestProject("/** 中文摘要。\n * " + body + "\n */")
            try {
                let generated = i18nTestGenerate(project)
                @Expect(publicHasDiagnostic(generated, "CJDOC3114"))
                let comment = generated.declarations[0].documentation.getOrThrow()
                var independent: Int64 = 0
                for (text in comment.localizedTexts where text.kind == "throws") {
                    @Expect(text.state, "unpaired")
                    @Expect(text.fieldId, "")
                    independent++
                }
                @Expect(independent, 2)
                let html = localizedThrowsHtml(generated, "zh-CN")
                @Expect(html.split("class=\"throws-row\"").size, 3)
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func invalidIdsAndUnsupportedQualifiersAreRejectedAtTheTagHead(): Unit {
        for ((line, code) in [
            ("@throws[id=] IllegalArgumentException Missing.", "CJDOC3113"),
            ("@throws[id=Bad] IllegalArgumentException Uppercase.", "CJDOC3113"),
            ("@throws[lang=en,id=../bad] IllegalArgumentException Unsafe.", "CJDOC3113"),
            ("@throws[id=range,lang=en] IllegalArgumentException Wrong order.", "CJDOC3101"),
            ("@throws[lang=en,id=x,id=y] IllegalArgumentException Duplicate.", "CJDOC3101"),
            ("@param[id=range] left Not an exception.", "CJDOC3101")
        ]) {
            @Expect(localizedTagHead(line).getOrThrow().error, Some(code))
        }
        @Expect(localizedTagHead("@throws[id=valid_1] IllegalArgumentException Text.")
            .getOrThrow().entryId, Some("valid_1"))
        @Expect(localizedTagHead("@throws[lang=EN,id=valid_1] IllegalArgumentException Text.")
            .getOrThrow().language, Some("en"))
    }

    @TestCase
    func strictReplayRejectsForgedThrowsAuthorGroups(): Unit {
        // Both pairs are valid source groups until a serialized field identity
        // is altered: cross-language subject disagreement and same-language reuse.
        for ((first, second) in [
            ("@throws[id=left] IllegalArgumentException First condition.",
                "@throws[lang=en,id=right] IllegalStateException Second condition."),
            ("@throws[lang=en,id=left] IllegalArgumentException First condition.",
                "@throws[lang=en,id=right] IllegalArgumentException Second condition.")
        ]) {
            let project = i18nTestProject("/** 中文摘要。\n * " + first + "\n * " + second + "\n */")
            try {
                let encoded = api_render.encodeDocIr(i18nTestGenerate(project))
                let forged = encoded.replace(":doc:throws:author-right\"", ":doc:throws:author-left\"")
                @Assert(forged != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(forged))
            } finally { let _ = removeIfExists(project, recursive: true) }
        }
    }

    @TestCase
    func strictReplayRejectsMalformedThrowsAuthorSuffixes(): Unit {
        let project = i18nTestProject("/** 中文摘要。\n * @throws[id=left] IllegalArgumentException Left condition.\n */")
        try {
            let encoded = api_render.encodeDocIr(i18nTestGenerate(project))
            for (id in ["", "Bad", "2first", "a/b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]) {
                let forged = encoded.replace(":doc:throws:author-left\"",
                    ":doc:throws:author-" + id + "\"")
                @Assert(forged != encoded)
                @ExpectThrows[IllegalArgumentException](api_render.decodeDocIr(forged))
            }
        } finally { let _ = removeIfExists(project, recursive: true) }
    }

    @TestCase
    func legacyUnresolvedThrowsRemainsUnpairedNotSilentlyDeduplicated(): Unit {
        let project = i18nTestProject("""
            /** 中文摘要。
             * @throws IllegalArgumentException 中文条件。
             * @throws[lang=en] IllegalArgumentException English condition.
             */
            """)
        try {
            let generated = i18nTestGenerate(project)
            @Expect(publicHasDiagnostic(generated, "CJDOC3107"))
            @Expect(localizedThrowsCount(generated, "zh-CN"), 2)
            let html = localizedThrowsHtml(generated, "zh-CN")
            @Expect(html.contains("中文条件。"))
            @Expect(html.contains("English condition."))
        } finally { let _ = removeIfExists(project, recursive: true) }
    }
}
