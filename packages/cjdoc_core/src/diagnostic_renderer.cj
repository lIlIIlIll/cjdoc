package cjdoc_core

private func appendDiagnosticSourceJson(builder: StringBuilder, source: ?SourceLocation): Unit {
    match (source) {
        case None => builder.append("null")
        case Some(value) =>
            builder.append("{\"path\":")
            builder.append(jsonEscape(value.path))
            builder.append(",\"startLine\":${value.startLine},\"startColumn\":${value.startColumn}")
            builder.append(",\"endLine\":${value.endLine},\"endColumn\":${value.endColumn}}")
    }
}

public func renderDiagnosticsJson(documentation: DocumentationSet): String {
    let builder = StringBuilder()
    builder.append("{\"schemaVersion\":\"cjdoc.diagnostics/1\",\"diagnostics\":[")
    var index: Int64 = 0
    while (index < documentation.diagnostics.size) {
        if (index > 0) { builder.append(",") }
        let diagnostic = documentation.diagnostics[index]
        builder.append("{\"severity\":")
        builder.append(jsonEscape(diagnostic.severity))
        builder.append(",\"code\":")
        builder.append(jsonEscape(diagnostic.code))
        builder.append(",\"message\":")
        builder.append(jsonEscape(diagnostic.message))
        builder.append(",\"source\":")
        appendDiagnosticSourceJson(builder, diagnostic.source)
        builder.append(",\"symbolId\":")
        match (diagnostic.symbolId) {
            case Some(value) => builder.append(jsonEscape(value))
            case None => builder.append("null")
        }
        builder.append("}")
        index++
    }
    builder.append("]}\n")
    builder.toString()
}

private func sarifLevel(severity: String): String {
    if (severity == "error") { "error" } else if (severity == "warning") { "warning" } else { "note" }
}

public func renderDiagnosticsSarif(documentation: DocumentationSet): String {
    let builder = StringBuilder()
    builder.append("{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",")
    builder.append("\"runs\":[{\"tool\":{\"driver\":{\"name\":\"cjdoc\",\"version\":\"0.3.0\"}},\"results\":[")
    var index: Int64 = 0
    while (index < documentation.diagnostics.size) {
        if (index > 0) { builder.append(",") }
        let diagnostic = documentation.diagnostics[index]
        builder.append("{\"ruleId\":")
        builder.append(jsonEscape(diagnostic.code))
        builder.append(",\"level\":")
        builder.append(jsonEscape(sarifLevel(diagnostic.severity)))
        builder.append(",\"message\":{\"text\":")
        builder.append(jsonEscape(diagnostic.message))
        builder.append("}")
        if (let Some(source) <- diagnostic.source) {
            builder.append(",\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":")
            builder.append(jsonEscape(source.path))
            builder.append("},\"region\":{\"startLine\":${source.startLine},\"startColumn\":${source.startColumn},")
            builder.append("\"endLine\":${source.endLine},\"endColumn\":${source.endColumn}}}}]")
        }
        builder.append("}")
        index++
    }
    builder.append("]}]}\n")
    builder.toString()
}
