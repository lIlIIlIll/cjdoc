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

private func admonitionIcon(level: String): String {
    let shape = match (level) {
        case "warning" => "<path d=\"M12 3 22 21H2Z\"/><path d=\"M12 9v5m0 3v.1\"/>"
        case "danger" => "<path d=\"M8 2h8l6 6v8l-6 6H8l-6-6V8Z\"/><path d=\"M12 7v7m0 3v.1\"/>"
        case _ => "<circle cx=\"12\" cy=\"12\" r=\"10\"/><path d=\"M12 11v6m0-10v.1\"/>"
    }
    "<svg viewBox=\"0 0 24 24\" width=\"18\" height=\"18\" fill=\"none\" stroke=\"currentColor\" " +
        "stroke-width=\"1.75\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\" focusable=\"false\">" +
        shape + "</svg>"
}

/** Render only an already captured block; malformed nodes degrade to their safe children. */
internal func appendAdmonitionHtml(out: RenderTextBuffer, node: MarkdownNode,
    assetLookup: HashMap<String, String>, rootPrefix: String,
    context: HtmlMarkdownContext): Unit {
    match (capturedAdmonitionLevel(node)) {
        case Some(level) =>
            let label = admonitionUiLabel(level, context.locale)
            out.append("<aside class=\"admonition admonition-${level}\" data-admonition-level=\"${level}\" aria-label=\"${escapeHtml(label)}\">\n")
            out.append("<div class=\"admonition-heading\"><span class=\"admonition-icon\" aria-hidden=\"true\">${admonitionIcon(level)}</span><span class=\"admonition-title\">${escapeHtml(label)}</span></div>\n")
            out.append("<div class=\"admonition-body\">\n")
            for (child in node.children) {
                appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
            }
            out.append("</div>\n</aside>\n")
        case None => for (child in node.children) {
            appendMarkdownNodeHtml(out, child, assetLookup, rootPrefix, context)
        }
    }
}

/** Add captured independent admonition tags after the introduction, without reparsing source text. */
internal func appendDocumentationAdmonitionsHtml(out: RenderTextBuffer,
    comment: DocComment, locale: String, assetLookup: HashMap<String, String>,
    rootPrefix: String, context: HtmlMarkdownContext): Unit {
    for (tag in comment.tags) {
        if (!isAdmonitionLevel(tag.name)) { continue }
        match (tag.descriptionMarkdown) {
            case Some(markdown) =>
                if (capturedAdmonitionTreeContains(markdown, tag.name)) {
                    appendDocumentationTagHtml(out, tag, locale, assetLookup, rootPrefix, context)
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
internal func appendAdmonitionRiskBadges(out: RenderTextBuffer, symbol: SymbolDoc,
    locale: String): Unit {
    match (symbol.documentation) {
        case Some(comment) =>
            let danger = commentHasAdmonitionLevel(comment, "danger")
            let warning = commentHasAdmonitionLevel(comment, "warning")
            if (!danger && !warning) { return }
            out.append("<span class=\"admonition-risk-badges\">")
            if (danger) {
                out.append("<span class=\"admonition-risk-badge admonition-risk-danger\" data-admonition-level=\"danger\">${admonitionIcon("danger")} ${escapeHtml(admonitionUiLabel("danger", locale))}</span>")
            }
            if (warning) {
                out.append("<span class=\"admonition-risk-badge admonition-risk-warning\" data-admonition-level=\"warning\">${admonitionIcon("warning")} ${escapeHtml(admonitionUiLabel("warning", locale))}</span>")
            }
            out.append("</span>")
        case None => ()
    }
}
