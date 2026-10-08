package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendReverseTypeUsages(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, typeLinkIndex: HtmlTypeLinkIndex,
    symbol: SymbolDoc, rootPrefix: String, locale: String): Unit {
    let usages = typeLinkIndex.reverseUsages(symbol.id)
    if (usages.isEmpty()) { return }
    out.append("<details class=\"reverse-type-usages\"><summary>${label(locale, "Used by", "使用于")} · ${usages.size}</summary><ul>")
    for (usage in usages) {
        out.append("<li><a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, usage.source))}\"><code>${escapeHtml(usage.source.qualifiedName)}</code></a> <span class=\"badge\">${escapeHtml(htmlKindLabel(usage.kind, locale))}</span></li>")
    }
    out.append("</ul></details>")
}

// The public reference is a reader surface, not a dump of compiler/provider
// metadata. Keep raw identities, source locations and resolution provenance in
// Doc IR and diagnostics outputs. Only API relationships belong on this page.
private func appendRelationshipUncertainty(out: RenderTextBuffer,
    state: String, locale: String): Unit {
    match (state) {
        case "resolved" => ()
        case "ambiguous" => out.append(" <span class=\"relation-note\">${label(locale, "Relationship target is ambiguous", "关联目标不明确")}</span>")
        case _ => out.append(" <span class=\"relation-note\">${label(locale, "Relationship not fully established", "关联关系尚未完全确认")}</span>")
    }
}

internal func appendReaderRelationships(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    headingTag!: String = "h2"): Unit {
    if (symbol.typeRelationships.isEmpty() && symbol.symbolRelationships.isEmpty()) { return }
    out.append("<section class=\"symbol-relationships\" aria-label=\"${label(locale, "Type and member relationships", "类型与成员关系")}\">")
    out.append("<${headingTag}>${label(locale, "Relationships", "关联关系")}</${headingTag}><dl>")
    for (relationship in symbol.typeRelationships) {
        out.append("<dt>${escapeHtml(htmlKindLabel(relationship.kind, locale))}</dt><dd>")
        appendTypeRefCodeHtml(out, relationship.target, typeLinkIndex, rootPrefix, locale)
        appendRelationshipUncertainty(out, relationship.target.semantic.state, locale)
        out.append("</dd>")
    }
    for (relationship in symbol.symbolRelationships) {
        out.append("<dt>${escapeHtml(htmlKindLabel(relationship.kind, locale))}</dt><dd>")
        match (relationship.targetSymbolId) {
            case Some(targetId) => match (findSymbol(index, targetId)) {
                case Some(target) => out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                // A filtered target must not leak through a relation's display text.
                case None => out.append("${label(locale, "Target not present in this documentation", "目标未包含在当前文档中")}")
            }
            case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
        }
        appendRelationshipUncertainty(out, relationship.state, locale)
        out.append("</dd>")
    }
    out.append("</dl></section>\n")
}

internal func appendSymbolMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", includeSummary!: Bool = true): Unit {
    out.append("<div class=\"symbol-meta\">")
    if (includeSummary) {
        match (symbol.documentation) {
            case Some(comment) => appendSummaryHtml(out, comment, symbol, assetLookup, rootPrefix)
            case None => ()
        }
    }
    out.append("<pre class=\"signature-block\" aria-label=\"${label(locale, "Signature", "签名")}\"><code>")
    appendLinkedSignatureHtml(out, symbol, typeLinkIndex, rootPrefix)
    out.append("</code></pre></div>\n")
}
