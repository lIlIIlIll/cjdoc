package cjdoc

import cjdoc.filesystem.readTextBounded
import cjdoc.model.*
import cjdoc.quality.api_diff.{apiDiffOptionText, appendDeclarationDiffEntries, appendExposureDiffEntries}
import cjdoc.render.*
import std.collection.*
import std.fs.*
import std.sort.*

private let API_DIFF_INPUT_LIMIT: Int64 = 64 * 1024 * 1024

private func validateIdentity(baseline: ApiContractSnapshot, current: ApiContractSnapshot): Unit {
    if (baseline.project != current.project || baseline.audience != current.audience ||
        baseline.cfgProfile != current.cfgProfile) {
        throw IllegalArgumentException("API diff inputs must match project, audience, and cfgProfile")
    }
}

public func compareApiContracts(baseline: ApiContractSnapshot, current: ApiContractSnapshot): ApiDiffReport {
    validateIdentity(baseline, current)
    let entries = ArrayList<ApiDiffEntry>()
    appendDeclarationDiffEntries(baseline, current, entries)
    appendExposureDiffEntries(baseline, current, entries)
    sort(entries, lessThan: { left, right =>
        let leftKey = "${apiDiffOptionText(left.oldId, "")}\n${apiDiffOptionText(left.newId, "")}\n${left.kind}"
        let rightKey = "${apiDiffOptionText(right.oldId, "")}\n${apiDiffOptionText(right.newId, "")}\n${right.kind}"
        leftKey < rightKey

    }, stable: true)
    var breaking: Int64 = 0
    var potentiallyBreaking: Int64 = 0
    var additive: Int64 = 0
    var documentationOnly: Int64 = 0
    var metadataOnly: Int64 = 0
    var unchanged: Int64 = 0
    for (entry in entries) {
        match (entry.classification) {
            case "breaking" => breaking++
            case "potentially-breaking" => potentiallyBreaking++
            case "additive" => additive++
            case "documentation-only" => documentationOnly++
            case "metadata-only" => metadataOnly++
            case _ => unchanged++
        }
    }
    let state = if (baseline.collectionState == "resolved" && current.collectionState == "resolved") {
        "resolved"
    } else { "partial" }
    ApiDiffReport(baseline, current, comparisonState: state,
        summary: ApiDiffSummary(breaking: breaking, potentiallyBreaking: potentiallyBreaking,
            additive: additive, documentationOnly: documentationOnly, metadataOnly: metadataOnly,
            unchanged: unchanged), entries: entries.toArray())
}

public func readApiContractSnapshot(path: String): ApiContractSnapshot {
    let text = readTextBounded(Path(path), API_DIFF_INPUT_LIMIT)
    decodeApiContractSnapshot(text)
}

public func renderApiDiffText(report: ApiDiffReport): String {
    let out = StringBuilder()
    out.append("API diff ${report.baseline.project} (${report.baseline.audience})\n")
    out.append("comparison: ${report.comparisonState}; breaking=${report.summary.breaking}, " +
        "potentially-breaking=${report.summary.potentiallyBreaking}, additive=${report.summary.additive}, " +
        "documentation-only=${report.summary.documentationOnly}, metadata-only=${report.summary.metadataOnly}\n")
    for (entry in report.entries where entry.classification != "unchanged") {
        let id = match (entry.newId) { case Some(value) => value case None => apiDiffOptionText(entry.oldId, "<unknown>") }
        out.append("${entry.classification}: ${entry.kind} ${id} (${entry.matchState})")
        for (reason in entry.reasons) { out.append("; ${reason}") }
        out.append("\n")
    }
    out.toString()
}

public func apiDiffExitCode(report: ApiDiffReport, denyBreaking: Bool,
    denyPotentiallyBreaking: Bool): Int64 {
    if ((denyBreaking && report.summary.breaking > 0) ||
        (denyPotentiallyBreaking && report.summary.potentiallyBreaking > 0)) { 1 } else { 0 }
}
