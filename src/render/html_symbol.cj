package cjdoc.render

import cjdoc.model.*
import std.collection.*

internal func appendReverseTypeUsages(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, typeLinkIndex: HtmlTypeLinkIndex,
    symbol: SymbolDoc, rootPrefix: String, locale: String): Unit {
    let usages = typeLinkIndex.reverseUsages(symbol.id)
    if (usages.isEmpty()) { return }
    w.open("details", attrs: [htmlClass("cj-usages cj-disclosure")])
    w.textElement("summary", label(locale, "Used by", "使用于") + " · " + usages.size.toString(),
        attrs: [htmlClass("cj-disclosure__summary")])
    w.element("p", [htmlClass("cj-usages__note")], { note =>
        note.text(label(locale, "Lists declarations that reference this type and where they use it.",
            "列出引用此类型的声明及其使用位置。"))
    })
    w.element("ul", [htmlClass("cj-usages__list")], { list =>
        for (usage in usages) {
            list.element("li", [htmlClass("cj-usages__item")], { item =>
                item.open("a", attrs: [htmlHref(SafeUrl.siteRoute(
                    rootPrefix + symbolUrl(index, usage.source)))])
                item.textElement("code", usage.source.qualifiedName)
                item.close("a")
                item.text(" ")
                item.textElement("span", reverseTypeUsageLabel(usage.kind, locale),
                    attrs: [htmlClass("cj-badge")])
            })
        }
    })
    w.close("details")
}

// The public reference is a reader surface, not a dump of compiler/provider
// metadata. Keep raw identities, source locations and resolution provenance in
// Doc IR and diagnostics outputs. Only API relationships belong on this page.
private func appendRelationshipUncertainty(w: HtmlWriter,
    state: String, locale: String): Unit {
    let note = match (state) {
        case "resolved" => ""
        case "ambiguous" => label(locale, "Relationship target is ambiguous", "关联目标不明确")
        case _ => label(locale, "Relationship not fully established", "关联关系尚未完全确认")
    }
    if (note.isEmpty()) { return }
    w.text(" ")
    w.textElement("span", note, attrs: [htmlClass("cj-relations__note")])
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

// A row is only suppressed when a navigation edge carries the same fact. The
// published index deliberately cannot resolve a filtered target, so a hidden
// navigation edge with the same kind and *exact* source spelling drops the
// weaker source row instead of disclosing its name.
private func typeRelationshipSuppressed(typeRelation: TypeRelationship, symbol: SymbolDoc,
    index: HashMap<String, SymbolDoc>, typeLinkIndex: HtmlTypeLinkIndex): Bool {
    for (navigation in symbol.symbolRelationships) {
        if (!readerSymbolRelationshipIsVisible(index, navigation) &&
            typeRelation.kind == navigation.kind &&
            typeLinkIndex.targetUrl(typeRelation.target).isNone() &&
            typeRelation.target.spelling.trimAscii() == navigation.targetDisplay.trimAscii()) {
            return true
        }
        if (!sameReaderRelationshipTarget(typeRelation, navigation, index, typeLinkIndex)) {
            continue
        }
        // Do not disclose a filtered target through its weaker source edge.
        if (!readerSymbolRelationshipIsVisible(index, navigation) ||
            preferReaderSymbolRelationship(typeRelation, navigation)) {
            return true
        }
    }
    false
}

private func symbolRelationshipSuperseded(relationship: SymbolRelationship,
    symbol: SymbolDoc, index: HashMap<String, SymbolDoc>,
    typeLinkIndex: HtmlTypeLinkIndex): Bool {
    for (source in symbol.typeRelationships) {
        if (sameReaderRelationshipTarget(source, relationship, index, typeLinkIndex) &&
            !preferReaderSymbolRelationship(source, relationship)) {
            return true
        }
    }
    false
}

private func appendRelationshipLabel(w: HtmlWriter, kind: String, locale: String): Unit {
    w.textElement("dt", readerRelationshipLabel(kind, locale),
        attrs: [htmlClass("cj-relations__term")])
    w.open("dd", attrs: [htmlClass("cj-relations__value")])
}

private func appendTypeRelationshipRows(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, rootPrefix: String, typeLinkIndex: HtmlTypeLinkIndex,
    locale: String): Unit {
    for (relationship in symbol.typeRelationships) {
        if (typeRelationshipSuppressed(relationship, symbol, index, typeLinkIndex)) { continue }
        appendRelationshipLabel(w, relationship.kind, locale)
        appendTypeRefCodeHtml(w, relationship.target, typeLinkIndex, rootPrefix, locale)
        appendRelationshipUncertainty(w, relationship.target.semantic.state, locale)
        w.close("dd")
    }
}

private func appendSymbolRelationshipRows(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    symbol: SymbolDoc, rootPrefix: String, typeLinkIndex: HtmlTypeLinkIndex,
    locale: String): Unit {
    for (relationship in symbol.symbolRelationships) {
        if (!readerSymbolRelationshipIsVisible(index, relationship)) { continue }
        if (symbolRelationshipSuperseded(relationship, symbol, index, typeLinkIndex)) { continue }
        appendRelationshipLabel(w, relationship.kind, locale)
        appendSymbolRelationshipTarget(w, index, relationship, rootPrefix)
        appendRelationshipUncertainty(w, relationship.state, locale)
        w.close("dd")
    }
}

private func appendSymbolRelationshipTarget(w: HtmlWriter, index: HashMap<String, SymbolDoc>,
    relationship: SymbolRelationship, rootPrefix: String): Unit {
    let isExtensionTarget = relationship.kind == "extensionTarget"
    let display = if (isExtensionTarget) {
        genericTypeDisplaySpelling(relationship.targetDisplay)
    } else { relationship.targetDisplay }
    match (relationship.targetSymbolId) {
        case Some(targetId) => match (findSymbol(index, targetId)) {
            case Some(target) =>
                let cssClass = if (isExtensionTarget) {
                    "cj-type-link cj-relations__target"
                } else { "cj-type-link" }
                w.open("a", attrs: [htmlClass(cssClass),
                    htmlHref(SafeUrl.siteRoute(rootPrefix + symbolUrl(index, target)))])
                w.textElement("code", display)
                w.close("a")
            // The visibility check above already discarded filtered targets.
            case None => ()
        }
        case None => w.textElement("code", display)
    }
}

internal func appendReaderRelationships(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    typeLinkIndex: HtmlTypeLinkIndex, locale: String,
    headingTag!: String = "h2"): Unit {
    // Rows are captured first so a symbol without reader-visible relationships
    // renders no empty section and no heading.
    let rows = TrustedHtml.capture({ captured =>
        appendTypeRelationshipRows(captured, index, symbol, rootPrefix, typeLinkIndex, locale)
        appendSymbolRelationshipRows(captured, index, symbol, rootPrefix, typeLinkIndex, locale)
    })
    if (rows.value.isEmpty()) { return }
    w.open("section", attrs: [htmlClass("cj-relations"),
        htmlAttr("aria-label", label(locale, "Type and member relationships", "类型与成员关系"))])
    w.textElement(headingTag, label(locale, "Relationships", "关联关系"),
        attrs: [htmlClass("cj-relations__title")])
    w.open("dl", attrs: [htmlClass("cj-relations__list")])
    w.trusted(rows)
    w.close("dl")
    w.close("section")
    w.newline()
}

internal func appendSymbolMetadata(w: HtmlWriter,
    index: HashMap<String, SymbolDoc>, symbol: SymbolDoc, rootPrefix: String,
    assetLookup: HashMap<String, String>, typeLinkIndex: HtmlTypeLinkIndex,
    locale!: String = "en", includeSummary!: Bool = true,
    pagePresentation!: Bool = false): Unit {
    w.open("div", attrs: [htmlClass("cj-symbol-meta")])
    if (includeSummary) {
        match (symbol.documentation) {
            case Some(comment) => appendSummaryHtml(w, comment, symbol, assetLookup, rootPrefix,
                locale: locale)
            case None => ()
        }
    }
    if (pagePresentation) {
        w.open("span", attrs: [htmlAttr("id", "declaration"), htmlClass("cj-anchor-alias")])
        w.close("span")
    }
    w.open("pre", attrs: [htmlClass("cj-signature"),
        htmlAttr("aria-label", label(locale, "Signature", "签名"))])
    w.open("code", attrs: [codeSourceAttr(symbol.headerSpelling)])
    appendLinkedSignatureHtml(w, symbol, typeLinkIndex, rootPrefix)
    w.close("code")
    w.close("pre")
    w.close("div")
    w.newline()
}
