package cjdoc.quality

import cjdoc.model.*
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
    let findings = ArrayList<Diagnostic>()
    match (symbol.documentation) {
        case Some(comment) =>
            if (repeats(summaryText(comment), symbol.name,
                ["API", "公开 API", "${projectName} 公开 API", "${projectName} API"])) {
                findings.add(Diagnostic("warning", "CJDOC3040",
                    "trivial-summary: description repeats declaration '${symbol.name}'",
                    source: Some(symbol.source), symbolId: Some(symbol.id)))
            }
            for (tag in comment.tags) {
                if (tag.name != "return") { continue }
                if (let Some(returnType) <- symbol.returnType) {
                    if (repeats(tag.description, returnType.spelling, ["返回", "return", "returns"])) {
                        findings.add(Diagnostic("warning", "CJDOC3042",
                            "trivial-return-description: description repeats the return type",
                            source: Some(symbol.source), symbolId: Some(symbol.id)))
                    }
                }
            }
        case None => ()
    }
    for (parameter in symbol.parameters where !parameter.name.startsWith("_")) {
        if (trivialParameterDocumentation(parameter)) {
            findings.add(Diagnostic("warning", "CJDOC3041",
                "trivial-param-description: description repeats parameter '${parameter.name}'",
                source: Some(symbol.source), symbolId: Some(symbol.id)))
        }
    }
    findings.toArray()
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
