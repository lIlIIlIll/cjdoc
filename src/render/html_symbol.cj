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

internal func appendDeclarationMetadata(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en"): Unit {
    out.append("<details class=\"declaration-metadata\"><summary>${label(locale, "Declaration metadata", "声明元数据")}</summary><p class=\"meta\"><span class=\"badge\" data-state=\"${escapeHtml(symbol.semantic.state)}\">${label(locale, "Semantic information", "语义信息")}: ${escapeHtml(htmlStateLabel(symbol.semantic.state, locale))}</span>")
    match (symbol.ownerId) {
        case Some(ownerId) => match (findSymbol(index, ownerId)) {
            case Some(owner) => out.append(" ${label(locale, "Owner", "所属类型")}: <a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, owner))}\"><code>${escapeHtml(owner.qualifiedName)}</code></a> ·")
            case None => out.append(" ${label(locale, "Owner", "所属类型")}: <code>${escapeHtml(ownerId)}</code> ·")
        }
        case None => ()
    }
    out.append(" <code>${escapeHtml(symbol.source.path)}:${symbol.source.start.line}:${symbol.source.start.column}</code></p>\n")
    out.append("<p class=\"meta\">${label(locale, "Kind", "类别")}: ${escapeHtml(htmlKindLabel(symbol.kind, locale))} · ${label(locale, "Visibility", "可见性")}: <code>${escapeHtml(symbol.visibility)}</code></p>")
    if (symbol.sourceApiSignature.state == "unavailable") {
        out.append("<p class=\"signature-context\">${label(locale, "Source signature tokens unavailable; showing the recorded declaration.", "源码签名词元未提供；显示记录的声明原文。")}</p>")
    }
    if (!symbol.genericParameters.isEmpty()) {
        out.append("<p class=\"meta\">${label(locale, "Generic parameters", "泛型参数")}: ")
        var first = true
        for (parameter in symbol.genericParameters) {
            if (!first) { out.append(", ") }; first = false
            out.append("<code>${escapeHtml(parameter)}</code>")
        }
        out.append("</p>\n")
    }
    if (!symbol.annotations.isEmpty()) {
        out.append("<p class=\"meta\">${label(locale, "Annotations", "注解")}: ")
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
            out.append("<dt>${escapeHtml(htmlKindLabel(relationship.kind, locale))}</dt><dd>")
            match (typeLinkIndex.targetUrl(relationship.target)) {
                case Some(url) => out.append("<a href=\"${rootPrefix}${escapeHtml(url)}\"><code>${escapeHtml(relationship.target.spelling)}</code></a>")
                case None => out.append("<code>${escapeHtml(relationship.target.spelling)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.target.semantic.state)}\">${escapeHtml(htmlStateLabel(relationship.target.semantic.state, locale))}</span></dd>")
        }
        for (relationship in symbol.symbolRelationships) {
            out.append("<dt>${escapeHtml(htmlKindLabel(relationship.kind, locale))}</dt><dd>")
            match (relationship.targetSymbolId) {
                case Some(targetId) => match (findSymbol(index, targetId)) {
                    case Some(target) =>
                        out.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                    case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
                }
                case None => out.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
            }
            out.append(" <span class=\"badge\" data-state=\"${escapeHtml(relationship.state)}\">${escapeHtml(htmlStateLabel(relationship.state, locale))}</span></dd>")
        }
        out.append("</dl>\n")
    }
    out.append("<p class=\"meta\">${label(locale, "Symbol ID", "符号标识")}: <code>${escapeHtml(symbol.id)}</code></p></details>")
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
