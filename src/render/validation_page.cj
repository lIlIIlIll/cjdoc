package cjdoc.render

import cjdoc.model.*

// This page reports captured diagnostics only. Absence of an attached example or
// API-diff report is not evidence of a successful check or compatibility.
internal func renderValidationHtml(documentation: DocumentationSet,
    docVersion: ?String, locale: String): String {
    let version = docVersion.getOrDefault({ => label(locale, "not provided", "未提供") })
    let body = TrustedHtml.capture { w =>
        w.open("div", attrs: [htmlClass("cj-validation")])
        w.open("p", attrs: [htmlClass("cj-validation__context")])
        w.text(label(locale, "Documentation version", "文档版本") + ": " + version + " · ")
        w.text(label(locale, "Diagnostics", "诊断") + ": " +
            documentation.diagnostics.size.toString() + " · ")
        w.text(label(locale, "API diff: not attached to this generation",
            "API diff：本次生成未附带"))
        w.close("p")
        w.open("section")
        w.textElement("h2", label(locale, "API diff evidence", "API diff 证据"))
        w.textElement("p", label(locale,
            "No comparison report was attached to this generation. Run the explicit cjdoc diff command to inspect version-to-version changes; this page does not infer compatibility.",
            "本次生成未附带比较报告。请显式运行 cjdoc diff 命令检查版本间变化；本页面不会推断兼容性。"))
        w.close("section")
        w.close("div")
    }
    renderUtilityHtmlPage(documentation, label(locale, "Validation results", "验证结果"),
        body, "", locale: locale, docVersion: docVersion, agentReadable: true)
}
