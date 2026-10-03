package cjdoc

import cjdoc.model.*
import cjdoc.render as public_render
import std.collection.*

private func conceptualLinkedSource(source: String, destination: String): ?String {
    if (destination.isEmpty() || destination.startsWith("/") || destination.contains(":") ||
        destination.contains("\\") || destination.contains("?") || destination.contains("%")) { return None }
    let segments = ArrayList<String>()
    let parent = source.split("/")
    if (parent.size > 1) {
        for (index in 0..(parent.size - 1)) { segments.add(parent[index]) }
    }
    for (part in destination.split("/")) {
        if (part.isEmpty() || part == ".") { continue }
        if (part == "..") {
            if (segments.isEmpty()) { return None }
            segments.remove(at: segments.size - 1)
        } else {
            segments.add(part)
        }
    }
    let out = StringBuilder()
    for (part in segments) {
        if (!out.toString().isEmpty()) { out.append("/") }
        out.append(part)
    }
    Some(out.toString())
}

private func conceptualLinkDestination(destination: String, page: ConceptualPage,
    pages: ArrayList<ConceptualPage>): String {
    let parts = destination.split("#", 2)
    let source = match (conceptualLinkedSource(page.source, parts[0])) {
        case Some(value) => value
        case None => return destination
    }
    var target: ?ConceptualPage = None
    for (candidate in pages) {
        if (candidate.source != source) { continue }
        // One source may intentionally be published at multiple routes. Such
        // an ambiguous source link must not silently select the first route.
        if (target.isSome()) { return destination }
        target = Some(candidate)
    }
    let selected = match (target) {
        case Some(value) => value
        case None => return destination
    }
    var fragment = ""
    if (parts.size == 2) {
        fragment = match (public_render.standaloneMarkdownFragment(
            parseStandaloneMarkdown(selected.markdown), "#" + parts[1])) {
            case Some(value) => value
            case None => return destination
        }
    }
    var prefix = ""
    for (_ in 1..page.route.split("/").size) { prefix += "../" }
    prefix + selected.route + fragment
}

internal func conceptualSourceLinks(node: MarkdownNode, page: ConceptualPage,
    pages: ArrayList<ConceptualPage>): HashMap<String, String> {
    let links = HashMap<String, String>()
    if (node.kind == "link") {
        let target = conceptualLinkDestination(node.literal, page, pages)
        if (target != node.literal) { links[node.literal] = target }
    }
    for (child in node.children) {
        for ((source, target) in conceptualSourceLinks(child, page, pages)) {
            links[source] = target
        }
    }
    links
}
