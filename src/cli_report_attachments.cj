package cjdoc

import cjdoc.render as report_render
import std.collection.*
import std.fs.*

private func capturedCliReport(kind: String, name: String): report_render.DocumentationReportAttachment {
    let path = Path(name)
    ensureNoSymbolicLinkAncestors(path, "captured report")
    report_render.DocumentationReportAttachment(kind, readTextBounded(path, docIrLimitBytes(64)))
}

internal func capturedCliReports(options: NewCliOptions): Array<report_render.DocumentationReportAttachment> {
    let reports = ArrayList<report_render.DocumentationReportAttachment>()
    if (let Some(path) <- options.validationReport) {
        reports.add(capturedCliReport("validation", path))
    }
    if (let Some(path) <- options.apiDiffReport) {
        reports.add(capturedCliReport("api-diff", path))
    }
    reports.toArray()
}
