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

// Human-facing labels should not expose internal relation-kind spellings.
internal func readerRelationshipLabel(kind: String, locale: String): String {
    if (locale == "zh-CN") {
        if (kind == "subType") { return "子类型" }
        return htmlKindLabel(kind, locale)
    }
    match (kind) {
        case "superType" => "Parent type"
        case "subType" => "Subtype"
        case "extensionTarget" => "Extension target"
        case "genericConstraint" => "Generic constraint"
        case "extendedBy" => "Extended by"
        case "inheritedMember" => "Inherited member"
        case "implements" => "Implements"
        case "implementedBy" => "Implemented by"
        case "override" => "Overrides"
        case "overriddenBy" => "Overridden by"
        case "overrides" => "Overrides"
        case "inherits" => "Inherits"
        case _ => htmlKindLabel(kind, locale)
    }
}

// The source records the type spelling; navigation may independently attach a
// resolved SymbolId to the same edge. Compare identities when both are known,
// falling back to *exact* source spelling only for an unresolved TypeRef.
// Different kinds and distinct resolved targets must remain separate rows.
private func sameReaderRelationshipTarget(typeRelation: TypeRelationship,
    symbolRelation: SymbolRelationship, index: HashMap<String, SymbolDoc>,
    typeLinkIndex: HtmlTypeLinkIndex): Bool {
    if (typeRelation.kind != symbolRelation.kind) { return false }
    let typeRef = typeRelation.target
    if (typeRef.semantic.state != "resolved") {
        return typeRef.spelling.trimAscii() == symbolRelation.targetDisplay.trimAscii()
    }
    match (symbolRelation.targetSymbolId) {
        case Some(id) =>
            match ((typeLinkIndex.targetUrl(typeRef), typeLinkIndex.targetUrlForSymbolId(id))) {
                case (Some(left), Some(right)) => left == right
                case _ => typeLinkIndex.sameUnfilteredTarget(typeRef, id)
            }
        case None => false
    }
}

// Prefer the resolved navigation edge; otherwise preserve the source TypeRef
// whenever it carries at least as much information as the symbol edge.
private func preferReaderSymbolRelationship(typeRelation: TypeRelationship,
    symbolRelation: SymbolRelationship): Bool {
    if (symbolRelation.state == "resolved") { return true }
    if (typeRelation.target.semantic.state == "resolved") { return false }
    if (symbolRelation.state == "ambiguous") { return true }
    symbolRelation.state == "partial" && typeRelation.target.semantic.state == "unavailable"
}

private func readerSymbolRelationshipIsVisible(index: HashMap<String, SymbolDoc>,
    relationship: SymbolRelationship): Bool {
    match (relationship.targetSymbolId) {
        case Some(id) => findSymbol(index, id).isSome()
        case None => true
    }
}

internal func appendReaderRelationships(out: RenderTextBuffer,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    headingTag!: String = "h2"): Unit {
    let rows = RenderTextBuffer()
    for (relationship in symbol.typeRelationships) {
        var suppress = false
        for (navigation in symbol.symbolRelationships) {
            // The published index deliberately cannot resolve a filtered target.
            // When a hidden navigation edge has the same kind and *exact* source
            // spelling, drop the weaker source row rather than disclosing its
            // name. Do not suppress a separately resolved, visible TypeRef.
            if (!readerSymbolRelationshipIsVisible(index, navigation) &&
                relationship.kind == navigation.kind &&
                typeLinkIndex.targetUrl(relationship.target).isNone() &&
                relationship.target.spelling.trimAscii() == navigation.targetDisplay.trimAscii()) {
                suppress = true
                break
            }
            if (!sameReaderRelationshipTarget(relationship, navigation, index, typeLinkIndex)) {
                continue
            }
            // Do not disclose a filtered target through its weaker source edge.
            if (!readerSymbolRelationshipIsVisible(index, navigation) ||
                preferReaderSymbolRelationship(relationship, navigation)) {
                suppress = true
                break
            }
        }
        if (suppress) { continue }
        rows.append("<dt>${escapeHtml(readerRelationshipLabel(relationship.kind, locale))}</dt><dd>")
        appendTypeRefCodeHtml(rows, relationship.target, typeLinkIndex, rootPrefix, locale)
        appendRelationshipUncertainty(rows, relationship.target.semantic.state, locale)
        rows.append("</dd>")
    }
    for (relationship in symbol.symbolRelationships) {
        if (!readerSymbolRelationshipIsVisible(index, relationship)) { continue }
        var superseded = false
        for (source in symbol.typeRelationships) {
            if (sameReaderRelationshipTarget(source, relationship, index, typeLinkIndex) &&
                !preferReaderSymbolRelationship(source, relationship)) {
                superseded = true
                break
            }
        }
        if (superseded) { continue }
        rows.append("<dt>${escapeHtml(readerRelationshipLabel(relationship.kind, locale))}</dt><dd>")
        match (relationship.targetSymbolId) {
            case Some(targetId) => match (findSymbol(index, targetId)) {
                case Some(target) => rows.append("<a href=\"${rootPrefix}${escapeHtml(symbolUrl(index, target))}\"><code>${escapeHtml(relationship.targetDisplay)}</code></a>")
                // The visibility check above already discarded filtered targets.
                case None => ()
            }
            case None => rows.append("<code>${escapeHtml(relationship.targetDisplay)}</code>")
        }
        appendRelationshipUncertainty(rows, relationship.state, locale)
        rows.append("</dd>")
    }
    let content = rows.toString()
    if (content.isEmpty()) { return }
    out.append("<section class=\"symbol-relationships\" aria-label=\"${label(locale, "Type and member relationships", "类型与成员关系")}\">")
    out.append("<${headingTag}>${label(locale, "Relationships", "关联关系")}</${headingTag}><dl>")
    out.append(content)
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
