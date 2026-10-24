package cjdoc.render

import cjdoc.model.*

// This page reports captured diagnostics only. Absence of an attached example or
// API-diff report is not evidence of a successful check or compatibility.
internal func renderValidationHtml(documentation: DocumentationSet,
    docVersion: ?String, locale: String): String {
    let version = docVersion.getOrDefault({ => label(locale, "not provided", "未提供") })
    let out = StringBuilder()
    out.append("<div class=\"validation-page\"><p class=\"validation-context\">")
    out.append(label(locale, "Documentation version", "文档版本"))
    out.append(": " + escapeHtml(version) + " · ")
    out.append(label(locale, "Diagnostics", "诊断"))
    out.append(": " + documentation.diagnostics.size.toString() + " · ")
    out.append(label(locale, "API diff: not attached to this generation", "API diff：本次生成未附带"))
    out.append("</p><section><h2>")
    out.append(label(locale, "API diff evidence", "API diff 证据"))
    out.append("</h2><p>")
    out.append(label(locale,
        "No comparison report was attached to this generation. Run the explicit cjdoc diff command to inspect version-to-version changes; this page does not infer compatibility.",
        "本次生成未附带比较报告。请显式运行 cjdoc diff 命令检查版本间变化；本页面不会推断兼容性。"))
    out.append("</p></section></div>")
    renderUtilityHtmlPage(documentation, label(locale, "Validation results", "验证结果"),
        out.toString(), "", locale: locale, docVersion: docVersion, agentReadable: true)
}
