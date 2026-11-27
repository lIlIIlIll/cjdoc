package cjdoc.quality

import cjdoc.model.*
import cjdoc.documentation.DocumentationQualityConfig
import std.collection.*

// Deliberately conservative: punctuation and inline code do not add API meaning.
private func normalized(value: String): String {
    let out = StringBuilder()
    for (rune in value.runes()) {
        match (rune) {
            case ' ' | '\t' | '\r' | '\n' | '`' | '*' | '.' | '。' | ':' | '：' => ()
            case _ => out.append(rune)
        }
    }
    out.toString().toAsciiLower()
}

private func plainText(node: MarkdownNode, out: StringBuilder): Unit {
    if (node.children.isEmpty()) { out.append(node.literal); return }
    for (child in node.children) { plainText(child, out) }
}

private func summaryText(comment: DocComment): String {
    for (child in comment.markdown.children) {
        if (child.kind != "paragraph") { continue }
        let out = StringBuilder()
        plainText(child, out)
        return out.toString()
    }
    ""
}

private func repeats(value: String, name: String, prefixes: Array<String>): Bool {
    let text = normalized(value)
    let subject = normalized(name)
    if (text.isEmpty() || subject.isEmpty()) { return false }
    if (text == subject) { return true }
    for (prefix in prefixes) {
        if (text == normalized(prefix) + subject) { return true }
    }
    false
}

/** Conservative placeholder findings for one declaration; these rules do not assess correctness. */
public func documentationQualityDiagnostics(symbol: SymbolDoc, projectName: String): Array<Diagnostic> {
    configuredQualityDiagnostics(symbol, projectName, None<DocumentationQualityConfig>)
}

// Generation-time callers pass the project `[lint]` policy so these rules honour
// `severity`, per-rule overrides and `off` exactly like the other quality rules.
protected func configuredQualityDiagnostics(symbol: SymbolDoc, projectName: String,
    config: ?DocumentationQualityConfig): Array<Diagnostic> {
    let findings = ArrayList<Diagnostic>()
    match (symbol.documentation) {
        case Some(comment) =>
            if (repeats(summaryText(comment), symbol.name,
                ["API", "公开 API", "${projectName} 公开 API", "${projectName} API"])) {
                addFinding(findings, "trivial-summary", "CJDOC3047",
                    "trivial-summary: description repeats declaration '${symbol.name}'",
                    symbol, config)
            }
            for (tag in comment.tags) {
                if (tag.name != "return") { continue }
                if (let Some(returnType) <- symbol.returnType) {
                    if (repeats(tag.description, returnType.spelling, ["返回", "return", "returns"])) {
                        addFinding(findings, "trivial-return-description", "CJDOC3049",
                            "trivial-return-description: description repeats the return type",
                            symbol, config)
                    }
                }
            }
        case None => ()
    }
    for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
        if (trivialParameterDocumentation(parameter)) {
            addFinding(findings, "trivial-param-description", "CJDOC3048",
                "trivial-param-description: description repeats parameter '${parameter.name}'",
                symbol, config)
        }
    }
    findings.toArray()
}

// Same fallback as the other quality rules: without configuration a rule is a
// warning, and `off` suppresses it entirely. Per-rule values override `severity`.
private func addFinding(findings: ArrayList<Diagnostic>, rule: String, code: String,
    message: String, symbol: SymbolDoc, config: ?DocumentationQualityConfig): Unit {
    let severity = match (config) {
        case Some(value) => value.severity(rule)
        case None => "warning"
    }
    if (severity == "off") { return }
    findings.add(Diagnostic(severity, code, message,
        source: Some(symbol.source), symbolId: Some(symbol.id)))
}

/** True only for a recognized description that restates the parameter name. */
public func trivialParameterDocumentation(parameter: ParameterDoc): Bool {
    match (parameter.documentation) {
        case Some(value) => repeats(value, parameter.name, ["参数", "parameter", "param"])
        case None => false
    }
}

/** Whether the summary contains text beyond whitespace; independent of placeholder findings. */
public func hasDocumentationSummary(symbol: SymbolDoc): Bool {
    match (symbol.documentation) {
        case Some(comment) => !summaryText(comment).trimAscii().isEmpty()
        case None => false
    }
}
