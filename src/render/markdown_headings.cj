package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func allocateMarkdownHeadingTarget(text: String, anchorPrefix: String,
    counts: HashMap<String, Int64>, used: HashSet<String>): (String, String) {
    let base = markdownFragmentSlug(text)
    var occurrence = counts.get(base).getOrDefault({ => 0 })
    var slug = if (occurrence == 0) { base } else { "${base}-${occurrence}" }
    while (used.contains("${anchorPrefix}--doc-${slug}")) {
        occurrence++
        slug = "${base}-${occurrence}"
    }
    counts[base] = occurrence + 1
    let target = "${anchorPrefix}--doc-${slug}"
    let _ = used.add(target)
    (slug, target)
}

internal class MarkdownOutputHeadingContext {
    let headingIds = ArrayList<String>()
    let fragmentTargets = HashMap<String, String>()
    var nextHeading: Int64 = 0
}

private func markdownNeedsHeadingContext(node: MarkdownNode, headingBase: Int64,
    namespaceHeadings: Bool): Bool {
    if (node.kind == "heading" && (namespaceHeadings ||
        markdownRequestedHeadingLevel(node, headingBase) > 6)) {
        return true
    }
    for (child in node.children) {
        if (markdownNeedsHeadingContext(child, headingBase, namespaceHeadings)) { return true }
    }
    false
}

private func collectMarkdownOutputHeadings(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, used: HashSet<String>,
    context: MarkdownOutputHeadingContext): Unit {
    if (node.kind == "heading") {
        let (slug, target) = allocateMarkdownHeadingTarget(markdownNodeText(node), anchorPrefix,
            counts, used)
        context.headingIds.add(target)
        context.fragmentTargets["#${slug}"] = "#${target}"
    }
    for (child in node.children) {
        collectMarkdownOutputHeadings(child, anchorPrefix, counts, used, context)
    }
}

internal func markdownOutputHeadingContext(node: MarkdownNode, headingBase: Int64,
    anchorPrefix: String, headingOrdinal: Int64,
    namespaceHeadings!: Bool = false): ?MarkdownOutputHeadingContext {
    if (node.kind != "document" || (headingBase <= 1 && !namespaceHeadings) ||
        !markdownNeedsHeadingContext(node, headingBase, namespaceHeadings)) { return None }
    let context = MarkdownOutputHeadingContext()
    let prefix = if (headingOrdinal >= 0) { "${anchorPrefix}--tag-${headingOrdinal}" }
        else { anchorPrefix }
    collectMarkdownOutputHeadings(node, prefix, HashMap<String, Int64>(),
        HashSet<String>(), context)
    Some(context)
}

// Localized summary and description are emitted separately but share authored fragments.
internal func markdownDescriptionHeadingContext(comment: DocComment, headingBase: Int64,
    anchorPrefix: String): ?MarkdownOutputHeadingContext {
    if (headingBase <= 1) { return None }
    var hasOverflow = false
    for (tag in comment.tags where tag.name == "summary" || tag.name == "description") {
        if (let Some(tree) <- tag.descriptionMarkdown) {
            if (tree.kind == "document" && markdownNeedsHeadingContext(tree, headingBase, false)) {
                hasOverflow = true
                break
            }
        }
    }
    if (!hasOverflow) { return None }
    let context = MarkdownOutputHeadingContext()
    let counts = HashMap<String, Int64>()
    let used = HashSet<String>()
    for (tag in comment.tags where tag.name == "summary" || tag.name == "description") {
        if (let Some(tree) <- tag.descriptionMarkdown) {
            collectMarkdownOutputHeadings(tree, anchorPrefix, counts, used, context)
        }
    }
    Some(context)
}

internal func markdownHeadingFragmentLinks(context: MarkdownOutputHeadingContext,
    capturedLinks: ?HashMap<String, String>): HashMap<String, String> {
    if (capturedLinks.isNone()) { return context.fragmentTargets }
    let links = HashMap<String, String>()
    if (let Some(captured) <- capturedLinks) {
        for ((source, destination) in captured) { links[source] = destination }
    }
    for ((source, target) in context.fragmentTargets) { links[source] = target }
    links
}
