protected package cjdoc.render.html

import cjdoc.render.foundation.{isReportAttachmentKind, reportAttachmentPath}
import cjdoc.render.routes.label

// A report attachment slot. `agent/reports/<kind>.json` is the single identity of
// an attachment, so the manifest row and this page cannot name different files.
// The element is a stable contract: version composition rewrites the same slot
// after attaching a report to an already-rendered page.
private func reportEvidenceState(locale: String, kind: String, attached: Bool): String {
    if (kind == "validation") {
        if (attached) {
            return label(locale, "Validation report: attached (recorded evidence, not a passing check)",
                "验证报告：已附带（仅为记录证据，不代表检查通过）")
        }
        return label(locale, "Validation report: not attached to this generation",
            "验证报告：本次生成未附带")
    }
    if (kind == "api-diff") {
        if (attached) {
            return label(locale, "API diff: attached comparison report (not a compatibility verdict)",
                "API diff：已附带比较报告（不代表兼容性结论）")
        }
        return label(locale, "API diff: not attached to this generation", "API diff：本次生成未附带")
    }
    if (attached) { kind + ": attached" } else { kind + ": not attached" }
}

internal func appendReportEvidence(w: HtmlWriter, locale: String, kind: String,
    href: ?String): Unit {
    w.open("p", attrs: [htmlClass("cj-validation__report"),
        htmlAttr("data-cjdoc-report-kind", kind),
        htmlAttr("data-cjdoc-report-state", if (href.isSome()) { "attached" } else { "absent" })])
    w.text(reportEvidenceState(locale, kind, href.isSome()))
    if (let Some(target) <- href) {
        w.text(" ")
        w.element("a", [htmlHref(SafeUrl.siteRoute(target))]) { link =>
            link.text(reportAttachmentPath(kind))
        }
    }
    w.close("p")
}

/** The exact markup of one attachment slot. Composition rewrites this contract. */
public func reportEvidenceMarkup(locale: String, kind: String, href: ?String): String {
    TrustedHtml.capture({ w => appendReportEvidence(w, locale, kind, href) }).value
}

/**
 * Replace the attachment slot of one kind with an attached slot.
 *
 * Composition attaches a report to an already-published document root whose
 * validation page may live at the root or under a language directory. Matching
 * the shared slot marker keeps the visible state and the linked file derived
 * from one definition instead of replacing one bilingual sentence pair. A page
 * without the slot is returned unchanged.
 */
public func attachReportEvidence(html: String, kind: String, href: String): String {
    if (!isReportAttachmentKind(kind)) {
        throw IllegalArgumentException("unsupported report attachment kind '${kind}'")
    }
    let prefix = "<p class=\"cj-validation__report\" data-cjdoc-report-kind=\"" + kind + "\""
    var start: Int64 = -1
    match (html.indexOf(prefix)) {
        case Some(value) => start = value
        case None => return html
    }
    var close: Int64 = -1
    match (html.indexOf("</p>", start)) {
        case Some(value) => close = value
        case None => return html
    }
    let locale = if (html.contains("<html lang=\"zh-CN\"") || html.contains("<html lang=\"zh\"")) {
        "zh-CN"
    } else {
        "en"
    }
    html[..start] + reportEvidenceMarkup(locale, kind, Some(href)) +
        html[(close + "</p>".size)..]
}
