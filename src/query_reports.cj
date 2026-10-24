package cjdoc

import cjdoc.model as query_model
import cjdoc.render as query_render
import std.collection.*
import yjson.*

// Attachments are recorded evidence, not instructions. Loading or querying a
// report never invokes its compiler, runner, diff command or claimed executable.
internal func loadDocumentationQueryReports(manifest: JsonObject,
    snapshot: query_render.DocumentationReadSnapshot, contents: HashMap<String, String>): JsonArray {
    let result = JsonNode.array()
    let kinds = HashSet<String>()
    let rows = manifest.get("reports").getOrThrow().asArray()
    for (index in 0..rows.size()) {
        let row = rows[index].asObject()
        let kind = queryString(row, "kind")
        if (!kinds.add(kind)) {
            throw DocumentationQueryException("unavailable", "duplicate_report_kind",
                "A frozen snapshot may attach at most one report of each kind.")
        }
        let entry = JsonNode.object()
        entry.put("kind", JsonNode.string(kind))
        entry.put("path", row.get("path").getOrThrow())
        entry.put("sha256", row.get("sha256").getOrThrow())
        entry.put("declaredSnapshotId", row.get("snapshotId").getOrThrow())
        entry.put("baselineSnapshotId", row.get("baselineSnapshotId").getOrThrow())
        entry.put("currentSnapshotId", row.get("currentSnapshotId").getOrThrow())
        var report: ?JsonObject = None
        if (let Some(text) <- contents.get(queryString(row, "path"))) {
            if (query_model.contractFingerprint(text) == queryString(row, "sha256")) {
                try { report = Some(querySnapshotJson(text)) } catch (_: Exception) { }
            }
        }
        entry.put("report", match (report) {
            case Some(value) => value
            case None => JsonNode.nullValue
        })
        entry.put("state", JsonNode.string(if (report.isNone()) { "invalid" }
            else if (queryString(row, "snapshotId") != snapshot.snapshotId) { "binding_mismatch" }
            else { "binding_unavailable" }))
        entry.put("binding", JsonNode.object())
        result.add(entry)
    }
    result
}

private func queryReportInputs(report: JsonObject): JsonObject {
    match (report.get("inputs")) {
        case Some(value) => if (value.kind() == JsonKind.Object) { value.asObject() } else { JsonNode.object() }
        case None => JsonNode.object()
    }
}

private func queryReportSnapshot(inputs: ArrayList<QuerySnapshotInput>, id: String): ?QuerySnapshotInput {
    if (id.isEmpty()) { return None }
    for (input in inputs where input.snapshot.snapshotId == id) { return Some(input) }
    None
}

private func queryReportEnvironment(report: JsonObject): (String, JsonNode) {
    match (report.get("environment")) {
        case Some(value) =>
            if (value.kind() != JsonKind.Object) { return ("unavailable", JsonNode.nullValue) }
            let environment = value.asObject()
            // Recorded compiler identity is preserved, never authenticated by
            // probing an installed SDK or by trusting a path in the report.
            let recorded = !queryString(environment, "compilerVersion").isEmpty() &&
                isSha256(queryString(environment, "compilerSha256")) &&
                !queryString(environment, "target").isEmpty() &&
                !queryString(environment, "cfgProfile").isEmpty()
            (if (recorded) { "recorded" } else { "incomplete" }, value)
        case None => ("unavailable", JsonNode.nullValue)
    }
}

private func queryBindValidationReport(input: QuerySnapshotInput, report: JsonObject,
    binding: JsonObject): String {
    let recorded = queryReportInputs(report)
    let identity = queryString(recorded, "snapshotId")
    let digest = queryString(recorded, "docIrSha256")
    binding.put("inputs", recorded)
    let (environmentState, environment) = queryReportEnvironment(report)
    binding.put("environmentState", JsonNode.string(environmentState))
    binding.put("environment", environment)
    if ((!identity.isEmpty() && identity != input.snapshot.snapshotId) ||
        (!digest.isEmpty() && digest != query_model.contractFingerprint(input.snapshot.encodedDocumentation))) {
        return "binding_mismatch"
    }
    if (environment.kind() == JsonKind.Object) {
        let profile = queryString(environment.asObject(), "cfgProfile")
        if (!profile.isEmpty() && profile != input.documentation.configuration.cfgProfile) {
            return "binding_mismatch"
        }
    }
    if (identity.isEmpty() || digest.isEmpty() || environmentState != "recorded") {
        return "binding_unavailable"
    }
    "attached"
}

private func queryBindApiDiffReport(input: QuerySnapshotInput, report: JsonObject,
    entry: JsonObject, inputs: ArrayList<QuerySnapshotInput>, binding: JsonObject): String {
    let recorded = queryReportInputs(report)
    let baselineId = queryString(recorded, "baselineSnapshotId")
    let currentId = queryString(recorded, "currentSnapshotId")
    binding.put("inputs", recorded)
    binding.put("environmentState", JsonNode.string("not_applicable"))
    binding.put("environment", JsonNode.nullValue)
    // Published api-diff/2 reports lack input fingerprints. Preserve their
    // original baseline/current records and do not infer identities from labels.
    for (name in ["baseline", "current"]) {
        if (let Some(value) <- report.get(name)) { binding.put(name, value) }
    }
    if ((!currentId.isEmpty() && currentId != input.snapshot.snapshotId) ||
        (!queryString(entry, "currentSnapshotId").isEmpty() &&
            queryString(entry, "currentSnapshotId") != input.snapshot.snapshotId) ||
        (!baselineId.isEmpty() && !queryString(entry, "baselineSnapshotId").isEmpty() &&
            baselineId != queryString(entry, "baselineSnapshotId"))) {
        return "binding_mismatch"
    }
    if (currentId.isEmpty() || baselineId.isEmpty()) { return "binding_unavailable" }
    let baseline = queryReportSnapshot(inputs, baselineId)
    if (baseline.isNone()) { return "binding_unavailable" }
    let baselineHash = queryString(recorded, "baselineDocIrSha256")
    let currentHash = queryString(recorded, "currentDocIrSha256")
    if (baselineHash.isEmpty() || currentHash.isEmpty()) { return "binding_unavailable" }
    if (baselineHash != query_model.contractFingerprint(baseline.getOrThrow().snapshot.encodedDocumentation) ||
        currentHash != query_model.contractFingerprint(input.snapshot.encodedDocumentation)) {
        return "binding_mismatch"
    }
    "attached"
}

internal func bindDocumentationQueryReports(inputs: ArrayList<QuerySnapshotInput>): Unit {
    for (input in inputs) {
        for (index in 0..input.attachments.size()) {
            let entry = input.attachments[index].asObject()
            let binding = JsonNode.object()
            binding.put("snapshotId", JsonNode.string(input.snapshot.snapshotId))
            binding.put("declaredSnapshotId", entry.get("declaredSnapshotId").getOrThrow())
            binding.put("trust", JsonNode.string("recorded_report_not_independent_execution_proof"))
            var state = queryString(entry, "state")
            if (state != "invalid" && state != "binding_mismatch") {
                let report = entry.get("report").getOrThrow().asObject()
                state = if (queryString(entry, "kind") == "validation") {
                    queryBindValidationReport(input, report, binding)
                } else { queryBindApiDiffReport(input, report, entry, inputs, binding) }
            }
            binding.put("state", JsonNode.string(state))
            entry.put("state", JsonNode.string(state))
            entry.put("binding", binding)
        }
    }
}
