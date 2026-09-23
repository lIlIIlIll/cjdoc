package cjdoc.render

import cjdoc.model.*
import cjdoc.quality.*

internal func appendDocumentationQualityArtifact(artifacts: RenderArtifactCollector,
    documentation: DocumentationSet): Unit {
    let projection = RenderProjection(documentation)
    var meaningfulSymbols: Int64 = 0
    var parameters: Int64 = 0
    var meaningfulParameters: Int64 = 0
    let findings = RenderTextBuffer()
    var first = true
    for (symbol in projection.visibleSymbols) {
        var trivialSummary = false
        for (finding in documentationQualityDiagnostics(symbol, documentation.project.name)) {
            if (finding.code == "CJDOC3040") { trivialSummary = true }
            if (!first) { findings.append(",") }; first = false
            findings.append("{\"symbolId\": "); appendSearchJsonString(findings, symbol.id)
            findings.append(", \"code\": "); appendSearchJsonString(findings, finding.code)
            findings.append(", \"message\": "); appendSearchJsonString(findings, finding.message)
            findings.append("}")
        }
        if (hasDocumentationSummary(symbol) && !trivialSummary) { meaningfulSymbols++ }
        for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
            parameters++
            if (let Some(value) <- parameter.documentation) {
                if (!value.trimAscii().isEmpty() && !trivialParameterDocumentation(parameter)) {
                    meaningfulParameters++
                }
            }
        }
    }
    let out = RenderTextBuffer()
    out.append("{\n  \"schemaVersion\": \"cjdoc.documentation-quality/1\",\n")
    out.append("  \"audience\": "); appendSearchJsonString(out, documentation.configuration.audience)
    out.append(",\n  \"assessment\": \"conservative-placeholder-heuristic\",\n")
    out.append("  \"symbols\": {\"total\": ${projection.visibleSymbols.size}, \"meaningful\": ${meaningfulSymbols}, \"percent\": ${coveragePercent(meaningfulSymbols, projection.visibleSymbols.size)}},\n")
    out.append("  \"parameters\": {\"total\": ${parameters}, \"meaningful\": ${meaningfulParameters}, \"percent\": ${coveragePercent(meaningfulParameters, parameters)}},\n")
    out.append("  \"findings\": [${findings.toString()}]\n}\n")
    artifacts.addText("coverage/quality.json", "application/json", out.toString())
}
