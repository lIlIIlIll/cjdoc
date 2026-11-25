protected package cjdoc.versions

import cjdoc.render.RenderArtifact
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private let COMPOSED_EVIDENCE_EN = """
<!doctype html><html lang="en"><body class="cj-page" data-cjdoc-route="utility">
<p class="cj-validation__context">Diagnostics: 0</p><section class="cj-validation__reports">
<h2>Attached report evidence</h2><p class="cj-validation__report" data-cjdoc-report-kind="validation" data-cjdoc-report-state="absent">Validation report: not attached to this generation</p><p class="cj-validation__report" data-cjdoc-report-kind="api-diff" data-cjdoc-report-state="absent">API diff: not attached to this generation</p>
</section></body></html>
"""

private let COMPOSED_EVIDENCE_ZH = """
<!doctype html><html lang="zh-CN"><body class="cj-page" data-cjdoc-route="utility">
<p class="cj-validation__context">诊断：0</p><section class="cj-validation__reports">
<h2>已附带报告证据</h2><p class="cj-validation__report" data-cjdoc-report-kind="validation" data-cjdoc-report-state="absent">验证报告：本次生成未附带</p><p class="cj-validation__report" data-cjdoc-report-kind="api-diff" data-cjdoc-report-state="absent">API diff：本次生成未附带</p>
</section></body></html>
"""

private let COMPOSED_DIFF = "{\"schemaVersion\":\"cjdoc.api-diff/2\",\"inputs\":{},\"entries\":[]}\n"

// Composition receives an already-loaded site; this fixture reproduces the
// source-edge facts it reads: the report is present and its spec names a diff.
private func composedSite(id: String, files: Array<VersionSourceFile>,
    apiDiff!: Bool = false): VersionSite {
    let spec = VersionComposeSpec(id, "unused")
    spec.basePath = id
    if (apiDiff) { spec.apiDiffSource = Some("unused/api-diff.json") }
    let site = VersionSite(spec, VersionSymbolIndex())
    for (file in files) {
        site.files.add(file)
        let _ = site.paths.add(file.path)
    }
    if (apiDiff) {
        site.files.add(VersionSourceFile("api-diff.json", "application/json",
            COMPOSED_DIFF.toArray()))
    }
    site
}

private func composedArtifact(artifacts: Array<RenderArtifact>, path: String): String {
    for (artifact in artifacts where artifact.path == path) {
        return String.fromUtf8(artifact.bytes)
    }
    throw IllegalStateException("missing composed artifact " + path)
}

private func composedSlotState(html: String, kind: String): String {
    let marker = "data-cjdoc-report-kind=\"" + kind + "\""
    let at = match (html.indexOf(marker)) {
        case Some(value) => value
        case None => throw IllegalStateException("missing composed report slot " + kind)
    }
    let tail = html[at..]
    let end = match (tail.indexOf("</p>")) {
        case Some(value) => value
        case None => throw IllegalStateException("composed report slot is unterminated")
    }
    if (tail[..end].contains("data-cjdoc-report-state=\"attached\"")) { "attached" } else { "absent" }
}

@Test
class ComposedReportEvidenceTest {
    @TestCase
    func composedAttachmentReachesEveryLanguageValidationPage(): Unit {
        let files = [
            VersionSourceFile("html/en/validation.html", "text/html; charset=utf-8",
                COMPOSED_EVIDENCE_EN.toArray()),
            VersionSourceFile("html/zh-CN/validation.html", "text/html; charset=utf-8",
                COMPOSED_EVIDENCE_ZH.toArray()),
            VersionSourceFile("validation.html", "text/html; charset=utf-8",
                COMPOSED_EVIDENCE_EN.toArray()),
            VersionSourceFile("index.html", "text/html; charset=utf-8",
                "<!doctype html><html lang=\"en\"><body data-cjdoc-route=\"home\">home</body></html>".toArray())
        ]
        let site = composedSite("1.3.0", files, apiDiff: true)
        let artifacts = composeVersionArtifacts(ArrayList<VersionSite>([site]), "1.3.0",
            "latest", VersionComposeBudget())
        for ((path, absentWording) in [
            ("1.3.0/validation.html", "API diff: not attached to this generation"),
            ("1.3.0/html/en/validation.html", "API diff: not attached to this generation"),
            ("1.3.0/html/zh-CN/validation.html", "API diff：本次生成未附带")
        ]) {
            let html = composedArtifact(artifacts, path)
            @Expect(composedSlotState(html, "api-diff"), "attached")
            // Root- and language-scoped pages both link the one composed report.
            let href = if (path == "1.3.0/validation.html") {
                "../1.3.0/api-diff.json"
            } else { "../../../1.3.0/api-diff.json" }
            @Expect(html.contains("href=\"" + href + "\""))
            @Expect(!html.contains(absentWording))
            // Attaching a diff never turns the validation slot into an attachment.
            @Expect(composedSlotState(html, "validation"), "absent")
            // The evidence page is still a real page and still gets the selector.
            @Expect(html.contains("class=\"cj-version-select\""))
        }
        // The composed report itself is published at the manifest path.
        @Expect(composedArtifact(artifacts, "1.3.0/api-diff.json"), COMPOSED_DIFF)
        @Expect(composedArtifact(artifacts, "versions.json").contains("\"apiDiff\":\"1.3.0/api-diff.json\""))
    }

    @TestCase
    func compositionWithoutADiffLeavesTheAbsenceVisible(): Unit {
        let files = [VersionSourceFile("html/en/validation.html", "text/html; charset=utf-8",
            COMPOSED_EVIDENCE_EN.toArray()),
            VersionSourceFile("index.html", "text/html; charset=utf-8",
                "<!doctype html><html lang=\"en\"><body data-cjdoc-route=\"home\">home</body></html>".toArray())]
        let site = composedSite("1.3.0", files)
        let artifacts = composeVersionArtifacts(ArrayList<VersionSite>([site]), "1.3.0",
            "latest", VersionComposeBudget())
        let html = composedArtifact(artifacts, "1.3.0/html/en/validation.html")
        @Expect(composedSlotState(html, "api-diff"), "absent")
        @Expect(!html.contains("api-diff.json"))
        @Expect(composedArtifact(artifacts, "versions.json").contains("\"apiDiff\":null"))
    }
}
