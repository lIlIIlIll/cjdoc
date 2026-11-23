protected package cjdoc.render.routes

import cjdoc.model.MarkdownNode
import cjdoc.render.foundation.{RenderTextBuffer, markdownNodeText}
import std.collection.*

protected func markdownFragmentSlug(value: String): String {
    let out = RenderTextBuffer()
    var pendingDash = false
    var wrote = false
    for (rune in value.runes()) {
        let code = UInt32(rune)
        if (code == 0x20u32 || code == 0x09u32 || code == 0x0Au32 || code == 0x0Du32) {
            pendingDash = wrote
            continue
        }
        let keep = (code >= 0x30u32 && code <= 0x39u32) ||
            (code >= 0x41u32 && code <= 0x5Au32) ||
            (code >= 0x61u32 && code <= 0x7Au32) || code == 0x2Du32 || code == 0x5Fu32 ||
            code >= 0x80u32
        if (!keep) { continue }
        if (pendingDash) { out.append("-"); pendingDash = false }
        if (code >= 0x41u32 && code <= 0x5Au32) {
            out.append(String.fromUtf8([UInt8(code + 0x20u32)]))
        } else {
            out.append(rune)
        }
        wrote = true
    }
    let slug = out.toString()
    if (slug.isEmpty()) { "section" } else { slug }
}

protected func allocateMarkdownHeadingTarget(text: String, anchorPrefix: String,
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

protected func collectMarkdownHeadingTargets(node: MarkdownNode, anchorPrefix: String,
    counts: HashMap<String, Int64>, used: HashSet<String>, ids: ArrayList<String>,
    fragments: HashMap<String, String>): Unit {
    if (node.kind == "heading") {
        let (slug, target) = allocateMarkdownHeadingTarget(markdownNodeText(node), anchorPrefix, counts, used)
        ids.add(target)
        fragments["#${slug}"] = target
    }
    for (child in node.children) { collectMarkdownHeadingTargets(child, anchorPrefix, counts, used, ids, fragments) }
}

/** Explicit mappings are checked against headings actually present in the tree. */
public func documentationSectionAnchor(tree: MarkdownNode, anchor: String): ?String {
    let ids = ArrayList<String>()
    let fragments = HashMap<String, String>()
    collectMarkdownHeadingTargets(tree, "standalone", HashMap<String, Int64>(), HashSet<String>(), ids, fragments)
    if (ids.contains(anchor)) { return Some(anchor) }
    fragments.get("#" + anchor)
}
