package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

/**
 * An already captured validation or API-diff report to publish with a snapshot.
 * The original JSON bytes are retained. Publication associates a file with the
 * package; it does not authenticate the producer or promote any execution claim.
 */
public class DocumentationReportAttachment {
    public let kind: String
    public let report: String
    internal let digest: String
    internal let baselineSnapshotId: ?String
    internal let currentSnapshotId: ?String

    public init(kind: String, report: String) {
        if (kind != "validation" && kind != "api-diff") {
            throw IllegalArgumentException("report kind must be validation or api-diff")
        }
        if (report.size > RENDER_ARTIFACT_LIMIT) {
            throw RenderResourceLimitException("captured_report_exceeds_resource_limit")
        }
        let value = JsonNode.parse(report, config: JsonReadOptions(
            maxInputBytes: RENDER_ARTIFACT_LIMIT, maxStringBytes: RENDER_ARTIFACT_LIMIT,
            maxBufferedValueBytes: RENDER_ARTIFACT_LIMIT, maxDepth: 128)).asObject()
        let inputs = match (value.get("inputs")) {
            case Some(node) => if (node.kind() == JsonKind.Object) { node.asObject() } else { JsonNode.object() }
            case None => JsonNode.object()
        }
        this.kind = kind
        this.report = report
        this.digest = contractFingerprint(report)
        this.baselineSnapshotId = capturedReportIdentity(inputs, "baselineSnapshotId")
        this.currentSnapshotId = capturedReportIdentity(inputs, "currentSnapshotId")
    }
}

private func capturedReportIdentity(value: JsonObject, name: String): ?String {
    match (value.get(name)) {
        case Some(node) => if (node.kind() == JsonKind.String && !node.asString().isEmpty()) {
            Some(node.asString())
        } else { None }
        case None => None
    }
}

internal func appendCapturedReportArtifacts(artifacts: RenderArtifactCollector,
    context: DocumentationReadSnapshot, reports: Array<DocumentationReportAttachment>): String {
    let kinds = HashSet<String>()
    let out = StringBuilder()
    for (report in reports) {
        if (!kinds.add(report.kind)) { throw IllegalArgumentException("duplicate captured report kind") }
        let path = "agent/reports/" + report.kind + ".json"
        artifacts.addText("html/" + path, "application/json", report.report)
        if (kinds.size > 1) { out.append(",") }
        out.append("{\"kind\":${escapeJsonString(report.kind)},\"path\":${escapeJsonString(path)}," +
            "\"sha256\":${escapeJsonString(report.digest)},\"snapshotId\":${escapeJsonString(context.snapshotId)}," +
            "\"baselineSnapshotId\":${nullableString(report.baselineSnapshotId)}," +
            "\"currentSnapshotId\":${nullableString(report.currentSnapshotId)}}")
    }
    out.toString()
}
