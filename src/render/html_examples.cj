package cjdoc.render

import cjdoc.model.*
import std.collection.*

private let EXAMPLE_COLLAPSED_OUTPUT_LINES: Int64 = 12

internal func isExampleFence(node: MarkdownNode, language: String): Bool {
    if (node.kind != "code_block") { return false }
    match (node.metadata) {
        case Some(metadata) => metadata.codeKind == Some("fenced") && metadata.language == Some(language)
        case None => false
    }
}

private func isExampleCode(node: MarkdownNode): Bool {
    isExampleFence(node, "cangjie") && !node.literal.isEmpty()
}

private func isExampleOutputCaption(node: MarkdownNode): Bool {
    if (node.kind != "paragraph" || node.children.size != 1) { return false }
    let child = node.children[0]
    let text = if (child.kind == "text") {
        let raw = child.literal.trimAscii()
        // The raw-text DocTag fallback does not parse emphasis.
        if (raw.size >= 4 && raw.startsWith("**") && raw.endsWith("**")) {
            raw[2..raw.size - 2]
        } else { raw }
    } else if (child.kind == "strong" && child.children.size == 1 && child.children[0].kind == "text") {
        child.children[0].literal.trimAscii()
    } else { return false }
    match (text) {
        case "Expected output" | "预期输出" | "预期输出 / Expected output" => true
        case _ => false
    }
}

// Standalone prose has no @example boundary. Only pair adjacent top-level
// fences, optionally separated by the conventional output caption.
internal func appendStandaloneExampleOrNode(w: HtmlWriter, tree: MarkdownNode, start: Int64,
    assets: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext): Int64 {
    let children = tree.children
    if (!isExampleCode(children[start])) {
        appendMarkdownNodeHtml(w, children[start], assets, rootPrefix, context)
        return start + 1
    }
    var afterCode = start + 1
    while (afterCode < children.size && isExampleCode(children[afterCode])) { afterCode++ }
    var output = afterCode
    if (output < children.size && isExampleOutputCaption(children[output])) { output++ }
    if (output < children.size && isExampleFence(children[output], "output")) {
        appendExamplePair(w, children, start, output, assets, rootPrefix, context, standalone: true)
        return output + 1
    }
    // Unpaired fences retain normal Markdown rendering.
    for (index in start..afterCode) {
        appendMarkdownNodeHtml(w, children[index], assets, rootPrefix, context)
    }
    afterCode
}

internal func appendApiExampleMarkdownHtml(w: HtmlWriter, tree: MarkdownNode,
    assets: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext): Unit {
    if (tree.kind != "document") {
        appendMarkdownNodeHtml(w, tree, assets, rootPrefix, context)
        return
    }
    let children = tree.children
    var firstCode: Int64 = -1
    var output: Int64 = -1
    for (index in 0..children.size) {
        if (isExampleFence(children[index], "output")) {
            // Do not pick a result from a malformed example with multiple output fences.
            if (output >= 0) {
                appendMarkdownNodeHtml(w, tree, assets, rootPrefix, context)
                return
            }
            output = index
        } else if (firstCode < 0 && isExampleCode(children[index])) { firstCode = index }
    }
    if (firstCode < 0 || output <= firstCode) {
        appendMarkdownNodeHtml(w, tree, assets, rootPrefix, context)
        return
    }
    for (index in 0..firstCode) { appendMarkdownNodeHtml(w, children[index], assets, rootPrefix, context) }
    appendExamplePair(w, children, firstCode, output, assets, rootPrefix, context)
    for (index in output + 1..children.size) {
        appendMarkdownNodeHtml(w, children[index], assets, rootPrefix, context)
    }
}

private func exampleLayout(output: MarkdownNode): String {
    let info = output.metadata.getOrThrow().infoRaw.getOrThrow().trimAscii()
    if (!info.startsWith("output ")) { return "stacked" }
    let attributes = info[7..].trimAscii()
    match (attributes) {
        case "layout=prose" => "prose"
        case "layout=side-by-side" => "side-by-side"
        case _ => "stacked"
    }
}

internal func openExampleDisclosure(w: HtmlWriter, className: String, caption: (HtmlWriter) -> Unit): Unit {
    w.open("details", attrs: [htmlClass(className), htmlFlag("data-cjdoc-example"), htmlFlag("open")])
    w.element("summary", [htmlClass("cj-example__summary")], caption)
}

private func appendExamplePair(w: HtmlWriter, children: ReadOnlyList<MarkdownNode>, start: Int64,
    output: Int64, assets: HashMap<String, String>, rootPrefix: String, context: HtmlMarkdownContext,
    standalone!: Bool = false): Unit {
    let layout = exampleLayout(children[output])
    let className = "cj-example-pair cj-example-pair--${layout}"
    if (standalone) {
        openExampleDisclosure(w, className) { summary =>
            summary.text(label(context.locale, "Example", "示例"))
        }
    } else { w.open("div", attrs: [htmlClass(className)]) }
    w.open("div", attrs: [htmlClass("cj-example-pair__panels")])
    w.open("div", attrs: [htmlClass("cj-example-pair__code")])
    for (index in start..output) {
        let child = children[index]
        if (isExampleOutputCaption(child)) { continue }
        if (isExampleCode(child)) {
            w.open("div", attrs: [htmlAttr("data-cjdoc-copy-panel", "code")])
            appendExampleToolbar(w, "Cangjie")
            appendMarkdownNodeHtml(w, child, assets, rootPrefix, context)
            w.close("div")
        } else {
            appendMarkdownNodeHtml(w, child, assets, rootPrefix, context)
        }
    }
    w.close("div")
    appendExampleOutput(w, children[output].literal, context.locale)
    w.close("div")
    w.close(if (standalone) { "details" } else { "div" })
    w.newline()
}

private func appendExampleToolbar(w: HtmlWriter, caption: String): Unit {
    w.element("div", [htmlClass("cj-example-pair__bar"), htmlFlag("data-cjdoc-copy-toolbar")]) { bar =>
        bar.textElement("span", caption)
    }
}

private func exampleOutputLineCount(value: String): Int64 {
    var lines: Int64 = 1
    // A terminating newline belongs to the last line, not to an additional line.
    for (index in 0..value.size - 1) {
        if (value[index] == b'\n') { lines++ }
    }
    lines
}

private func appendExampleOutput(w: HtmlWriter, value: String, locale: String): Unit {
    w.open("div", attrs: [htmlClass("cj-example-pair__output"), htmlAttr("data-cjdoc-copy-panel", "output")])
    appendExampleToolbar(w, label(locale, "Expected output", "预期输出"))
    if (value.isEmpty()) {
        w.textElement("p", label(locale, "No standard output expected.", "预期无标准输出。"),
            attrs: [htmlClass("cj-example-pair__empty")])
    } else {
        let lines = exampleOutputLineCount(value)
        let collapse = lines > EXAMPLE_COLLAPSED_OUTPUT_LINES
        if (collapse) {
            w.open("details", attrs: [htmlClass("cj-example-pair__disclosure")])
            w.element("summary", []) { summary =>
                summary.textElement("span", label(locale, "Show all ${lines} lines", "展开全部 ${lines} 行"),
                    attrs: [htmlClass("cj-example-pair__expand")])
                summary.textElement("span", label(locale, "Hide output", "收起输出"),
                    attrs: [htmlClass("cj-example-pair__collapse")])
            }
        }
        appendCodeBlockHtml(w, value, codeBlockAttrs(value, ""), None, output: true)
        if (collapse) { w.close("details") }
    }
    w.close("div")
}
