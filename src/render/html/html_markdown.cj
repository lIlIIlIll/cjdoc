protected package cjdoc.render.html

import cjdoc.render.foundation.escapeHtml
import cjdoc.render.reading.{
    ExampleFenceOpening, behaviorContractLabel, exampleFenceOpening, isBehaviorContractTag,
    isExampleFenceClosing, trimExampleBlankLines}
import cjdoc.render.routes.{symbolAnchor, label, collectMarkdownHeadingTargets}
import cjdoc.render.foundation.{
    RenderTextBuffer, markdownNodeText, safeLinkDestination, safeRelativeLinkDestination,
    appendHtmlEscapedValue}
import cjdoc.model.*
import std.collection.*


// Markdown block/inline dispatch lives in html_markdown_nodes.cj so this file
// stays within the repository size guidance.

internal func safeMappedRelativeLinkDestination(value: String): Bool {
    let parts = value.split("#", 2)
    var path = parts[0]
    while (path.startsWith("../")) { path = path.removePrefix("../") }
    if (path.contains("%") || !safeRelativeLinkDestination(path)) { return false }
    parts.size == 1 || safeLinkDestination("#" + parts[1])
}

/**
 * Standalone Markdown as a self-contained HTML fragment.
 *
 * This is the only HTML entry point in the renderer that still returns a String:
 * callers outside the `cjdoc.render` package cannot name `HtmlWriter`, so the
 * value is produced by capturing a writer and therefore still passes every
 * escaping and balance check. Renderer-internal callers append through
 * `appendStandaloneMarkdownHtml` instead of building a string first.
 */
public func renderStandaloneMarkdownHtml(node: MarkdownNode,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None, locale!: String = "en"): String {
    TrustedHtml.capture({ w =>
        appendStandaloneMarkdownHtml(w, node, sourceLinks: sourceLinks, pageTitle: pageTitle,
            locale: locale)
    }).value
}

internal func appendStandaloneMarkdownHtml(w: HtmlWriter, node: MarkdownNode,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None,
    sectionIds!: HashMap<String, String> = HashMap<String, String>(),
    locale!: String = "en"): Unit {
    appendStandaloneMarkdownHtmlWithAssets(w, node, HashMap<String, String>(), "",
        sourceLinks: sourceLinks, pageTitle: pageTitle, sectionIds: sectionIds, locale: locale)
}

internal func appendStandaloneMarkdownHtmlWithAssets(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
    pageTitle!: ?String = None, bindingSource!: String = "",
    bindingChips!: ?HashMap<Int64, TrustedHtml> = None, headingBase!: Int64 = 2,
    afterFirstCode!: ?TrustedHtml = None,
    sectionIds!: HashMap<String, String> = HashMap<String, String>(),
    locale!: String = "en"): Unit {
    let context = HtmlMarkdownContext(headingBase, sourceLinks: sourceLinks,
        bindingSource: bindingSource, bindingChips: bindingChips, locale: locale)
    context.sectionIds = sectionIds
    collectMarkdownHeadings(node, "standalone", HashMap<String, Int64>(), context)
    appendStandaloneDocumentHtml(w, node, context, pageTitle, assetLookup, rootPrefix,
        afterFirstCode)
}

private func appendAfterFirstCode(w: HtmlWriter, fragment: ?TrustedHtml): Unit {
    if (let Some(value) <- fragment) { w.trusted(value) }
}

// Suppress exactly the Markdown's own leading level-1 heading when the page
// shell already rendered the same title as the page <h1>. A differently titled
// or absent leading heading is untouched, and any later heading — including one
// repeating the same text — keeps the heading stream and its shareable anchor.
// The suppressed title retains its fragment so source links and section mappings
// still address the title without repeating its visible text.
private func standaloneTitleHeadingIndex(node: MarkdownNode, pageTitle: ?String): ?Int64 {
    let title = match (pageTitle) {
        case Some(value) => value
        case None => return None
    }
    for (index in 0..node.children.size) {
        let child = node.children[index]
        if (child.kind != "heading") { return None }
        let sourceLevel = match (child.metadata) {
            case Some(metadata) => match (metadata.headingLevel) {
                case Some(value) => value
                case None => 1
            }
            case None => 1
        }
        if (sourceLevel != 1) { return None }
        return if (markdownNodeText(child) == title) { Some(index) } else { None }
    }
    None
}

private func appendStandaloneDocumentHtml(w: HtmlWriter, node: MarkdownNode,
    context: HtmlMarkdownContext, pageTitle: ?String, assetLookup: HashMap<String, String>,
    rootPrefix: String, afterFirstCode: ?TrustedHtml): Unit {
    if (node.kind != "document") {
        appendMarkdownNodeHtml(w, node, assetLookup, rootPrefix, context)
        appendAfterFirstCode(w, afterFirstCode)
        return
    }
    let titleIndex = standaloneTitleHeadingIndex(node, pageTitle)
    var inserted = false
    var index: Int64 = 0
    while (index < node.children.size) {
        let child = node.children[index]
        var next = index + 1
        if (titleIndex == Some(index)) {
            let id = context.headingIds[context.nextHeading]
            context.nextHeading++
            w.open("span", attrs: anchorAttrs(id, context))
            w.close("span")
            w.newline()
        } else {
            next = appendStandaloneExampleOrNode(w, node, index, assetLookup, rootPrefix, context)
        }
        if (!inserted && child.kind == "code_block") {
            appendAfterFirstCode(w, afterFirstCode)
            inserted = true
        }
        index = next
    }
    if (!inserted) { appendAfterFirstCode(w, afterFirstCode) }
}

// `id` stays the first attribute: the captured-page producer splices a section
// identity onto these anchors by matching `id="…"` byte-for-byte.
internal func anchorAttrs(id: String, context: HtmlMarkdownContext): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>()
    attrs.add(htmlAttr("id", id))
    if (let Some(sectionId) <- context.sectionIds.get(id)) {
        attrs.add(htmlAttr("data-semantic-section", sectionId))
    }
    attrs.toArray()
}

/** Resolve a source Markdown fragment using the same heading IDs as standalone HTML. */
public func standaloneMarkdownFragment(node: MarkdownNode, fragment: String): ?String {
    let context = HtmlMarkdownContext(2)
    collectMarkdownHeadings(node, "standalone", HashMap<String, Int64>(), context)
    match (context.fragmentTargets.get(fragment)) {
        case Some(target) => Some("#" + target)
        case None => None
    }
}

public func escapeStandaloneHtml(value: String): String {
    escapeHtml(value)
}

internal func appendStructuredTextHtml(w: HtmlWriter, value: String): Unit {
    if (value.isEmpty()) { return }
    w.textElement("p", value)
    w.newline()
}

/** Code-block attributes shared by author examples and Markdown fences. */
internal func codeBlockAttrs(raw: String, language: String,
    attributesRaw!: String = ""): Array<HtmlAttr> {
    let attrs = ArrayList<HtmlAttr>()
    attrs.add(codeSourceAttr(raw))
    if (!language.isEmpty()) { attrs.add(htmlAttr("data-language", language)) }
    if (!attributesRaw.isEmpty()) {
        attrs.add(htmlAttr("data-cjdoc-attributes", attributesRaw))
    }
    attrs.toArray()
}

// Author examples and Markdown fences share one code-block structure, so the
// copy controller sees a single DOM shape everywhere.
internal func appendCodeBlockHtml(w: HtmlWriter, code: String,
    attrs: Array<HtmlAttr>, highlight: ?CodeHighlight, output!: Bool = false): Unit {
    w.element("div", [htmlClass(if (output) { "cj-code cj-code--output" } else { "cj-code" })]) { block =>
        block.element("pre", [htmlClass("cj-code__pre")]) { pre =>
            pre.open("code", attrs: attrs)
            appendHighlightedCodeHtml(pre, code, "", highlight: highlight)
            pre.close("code")
        }
    }
    w.newline()
}

private func exampleFallbackMarkdown(content: String): MarkdownNode {
    let children = ArrayList<MarkdownNode>()
    var prose = StringBuilder()
    var proseLineCount: Int64 = 0
    var code = StringBuilder()
    var codeLineCount: Int64 = 0
    var activeFence: ?ExampleFenceOpening = None
    for (line in content.split("\n")) {
        match (activeFence) {
            case Some(fence) =>
                if (isExampleFenceClosing(line, fence)) {
                    children.add(exampleFallbackCode(fence, code.toString()))
                    activeFence = None
                    code = StringBuilder()
                    codeLineCount = 0
                } else {
                    if (codeLineCount > 0) { code.append("\n") }
                    code.append(line)
                    codeLineCount++
                }
            case None =>
                match (exampleFenceOpening(line)) {
                    case Some(fence) =>
                        appendExampleFallbackProse(children, prose.toString())
                        prose = StringBuilder()
                        proseLineCount = 0
                        activeFence = Some(fence)
                    case None =>
                        if (proseLineCount > 0) { prose.append("\n") }
                        prose.append(line)
                        proseLineCount++
                }
        }
    }
    match (activeFence) {
        case Some(fence) => children.add(exampleFallbackCode(fence, code.toString()))
        case None => ()
    }
    appendExampleFallbackProse(children, prose.toString())
    MarkdownNode("document", children: children.toArray())
}

private func appendExampleFallbackProse(children: ArrayList<MarkdownNode>, prose: String): Unit {
    let text = trimExampleBlankLines(prose)
    if (!text.isEmpty()) {
        children.add(MarkdownNode("paragraph", children: [MarkdownNode("text", literal: text)]))
    }
}

private func exampleFallbackCode(fence: ExampleFenceOpening, value: String): MarkdownNode {
    let metadata = MarkdownNodeMetadata.forCodeBlock("fenced", Some(fence.marker), fence.length,
        fence.info, fence.language, "")
    MarkdownNode("code_block", metadata, literal: value)
}

// The single-kind heading is the reader's entry point, not an internal
// "behavior contracts" category followed by a redundant label. Chinese reuses
// the published label; English headings read as prose while list labels stay
// the raw tag names the author wrote.
private func behaviorContractHeading(name: String, locale: String): String {
    if (locale == "zh-CN") { return behaviorContractLabel(name, locale) }
    match (name) {
        case "precondition" => "Precondition"
        case "postcondition" => "Postcondition"
        case "invariant" => "Invariant"
        case "performance" => "Performance"
        case "state" => "State"
        case "concurrency" => "Concurrency"
        case "platform" => "Platform"
        case "compatibility" => "Compatibility"
        case "error" => "Error behavior"
        case _ => name
    }
}

private func appendIncompleteBadge(w: HtmlWriter, locale: String): Unit {
    w.textElement("span", label(locale, "incomplete", "不完整"),
        attrs: [htmlClass("cj-badge"), htmlAttr("data-state", "incomplete")])
}

protected func appendDocumentationContractsHtml(w: HtmlWriter, comment: DocComment,
    locale: String, anchor: String, assetLookup!: HashMap<String, String> = HashMap<String, String>(),
    rootPrefix!: String = "", markdownContext!: HtmlMarkdownContext = HtmlMarkdownContext(2),
    headingLevel!: Int64 = 3): Unit {
    let heading = "h${min(6, headingLevel)}"
    var contractCount: Int64 = 0
    var soleContract: ?DocTag = None
    for (tag in comment.tags) {
        if (!isBehaviorContractTag(tag.name)) { continue }
        contractCount++
        if (contractCount == 1) { soleContract = Some(tag) }
    }
    if (contractCount == 0) { return }

    // Keep the previously published heading anchor stable, including when
    // the visible heading becomes more specific.
    let headingId = anchor + "--behavior-contracts-heading"
    w.open("section", attrs: [htmlClass("cj-contracts"),
        htmlAttr("aria-labelledby", headingId)])
    if (contractCount == 1) {
        match (soleContract) {
            case Some(tag) =>
                w.textElement(heading, behaviorContractHeading(tag.name, locale),
                    attrs: [htmlAttr("id", headingId)])
                w.open("div", attrs: [htmlClass("cj-contracts--single")])
                appendSoleContractBody(w, tag, locale, assetLookup, rootPrefix, markdownContext)
                w.close("div")
            case None => ()
        }
        w.close("section")
        w.newline()
        return
    }
    w.textElement(heading, label(locale, "Behavioral constraints", "行为约束"),
        attrs: [htmlAttr("id", headingId)])
    appendContractTerms(w, comment, locale, assetLookup, rootPrefix, markdownContext)
    w.close("section")
    w.newline()
}

private func appendContractTerms(w: HtmlWriter, comment: DocComment, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext): Unit {
    w.open("dl")
    w.newline()
    for (tag in comment.tags) {
        if (!isBehaviorContractTag(tag.name)) { continue }
        w.element("dt", Array<HtmlAttr>()) { term =>
            term.textElement("code", behaviorContractLabel(tag.name, locale))
            if (!tag.subject.isEmpty()) {
                term.text(" ")
                term.textElement("code", tag.subject)
            }
        }
        w.element("dd", Array<HtmlAttr>()) { body =>
            if (tag.description.trimAscii().isEmpty()) {
                appendIncompleteBadge(body, locale)
            } else {
                appendDocumentationTagHtml(body, tag, locale, assetLookup, rootPrefix,
                    markdownContext)
            }
        }
        w.newline()
    }
    w.close("dl")
}

private func appendSoleContractBody(w: HtmlWriter, tag: DocTag, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext): Unit {
    if (!tag.subject.isEmpty()) {
        w.element("p", [htmlClass("cj-contracts__subject")]) { body =>
            body.textElement("code", tag.subject)
        }
    }
    if (tag.description.trimAscii().isEmpty()) {
        appendIncompleteBadge(w, locale)
    } else {
        appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix, markdownContext)
    }
}

internal func appendDocumentationExamplesHtml(w: HtmlWriter, comment: DocComment,
    locale: String, headingLevel!: Int64 = 3, symbol!: ?SymbolDoc = None,
    assetLookup!: HashMap<String, String> = HashMap<String, String>(), rootPrefix!: String = "",
    markdownContext!: HtmlMarkdownContext = HtmlMarkdownContext(2)): Unit {
    var hasExamples = false
    for (tag in comment.tags) { if (tag.name == "example") { hasExamples = true; break } }
    if (!hasExamples) { return }
    w.textElement("h${headingLevel}", label(locale, "Examples", "示例"))
    w.open("div", attrs: [htmlClass("cj-examples")])
    w.newline()
    var exampleIndex: Int64 = 0
    let symbolPrefix = match (symbol) { case Some(value) => symbolAnchor(value) case None => "examples" }
    for (tag in comment.tags) {
        if (tag.name != "example") { continue }
        exampleIndex++
        let title = if (tag.subject.isEmpty()) {
            label(locale, "Example ${exampleIndex}", "示例 ${exampleIndex}")
        } else { tag.subject }
        openExampleDisclosure(w, "cj-example") { summary =>
            summary.textElement("h${min(6, headingLevel + 1)}", title,
                attrs: [htmlClass("cj-example__title")])
            appendContentLanguageHtml(summary, tag, locale)
        }
        appendExampleBodyHtml(w, tag, locale, assetLookup, rootPrefix, markdownContext,
            symbolPrefix, exampleIndex)
        w.close("details")
        w.newline()
    }
    w.close("div")
    w.newline()
}

private func appendExampleBodyHtml(w: HtmlWriter, tag: DocTag, locale: String,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    markdownContext: HtmlMarkdownContext, symbolPrefix: String, exampleIndex: Int64): Unit {
    let content = trimExampleBlankLines(tag.description)
    if (content.isEmpty()) {
        w.textElement("p", label(locale, "No example content.", "示例内容为空。"),
            attrs: [htmlClass("cj-empty")])
        w.newline()
        return
    }
    match (tag.exampleMarkdown) {
        case Some(tree) =>
            // Share the enclosing heading stream, but scope source fragments to
            // this example so repeated #usage links stay local.
            let enclosingTargets = markdownContext.fragmentTargets
            markdownContext.fragmentTargets = HashMap<String, String>()
            markdownContext.nextHeading = markdownContext.headingIds.size
            collectMarkdownHeadings(tree, "${symbolPrefix}--example-${exampleIndex}",
                HashMap<String, Int64>(), markdownContext)
            appendApiExampleMarkdownHtml(w, tree, assetLookup, rootPrefix, markdownContext)
            markdownContext.fragmentTargets = enclosingTargets
        case None => appendApiExampleMarkdownHtml(w, exampleFallbackMarkdown(content),
            assetLookup, rootPrefix, markdownContext)
    }
}

protected class HtmlMarkdownContext {
    let headingBase: Int64
    let allowExternalLinks: Bool
    let headingIds = ArrayList<String>()
    var fragmentTargets = HashMap<String, String>()
    let usedHeadingSlugs = HashSet<String>()
    let sourceLinks: HashMap<String, String>
    let bindingSource: String
    let bindingChips: ?HashMap<Int64, TrustedHtml>
    let locale: String
    let fieldAnchorNamespace: String
    var nextHeading: Int64 = 0
    // Filled by the standalone page renderer; empty for symbol/field contexts.
    var sectionIds = HashMap<String, String>()

    init(headingBase: Int64, allowExternalLinks!: Bool = true,
        sourceLinks!: HashMap<String, String> = HashMap<String, String>(),
        bindingSource!: String = "", bindingChips!: ?HashMap<Int64, TrustedHtml> = None,
        locale!: String = "en", fieldAnchorNamespace!: String = "") {
        this.headingBase = headingBase
        this.allowExternalLinks = allowExternalLinks
        this.sourceLinks = sourceLinks
        this.bindingSource = bindingSource
        this.bindingChips = bindingChips
        this.locale = locale
        this.fieldAnchorNamespace = fieldAnchorNamespace
    }
}

internal func markdownHtmlContext(comment: DocComment, symbol: SymbolDoc,
    headingBase: Int64, locale!: String = "en",
    fieldAnchorNamespace!: String = ""): HtmlMarkdownContext {
    let context = HtmlMarkdownContext(headingBase, locale: locale,
        fieldAnchorNamespace: fieldAnchorNamespace)
    collectMarkdownHeadings(comment.markdown, symbolAnchor(symbol), HashMap<String, Int64>(), context)
    context
}

internal func collectMarkdownHeadings(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, context: HtmlMarkdownContext): Unit {
    collectMarkdownHeadingTargets(node, anchorPrefix, counts, context.usedHeadingSlugs,
        context.headingIds, context.fragmentTargets)
}

internal func appendMarkdownChildrenHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    for (child in node.children) {
        appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
    }
}
