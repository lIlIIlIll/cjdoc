package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendReverseTypeUsages(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, typeLinkIndex: HtmlTypeLinkIndex,
    symbol: SymbolDoc, rootPrefix: String, locale: String): Unit {
    let usages = typeLinkIndex.reverseUsages(symbol.id)
    if (usages.isEmpty()) { return }
    out.append("<section class=\"reverse-type-usages\"><h2>${label(locale, "Used by", "使用于")}</h2><ul>")
    for (usage in usages) {
        out.append("<li><a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, usage.source))}\"><code>${escapeHtml(usage.source.qualifiedName)}</code></a> <span class=\"badge\">${escapeHtml(usage.kind)}</span></li>")
    }
    out.append("</ul></section>")
}

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", includeSummary!: Bool = true): Unit {
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
            out.append("<dt>${escapeHtml(relationship.kind)}</dt><dd>")
            match (typeLinkIndex.targetUrl(relationship.target)) {
                case Some(url) => out.append("<a href=\"${rootPrefix}${escapeHtml(url)}\"><code>${escapeHtml(relationship.target.spelling)}</code></a>")
                case None => out.append("<code>${escapeHtml(relationship.target.spelling)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(relationship.target.semantic.state)}</span></dd>")
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
    out.append("<p class=\"meta\">Symbol ID: <code>${escapeHtml(symbol.id)}</code></p></details>")
    appendReverseTypeUsages(out, index, typeLinkIndex, symbol, rootPrefix, locale)
    if (includeSummary) {
        match (symbol.documentation) {
            case Some(comment) => appendSummaryHtml(out, comment, symbol, assetLookup, rootPrefix)
            case None => ()
        }
    }
    out.append("<h2 class=\"signature-heading\">${label(locale, "Signature", "签名")}</h2><pre class=\"signature-block\"><code>")
    appendLinkedSignatureHtml(out, symbol, typeLinkIndex, rootPrefix)
    out.append("</code></pre></div>\n")
}

