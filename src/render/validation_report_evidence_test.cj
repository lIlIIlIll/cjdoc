package cjdoc.render

import cjdoc.render.agent.DocumentationReportAttachment
import cjdoc.render.foundation.{RenderArtifact, reportAttachmentPath}
import cjdoc.render.html.{attachReportEvidence, reportEvidenceMarkup}
import cjdoc.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let REPORT_MODULE = "cjdoc:module:v1:report-evidence"
private let REPORT_SYMBOL = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Areport-evidence::issue_repro::function:value#g0()"

private func reportDocumentation(languages!: Array<String> = [],
    readingLanguage!: String = "en"): DocumentationSet {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    let value = SymbolDoc(REPORT_SYMBOL, "function", "value", "issue_repro.value", "issue_repro",
        REPORT_MODULE, "public", source, "public func value(): Int64 { 1 }",
        SemanticInfo("partial", "ast"))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("issue_repro"),
        ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", REPORT_MODULE, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(REPORT_MODULE, "issue_repro", "root", "", packageNames: ["issue_repro"])],
        packages: [PackageDoc("issue_repro", REPORT_MODULE, sourceFiles: ["src/api.cj"],
            symbolIds: [REPORT_SYMBOL])],
        files: [FileDoc("src/api.cj", REPORT_MODULE, "issue_repro")],
        declarations: [value],
        languageOptions: if (languages.isEmpty()) { None }
            else { Some(DocumentationLanguageOptions(readingLanguage, languages: languages)) },
        readingLanguage: Some(readingLanguage))
}

private let API_DIFF_REPORT = "{\"schemaVersion\":\"cjdoc.api-diff/2\"," +
    "\"baseline\":{\"project\":\"issue_repro\"},\"current\":{\"project\":\"issue_repro\"}," +
    "\"inputs\":{},\"entries\":[]}"

private let VALIDATION_REPORT = "{\"schemaVersion\":\"cjdoc.validation/1\",\"inputs\":{},\"checks\":[]}"

private func reportArtifact(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) { return artifact.content }
    throw IllegalStateException("missing artifact " + path)
}

private func manifestReportKinds(manifest: String): HashSet<String> {
    let kinds = HashSet<String>()
    let start = match (manifest.indexOf("\"reports\":[")) {
        case Some(value) => value + "\"reports\":[".size
        case None => throw IllegalStateException("manifest has no reports inventory")
    }
    let tail = manifest[start..]
    let endAt = match (tail.indexOf("]")) {
        case Some(value) => value
        case None => throw IllegalStateException("manifest reports inventory is unterminated")
    }
    var rest = tail[..endAt]
    while (let Some(position) <- rest.indexOf("\"kind\":\"")) {
        let inner = rest[(position + "\"kind\":\"".size)..]
        let end = match (inner.indexOf("\"")) {
            case Some(value) => value
            case None => break
        }
        let _ = kinds.add(inner[..end])
        rest = inner[end..]
    }
    kinds
}

/** The attachment state of one kind, read from its own slot rather than prose. */
private func slotState(page: String, kind: String): String {
    let marker = "data-cjdoc-report-kind=\"" + kind + "\""
    let at = match (page.indexOf(marker)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing report slot " + kind)
    }
    let tail = page[at..]
    let end = match (tail.indexOf("</p>")) {
        case Some(value) => value
        case None => throw IllegalStateException("report slot is unterminated")
    }
    if (tail[..end].contains("data-cjdoc-report-state=\"attached\"")) { "attached" } else { "absent" }
}

@Test
class ValidationReportEvidenceTest {
    @TestCase
    func attachedReportsAreLinkedAndAbsenceStaysExplicit(): Unit {
        let reports = [
            DocumentationReportAttachment("api-diff", API_DIFF_REPORT),
            DocumentationReportAttachment("validation", VALIDATION_REPORT)
        ]
        let artifacts = renderDocumentationFormatsWithOptions(reportDocumentation(), ["html"],
            locale: "en", reports: reports)
        let page = reportArtifact(artifacts, "html/validation.html")
        for ((kind, path) in [("api-diff", "agent/reports/api-diff.json"),
            ("validation", "agent/reports/validation.json")]) {
            @Expect(slotState(page, kind), "attached")
            @Expect(page.contains("href=\"" + path + "\""))
            @Expect(reportArtifact(artifacts, "html/" + path).size > 0)
        }
        // An attachment is recorded evidence, never a passing or compatibility claim.
        @Expect(page.contains("not a passing check or a compatibility verdict"))
        let kinds = manifestReportKinds(reportArtifact(artifacts, "html/agent/manifest.json"))
        @Expect(kinds.contains("api-diff"))
        @Expect(kinds.contains("validation"))

        let absentArtifacts = renderDocumentationFormatsWithOptions(reportDocumentation(),
            ["html"], locale: "en")
        let absent = reportArtifact(absentArtifacts, "html/validation.html")
        for ((kind, path) in [("api-diff", "agent/reports/api-diff.json"),
            ("validation", "agent/reports/validation.json")]) {
            @Expect(slotState(absent, kind), "absent")
            @Expect(!absent.contains("href=\"" + path + "\""))
        }
        @Expect(manifestReportKinds(reportArtifact(absentArtifacts,
            "html/agent/manifest.json")).isEmpty())
    }

    @TestCase
    func everyLanguageCopyOfTheEvidencePageReportsTheSameAttachments(): Unit {
        let reports = [DocumentationReportAttachment("api-diff", API_DIFF_REPORT)]
        let artifacts = renderDocumentationFormatsWithOptions(
            reportDocumentation(languages: ["en", "zh-CN"]), ["html"], allLanguages: true,
            reports: reports)
        for ((language, wording) in [("en", "not a passing check or a compatibility verdict"),
            ("zh-CN", "不代表检查通过或兼容性结论")]) {
            let page = reportArtifact(artifacts, "html/" + language + "/validation.html")
            @Expect(slotState(page, "api-diff"), "attached")
            @Expect(page.contains("href=\"" + reportAttachmentPath("api-diff") + "\""))
            @Expect(page.contains(wording))
            @Expect(manifestReportKinds(reportArtifact(artifacts,
                "html/" + language + "/agent/manifest.json")).contains("api-diff"))
        }
    }

    @TestCase
    func compositionRewritesTheSharedSlotAtTheRootAndUnderLanguageDirectories(): Unit {
        let artifacts = renderDocumentationFormatsWithOptions(
            reportDocumentation(languages: ["en", "zh-CN"]), ["html"], allLanguages: true)
        for ((language, href) in [("en", "../../api-diff.json"),
            ("zh-CN", "../../api-diff.json")]) {
            let original = reportArtifact(artifacts, "html/" + language + "/validation.html")
            @Expect(slotState(original, "api-diff"), "absent")
            let composed = attachReportEvidence(original, "api-diff", href)
            @Expect(slotState(composed, "api-diff"), "attached")
            @Expect(composed.contains("href=\"" + href + "\""))
            @Expect(!composed.contains("href=\"" + reportAttachmentPath("api-diff") + "\""))
            // The other kind and the rest of the page are untouched.
            @Expect(slotState(composed, "validation"), "absent")
            @Expect(composed.size > original.size)
        }
        // A page without the slot is returned byte for byte.
        let plain = "<html><body>no evidence page</body></html>"
        @Expect(attachReportEvidence(plain, "api-diff", "x/api-diff.json"), plain)
    }

    @TestCase
    func slotMarkupIsLocaleStableAndCarriesNoVerdict(): Unit {
        for ((locale, text) in [("en", "API diff: not attached to this generation"),
            ("zh-CN", "API diff：本次生成未附带")]) {
            let markup = reportEvidenceMarkup(locale, "api-diff", None)
            @Expect(markup.contains(text))
            let attached = reportEvidenceMarkup(locale, "api-diff",
                Some(reportAttachmentPath("api-diff")))
            @Expect(attached.contains("data-cjdoc-report-state=\"attached\""))
            @Expect(!attached.contains(text))
            @Expect(!attached.contains("compatible"))
        }
    }
}
