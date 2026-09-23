package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    locale!: String = "en"): Unit {
    out.append("<div class=\"symbol-meta\"><p class=\"meta\"><span class=\"badge\">${escapeHtml(symbol.kind)}</span>")
    out.append("<span class=\"badge\">${escapeHtml(symbol.visibility)}</span>")
    out.append("</p><details class=\"declaration-metadata\"><summary>${label(locale, "Declaration metadata", "声明元数据")}</summary><p class=\"meta\"><span class=\"badge\" data-state=\"${escapeHtml(symbol.semantic.state)}\">semantic: ${escapeHtml(symbol.semantic.state)}</span>")
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => out.append(" Owner: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a> ·")
            case None => out.append(" Owner: <code>${escapeHtml(ownerId)}</code> ·")
        }
        case None => ()
    }
    out.append(" <code>${escapeHtml(symbol.source.path)}:${symbol.source.start.line}:${symbol.source.start.column}</code></p>\n")
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<p class=\"meta\">Generic parameters: ")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append("<code>${escapeHtml(parameter)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.annotations.isEmpty()) {
        out.append("<p class=\"meta\">Annotations: ")
        var first = true
        for (annotation in symbol.annotations) {
            if (!first) { out.append(" ") }; first = false
            out.append("<code>${escapeHtml(annotation.spelling)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.typeRelationships.isEmpty() || !symbol.symbolRelationships.isEmpty()) {
        out.append("<dl class=\"relationships\">")
        for (relationship in symbol.typeRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd><code>${escapeHtml(relationship.target.spelling)}</code> <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span></dd>")
        }
        for (relationship in symbol.symbolRelationships) {
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (findSymbol(index, targetId)) {
                    case Some(target) =>
                        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.state)}\">${escapeHtml(relationship.state)}</span></dd>")
        }
        out.append("</dl>\n")
    }
    out.append("<p class=\"meta\">Symbol ID: <code>${escapeHtml(symbol.id)}</code></p></details></div><p class=\"signature-heading\">${label(locale, "Signature", "签名")}</p><pre class=\"signature-block\"><code>${escapeHtml(symbol.headerSpelling)}</code></pre>\n")
}

