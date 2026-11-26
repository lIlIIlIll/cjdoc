protected package cjdoc.render.html

import cjdoc.render.foundation.ReportAttachmentView
import cjdoc.render.routes.label
import cjdoc.model.*
import std.collection.*

// This page reports captured diagnostics and attached reports only. An attached
// report is recorded evidence; neither its presence nor its absence is evidence
// of a successful check or of API compatibility.
protected func renderValidationHtml(documentation: DocumentationSet, projection: RenderProjection,
    docVersion: ?String, locale: String,
    reports!: Array<ReportAttachmentView> = []): String {
    let version = docVersion.getOrDefault({ => label(locale, "not provided", "未提供") })
    let attached = HashMap<String, String>()
    for (report in reports) { attached[report.kind] = report.path }
    let body = TrustedHtml.capture({ w =>
        w.open("div", attrs: [htmlClass("cj-validation")])
        w.open("p", attrs: [htmlClass("cj-validation__context")])
        w.text(label(locale, "Documentation version", "文档版本") + ": " + version + " · ")
        w.text(label(locale, "Diagnostics", "诊断") + ": " +
            documentation.diagnostics.size.toString())
        w.close("p")
        w.open("section", attrs: [htmlClass("cj-validation__reports")])
        w.textElement("h2", label(locale, "Attached report evidence", "已附带报告证据"))
        for (kind in ["validation", "api-diff"]) {
            appendReportEvidence(w, locale, kind, attached.get(kind))
        }
        w.textElement("p", label(locale,
            "Attached reports are recorded evidence, not a passing check or a compatibility verdict. Use the explicit cjdoc diff command to inspect version-to-version changes.",
            "已附带的报告是记录下来的证据，不代表检查通过或兼容性结论。请显式运行 cjdoc diff 命令检查版本间变化。"))
        w.close("section")
        w.close("div")
    })
    renderUtilityHtmlPage(documentation, projection, label(locale, "Validation results", "验证结果"),
        body, "", locale: locale, docVersion: docVersion, agentReadable: true)
}
