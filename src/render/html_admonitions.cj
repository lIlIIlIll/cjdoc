package cjdoc.render

import cjdoc.model.*
import std.collection.*

/** Returns a level only for a structurally usable captured admonition node. */
internal func capturedAdmonitionLevel(node: MarkdownNode): ?String {
    if (node.kind != "admonition" || !node.literal.isEmpty() || node.children.isEmpty()) {
        return None
    }
    match (node.metadata) {
        case Some(metadata) =>
            if (metadata.kind == "admonition") {
                match (metadata.admonitionLevel) {
                    case Some(level) => if (isAdmonitionLevel(level)) { Some(level) } else { None }
                    case None => None
                }
            } else { None }
        case None => None
    }
}

internal func capturedAdmonitionTreeContains(node: MarkdownNode, level: String): Bool {
    if (capturedAdmonitionLevel(node) == Some(level)) { return true }
    for (child in node.children) {
        if (capturedAdmonitionTreeContains(child, level)) { return true }
    }
    false
}

internal func capturedAdmonitionMarkdownMarker(level: String): ?String {
    match (level) {
        case "note" => Some("NOTE")
        case "warning" => Some("WARNING")
        case "danger" => Some("CAUTION")
        case _ => None
    }
}

private func admonitionUiLabel(level: String, locale: String): String {
    if (locale == "zh-CN") {
        match (level) {
            case "note" => "注意"
            case "warning" => "警告"
            case "danger" => "危险"
            case _ => "提示"
        }
    } else {
        match (level) {
            case "note" => "Note"
            case "warning" => "Warning"
            case "danger" => "Danger"
            case _ => "Admonition"
        }
    }
}

/** Render only an already captured block; malformed nodes degrade to their safe children. */
internal func appendAdmonitionHtml(w: HtmlWriter, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    match (capturedAdmonitionLevel(node)) {
        case Some(level) =>
            let title = admonitionUiLabel(level, context.locale)
            w.open("aside", attrs: [htmlClass("cj-admonition cj-admonition--" + level),
                htmlAttr("data-admonition-level", level), htmlAttr("aria-label", title)])
            w.element("div", [htmlClass("cj-admonition__head")]) { head =>
                head.element("span", [htmlClass("cj-admonition__icon"),
                    htmlAttr("aria-hidden", "true")]) { holder => holder.icon(level) }
                head.textElement("span", title, attrs: [htmlClass("cj-admonition__title")])
            }
            w.element("div", [htmlClass("cj-admonition__body cj-prose")]) { body =>
                for (child in node.children) {
                    appendMarkdownNodeHtml(body, child, assetLookup, rootPrefix, context)
                }
            }
            w.close("aside")
        case None => for (child in node.children) {
            appendMarkdownNodeHtml(w, child, assetLookup, rootPrefix, context)
        }
    }
}

/** Add captured independent admonition tags after the introduction, without reparsing source text. */
internal func appendDocumentationAdmonitionsHtml(w: HtmlWriter,
    comment: DocComment, locale: String, assetLookup: HashMap<String, String>,
    rootPrefix: String, context: HtmlMarkdownContext): Unit {
    for (tag in comment.tags) {
        if (!isAdmonitionLevel(tag.name)) { continue }
        match (tag.descriptionMarkdown) {
            case Some(markdown) =>
                if (capturedAdmonitionTreeContains(markdown, tag.name)) {
                    appendDocumentationTagHtml(w, tag, locale, assetLookup, rootPrefix, context)
                }
            case None => ()
        }
    }
}

private func commentHasAdmonitionLevel(comment: DocComment, level: String): Bool {
    if (capturedAdmonitionTreeContains(comment.markdown, level)) { return true }
    for (tag in comment.tags) {
        if (tag.name != level) { continue }
        match (tag.descriptionMarkdown) {
            case Some(markdown) => if (capturedAdmonitionTreeContains(markdown, level)) { return true }
            case None => ()
        }
    }
    false
}

/** Compact, always-visible risk markers for collapsed member details. */
internal func appendAdmonitionRiskBadges(w: HtmlWriter, symbol: SymbolDoc,
    locale: String): Unit {
    let comment = match (symbol.documentation) {
        case Some(value) => value
        case None => return
    }
    let danger = commentHasAdmonitionLevel(comment, "danger")
    let warning = commentHasAdmonitionLevel(comment, "warning")
    if (!danger && !warning) { return }
    w.open("span", attrs: [htmlClass("cj-risks")])
    if (danger) { appendAdmonitionRiskBadge(w, "danger", locale) }
    if (warning) { appendAdmonitionRiskBadge(w, "warning", locale) }
    w.close("span")
}

private func appendAdmonitionRiskBadge(w: HtmlWriter, level: String, locale: String): Unit {
    w.open("span", attrs: [htmlClass("cj-risk cj-risk--" + level),
        htmlAttr("data-admonition-level", level)])
    w.icon(level)
    w.text(" " + admonitionUiLabel(level, locale))
    w.close("span")
}
